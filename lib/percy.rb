require 'uri'
require 'json'
require 'version'
require 'net/http'
require 'selenium-webdriver'
require_relative 'driver_metadata'

module Percy
  CLIENT_INFO = "percy-selenium-ruby/#{VERSION}".freeze
  ENV_INFO = "selenium/#{Selenium::WebDriver::VERSION} ruby/#{RUBY_VERSION}".freeze

  PERCY_DEBUG = ENV['PERCY_LOGLEVEL'] == 'debug'
  PERCY_SERVER_ADDRESS = ENV['PERCY_SERVER_ADDRESS'] || 'http://localhost:5338'
  LABEL = "[\u001b[35m" + (PERCY_DEBUG ? 'percy:ruby' : 'percy') + "\u001b[39m]"
  RESPONSIVE_CAPTURE_SLEEP_TIME = ENV['RESPONSIVE_CAPTURE_SLEEP_TIME']
  PERCY_RESPONSIVE_CAPTURE_RELOAD_PAGE =
    (ENV['PERCY_RESPONSIVE_CAPTURE_RELOAD_PAGE'] || 'false').downcase
  PERCY_RESPONSIVE_CAPTURE_MIN_HEIGHT =
    (ENV['PERCY_RESPONSIVE_CAPTURE_MIN_HEIGHT'] || 'false').downcase

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

    if @session_type == 'automate'
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

    begin
      page_origin = get_origin(driver.current_url)
      iframes = driver.find_elements(:tag_name, 'iframe')
      if iframes.any?
        processed_frames = []
        iframes.each do |frame|
          frame_src = frame.attribute('src')
          next if unsupported_iframe_src?(frame_src)

          begin
            frame_origin = get_origin(URI.join(driver.current_url, frame_src).to_s)
          rescue StandardError => e
            log("Skipping iframe \"#{frame_src}\": #{e}", 'debug')
            next
          end

          next if frame_origin == page_origin

          result = process_frame(driver, frame, options, percy_dom_script)
          processed_frames << result if result
        end
        dom_snapshot['corsIframes'] = processed_frames if processed_frames.any?
      end
    rescue StandardError => e
      log("Failed to process cross-origin iframes: #{e}", 'debug')
      begin
        driver.switch_to.default_content
      rescue StandardError
        nil
      end
    end

    dom_snapshot['cookies'] = get_browser_instance(driver).all_cookies
    dom_snapshot
  end

  def self.unsupported_iframe_src?(src)
    src.nil? || src.empty? || src == 'about:blank' ||
      src.start_with?('javascript:') || src.start_with?('data:') || src.start_with?('vbscript:')
  end

  def self.get_origin(url)
    uri = URI.parse(url)
    netloc = uri.host.to_s
    default_ports = {'http' => 80, 'https' => 443}
    netloc += ":#{uri.port}" if uri.port && uri.port != default_ports[uri.scheme]
    "#{uri.scheme}://#{netloc}"
  end

  def self.process_frame(driver, frame_element, options, percy_dom_script)
    frame_url = frame_element.attribute('src') || 'unknown-src'
    iframe_snapshot = nil

    begin
      driver.switch_to.frame(frame_element)
      begin
        driver.execute_script(percy_dom_script)
        iframe_options = options.merge('enableJavaScript' => true)
        iframe_snapshot =
          driver.execute_script("return PercyDOM.serialize(#{iframe_options.to_json})")
      rescue StandardError => e
        log("Failed to process cross-origin frame #{frame_url}: #{e}", 'debug')
      ensure
        begin
          driver.switch_to.default_content
        rescue StandardError
          begin
            driver.switch_to.parent_frame
          rescue StandardError
            nil
          end
        end
      end
    rescue StandardError => e
      log("Failed to switch to frame #{frame_url}: #{e}", 'debug')
      begin
        driver.switch_to.default_content
      rescue StandardError
        nil
      end
      return nil
    end

    return nil if iframe_snapshot.nil?

    percy_element_id = frame_element.attribute('data-percy-element-id')
    unless percy_element_id
      log("Skipping frame #{frame_url}: no matching percyElementId found", 'debug')
      return nil
    end

    {
      'iframeData' => {'percyElementId' => percy_element_id},
      'iframeSnapshot' => iframe_snapshot,
      'frameUrl' => frame_url,
    }
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

    if PERCY_RESPONSIVE_CAPTURE_MIN_HEIGHT == 'true'
      min = options[:minHeight] || @cli_config&.dig('snapshot', 'minHeight')
      target_height = min if min
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

        if PERCY_RESPONSIVE_CAPTURE_RELOAD_PAGE == 'true'
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

    unless @session_type == 'automate'
      raise StandardError, 'Invalid function call - percy_screenshot(). ' \
        'Please use percy_snapshot() function for taking screenshot. ' \
        'percy_screenshot() should be used only while using Percy with Automate. ' \
        'For more information on usage of percy_snapshot(), ' \
        'refer doc for your language https://www.browserstack.com/docs/percy/integrate/overview'
    end

    begin
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
