require 'spec_helper'

RSpec.describe Cache do
  let(:session_id) { 'session_id_123' }
  let(:url) { 'https://example-hub:4444/wd/hub' }
  let(:caps) { { 'browser' => 'chrome', 'platform' => 'windows', 'browserVersion' => '115.0.1' } }

  before(:each) { Cache.clear_cache! }

  describe '.check_types' do
    it 'raises TypeError when session_id is not a string' do
      expect { Cache.check_types(123, Cache::COMMAND_EXECUTOR_URL) }
        .to raise_error(TypeError, 'Argument session_id should be string')
    end

    it 'raises TypeError when property is not a string' do
      expect { Cache.check_types(session_id, 123) }
        .to raise_error(TypeError, 'Argument property should be string')
    end

    it 'does not raise when both arguments are strings' do
      expect { Cache.check_types(session_id, Cache::COMMAND_EXECUTOR_URL) }.not_to raise_error
    end
  end

  describe '.set_cache' do
    it 'raises TypeError when session_id is not a string' do
      expect { Cache.set_cache(123, Cache::COMMAND_EXECUTOR_URL, url) }
        .to raise_error(TypeError, 'Argument session_id should be string')
    end

    it 'raises TypeError when property is not a string' do
      expect { Cache.set_cache(session_id, 123, url) }
        .to raise_error(TypeError, 'Argument property should be string')
    end

    it 'stores the command_executor_url in cache with a timestamp' do
      Cache.set_cache(session_id, Cache::COMMAND_EXECUTOR_URL, url)
      expect(Cache::CACHE[session_id][Cache::COMMAND_EXECUTOR_URL]).to eq(url)
      expect(Cache::CACHE[session_id][Cache::TIMEOUT_KEY]).to be_a(Float)
    end

    it 'stores the capabilities in cache' do
      Cache.set_cache(session_id, Cache::CAPABILITIES, caps)
      expect(Cache::CACHE[session_id][Cache::CAPABILITIES]).to eq(caps)
    end

    it 'updates an existing session entry' do
      Cache.set_cache(session_id, Cache::COMMAND_EXECUTOR_URL, url)
      new_url = 'https://new-hub:4444/wd/hub'
      Cache.set_cache(session_id, Cache::COMMAND_EXECUTOR_URL, new_url)
      expect(Cache::CACHE[session_id][Cache::COMMAND_EXECUTOR_URL]).to eq(new_url)
    end
  end

  describe '.get_cache' do
    before do
      Cache.set_cache(session_id, Cache::COMMAND_EXECUTOR_URL, url)
      Cache.set_cache(session_id, Cache::CAPABILITIES, caps)
    end

    it 'raises TypeError when session_id is not a string' do
      expect { Cache.get_cache(123, Cache::COMMAND_EXECUTOR_URL) }
        .to raise_error(TypeError, 'Argument session_id should be string')
    end

    it 'raises TypeError when property is not a string' do
      expect { Cache.get_cache(session_id, 123) }
        .to raise_error(TypeError, 'Argument property should be string')
    end

    it 'returns the cached command_executor_url' do
      expect(Cache.get_cache(session_id, Cache::COMMAND_EXECUTOR_URL)).to eq(url)
    end

    it 'returns the cached capabilities' do
      expect(Cache.get_cache(session_id, Cache::CAPABILITIES)).to eq(caps)
    end

    it 'returns nil for a missing property' do
      expect(Cache.get_cache(session_id, 'nonexistent_key')).to be_nil
    end

    it 'returns nil for an unknown session' do
      expect(Cache.get_cache('unknown_session', Cache::COMMAND_EXECUTOR_URL)).to be_nil
    end

    it 'calls cleanup_cache' do
      expect(Cache).to receive(:cleanup_cache).and_call_original
      Cache.get_cache(session_id, Cache::COMMAND_EXECUTOR_URL)
    end
  end

  describe '.cleanup_cache' do
    it 'removes entries that have exceeded the cache timeout' do
      Cache.set_cache(session_id, Cache::COMMAND_EXECUTOR_URL, url)
      Cache::CACHE[session_id][Cache::TIMEOUT_KEY] = Time.now.to_f - (Cache::CACHE_TIMEOUT + 1)
      Cache.cleanup_cache
      expect(Cache::CACHE).not_to have_key(session_id)
    end

    it 'keeps entries that have not exceeded the cache timeout' do
      Cache.set_cache(session_id, Cache::COMMAND_EXECUTOR_URL, url)
      Cache.cleanup_cache
      expect(Cache::CACHE).to have_key(session_id)
    end

    it 'only removes expired entries, leaving valid ones' do
      expired_session = 'expired_session'
      Cache.set_cache(session_id, Cache::COMMAND_EXECUTOR_URL, url)
      Cache.set_cache(expired_session, Cache::COMMAND_EXECUTOR_URL, url)
      Cache::CACHE[expired_session][Cache::TIMEOUT_KEY] = Time.now.to_f - (Cache::CACHE_TIMEOUT + 1)
      Cache.cleanup_cache
      expect(Cache::CACHE).to have_key(session_id)
      expect(Cache::CACHE).not_to have_key(expired_session)
    end
  end

  describe '.clear_cache!' do
    it 'removes all entries from the cache' do
      Cache.set_cache(session_id, Cache::COMMAND_EXECUTOR_URL, url)
      Cache.set_cache('other_session', Cache::CAPABILITIES, caps)
      Cache.clear_cache!
      expect(Cache::CACHE).to be_empty
    end
  end
end
