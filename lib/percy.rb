require 'net/http'
require 'uri'
require 'json'

module Percy
  VERSION = "1.0.0-beta.0".freeze
  CLIENT_INFO = "percy-selenium-ruby/#{VERSION}"
  PERCY_DEBUG = ENV["PERCY_LOGLEVEL"] == "debug"
  PERCY_SERVER_ADDRESS = ENV["PERCY_SERVER_ADDRESS"] || "http://localhost:5338"
  LABEL = "[\u001b[35m" + (PERCY_DEBUG ? "percy:ruby" : "percy") + "\u001b[39m]"


  # Takes a snapshot of the given page HTML and its assets.
  #
  # @param
  def self.snapshot(driver, name, options = {})
    return unless self.is_percy_enabled?

    begin
      driver.execute_script(self.fetch_percy_dom)
      dom_snapshot = driver.execute_script("return PercyDOM.serialize(#{options.to_json})")

      response = self.fetch("percy/snapshot", {
                              name: name,
                              url: driver.current_url,
                              dom_snapshot: dom_snapshot,
                              client_info: CLIENT_INFO,
                              # environment_info: self.environment_info
                            })

      if !response.body.to_json["success"]
        raise StandardError.new data["error"]
      end

    rescue => e
      self.log("Could not take DOM snapshot '#{name}'")

      if PERCY_DEBUG
        self.log(e)
      end
    end
  end

  private

  def self.is_percy_enabled?
    return @percy_enabled if defined? @percy_enabled

    begin
      response = self.fetch("percy/healthcheck")
      version = response['x-percy-core-version']

      if version.empty?
        self.log("You may be using @percy/agent " +
                 "which is no longer supported by this SDK. " +
                 "Please uninstall @percy/agent and install @percy/cli instead. " +
                 "https://docs.percy.io/docs/migrating-to-percy-cli")
        @percy_enabled = false
        return false
      end

      if version.split(".")[0] != "1"
        self.log("Unsupported Percy CLI version, #{version}")
        @percy_enabled = false
        return false
      end

      @percy_enabled = true
      return true
    rescue => e
      self.log("Percy is not running, disabling snapshots")

      if PERCY_DEBUG
        self.log(e)
      end
      @percy_enabled = false
      return false
    end
  end

  def self.fetch_percy_dom
    return @percy_dom if defined? @percy_dom
    response = self.fetch("percy/dom.js")
    @percy_dom = response.body
  end

  def self.log(msg)
    puts "#{LABEL} #{msg}"
  end

  def self.fetch(url, data = nil)
    begin
      uri = URI("#{PERCY_SERVER_ADDRESS}/#{url}")

      if data
        response = Net::HTTP.post(uri, data.to_json)
      else
        response = Net::HTTP.get_response(uri)
      end

      if !response.kind_of? Net::HTTPSuccess
        raise StandardError.new "Failed with HTTP error code: #{response.code}"
      end

      response
    rescue => e
      if PERCY_DEBUG
        self.log(e)
      end
    end
  end
end
