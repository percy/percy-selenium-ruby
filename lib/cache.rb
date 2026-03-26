class Cache
  CACHE = {} # rubocop:disable Style/MutableConstant
  CACHE_TIMEOUT = 5 * 60 # 300 seconds
  TIMEOUT_KEY = 'last_access_time'.freeze
  MUTEX = Mutex.new

  # Caching Keys
  CAPABILITIES = 'capabilities'.freeze
  COMMAND_EXECUTOR_URL = 'command_executor_url'.freeze

  def self.check_types(session_id, property)
    raise TypeError, 'Argument session_id should be string' unless session_id.is_a?(String)
    raise TypeError, 'Argument property should be string' unless property.is_a?(String)
  end

  def self.set_cache(session_id, property, value)
    check_types(session_id, property)
    MUTEX.synchronize do
      session = CACHE[session_id] || {}
      session[TIMEOUT_KEY] = Time.now.to_f
      session[property] = value
      CACHE[session_id] = session
    end
  end

  def self.get_cache(session_id, property)
    check_types(session_id, property)
    MUTEX.synchronize do
      cleanup_cache
      session = CACHE[session_id] || {}
      session[property]
    end
  end

  def self.clear_cache!
    MUTEX.synchronize do
      CACHE.clear
    end
  end

  def self.cleanup_cache
    now = Time.now.to_f
    CACHE.delete_if do |_, session|
      timestamp = session[TIMEOUT_KEY]
      timestamp && (now - timestamp >= CACHE_TIMEOUT)
    end
  end
  private_class_method :cleanup_cache
end
