require 'spec_helper'

RSpec.describe DriverMetaData do
  let(:session_id) { 'session_id_123' }
  let(:url) { 'http://hub:4444/wd/hub' }
  let(:caps_hash) { { 'browser' => 'chrome', 'platform' => 'windows', 'browserVersion' => '115.0.1' } }

  before(:each) do
    Cache.clear_cache!
    stub_request(:post, 'http://localhost:5338/percy/log').to_return(status: 200, body: '', headers: {})
  end

  describe '#session_id' do
    it 'returns the session id from the driver' do
      driver = double('WebDriver', session_id: session_id)
      metadata = DriverMetaData.new(driver)
      expect(metadata.session_id).to eq(session_id)
    end
  end

  describe '#command_executor_url' do
    let(:http_double) { double('http') }
    let(:bridge_double) { double('bridge', http: http_double) }
    let(:mock_driver) do
      d = double('WebDriver', session_id: session_id)
      allow(d).to receive(:bridge).and_return(bridge_double)
      d
    end

    context 'when bridge.http.server_url succeeds' do
      before do
        allow(http_double).to receive(:server_url).and_return(URI(url))
      end

      it 'returns the command executor url' do
        metadata = DriverMetaData.new(mock_driver)
        expect(metadata.command_executor_url).to eq(url)
      end

      it 'caches the url and returns it on subsequent calls without re-fetching' do
        metadata = DriverMetaData.new(mock_driver)
        metadata.command_executor_url
        metadata.command_executor_url
        expect(mock_driver).to have_received(:bridge).once
        expect(Cache.get_cache(session_id, Cache::COMMAND_EXECUTOR_URL)).to eq(url)
      end
    end

    context 'when bridge.http.server_url raises but @server_url ivar succeeds' do
      before do
        allow(http_double).to receive(:server_url).and_raise(StandardError, 'server_url failed')
        allow(http_double).to receive(:instance_variable_get).with(:@server_url).and_return(URI(url))
      end

      it 'falls back to @server_url instance variable and returns the url' do
        metadata = DriverMetaData.new(mock_driver)
        expect(metadata.command_executor_url).to eq(url)
      end
    end

    context 'when both server_url and @server_url ivar raise' do
      before do
        allow(http_double).to receive(:server_url).and_raise(StandardError)
        allow(http_double).to receive(:instance_variable_get).with(:@server_url).and_raise(StandardError)
      end

      it 'returns an empty string' do
        metadata = DriverMetaData.new(mock_driver)
        expect(metadata.command_executor_url).to eq('')
      end
    end

    context 'when bridge access itself raises' do
      let(:mock_driver) do
        d = double('WebDriver', session_id: session_id)
        allow(d).to receive(:bridge).and_raise(StandardError, 'bridge not available')
        d
      end

      it 'returns an empty string' do
        metadata = DriverMetaData.new(mock_driver)
        expect(metadata.command_executor_url).to eq('')
      end
    end
  end

  describe '#capabilities' do
    let(:caps_double) { double('Capabilities') }
    let(:mock_driver) { double('WebDriver', session_id: session_id, capabilities: caps_double) }

    context 'when as_json succeeds' do
      before { allow(caps_double).to receive(:as_json).and_return(caps_hash) }

      it 'returns capabilities as json' do
        metadata = DriverMetaData.new(mock_driver)
        expect(metadata.capabilities).to eq(caps_hash)
      end

      it 'caches capabilities and returns them on subsequent calls without re-fetching' do
        metadata = DriverMetaData.new(mock_driver)
        metadata.capabilities
        metadata.capabilities
        expect(caps_double).to have_received(:as_json).once
        expect(Cache.get_cache(session_id, Cache::CAPABILITIES)).to eq(caps_hash)
      end
    end

    context 'when as_json raises but to_h succeeds' do
      before do
        allow(caps_double).to receive(:as_json).and_raise(StandardError)
        allow(caps_double).to receive(:to_h).and_return(caps_hash)
      end

      it 'falls back to to_h' do
        metadata = DriverMetaData.new(mock_driver)
        expect(metadata.capabilities).to eq(caps_hash)
      end
    end

    context 'when both as_json and to_h raise' do
      before do
        allow(caps_double).to receive(:as_json).and_raise(StandardError)
        allow(caps_double).to receive(:to_h).and_raise(StandardError)
      end

      it 'returns an empty hash' do
        metadata = DriverMetaData.new(mock_driver)
        expect(metadata.capabilities).to eq({})
      end
    end
  end
end
