require 'uri'
require 'json'
require 'version'
require 'net/http'
require 'selenium-webdriver'
require 'capybara'

module Percy
  CLIENT_INFO = "percy-selenium-ruby/#{VERSION}".freeze
  ENV_INFO = "selenium/#{Selenium::WebDriver::VERSION} ruby/#{RUBY_VERSION}".freeze

  PERCY_DEBUG = ENV['PERCY_LOGLEVEL'] == 'debug'
  PERCY_SERVER_ADDRESS = ENV['PERCY_SERVER_ADDRESS'] || 'http://localhost:5338'
  LABEL = "[\u001b[35m" + (PERCY_DEBUG ? 'percy:ruby' : 'percy') + "\u001b[39m]"
  RESONSIVE_CAPTURE_SLEEP_TIME = ENV['RESONSIVE_CAPTURE_SLEEP_TIME']

  # Take a DOM snapshot and post it to the snapshot endpoint
  def self.snapshot(driver, name, options = {})
    return unless percy_enabled?

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
    if driver.is_a?(Capybara::Session)
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
    begin
      if driver.capabilities.browser_name == 'chrome' && driver.respond_to?(:execute_cdp)
        driver.execute_cdp('Emulation.setDeviceMetricsOverride', {
                             height: height, width: width, deviceScaleFactor: 1, mobile: false,
                           },)
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
    rescue Selenium::WebDriver::Error::TimeoutError
      log("Timed out waiting for window resize event for width #{width}", 'debug')
    end
  end

  def self.capture_responsive_dom(driver, options)
    widths = get_widths_for_multi_dom(options)
    dom_snapshots = []
    window_size = get_browser_instance(driver).window.size
    current_width = window_size.width
    current_height = window_size.height
    last_window_width = current_width
    resize_count = 0
    driver.execute_script('PercyDOM.waitForResize()')

    widths.each do |width|
      if last_window_width != width
        resize_count += 1
        change_window_dimension_and_wait(driver, width, current_height, resize_count)
        last_window_width = width
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

  def self._clear_cache!
    @percy_dom = nil
    @percy_enabled = nil
    @eligible_widths = nil
    @cli_config = nil
  end
end
