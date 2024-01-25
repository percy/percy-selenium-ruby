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

  # Take a DOM snapshot and post it to the snapshot endpoint
  def self.snapshot(driver, name, options = {})
    return unless percy_enabled?

    begin
      driver.execute_script(fetch_percy_dom)
      dom_snapshot = driver.execute_script("return PercyDOM.serialize(#{options.to_json})")

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
      response.body.to_json['data']
    rescue StandardError => e
      log("Could not take DOM snapshot '#{name}'")

      if PERCY_DEBUG then log(e) end
    end
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
            'https://docs.percy.io/docs/migrating-to-percy-cli')
        @percy_enabled = false
        return false
      end

      if version.split('.')[0] != '1'
        log("Unsupported Percy CLI version, #{version}")
        @percy_enabled = false
        return false
      end

      @percy_enabled = true
      true
    rescue StandardError => e
      log('Percy is not running, disabling snapshots')

      if PERCY_DEBUG then log(e) end
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

  def self.log(msg)
    puts "#{LABEL} #{msg}"
  end

  # Make an HTTP request (GET,POST) using Ruby's Net::HTTP. If `data` is present,
  # `fetch` will POST as JSON.
  def self.fetch(url, data = nil)
    uri = URI("#{PERCY_SERVER_ADDRESS}/#{url}")

    response = if data
      http = Net::HTTP.new(uri.host, uri.port)
      http.read_timeout = 600 # seconds
      request = Net::HTTP::Post.new(url.path)
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
  end
end
