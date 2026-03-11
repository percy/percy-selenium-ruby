require 'uri'
require 'json'
require 'version'
require 'net/http'
require 'selenium-webdriver'

module Percy
  CLIENT_INFO = "percy-selenium-ruby/#{VERSION}".freeze
  ENV_INFO = "selenium/#{Selenium::WebDriver::VERSION} ruby/#{RUBY_VERSION}".freeze

  PERCY_DEBUG = ENV['PERCY_LOGLEVEL'] == 'debug'
  PERCY_SERVER_ADDRESS = ENV['PERCY_SERVER_ADDRESS'] || 'http://localhost:5338'
  LABEL = "[\u001b[35m" + (PERCY_DEBUG ? 'percy:ruby' : 'percy') + "\u001b[39m]"
  RESONSIVE_CAPTURE_SLEEP_TIME = ENV['RESONSIVE_CAPTURE_SLEEP_TIME']
  PERCY_RESPONSIVE_CAPTURE_RELOAD_PAGE = (ENV['PERCY_RESPONSIVE_CAPTURE_RELOAD_PAGE'] || 'false').downcase
  PERCY_RESPONSIVE_CAPTURE_MIN_HEIGHT = (ENV['PERCY_RESPONSIVE_CAPTURE_MIN_HEIGHT'] || 'false').downcase
  
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

  # Take a DOM snapshot and post it to the snapshot endpoint
  def self.snapshot(driver, name, options = {})
    return unless percy_enabled?

    if @session_type == 'automate'
      raise StandardError, 'Invalid function call - percy_snapshot(). ' \
        'Please use percy_screenshot() function while using Percy with Automate. ' \
        'For more information on usage of percy_screenshot(), ' \
        'refer https://www.browserstack.com/docs/percy/integrate/functional-and-visual'
    end

    begin
      driver.execute_script(fetch_percy_dom)
      dom_snapshot = if responsive_snapshot_capture?(options)
        capture_responsive_dom(driver, options)
      else
        get_serialized_dom(driver, options)
      end

      response = fetch('percy/snapshot',
        name: name,
        url: driver.current_url,
        dom_snapshot: dom_snapshot,
        client_info: CLIENT_INFO,
        environment_info: ENV_INFO,
        **options,)

      unless response.body.to_json['success']
        raise StandardError, data['error']
      end

      body = JSON.parse(response.body)
      body['data']
    rescue StandardError => e
      log("Could not take DOM snapshot '#{name}'")
      log(e, 'debug')
    end
  end

  def self.get_browser_instance(driver)
    # this means it is a capybara session
    if driver.respond_to?(:driver) && driver.driver.respond_to?(:browser)
      return driver.driver.browser.manage
    end

    driver.manage
  end

  def self.get_serialized_dom(driver, options)
    dom_snapshot = driver.execute_script("return PercyDOM.serialize(#{options.to_json})")

    dom_snapshot['cookies'] = get_browser_instance(driver).all_cookies
    dom_snapshot
  end

  def self.get_widths_for_multi_dom(options)
    user_passed_widths = options[:widths] || []

    # Deep copy mobile widths otherwise it will get overridden
    all_widths = @eligible_widths['mobile']&.dup || []
    if user_passed_widths.any?
      all_widths.concat(user_passed_widths)
    else
      all_widths.concat(@eligible_widths['config'] || [])
    end

    all_widths.uniq
  end

  def self.change_window_dimension_and_wait(driver, width, height, resize_count)
    # Log the intent
    log("Attempting to resize window to #{width}x#{height}", 'debug')

    begin
      if driver.capabilities.browser_name == 'chrome' && driver.respond_to?(:execute_cdp)
        driver.execute_cdp('Emulation.setDeviceMetricsOverride', {
                             height: height, width: width, deviceScaleFactor: 1, mobile: false,
                           })
      else
        get_browser_instance(driver).window.resize_to(width, height)
      end
    rescue StandardError => e
      log("Resizing using cdp failed, falling back to driver for width #{width} #{e}", 'debug')
      get_browser_instance(driver).window.resize_to(width, height)
    end

    begin
      wait = Selenium::WebDriver::Wait.new(timeout: 1)
      wait.until { driver.execute_script('return window.resizeCount') == resize_count }
      actual_size = driver.execute_script("return { w: window.innerWidth, h: window.innerHeight }")
      log("Resize successful. New Viewport Size: #{actual_size['w']}x#{actual_size['h']}", 'debug')
    rescue Selenium::WebDriver::Error::TimeoutError
      log("Timed out waiting for window resize event for width #{width}", 'debug')
    end
  end

  def self.capture_responsive_dom(driver, options)
    widths = get_widths_for_multi_dom(options)
    dom_snapshots = []
    window_size = get_browser_instance(driver).window.size
    initial_viewport = driver.execute_script("return { w: window.innerWidth, h: window.innerHeight }")
    log("Initial Window Size: #{window_size.width}x#{window_size.height} (Viewport: #{initial_viewport['w']}x#{initial_viewport['h']})", 'debug')
    current_width = window_size.width
    current_height = window_size.height
    last_window_width = current_width
    resize_count = 0
    driver.execute_script('PercyDOM.waitForResize()')

    target_height = current_height

    # If a minimum height is requested via env/config/options, compute a target height
    if PERCY_RESPONSIVE_CAPTURE_MIN_HEIGHT
      min_height = options[:minHeight] || @cli_config&.dig('snapshot', 'minHeight')
      log("current minheight #{min_height}",'debug')
      if min_height
        begin
          target_height = driver.execute_script("return window.outerHeight - window.innerHeight + #{min_height}")
          log("Calculated height for responsive capture using minHeight: #{target_height}", 'debug')
        rescue StandardError => e
          log("Failed to calculate responsive target height: #{e}", 'debug')
        end
      end
    end

    widths.each do |width|
      if last_window_width != width
        resize_count += 1
        change_window_dimension_and_wait(driver, width, target_height, resize_count)
        last_window_width = width
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
        driver.execute_script(fetch_percy_dom)
      end

      sleep(RESONSIVE_CAPTURE_SLEEP_TIME.to_i) if defined?(RESONSIVE_CAPTURE_SLEEP_TIME)

      dom_snapshot = get_serialized_dom(driver, options)
      dom_snapshot['width'] = width
      dom_snapshots << dom_snapshot
    end

    change_window_dimension_and_wait(driver, current_width, current_height, resize_count + 1)
    dom_snapshots
  end

  def self.responsive_snapshot_capture?(options)
    # Don't run responsive snapshot capture when defer uploads is enabled
    return false if @cli_config&.dig('percy', 'deferUploads')

    options[:responsive_snapshot_capture] ||
      options[:responsiveSnapshotCapture] ||
      @cli_config&.dig('snapshot', 'responsiveSnapshotCapture')
  end

  # Determine if the Percy server is running, caching the result so it is only checked once
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
      @eligible_widths = response_body['widths']
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

  # Fetch the @percy/dom script, caching the result so it is only fetched once
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

  # Make an HTTP request (GET,POST) using Ruby's Net::HTTP. If `data` is present,
  # `fetch` will POST as JSON.
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

  # Take a screenshot on a Percy Automate session
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
        options[:consider_region_selenium_elements] = options.delete(:considerRegionSeleniumElements)
      end

      ignore_region_elements = get_element_ids(options.delete(:ignore_region_selenium_elements) || [])
      consider_region_elements = get_element_ids(options.delete(:consider_region_selenium_elements) || [])

      options[:ignore_region_elements] = ignore_region_elements
      options[:consider_region_elements] = consider_region_elements

      response = fetch('percy/automateScreenshot',
        client_info: CLIENT_INFO,
        environment_info: ENV_INFO,
        sessionId: metadata[:session_id],
        commandExecutorUrl: metadata[:command_executor_url],
        capabilities: metadata[:capabilities],
        snapshotName: name,
        options: options)

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
    session_id = driver.session_id

    command_executor_url = nil
    begin
      url = driver.send(:bridge).http.send(:server_url)
      command_executor_url = url.to_s unless url.nil?
    rescue StandardError => e
      log("Could not get command_executor_url via bridge.http.server_url: #{e}", 'debug')
    end

    if command_executor_url.nil? || command_executor_url.empty?
      begin
        url = driver.send(:bridge).http.instance_variable_get(:@server_url)
        command_executor_url = url.to_s unless url.nil?
      rescue StandardError => e
        log("Could not get @server_url instance variable: #{e}", 'debug')
      end
    end

    command_executor_url ||= ''

    capabilities = begin
      driver.capabilities.as_json
    rescue StandardError
      begin
        driver.capabilities.to_h
      rescue StandardError
        {}
      end
    end

    { session_id: session_id, command_executor_url: command_executor_url, capabilities: capabilities }
  end

  def self.get_element_ids(elements)
    elements.map(&:id)
  end

  def self._clear_cache!
    @percy_dom = nil
    @percy_enabled = nil
    @eligible_widths = nil
    @cli_config = nil
    @session_type = nil
  end
end
