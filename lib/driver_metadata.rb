require_relative 'cache'

class DriverMetaData
  def initialize(driver)
    @driver = driver
  end

  def session_id
    @driver.session_id
  end

  def command_executor_url
    cached = Cache.get_cache(session_id, Cache::COMMAND_EXECUTOR_URL)
    return cached unless cached.nil?

    url = nil

    begin
      raw = @driver.send(:bridge).http.send(:server_url)
      url = raw.to_s unless raw.nil?
    rescue StandardError => e
      Percy.log("Could not get command_executor_url via bridge.http.server_url: #{e}",
                'debug') if defined?(Percy)
    end

    if url.nil? || url.empty?
      begin
        raw = @driver.send(:bridge).http.instance_variable_get(:@server_url)
        url = raw.to_s unless raw.nil?
      rescue StandardError => e
        Percy.log("Could not get @server_url instance variable: #{e}", 'debug') if defined?(Percy)
      end
    end

    url ||= ''
    Cache.set_cache(session_id, Cache::COMMAND_EXECUTOR_URL, url)
    url
  end

  def capabilities
    cached = Cache.get_cache(session_id, Cache::CAPABILITIES)
    return cached unless cached.nil?

    caps = nil
    begin
      caps = @driver.capabilities.as_json
    rescue StandardError
      begin
        caps = @driver.capabilities.to_h
      rescue StandardError
        caps = {}
      end
    end

    Cache.set_cache(session_id, Cache::CAPABILITIES, caps)
    caps
  end
end
