require 'uri'
require 'json'
require 'version'
require 'net/http'
require 'selenium-webdriver'
require_relative 'driver_metadata'

module Percy
  CLIENT_INFO = "percy-selenium-ruby/#{VERSION}".freeze
  ENV_INFO = "selenium/#{Selenium::WebDriver::VERSION} ruby/#{RUBY_VERSION}".freeze

  SESSION_TYPE_AUTOMATE = 'automate'.freeze
  SESSION_TYPE_WEB = 'web'.freeze

  PERCY_DEBUG = ENV['PERCY_LOGLEVEL'] == 'debug'
  PERCY_SERVER_ADDRESS = ENV['PERCY_SERVER_ADDRESS'] || 'http://localhost:5338'
  LABEL = "[\u001b[35m" + (PERCY_DEBUG ? 'percy:ruby' : 'percy') + "\u001b[39m]"
  RESPONSIVE_CAPTURE_SLEEP_TIME = ENV['RESPONSIVE_CAPTURE_SLEEP_TIME'] ||
    ENV['RESONSIVE_CAPTURE_SLEEP_TIME']

  CHROMIUM_BROWSERS = %w[chrome chromium msedge microsoftedge chrome-headless-shell].freeze
  NON_CDP_BROWSERS = %w[firefox safari].freeze
  CLOSED_SHADOW_MAX_HOSTS = 200
  LOCAL_HOSTS = %w[localhost 127.0.0.1 ::1].freeze

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

  # Recursively convert all Hash keys (at every nesting level) to symbols so
  # config (string keys from JSON) and per-call options (symbol keys) merge on
  # consistent keys. Arrays are walked; scalars are returned as-is.
  def self.deep_symbolize(obj)
    case obj
    when Hash then obj.each_with_object({}) { |(k, v), h| h[k.to_sym] = deep_symbolize(v) }
    when Array then obj.map { |e| deep_symbolize(e) }
    else obj
    end
  end

  # Deep-merge `override` onto `base`: nested Hashes merge recursively, while
  # arrays and scalars from `override` replace those in `base`.
  def self.deep_merge_options(base, override)
    base.merge(override) do |_key, old_val, new_val|
      old_val.is_a?(Hash) && new_val.is_a?(Hash) ? deep_merge_options(old_val, new_val) : new_val
    end
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

      # Merge .percy.yml config options with snapshot options (snapshot options take priority)
      config_options = @cli_config&.dig('snapshot') || {}
      # Config keys are strings (JSON parse); per-call options use symbols, as
      # do downstream consumers (responsive_snapshot_capture?, capture_responsive_dom).
      # Deep-symbolize both sides so nested keys are consistent, then deep-merge
      # so nested Hashes merge recursively (per-call wins at leaves; arrays/scalars
      # replace) instead of a shallow top-level overwrite dropping config siblings.
      merged_options = deep_merge_options(deep_symbolize(config_options), deep_symbolize(options))

      dom_snapshot = if responsive_snapshot_capture?(merged_options)
        capture_responsive_dom(driver, merged_options, percy_dom_script: percy_dom_script)
      else
        get_serialized_dom(driver, merged_options, percy_dom_script: percy_dom_script)
      end

      # Strip `readiness` before POSTing -- SDK-local config that the CLI
      # already has via healthcheck.
      post_options = options.reject { |k, _| k.to_s == 'readiness' }
      response = fetch('percy/snapshot',
        name: name,
        url: driver.current_url,
        dom_snapshot: dom_snapshot,
        client_info: CLIENT_INFO,
        environment_info: ENV_INFO,
        **post_options,)

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
    native_driver(driver).manage
  end

  # Shallow-merge of global (@cli_config.snapshot.readiness) and per-snapshot
  # (options[:readiness] / options['readiness']) readiness config. Per-snapshot
  # keys win, unspecified global keys (notably preset: disabled) are inherited.
  def self.resolve_readiness_config(options)
    global = @cli_config&.dig('snapshot', 'readiness')
    global = {} unless global.is_a?(Hash)
    per_snapshot = options[:readiness] || options['readiness']
    per_snapshot = {} unless per_snapshot.is_a?(Hash)
    # Normalise symbol keys to strings so the merge collapses :preset and 'preset'.
    [global, per_snapshot].each_with_object({}) do |hash, merged|
      hash.each { |k, v| merged[k.to_s] = v }
    end
  end

  # Readiness gate: runs PercyDOM.waitForReady via
  # execute_async_script BEFORE serialize. Graceful on old CLIs that lack the
  # method. Returns readiness diagnostics (or nil) for attachment to domSnapshot.
  def self.wait_for_ready(driver, options)
    readiness_config = resolve_readiness_config(options)
    return nil if readiness_config['preset'] == 'disabled'

    # Match the driver's async-script timeout to readiness.timeoutMs so a
    # higher user-configured timeout isn't silently capped by Selenium's
    # default (~30s) firing ScriptTimeoutException before the in-page
    # Promise resolves.
    timeout_ms = readiness_config['timeoutMs']
    previous_timeout = nil
    if timeout_ms.is_a?(Numeric) && timeout_ms > 0
      begin
        previous_timeout = driver.manage.timeouts.script_timeout
        driver.manage.timeouts.script_timeout = (timeout_ms / 1000.0) + 2
      rescue StandardError
        previous_timeout = nil # best-effort; older Selenium / unsupported
      end
    end

    begin
      script = <<~JS
        var cfg = #{readiness_config.to_json};
        var done = arguments[arguments.length - 1];
        try {
          if (typeof PercyDOM !== 'undefined' && typeof PercyDOM.waitForReady === 'function') {
            PercyDOM.waitForReady(cfg).then(function(r){ done(r); }).catch(function(){ done(); });
          } else { done(); }
        } catch (e) { done(); }
      JS
      driver.execute_async_script(script)
    rescue StandardError => e
      log("waitForReady failed, proceeding to serialize: #{e}", 'debug')
      nil
    ensure
      if previous_timeout
        begin
          driver.manage.timeouts.script_timeout = previous_timeout
        rescue StandardError
          # best-effort
        end
      end
    end
  end

  def self.get_serialized_dom(driver, options, percy_dom_script: nil)
    # Readiness gate before serialize. Graceful on old CLI.
    readiness_diagnostics = wait_for_ready(driver, options)
    # Strip `readiness` from forwarded serialize args -- it's consumed by
    # wait_for_ready upstream, not a PercyDOM.serialize argument.
    serialize_options = options.reject { |k, _| k.to_s == 'readiness' }
    expose_closed_shadow_roots(driver, options)
    dom_snapshot = driver.execute_script("return PercyDOM.serialize(#{serialize_options.to_json})")
    # `!nil?` preserves legitimate falsy returns like {} ("gate ran, no
    # notable diagnostics").
    if !readiness_diagnostics.nil? && dom_snapshot.is_a?(Hash)
      dom_snapshot['readiness_diagnostics'] = readiness_diagnostics
    end
    begin
      page_origin = get_origin(driver.current_url)
      iframes = percy_dom_script ? driver.find_elements(:tag_name, 'iframe') : []
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

  # @percy/dom reads closed shadow roots from window.__percyClosedShadowRoots
  # (a WeakMap host -> root) because page JS cannot reach them. Fill it with the
  # first strategy the session supports: CDP, then BiDi, then classic WebDriver.
  def self.expose_closed_shadow_roots(driver, options = {})
    return if options[:disableShadowDOM] || options['disableShadowDOM']

    native = native_driver(driver)
    return if chromium_with_cdp?(native) && expose_closed_shadow_roots_cdp(native)
    return if bidi_session?(native) && expose_closed_shadow_roots_bidi(native)

    expose_closed_shadow_roots_classic(native) if closed_shadow_classic_allowed?(native)
  rescue StandardError => e
    log("Could not expose closed shadow roots: #{e}", 'warn')
  end

  CLOSED_SHADOW_SET_FN = 'function(shadowRoot) { ' \
    'window.__percyClosedShadowRoots = window.__percyClosedShadowRoots || new WeakMap(); ' \
    'window.__percyClosedShadowRoots.set(this, shadowRoot); }'.freeze

  def self.expose_closed_shadow_roots_cdp(native)
    native.execute_cdp('DOM.enable')
    root = native.execute_cdp('DOM.getDocument', depth: -1, pierce: true)&.dig('root')
    return false if root.nil?

    closed_shadow_pairs(root).each do |host_id, shadow_id|
      host = native.execute_cdp('DOM.resolveNode', backendNodeId: host_id).dig('object', 'objectId')
      shadow = native.execute_cdp('DOM.resolveNode', backendNodeId: shadow_id)
        .dig('object', 'objectId')
      next unless host && shadow

      native.execute_cdp(
        'Runtime.callFunctionOn',
        functionDeclaration: CLOSED_SHADOW_SET_FN, objectId: host, arguments: [{objectId: shadow}],
      )
    end
    true
  rescue StandardError => e
    log("Could not expose closed shadow roots via CDP: #{e}", 'debug')
    false
  end

  # Child frame documents are skipped: their closed roots would need the
  # WeakMap in the frame's own realm.
  def self.closed_shadow_pairs(node, pairs = [])
    return pairs if node.nil? || node['contentDocument']

    (node['shadowRoots'] || []).each do |shadow|
      if shadow['shadowRootType'] == 'closed'
        pairs << [node['backendNodeId'], shadow['backendNodeId']]
      end
      closed_shadow_pairs(shadow, pairs)
    end
    (node['children'] || []).each { |child| closed_shadow_pairs(child, pairs) }
    pairs
  end

  # Open roots are walked in-page; each closed root found needs another call
  # because page JS cannot see into it.
  BIDI_SHADOW_CANDIDATES_FN = '(root) => { const out = []; ' \
    'const hostable = ' \
    '/^(article|aside|blockquote|body|div|footer|h[1-6]|header|main|nav|p|section|span)$/; ' \
    'const walk = (r) => { for (const e of r.querySelectorAll("*")) { ' \
    'if (e.shadowRoot) walk(e.shadowRoot); ' \
    'else if (e.localName.includes("-") || hostable.test(e.localName)) out.push(e); } }; ' \
    'walk(root || document); return out; }'.freeze
  BIDI_SHADOW_SET_FN = '(pairs) => { ' \
    'const m = window.__percyClosedShadowRoots = ' \
    'window.__percyClosedShadowRoots || new WeakMap(); ' \
    'for (const [h, s] of pairs) m.set(h, s); }'.freeze

  # Selenium Ruby has no typed script module, so this uses the raw BiDi command.
  def self.expose_closed_shadow_roots_bidi(native)
    context = native.window_handle
    scopes = [nil]
    exposed = 0
    until scopes.empty?
      scope = scopes.shift
      args = scope ? [{sharedId: scope}] : []
      nodes = bidi_call_function(native, context, BIDI_SHADOW_CANDIDATES_FN, args)['value'] || []
      pairs = nodes.map do |node|
        shadow = node.dig('value', 'shadowRoot')
        [node['sharedId'], shadow['sharedId']] if shadow && shadow.dig('value', 'mode') == 'closed'
      end.compact
      next if pairs.empty?

      refs = pairs.map do |host, shadow|
        {type: 'array', value: [{sharedId: host}, {sharedId: shadow}]}
      end
      bidi_call_function(native, context, BIDI_SHADOW_SET_FN, [{type: 'array', value: refs}])
      exposed += pairs.length
      break if exposed >= closed_shadow_max_hosts

      scopes.concat(pairs.map(&:last))
    end
    true
  rescue StandardError => e
    log("Could not expose closed shadow roots via BiDi: #{e}", 'debug')
    false
  end

  def self.bidi_call_function(native, context, function, args)
    response = native.bidi.send_cmd(
      'script.callFunction',
      functionDeclaration: function, awaitPromise: false, target: {context: context},
      arguments: args, resultOwnership: 'none',
      serializationOptions: {maxDomDepth: 0, includeShadowTree: 'all'},
    )
    unless response['type'] == 'success'
      raise StandardError, "script.callFunction #{response['type']}"
    end

    response['result'] || {}
  end

  CLASSIC_SHADOW_CANDIDATES_JS = 'const out = []; ' \
    'const walk = (r) => { for (const e of r.querySelectorAll("*")) { ' \
    'if (e.shadowRoot) walk(e.shadowRoot); else if (e.localName.includes("-")) out.push(e); } }; ' \
    'walk(arguments[0] || document); return out;'.freeze
  CLASSIC_SHADOW_SET_JS = '(window.__percyClosedShadowRoots = ' \
    'window.__percyClosedShadowRoots || new WeakMap()).set(arguments[0], arguments[1]);'.freeze

  # W3C Get Element Shadow Root returns closed roots too. It costs one round
  # trip per candidate, hence the cap and the local-only default.
  def self.expose_closed_shadow_roots_classic(native)
    max_hosts = closed_shadow_max_hosts
    checked = 0
    scopes = [nil]
    capped = false
    until scopes.empty? || capped
      hosts = native.execute_script(CLASSIC_SHADOW_CANDIDATES_JS, scopes.shift) || []
      hosts.each do |host|
        capped = checked >= max_hosts
        break if capped

        checked += 1
        shadow = element_shadow_root(host)
        next if shadow.nil?

        native.execute_script(CLASSIC_SHADOW_SET_JS, host, shadow)
        scopes << shadow
      end
    end
    return unless capped

    log("Closed shadow root scan stopped at #{max_hosts} hosts (PERCY_CLOSED_SHADOW_MAX_HOSTS)",
      'debug',)
  end

  # NoSuchShadowRoot means "not a host"; Safari answers null, which the
  # binding cannot wrap. Both mean skip.
  def self.element_shadow_root(host)
    host.shadow_root
  rescue StandardError
    nil
  end

  def self.closed_shadow_max_hosts
    value = Integer(ENV['PERCY_CLOSED_SHADOW_MAX_HOSTS'] || CLOSED_SHADOW_MAX_HOSTS)
    value > 0 ? value : CLOSED_SHADOW_MAX_HOSTS
  rescue ArgumentError, TypeError
    CLOSED_SHADOW_MAX_HOSTS
  end

  # Remote grids add a full round trip per candidate, so classic is opt-in there.
  def self.closed_shadow_classic_allowed?(native)
    return true if ENV['PERCY_CLOSED_SHADOW_CLASSIC'] == 'true'
    return true if LOCAL_HOSTS.include?(command_executor_host(native))

    unless @closed_shadow_remote_logged
      @closed_shadow_remote_logged = true
      log('closed shadow roots skipped on remote session; start the session with ' \
          'webSocketUrl: true or set PERCY_CLOSED_SHADOW_CLASSIC=true')
    end
    false
  end

  def self.command_executor_host(native)
    return nil unless native.respond_to?(:bridge, true)

    URI.parse(native.send(:bridge).http.send(:server_url).to_s).hostname
  rescue StandardError
    nil
  end

  def self.unsupported_iframe_src?(src)
    src.nil? || src.empty? || src == 'about:blank' ||
      src.start_with?('javascript:') || src.start_with?('data:') || src.start_with?('vbscript:')
  end

  def self.get_origin(url)
    uri = URI.parse(url)
    raise URI::InvalidURIError, "no host in #{url}" if uri.host.nil?

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

  # Returns the mechanism that was used (:cdp, :bidi or :window) so the caller
  # can undo exactly that on restore.
  def self.change_window_dimension_and_wait(driver, width, height, exact: true)
    log("Attempting to resize window to #{width}x#{height}", 'debug')

    mechanism = if exact
      set_exact_viewport(driver, width, height)
    else
      legacy_resize(driver, width, height)
    end

    actual = wait_for_viewport_width(driver, width)
    if exact && mechanism == :window && actual != width
      warn_viewport_mismatch(driver, width, actual)
    end
    mechanism
  end

  # CDP and BiDi emulate the viewport exactly. A window resize cannot go below
  # the OS minimum window width (~500px) and includes browser chrome (Edge has
  # an 8px border), so it is only the last resort.
  def self.set_exact_viewport(driver, width, height)
    native = native_driver(driver)

    if chromium_with_cdp?(native)
      begin
        native.execute_cdp(
          'Emulation.setDeviceMetricsOverride',
          height: height, width: width, deviceScaleFactor: 1, mobile: false,
        )
        return :cdp
      rescue StandardError => e
        log("CDP viewport override failed for width #{width}: #{e}", 'debug')
      end
    end

    if bidi_session?(native)
      begin
        native.bidi.send_cmd(
          'browsingContext.setViewport',
          context: native.window_handle,
          viewport: {width: width, height: height},
          devicePixelRatio: 1,
        )
        return :bidi
      rescue StandardError => e
        log("BiDi viewport override failed for width #{width}: #{e}", 'debug')
      end
    end

    resize_window_to_viewport(driver, width, height)
    :window
  end

  # exactResponsiveWidth: false keeps the pre-exact behaviour: CDP on Chrome
  # only, otherwise a plain window resize.
  def self.legacy_resize(driver, width, height)
    native = native_driver(driver)
    if browser_name(native) == 'chrome' && native.respond_to?(:execute_cdp)
      native.execute_cdp(
        'Emulation.setDeviceMetricsOverride',
        height: height, width: width, deviceScaleFactor: 1, mobile: false,
      )
      return :cdp
    end

    resize_window(driver, width, height)
    :window
  rescue StandardError => e
    log("Resizing using cdp failed, falling back to driver for width #{width} #{e}", 'debug')
    resize_window(driver, width, height)
    :window
  end

  def self.resize_window(driver, width, height)
    get_browser_instance(driver).window.resize_to(width, height)
    driver.execute_script("window.dispatchEvent(new Event('resize'));")
  end

  def self.resize_window_to_viewport(driver, width, height)
    resize_window(driver, width, height)
    actual = viewport_size(driver)['w']
    return if actual.nil? || actual == width

    resize_window(driver, width + (width - actual), height)
  end

  def self.restore_viewport(driver, width, height, mechanisms)
    mechanisms = mechanisms.compact.uniq
    native = native_driver(driver)
    resize = mechanisms.include?(:window)

    if mechanisms.include?(:cdp)
      begin
        native.execute_cdp('Emulation.clearDeviceMetricsOverride')
      rescue StandardError => e
        log("Could not clear CDP viewport override: #{e}", 'debug')
        resize = true
      end
    end

    if mechanisms.include?(:bidi)
      begin
        clear_bidi_viewport(native)
      rescue StandardError => e
        log("Could not clear BiDi viewport override: #{e}", 'debug')
        resize = true
      end
    end

    get_browser_instance(driver).window.resize_to(width, height) if resize
  end

  # BiDi#send_cmd drops nil params, but resetting the viewport needs an
  # explicit `viewport: null`, so this goes through the raw socket.
  def self.clear_bidi_viewport(native)
    bidi = native.bidi
    raise StandardError, 'BiDi binding cannot send a null viewport' unless bidi.respond_to?(:ws)

    message = bidi.ws.send_cmd(
      method: 'browsingContext.setViewport',
      params: {context: native.window_handle, viewport: nil, devicePixelRatio: nil},
    )
    raise StandardError, message['message'].to_s if message && message['error']
  end

  def self.viewport_size(driver)
    driver.execute_script('return { w: window.innerWidth, h: window.innerHeight }') || {}
  end

  def self.wait_for_viewport_width(driver, width)
    begin
      Selenium::WebDriver::Wait.new(timeout: 1).until { viewport_size(driver)['w'] == width }
    rescue Selenium::WebDriver::Error::TimeoutError
      log("Timed out waiting for viewport width #{width}", 'debug')
    end
    size = viewport_size(driver)
    log("New Viewport Size: #{size['w']}x#{size['h']}", 'debug')
    size['w']
  end

  def self.warn_viewport_mismatch(driver, width, actual)
    log("Viewport width is #{actual} instead of #{width} after window resize", 'debug')
    native = native_driver(driver)
    session = session_id_of(native)
    @viewport_warned_sessions ||= {}
    return if @viewport_warned_sessions[session]

    @viewport_warned_sessions[session] = true
    log("#{browser_name(native)} could not be resized to exact responsive widths " \
        "(got #{actual}px for #{width}px). Start the session with `webSocketUrl: true` " \
        'to enable WebDriver BiDi for exact widths.', 'warn',)
  end

  def self.session_id_of(native)
    native.session_id
  rescue StandardError
    nil
  end

  def self.exact_responsive_width?(options)
    [
      options[:exactResponsiveWidth],
      options[:exact_responsive_width],
      @cli_config&.dig('snapshot', 'exactResponsiveWidth'),
    ].each { |value| return value unless value.nil? }
    true
  end

  def self.native_driver(driver)
    if driver.respond_to?(:driver) && driver.driver.respond_to?(:browser)
      return driver.driver.browser
    end

    driver
  end

  def self.browser_name(native)
    native.capabilities.browser_name.to_s.downcase
  rescue StandardError
    ''
  end

  def self.chromium_with_cdp?(native)
    return false unless native.respond_to?(:execute_cdp)

    name = browser_name(native)
    CHROMIUM_BROWSERS.include?(name) || !NON_CDP_BROWSERS.include?(name)
  end

  # Only a session that was started with `webSocketUrl: true` has a BiDi
  # socket; the SDK cannot enable it after the fact.
  def self.bidi_session?(native)
    return false unless native.respond_to?(:bidi) && native.respond_to?(:capabilities)

    caps = native.capabilities
    (caps[:web_socket_url] || caps['webSocketUrl']).is_a?(String)
  rescue StandardError
    false
  end

  def self.capture_responsive_dom(driver, options, percy_dom_script: nil)
    widths = get_responsive_widths(options[:widths] || [])
    dom_snapshots = []
    window_size = get_browser_instance(driver).window.size
    current_width = window_size.width
    current_height = window_size.height
    last_window_width = current_width
    last_window_height = current_height
    exact = exact_responsive_width?(options)
    mechanisms = []
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
          mechanisms << change_window_dimension_and_wait(driver, width, height, exact: exact)
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
        end

        sleep(RESPONSIVE_CAPTURE_SLEEP_TIME.to_i) if RESPONSIVE_CAPTURE_SLEEP_TIME

        dom_snapshot = get_serialized_dom(driver, options, percy_dom_script: percy_dom_script)
        dom_snapshot['width'] = width
        dom_snapshots << dom_snapshot
      end
    ensure
      restore_viewport(driver, current_width, current_height, mechanisms)
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
    @viewport_warned_sessions = nil
    @closed_shadow_remote_logged = nil
    Cache.clear_cache!
  end
end
