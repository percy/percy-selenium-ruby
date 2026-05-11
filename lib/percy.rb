require 'uri'
require 'json'
require 'set'
require 'version'
require 'net/http'
require 'selenium-webdriver'
require_relative 'driver_metadata'

module Percy
  # Maximum nesting depth for cross-origin iframe recursion. Bounds the cost
  # of pathological pages and prevents runaway recursion on cyclic frame trees.
  DEFAULT_MAX_FRAME_DEPTH = 5

  # Iframe src prefixes / sentinels we never attempt to switch into — these
  # represent either browser-internal documents, non-HTTP URI schemes, or
  # placeholder values that have no meaningful CORS content to capture.
  UNSUPPORTED_IFRAME_SRCS = %w[
    about:blank about:srcdoc javascript: data: vbscript: blob: chrome: chrome-extension: blank
  ].freeze

  # Raised when a nested-frame restoration step fails and we can no longer
  # trust that subsequent driver.switch_to / find_elements calls will resolve
  # against the correct frame context. Carries any iframes captured before
  # the loss so the caller can still preserve partial work.
  class PercyContextLost < StandardError
    attr_accessor :partial_capture
  end

  CLIENT_INFO = "percy-selenium-ruby/#{VERSION}".freeze
  ENV_INFO = "selenium/#{Selenium::WebDriver::VERSION} ruby/#{RUBY_VERSION}".freeze

  SESSION_TYPE_AUTOMATE = 'automate'.freeze
  SESSION_TYPE_WEB = 'web'.freeze

  PERCY_DEBUG = ENV['PERCY_LOGLEVEL'] == 'debug'
  PERCY_SERVER_ADDRESS = ENV['PERCY_SERVER_ADDRESS'] || 'http://localhost:5338'
  LABEL = "[\u001b[35m" + (PERCY_DEBUG ? 'percy:ruby' : 'percy') + "\u001b[39m]"
  RESPONSIVE_CAPTURE_SLEEP_TIME = ENV['RESPONSIVE_CAPTURE_SLEEP_TIME'] ||
    ENV['RESONSIVE_CAPTURE_SLEEP_TIME']

  def self.responsive_capture_reload_page?
    val = ENV['PERCY_RESPONSIVE_CAPTURE_RELOAD_PAGE'] ||
      ENV['PERCY_RESONSIVE_CAPTURE_RELOAD_PAGE'] || 'false'
    val.casecmp('true') == 0
  end

  def self.responsive_capture_min_height?
    val = ENV['PERCY_RESPONSIVE_CAPTURE_MIN_HEIGHT'] ||
      ENV['PERCY_RESONSIVE_CAPTURE_MIN_HEIGHT'] || 'false'
    val.casecmp('true') == 0
  end

  def self.create_region(
    bounding_box: nil, element_xpath: nil, element_css: nil, padding: nil,
    algorithm: 'ignore', diff_sensitivity: nil, image_ignore_threshold: nil,
    carousels_enabled: nil, banners_enabled: nil, ads_enabled: nil, diff_ignore_threshold: nil
  )
    element_selector = {}
    element_selector[:boundingBox] = bounding_box if bounding_box
    element_selector[:elementXpath] = element_xpath if element_xpath
    element_selector[:elementCSS] = element_css if element_css

    region = {
      algorithm: algorithm,
      elementSelector: element_selector,
    }

    region[:padding] = padding if padding

    if %w[standard intelliignore].include?(algorithm)
      configuration = {
        diffSensitivity: diff_sensitivity,
        imageIgnoreThreshold: image_ignore_threshold,
        carouselsEnabled: carousels_enabled,
        bannersEnabled: banners_enabled,
        adsEnabled: ads_enabled,
      }.compact

      region[:configuration] = configuration unless configuration.empty?
    end

    assertion = {}
    assertion[:diffIgnoreThreshold] = diff_ignore_threshold unless diff_ignore_threshold.nil?
    region[:assertion] = assertion unless assertion.empty?

    region
  end

  def self.snapshot(driver, name, options = {})
    return unless percy_enabled?

    if @session_type == SESSION_TYPE_AUTOMATE
      raise StandardError, 'Invalid function call - percy_snapshot(). ' \
        'Please use percy_screenshot() function while using Percy with Automate. ' \
        'For more information on usage of percy_screenshot(), ' \
        'refer https://www.browserstack.com/docs/percy/integrate/functional-and-visual'
    end

    begin
      percy_dom_script = fetch_percy_dom
      driver.execute_script(percy_dom_script)
      dom_snapshot = if responsive_snapshot_capture?(options)
        capture_responsive_dom(driver, options, percy_dom_script: percy_dom_script)
      else
        get_serialized_dom(driver, options, percy_dom_script: percy_dom_script)
      end

      response = fetch('percy/snapshot',
        name: name,
        url: driver.current_url,
        dom_snapshot: dom_snapshot,
        client_info: CLIENT_INFO,
        environment_info: ENV_INFO,
        **options,)

      body = JSON.parse(response.body)
      unless body['success']
        raise StandardError, body['error']
      end

      body['data']
    rescue StandardError => e
      log("Could not take DOM snapshot '#{name}'")
      log(e, 'debug')
    end
  end

  def self.get_browser_instance(driver)
    if driver.respond_to?(:driver) && driver.driver.respond_to?(:browser)
      return driver.driver.browser.manage
    end

    driver.manage
  end

  def self.get_serialized_dom(driver, options, percy_dom_script: nil)
    dom_snapshot = driver.execute_script("return PercyDOM.serialize(#{options.to_json})")
    if percy_dom_script
      max_depth = resolve_max_frame_depth(options, @cli_config)
      ignore_selectors = resolve_ignore_selectors(options, @cli_config)
      ctx = {
        max_frame_depth: max_depth,
        ignore_selectors: ignore_selectors,
        serialize_options: options,
        percy_dom_script: percy_dom_script,
      }
      processed = capture_cors_iframes(driver, ctx)
      dom_snapshot['corsIframes'] = processed if processed.any?
    end

    dom_snapshot['cookies'] = get_browser_instance(driver).all_cookies
    dom_snapshot
  end

  # Top-level entry: enumerate iframes from the page document, filter the
  # ones we should never enter (browser-internal, srcdoc, same-origin,
  # ignored), then recurse into each one through process_frame_tree. A
  # PercyContextLost raised by a deeper frame aborts further sibling
  # iteration but preserves whatever we already captured.
  def self.capture_cors_iframes(driver, ctx)
    page_url = driver.current_url
    page_origin = get_origin(page_url) rescue nil
    iframes_meta = enumerate_iframes(driver, ctx[:ignore_selectors])
    return [] if iframes_meta.empty?

    iframe_elements = driver.find_elements(css: 'iframe')
    cors = []
    iframes_meta.each_with_index do |meta, i|
      element = iframe_elements[i]
      next if element.nil?
      next if should_skip_iframe?(meta, page_origin)

      begin
        entries = process_frame_tree(driver, element, meta, 1,
                                     Set.new([page_url].compact), ctx,)
        cors.concat(entries) if entries.any?
      rescue PercyContextLost => e
        log('Aborting further nested CORS capture due to lost frame context', 'debug')
        cors.concat(e.partial_capture) if e.partial_capture&.any?
        break
      end
    end

    cors
  rescue StandardError => e
    log("Failed to process cross-origin iframes: #{e}", 'debug')
    begin
      driver.switch_to.default_content
    rescue StandardError
      nil
    end
    []
  end

  def self.enumerate_iframes(driver, ignore_selectors)
    result = driver.execute_script("return #{enumerate_iframes_script(ignore_selectors)}")
    result.is_a?(Array) ? result : []
  rescue StandardError => e
    log("Failed to enumerate iframes: #{e}", 'debug')
    []
  end

  def self.should_skip_iframe?(meta, parent_origin)
    src = meta['src']
    return true if is_unsupported_iframe_src?(src)
    return true if meta['srcdoc'] && !meta['srcdoc'].to_s.empty?
    return true if meta['percyElementId'].nil? || meta['percyElementId'].to_s.empty?

    frame_origin = get_origin(src) rescue nil
    return true if frame_origin.nil?
    return true if frame_origin == parent_origin

    false
  end

  # Switch into iframe_element, serialize its document, then recurse into
  # nested cross-origin iframes that live inside it. Depth-capped against
  # ctx[:max_frame_depth] and guarded against cyclic frame trees by
  # ancestor_urls. Restores the parent frame on exit; if that restoration
  # fails inside a nested call, raises PercyContextLost carrying the partial
  # capture so the caller can preserve work done before the loss.
  def self.process_frame_tree(driver, iframe_element, meta, depth, ancestor_urls, ctx)
    if depth > ctx[:max_frame_depth]
      log("Reached max iframe nesting depth (#{ctx[:max_frame_depth]}); " \
          "stopping at #{meta['src']}", 'debug',)
      return []
    end
    if ancestor_urls.include?(meta['src'])
      log("Skipping cyclic iframe (#{meta['src']} appears in ancestor chain)", 'debug')
      return []
    end

    collected = []
    switched_in = false
    captured_error = nil

    begin
      driver.switch_to.frame(iframe_element)
      switched_in = true

      driver.execute_script(ctx[:percy_dom_script])
      iframe_options = (ctx[:serialize_options] || {}).merge('enableJavaScript' => true)
      iframe_snapshot =
        driver.execute_script("return PercyDOM.serialize(#{iframe_options.to_json})")
      frame_url = driver.execute_script('return document.URL') rescue meta['src']

      if iframe_snapshot.nil?
        log("Serialization returned empty result for frame: #{meta['src']}", 'debug')
        return collected
      end

      collected << {
        'iframeData' => {'percyElementId' => meta['percyElementId']},
        'iframeSnapshot' => iframe_snapshot,
        'frameUrl' => frame_url || meta['src'],
      }
      log("Captured cross-origin iframe (depth #{depth}): #{frame_url || meta['src']}", 'debug')

      if depth < ctx[:max_frame_depth]
        current_origin = get_origin(frame_url || meta['src']) rescue nil
        child_metas = enumerate_iframes(driver, ctx[:ignore_selectors])
        child_elements = driver.find_elements(css: 'iframe')
        next_ancestors = ancestor_urls.dup
        next_ancestors.add(meta['src'])
        next_ancestors.add(frame_url) if frame_url
        child_metas.each_with_index do |child_meta, i|
          child_element = child_elements[i]
          next if child_element.nil?
          next if should_skip_iframe?(child_meta, current_origin)

          nested = process_frame_tree(driver, child_element, child_meta, depth + 1,
                                      next_ancestors, ctx,)
          collected.concat(nested) if nested.any?
        end
      end

      collected
    rescue PercyContextLost => e
      # Merge any partial capture from the inner level into ours before propagating
      if e.partial_capture&.any?
        collected.concat(e.partial_capture)
      end
      e.partial_capture = collected
      raise
    rescue StandardError => e
      log("Failed to process cross-origin iframe #{meta['src']}: #{e}", 'debug')
      captured_error = e
      collected
    ensure
      if switched_in
        # Step up exactly one level so an outer recursion continues from its
        # own context. If parent_frame fails we have no reliable way to land
        # in the correct parent — fall back to default_content and, if this
        # happened inside a nested frame, raise PercyContextLost so the
        # caller stops iterating siblings whose enumeration was performed in
        # a now-lost context.
        begin
          driver.switch_to.parent_frame
        rescue StandardError => parent_err
          log("Failed to switch back to parent frame: #{parent_err}", 'debug')
          begin
            driver.switch_to.default_content
          rescue StandardError
            nil
          end
          if depth > 1
            err = PercyContextLost.new("Lost parent frame context: #{parent_err.message}")
            err.partial_capture = collected
            err.set_backtrace(captured_error.backtrace) if captured_error
            raise err
          end
        end
      end
    end
  end

  # Inlined helper: returns true for srcs we should never attempt to switch
  # into (browser-internal, non-HTTP schemes, or placeholders). Also used
  # post-switch on document.URL to catch about:blank / error-page redirects
  # that aren't visible in the static src attribute.
  def self.is_unsupported_iframe_src?(src)
    return true if src.nil? || src.to_s.empty?

    UNSUPPORTED_IFRAME_SRCS.any? { |prefix| src == prefix || src.start_with?(prefix) }
  end

  # Backwards-compatible alias for the original method name.
  def self.unsupported_iframe_src?(src)
    is_unsupported_iframe_src?(src)
  end

  def self.get_origin(url)
    uri = URI.parse(url)
    raise URI::InvalidURIError, "no host in #{url}" if uri.host.nil?

    netloc = uri.host.to_s
    default_ports = {'http' => 80, 'https' => 443}
    netloc += ":#{uri.port}" if uri.port && uri.port != default_ports[uri.scheme]
    "#{uri.scheme}://#{netloc}"
  end

  # Clamp a user-supplied iframe depth to a sane range. Negative or non-numeric
  # input falls back to the default; very large values are capped to avoid
  # unbounded recursion on degenerate pages.
  def self.clamp_frame_depth(depth, default: DEFAULT_MAX_FRAME_DEPTH)
    return default if depth.nil?

    n = Integer(depth) rescue nil
    return default if n.nil?
    return 0 if n < 0

    [n, 50].min
  end

  # Accept selector input as String, Array, or nil and produce a flat array of
  # non-empty strings. Lets the user pass either a single selector or many.
  def self.normalize_ignore_selectors(input)
    return [] if input.nil?

    arr = input.is_a?(Array) ? input : [input]
    arr.flat_map { |s| s.is_a?(Array) ? s : [s] }
       .reject { |s| s.nil? || s.to_s.strip.empty? }
       .map(&:to_s)
  end

  def self.resolve_max_frame_depth(options, config = nil)
    val = options[:maxIframeDepth] || options[:max_iframe_depth] ||
      config&.dig('snapshot', 'maxIframeDepth')
    clamp_frame_depth(val)
  end

  def self.resolve_ignore_selectors(options, config = nil)
    val = options[:ignoreIframeSelectors] || options[:ignore_iframe_selectors] ||
      config&.dig('snapshot', 'ignoreIframeSelectors') || []
    normalize_ignore_selectors(val)
  end

  # Browser-side script that enumerates all <iframe> elements and returns a
  # plain-data array describing each, including data-percy-ignore attribute
  # state and which configured ignoreIframeSelectors it matches. We do all
  # filtering off this snapshot rather than re-querying the DOM repeatedly.
  def self.enumerate_iframes_script(selectors)
    selectors_json = (selectors || []).to_json
    <<~JS
      (function() {
        var selectors = #{selectors_json};
        var iframes = document.querySelectorAll('iframe');
        var result = [];
        for (var i = 0; i < iframes.length; i++) {
          var frame = iframes[i];
          var matchesIgnore = false;
          if (selectors && selectors.length) {
            for (var j = 0; j < selectors.length; j++) {
              try { if (frame.matches(selectors[j])) { matchesIgnore = true; break; } } catch (e) {}
            }
          }
          result.push({
            src: frame.src || '',
            srcdoc: frame.getAttribute('srcdoc'),
            percyElementId: frame.getAttribute('data-percy-element-id'),
            dataPercyIgnore: frame.hasAttribute('data-percy-ignore'),
            matchesIgnoreSelector: matchesIgnore,
            index: i
          });
        }
        return result;
      })();
    JS
  end


  def self.get_responsive_widths(widths = [])
    begin
      widths_list = widths.is_a?(Array) ? widths : []
      query_param = widths_list.any? ? "?widths=#{widths_list.join(',')}" : ''
      response = fetch("percy/widths-config#{query_param}")
      data = JSON.parse(response.body)
      widths_data = data['widths']
      unless widths_data.is_a?(Array)
        msg = 'Update Percy CLI to the latest version to use responsiveSnapshotCapture'
        raise StandardError, msg
      end

      widths_data
    rescue StandardError => e
      log("Failed to get responsive widths: #{e}.", 'debug')
      raise StandardError, 'Update Percy CLI to the latest version to use ' \
        'responsiveSnapshotCapture'
    end
  end

  def self.change_window_dimension_and_wait(driver, width, height, resize_count)
    log("Attempting to resize window to #{width}x#{height}", 'debug')

    begin
      if driver.capabilities.browser_name == 'chrome' && driver.respond_to?(:execute_cdp)
        driver.execute_cdp('Emulation.setDeviceMetricsOverride', {
                             height: height, width: width, deviceScaleFactor: 1, mobile: false,
                           },)
      else
        get_browser_instance(driver).window.resize_to(width, height)
        driver.execute_script("window.dispatchEvent(new Event('resize'));")
      end
    rescue StandardError => e
      log("Resizing using cdp failed, falling back to driver for width #{width} #{e}", 'debug')
      get_browser_instance(driver).window.resize_to(width, height)
      driver.execute_script("window.dispatchEvent(new Event('resize'));")
    end

    begin
      wait = Selenium::WebDriver::Wait.new(timeout: 1)
      wait.until { driver.execute_script('return window.resizeCount') == resize_count }
      actual_size = driver.execute_script('return { w: window.innerWidth, h: window.innerHeight }')
      log("Resize successful. New Viewport Size: #{actual_size['w']}x#{actual_size['h']}", 'debug')
    rescue Selenium::WebDriver::Error::TimeoutError
      log("Timed out waiting for window resize event for width #{width}", 'debug')
    end
  end

  def self.capture_responsive_dom(driver, options, percy_dom_script: nil)
    widths = get_responsive_widths(options[:widths] || [])
    dom_snapshots = []
    window_size = get_browser_instance(driver).window.size
    current_width = window_size.width
    current_height = window_size.height
    last_window_width = current_width
    last_window_height = current_height
    resize_count = 0
    driver.execute_script('PercyDOM.waitForResize()')
    target_height = current_height

    if responsive_capture_min_height?
      min = options[:minHeight] || @cli_config&.dig('snapshot', 'minHeight')
      if min
        target_height = min
      else
        log('PERCY_RESPONSIVE_CAPTURE_MIN_HEIGHT is enabled but no minHeight value ' \
            'was provided in options or CLI config; using current window height', 'debug',)
      end
    end

    begin
      widths.each do |width_dict|
        width = width_dict['width']
        height = width_dict['height'] || target_height

        if last_window_width != width || last_window_height != height
          resize_count += 1
          change_window_dimension_and_wait(driver, width, height, resize_count)
          last_window_width = width
          last_window_height = height
        end

        if responsive_capture_reload_page?
          log("Reloading page for width: #{width}", 'debug')
          begin
            driver.navigate.refresh
          rescue StandardError
            begin
              driver.driver.browser.navigate.refresh
            rescue StandardError => e
              log("Failed to refresh page: #{e}", 'debug')
            end
          end
          percy_dom_script = fetch_percy_dom
          driver.execute_script(percy_dom_script)
          driver.execute_script('PercyDOM.waitForResize()')
          resize_count = 0
        end

        sleep(RESPONSIVE_CAPTURE_SLEEP_TIME.to_i) if RESPONSIVE_CAPTURE_SLEEP_TIME

        dom_snapshot = get_serialized_dom(driver, options, percy_dom_script: percy_dom_script)
        dom_snapshot['width'] = width
        dom_snapshots << dom_snapshot
      end
    ensure
      change_window_dimension_and_wait(driver, current_width, current_height, resize_count + 1)
    end

    dom_snapshots
  end

  def self.responsive_snapshot_capture?(options)
    return false if @cli_config&.dig('percy', 'deferUploads')

    options[:responsive_snapshot_capture] ||
      options[:responsiveSnapshotCapture] ||
      @cli_config&.dig('snapshot', 'responsiveSnapshotCapture')
  end

  def self.percy_enabled?
    return @percy_enabled unless @percy_enabled.nil?

    begin
      response = fetch('percy/healthcheck')
      version = response['x-percy-core-version']

      if version.nil?
        log('You may be using @percy/agent ' \
            'which is no longer supported by this SDK. ' \
            'Please uninstall @percy/agent and install @percy/cli instead. ' \
            'https://www.browserstack.com/docs/percy/migration/migrate-to-cli')
        @percy_enabled = false
        return false
      end

      if version.split('.')[0] != '1'
        log("Unsupported Percy CLI version, #{version}")
        @percy_enabled = false
        return false
      end

      response_body = JSON.parse(response.body)
      @cli_config = response_body['config']
      @session_type = response_body['type']
      @percy_enabled = true
      true
    rescue StandardError => e
      log('Percy is not running, disabling snapshots')
      log(e, 'debug')
      @percy_enabled = false
      false
    end
  end

  def self.fetch_percy_dom
    return @percy_dom unless @percy_dom.nil?

    response = fetch('percy/dom.js')
    @percy_dom = response.body
  end

  def self.log(msg, lvl = 'info')
    msg = "#{LABEL} #{msg}"
    begin
      fetch('percy/log', {message: msg, level: lvl})
    rescue StandardError => e
      if PERCY_DEBUG
        puts "Sending log to CLI Failed #{e}"
      end
    ensure
      if lvl != 'debug' || PERCY_DEBUG
        puts msg
      end
    end
  end

  def self.fetch(url, data = nil)
    uri = URI("#{PERCY_SERVER_ADDRESS}/#{url}")

    response = if data
      http = Net::HTTP.new(uri.host, uri.port)
      http.read_timeout = 600 # seconds
      request = Net::HTTP::Post.new(uri.path)
      request.body = data.to_json
      http.request(request)
    else
      Net::HTTP.get_response(uri)
    end

    unless response.is_a? Net::HTTPSuccess
      raise StandardError, "Failed with HTTP error code: #{response.code}"
    end

    response
  end

  def self.percy_screenshot(driver, name, options = {})
    return unless percy_enabled?

    unless @session_type == SESSION_TYPE_AUTOMATE
      raise StandardError, 'Invalid function call - percy_screenshot(). ' \
        'Please use percy_snapshot() function for taking screenshot. ' \
        'percy_screenshot() should be used only while using Percy with Automate. ' \
        'For more information on usage of percy_snapshot(), ' \
        'refer doc for your language https://www.browserstack.com/docs/percy/integrate/overview'
    end

    begin
      options = options.dup
      metadata = get_driver_metadata(driver)

      if options.key?(:ignoreRegionSeleniumElements)
        options[:ignore_region_selenium_elements] = options.delete(:ignoreRegionSeleniumElements)
      end
      if options.key?(:considerRegionSeleniumElements)
        options[:consider_region_selenium_elements] =
          options.delete(:considerRegionSeleniumElements)
      end

      ignore_region_elements =
        get_element_ids(options.delete(:ignore_region_selenium_elements) || [])
      consider_region_elements =
        get_element_ids(options.delete(:consider_region_selenium_elements) || [])

      options[:ignore_region_elements] = ignore_region_elements
      options[:consider_region_elements] = consider_region_elements

      response = fetch('percy/automateScreenshot',
        client_info: CLIENT_INFO,
        environment_info: ENV_INFO,
        sessionId: metadata.session_id,
        commandExecutorUrl: metadata.command_executor_url,
        capabilities: metadata.capabilities,
        snapshotName: name,
        options: options,)

      body = JSON.parse(response.body)
      unless body['success']
        raise StandardError, body['error']
      end

      body['data']
    rescue StandardError => e
      log("Could not take Screenshot '#{name}'")
      log(e, 'debug')
    end
  end

  def self.get_driver_metadata(driver)
    DriverMetaData.new(driver)
  end

  def self.get_element_ids(elements)
    elements.map(&:id)
  end

  def self._clear_cache!
    @percy_dom = nil
    @percy_enabled = nil
    @cli_config = nil
    @session_type = nil
    Cache.clear_cache!
  end
end
