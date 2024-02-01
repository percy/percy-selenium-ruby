# rubocop:disable RSpec/MultipleDescribes
RSpec.describe Percy, type: :feature do
  before(:each) do
    WebMock.disable_net_connect!(allow: '127.0.0.1', disallow: 'localhost')
    Percy._clear_cache!
  end

  describe 'snapshot', type: :feature, js: true do
    it 'disables when healthcheck version is incorrect' do
      stub_request(:get, "#{Percy::PERCY_SERVER_ADDRESS}/percy/healthcheck")
        .to_return(status: 200, body: '', headers: {'x-percy-core-version': '0.1.0'})

      expect { Percy.snapshot(page, 'Name') }
        .to output("#{Percy::LABEL} Unsupported Percy CLI version, 0.1.0\n").to_stdout
    end

    it 'disables when healthcheck version is missing' do
      stub_request(:get, "#{Percy::PERCY_SERVER_ADDRESS}/percy/healthcheck")
        .to_return(status: 200, body: '', headers: {})

      expect { Percy.snapshot(page, 'Name') }
        .to output(
          "#{Percy::LABEL} You may be using @percy/agent which" \
          ' is no longer supported by this SDK. Please uninstall' \
          ' @percy/agent and install @percy/cli instead.' \
          " https://docs.percy.io/docs/migrating-to-percy-cli\n",
        ).to_stdout
    end

    it 'disables when healthcheck fails' do
      stub_request(:get, "#{Percy::PERCY_SERVER_ADDRESS}/percy/healthcheck")
        .to_return(status: 500, body: '', headers: {})

      expect { Percy.snapshot(page, 'Name') }
        .to output("#{Percy::LABEL} Percy is not running, disabling snapshots\n").to_stdout
    end

    it 'disables when healthcheck fails to connect' do
      stub_request(:get, "#{Percy::PERCY_SERVER_ADDRESS}/percy/healthcheck")
        .to_raise(StandardError)

      expect { Percy.snapshot(page, 'Name') }
        .to output("#{Percy::LABEL} Percy is not running, disabling snapshots\n").to_stdout
    end

    it 'throws an error when driver is not provided' do
      stub_request(:get, "#{Percy::PERCY_SERVER_ADDRESS}/percy/healthcheck")
        .to_return(status: 500, body: '', headers: {})

      expect { Percy.snapshot }.to raise_error(ArgumentError)
    end

    it 'throws an error when name is not provided' do
      stub_request(:get, "#{Percy::PERCY_SERVER_ADDRESS}/percy/healthcheck")
        .to_return(status: 500, body: '', headers: {})

      expect { Percy.snapshot(page) }.to raise_error(ArgumentError)
    end

    it 'logs an error  when sending a snapshot fails' do
      stub_request(:get, "#{Percy::PERCY_SERVER_ADDRESS}/percy/healthcheck")
        .to_return(status: 200, body: '', headers: {'x-percy-core-version': '1.0.0'})

      stub_request(:get, "#{Percy::PERCY_SERVER_ADDRESS}/percy/dom.js")
        .to_return(
          status: 200,
          body: 'window.PercyDOM = { serialize: () => document.documentElement.outerHTML };',
          headers: {},
        )

      stub_request(:post, 'http://localhost:5338/percy/snapshot')
        .to_return(status: 200, body: '', headers: {})

      expect { Percy.snapshot(page, 'Name') }
        .to output("#{Percy::LABEL} Could not take DOM snapshot 'Name'\n").to_stdout
    end

    it 'sends snapshots to the local server' do
      stub_request(:get, "#{Percy::PERCY_SERVER_ADDRESS}/percy/healthcheck")
        .to_return(status: 200, body: '', headers: {'x-percy-core-version': '1.0.0'})

      stub_request(:get, "#{Percy::PERCY_SERVER_ADDRESS}/percy/dom.js")
        .to_return(
          status: 200,
          body: 'window.PercyDOM = { serialize: () => document.documentElement.outerHTML };',
          headers: {},
        )

      stub_request(:post, 'http://localhost:5338/percy/snapshot')
        .to_return(status: 200, body: '{"success": "true" }', headers: {})

      visit 'index.html'
      data = Percy.snapshot(page, 'Name', widths: [944])

      expect(WebMock).to have_requested(:post, "#{Percy::PERCY_SERVER_ADDRESS}/percy/snapshot")
        .with(
          body: {
            name: 'Name',
            url: 'http://127.0.0.1:3003/index.html',
            dom_snapshot:
              "<html><head><title>I am a page</title></head><body>Snapshot me\n</body></html>",
            client_info: "percy-selenium-ruby/#{Percy::VERSION}",
            environment_info: "selenium/#{Selenium::WebDriver::VERSION} ruby/#{RUBY_VERSION}",
            widths: [944],
          }.to_json,
        ).once

      expect(data).to eq(nil)
    end

    it 'sends snapshots for sync' do
      stub_request(:get, "#{Percy::PERCY_SERVER_ADDRESS}/percy/healthcheck")
        .to_return(status: 200, body: '', headers: {'x-percy-core-version': '1.0.0'})

      stub_request(:get, "#{Percy::PERCY_SERVER_ADDRESS}/percy/dom.js")
        .to_return(
          status: 200,
          body: 'window.PercyDOM = { serialize: () => document.documentElement.outerHTML };',
          headers: {},
        )

      stub_request(:post, 'http://localhost:5338/percy/snapshot')
        .to_return(status: 200, body: '{"success": "true", "data": "sync_data" }', headers: {})

      visit 'index.html'
      data = Percy.snapshot(page, 'Name', { :sync => true })

      expect(WebMock).to have_requested(:post, "#{Percy::PERCY_SERVER_ADDRESS}/percy/snapshot")
        .with(
          body: {
            name: 'Name',
            url: 'http://127.0.0.1:3003/index.html',
            dom_snapshot:
              "<html><head><title>I am a page</title></head><body>Snapshot me\n</body></html>",
            client_info: "percy-selenium-ruby/#{Percy::VERSION}",
            environment_info: "selenium/#{Selenium::WebDriver::VERSION} ruby/#{RUBY_VERSION}",
            widths: [944],
          }.to_json,
        ).once

      expect(data).to eq('sync_data')
    end
  end
end

RSpec.describe Percy, type: :feature do
  before(:each) do
    WebMock.reset!
    WebMock.allow_net_connect!
    Percy._clear_cache!
  end

  describe 'integration', type: :feature do
    it 'sends snapshots to percy server' do
      visit 'index.html'
      Percy.snapshot(page, 'Name', widths: [375])
      sleep 5 # wait for percy server to process
      resp = Net::HTTP.get_response(URI("#{Percy::PERCY_SERVER_ADDRESS}/test/requests"))
      requests = JSON.parse(resp.body)['requests']
      healthcheck = requests[0]
      expect(healthcheck['url']).to eq('/percy/healthcheck')

      snap = requests[2]['body']
      expect(snap['name']).to eq('Name')
      expect(snap['url']).to eq('http://127.0.0.1:3003/index.html')
      expect(snap['client_info']).to include('percy-selenium-ruby')
      expect(snap['environment_info']).to include('selenium')
      expect(snap['widths']).to eq([375])
    end
  end
end
# rubocop:enable RSpec/MultipleDescribes
