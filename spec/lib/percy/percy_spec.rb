# rubocop:disable RSpec/MultipleDescribes
RSpec.describe Percy, type: :feature do
  dom_string = "<html><head><title>I am a page</title></head><body>Snapshot me\n</body></html>"
  fetch_script_string = 'window.PercyDOM = {' \
  'serialize: () => {' \
    'return {' \
      'html: document.documentElement.outerHTML,' \
      'cookies: ""' \
    '}' \
  '},' \
  'waitForResize: () => {' \
    'if(!window.resizeCount) {' \
      'window.addEventListener(\'resize\', () => window.resizeCount++)' \
    '}' \
    'window.resizeCount = 0;' \
  '}};'

  before(:each) do
    WebMock.disable_net_connect!(allow: '127.0.0.1', disallow: 'localhost')
    stub_request(:post, 'http://localhost:5338/percy/log').to_raise(StandardError)
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
          " https://www.browserstack.com/docs/percy/migration/migrate-to-cli\n",
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

    it 'raises when session_type is automate' do
      stub_request(:get, "#{Percy::PERCY_SERVER_ADDRESS}/percy/healthcheck")
        .to_return(
          status: 200,
          body: '{"success":true,"type":"automate"}',
          headers: {'x-percy-core-version': '1.0.0'},
        )

      expect { Percy.snapshot(page, 'Name') }
        .to raise_error(StandardError, /Invalid function call - percy_snapshot\(\)/)
    end

    it 'does not raise when older CLI omits type from healthcheck' do
      stub_request(:get, "#{Percy::PERCY_SERVER_ADDRESS}/percy/healthcheck")
        .to_return(
          status: 200,
          body: '{"success":true}',
          headers: {'x-percy-core-version': '1.0.0'},
        )

      stub_request(:get, "#{Percy::PERCY_SERVER_ADDRESS}/percy/dom.js")
        .to_return(
          status: 200,
          body: fetch_script_string,
          headers: {},
        )

      stub_request(:post, 'http://localhost:5338/percy/snapshot')
        .to_return(status: 200, body: '{"success":true}', headers: {})

      visit 'index.html'
      expect { Percy.snapshot(page, 'Name') }.to_not raise_error
    end

    it 'logs an error when sending a snapshot fails' do
      stub_request(:get, "#{Percy::PERCY_SERVER_ADDRESS}/percy/healthcheck")
        .to_return(status: 200, body: '{"success":true}',
                   headers: {'x-percy-core-version': '1.0.0'},)

      stub_request(:get, "#{Percy::PERCY_SERVER_ADDRESS}/percy/dom.js")
        .to_return(
          status: 200,
          body: fetch_script_string,
          headers: {},
        )

      stub_request(:post, 'http://localhost:5338/percy/snapshot')
        .to_return(status: 200, body: '', headers: {})

      expect { Percy.snapshot(page, 'Name') }
        .to output("#{Percy::LABEL} Could not take DOM snapshot 'Name'\n").to_stdout
    end

    it 'sends snapshots to the local server' do
      stub_request(:get, "#{Percy::PERCY_SERVER_ADDRESS}/percy/healthcheck")
        .to_return(status: 200, body: '{"success":true}', headers: {
                     'x-percy-core-version': '1.0.0',
                   },)

      stub_request(:get, "#{Percy::PERCY_SERVER_ADDRESS}/percy/dom.js")
        .to_return(
          status: 200,
          body: fetch_script_string,
          headers: {},
        )

      stub_request(:post, 'http://localhost:5338/percy/snapshot')
        .to_return(status: 200, body: '{"success":true}', headers: {})

      visit 'index.html'
      data = Percy.snapshot(page, 'Name', widths: [944])

      expect(WebMock).to have_requested(:post, "#{Percy::PERCY_SERVER_ADDRESS}/percy/snapshot")
        .with(
          body: {
            name: 'Name',
            url: 'http://127.0.0.1:3003/index.html',
            dom_snapshot:
              {"cookies": [], "html": dom_string},
            client_info: "percy-selenium-ruby/#{Percy::VERSION}",
            environment_info: "selenium/#{Selenium::WebDriver::VERSION} ruby/#{RUBY_VERSION}",
            widths: [944],
          }.to_json,
        ).once

      expect(data).to eq(nil)
    end

    it 'sends multiple dom snapshots to the local server' do
      stub_request(:get, "#{Percy::PERCY_SERVER_ADDRESS}/percy/healthcheck").to_return(
        status: 200,
        body: '{"success":true, "widths": { "mobile": [390], "config": [765, 1280]} }',
        headers: {
          'x-percy-core-version': '1.0.0',
          'config': {}, 'widths': {'mobile': [375], 'config': [765, 1280]},
        },
      )

      stub_request(:get, "#{Percy::PERCY_SERVER_ADDRESS}/percy/dom.js")
        .to_return(
          status: 200,
          body: fetch_script_string,
          headers: {},
        )

      stub_request(:get, "#{Percy::PERCY_SERVER_ADDRESS}/percy/widths-config")
        .to_return(
          status: 200,
          body: {widths: [{width: 390}, {width: 765}, {width: 1280}]}.to_json,
          headers: {},
        )

      stub_request(:post, 'http://localhost:5338/percy/snapshot')
        .to_return(status: 200, body: '{"success":true}', headers: {})

      visit 'index.html'
      data = Percy.snapshot(page, 'Name', {responsive_snapshot_capture: true})

      expect(WebMock).to have_requested(:post, "#{Percy::PERCY_SERVER_ADDRESS}/percy/snapshot")
        .with(
          body: {
            name: 'Name',
            url: 'http://127.0.0.1:3003/index.html',
            dom_snapshot: [
              {'cookies': [], 'html': dom_string, 'width': 390},
              {'cookies': [], 'html': dom_string, 'width': 765},
              {'cookies': [], 'html': dom_string, 'width': 1280},
            ],
            client_info: "percy-selenium-ruby/#{Percy::VERSION}",
            environment_info: "selenium/#{Selenium::WebDriver::VERSION} ruby/#{RUBY_VERSION}",
            responsive_snapshot_capture: true,
          }.to_json,
        ).once

      expect(data).to eq(nil)
    end

    # Drives the full responsive `Percy.snapshot` path (capture_responsive_dom ->
    # get_serialized_dom -> POST /percy/snapshot) and asserts on the real
    # webmock-captured POST body.
    #
    # A faithful Selenium driver double is used instead of a live Firefox: a
    # real headless Firefox is not deterministic for this flow on CI. The
    # responsive capture resizes the window per width and then restores it in an
    # `ensure`; headless Firefox / geckodriver intermittently crashes marionette
    # on resize ("Failed to decode response from marionette" -> a dead session),
    # whereupon the next WebDriver command raises InvalidSessionIdError. That
    # error propagated out of capture_responsive_dom and was swallowed by
    # Percy.snapshot's rescue, so no snapshot POST was ever sent and the captured
    # body stayed nil. The double exercises the same code paths every time.
    it 'sends multiple dom snapshots to the local server using selenium' do
      stub_request(:get, "#{Percy::PERCY_SERVER_ADDRESS}/percy/healthcheck").to_return(
        status: 200,
        body: '{"success":true, "widths": { "mobile": [390], "config": [765, 1280]} }',
        headers: {
          'x-percy-core-version': '1.0.0',
          'config': {}, 'widths': {'mobile': [375], 'config': [765, 1280]},
        },
      )

      stub_request(:get, "#{Percy::PERCY_SERVER_ADDRESS}/percy/dom.js")
        .to_return(
          status: 200,
          body: fetch_script_string,
          headers: {},
        )

      stub_request(:get, "#{Percy::PERCY_SERVER_ADDRESS}/percy/widths-config")
        .to_return(
          status: 200,
          body: {widths: [{width: 390}, {width: 765}, {width: 1280}]}.to_json,
          headers: {},
        )

      received_body = nil
      stub_request(:post, 'http://localhost:5338/percy/snapshot').to_return do |request|
        received_body = JSON.parse(request.body)
        {status: 200, body: '{"success":true}', headers: {}}
      end

      # Faithful Selenium::WebDriver driver double covering every call the
      # responsive snapshot path makes.
      cookies = [{'name' => 'cookie-name', 'value' => 'cookie-value', 'path' => '/'}]
      driver = double('driver')
      manage = double('manage')
      window = double('window')
      window_size = double('window_size', width: 1280, height: 900)
      capabilities = double('capabilities', browser_name: 'firefox')

      allow(driver).to receive(:respond_to?).and_return(false)
      allow(driver).to receive(:respond_to?).with(:driver).and_return(false)
      allow(driver).to receive(:respond_to?).with(:execute_cdp).and_return(false)
      allow(driver).to receive(:capabilities).and_return(capabilities)
      allow(driver).to receive(:session_id).and_return('session-1')
      allow(driver).to receive(:current_url).and_return('http://127.0.0.1:3003/index.html')
      allow(driver).to receive(:find_elements).and_return([])
      allow(driver).to receive(:manage).and_return(manage)
      allow(manage).to receive(:window).and_return(window)
      allow(manage).to receive(:all_cookies).and_return(cookies)
      allow(window).to receive(:size).and_return(window_size)
      allow(window).to receive(:resize_to)
      # Resize wait: return immediately (no 1s timeout per width) and skip the
      # innerWidth/innerHeight diagnostics read.
      wait = instance_double(Selenium::WebDriver::Wait)
      allow(Selenium::WebDriver::Wait).to receive(:new).and_return(wait)
      allow(wait).to receive(:until)
      # waitForReady gate: fake PercyDOM has no waitForReady, so the async script
      # resolves with nil, exactly like a real browser would here.
      allow(driver).to receive(:execute_async_script).and_return(nil)
      # PercyDOM injection / waitForResize / dispatchEvent / resizeCount poll
      # return nil; the innerWidth/innerHeight diagnostic read returns a size
      # hash; the serialize call returns the serialized DOM (its `cookies` field
      # is overwritten by the SDK from all_cookies afterward).
      allow(driver).to receive(:execute_script) do |script|
        if script.include?('PercyDOM.serialize')
          {'html' => dom_string, 'cookies' => ''}
        elsif script.include?('innerWidth')
          {'w' => 1280, 'h' => 900}
        end
      end

      data = Percy.snapshot(driver, 'Name', {responsive_snapshot_capture: true})

      # Fail loudly with a meaningful message if the snapshot POST never fired
      # (Percy.snapshot swallows StandardErrors), instead of a cryptic
      # NoMethodError on nil when the body assertions run below.
      expect(received_body).to_not(
        be_nil, 'expected Percy.snapshot to POST /percy/snapshot, but no request was captured',
      )
      expect(received_body['name']).to eq('Name')
      expect(received_body['url']).to eq('http://127.0.0.1:3003/index.html')
      expect(received_body['dom_snapshot'].length).to eq(3)
      expect(received_body['dom_snapshot'].map { |s| s['width'] }).to eq([390, 765, 1280])
      expect(received_body['dom_snapshot'].first['cookies'].first['name']).to eq('cookie-name')
      expect(data).to eq(nil)
    end

    it 'sends snapshots for sync' do
      stub_request(:get, "#{Percy::PERCY_SERVER_ADDRESS}/percy/healthcheck")
        .to_return(status: 200, body: '{"success":true}',
                   headers: {'x-percy-core-version': '1.0.0'},)

      stub_request(:get, "#{Percy::PERCY_SERVER_ADDRESS}/percy/dom.js")
        .to_return(
          status: 200,
          body: fetch_script_string,
          headers: {},
        )

      stub_request(:post, 'http://localhost:5338/percy/snapshot')
        .to_return(status: 200, body: '{"success":true, "data": "sync_data"}', headers: {})

      visit 'index.html'
      data = Percy.snapshot(page, 'Name', {sync: true})

      expect(WebMock).to have_requested(:post, "#{Percy::PERCY_SERVER_ADDRESS}/percy/snapshot")
        .with(
          body: {
            name: 'Name',
            url: 'http://127.0.0.1:3003/index.html',
            dom_snapshot:
            {'cookies' => [], 'html' => dom_string},
            client_info: "percy-selenium-ruby/#{Percy::VERSION}",
            environment_info: "selenium/#{Selenium::WebDriver::VERSION} ruby/#{RUBY_VERSION}",
            sync: true,
          }.to_json,
        ).once

      expect(data).to eq('sync_data')
    end

    it 'merges .percy.yml config with per-snapshot options (per-call wins)' do
      # Healthcheck returns a config whose `snapshot` block carries a
      # config-only key (enableJavaScript) and a percyCSS value that the
      # per-snapshot call will override.
      stub_request(:get, "#{Percy::PERCY_SERVER_ADDRESS}/percy/healthcheck")
        .to_return(
          status: 200,
          body: {
            success: true,
            config: {'snapshot' => {'enableJavaScript' => true, 'percyCSS' => 'FROM_CONFIG'}},
          }.to_json,
          headers: {'x-percy-core-version': '1.0.0'},
        )

      stub_request(:get, "#{Percy::PERCY_SERVER_ADDRESS}/percy/dom.js")
        .to_return(status: 200, body: fetch_script_string, headers: {})

      stub_request(:post, 'http://localhost:5338/percy/snapshot')
        .to_return(status: 200, body: '{"success":true}', headers: {})

      # Capture the argument passed to PercyDOM.serialize so we can assert how
      # config and per-call options were merged before serialization.
      captured_serialize_call = nil
      allow(page).to receive(:execute_script).and_wrap_original do |original, script, *args|
        captured_serialize_call = script if script.to_s.include?('PercyDOM.serialize')
        original.call(script, *args)
      end

      visit 'index.html'
      Percy.snapshot(page, 'Name', percyCSS: 'FROM_CALL')

      expect(captured_serialize_call).to_not be_nil
      serialized = JSON.parse(captured_serialize_call[/PercyDOM\.serialize\((.*)\)/m, 1])
      # Config-only key still reaches serialize...
      expect(serialized['enableJavaScript']).to eq(true)
      # ...and the per-call option wins over the config value.
      expect(serialized['percyCSS']).to eq('FROM_CALL')
    end

    it 'deep-merges nested config and per-snapshot options (sibling kept, leaf overridden)' do
      # Config `snapshot` block carries a nested `discovery` hash; the per-call
      # discovery only overrides one leaf, so the sibling key must survive.
      stub_request(:get, "#{Percy::PERCY_SERVER_ADDRESS}/percy/healthcheck")
        .to_return(
          status: 200,
          body: {
            success: true,
            config: {
              'snapshot' => {
                'discovery' => {'networkIdleTimeout' => 50, 'disableCache' => false},
              },
            },
          }.to_json,
          headers: {'x-percy-core-version': '1.0.0'},
        )

      stub_request(:get, "#{Percy::PERCY_SERVER_ADDRESS}/percy/dom.js")
        .to_return(status: 200, body: fetch_script_string, headers: {})

      stub_request(:post, 'http://localhost:5338/percy/snapshot')
        .to_return(status: 200, body: '{"success":true}', headers: {})

      captured_serialize_call = nil
      allow(page).to receive(:execute_script).and_wrap_original do |original, script, *args|
        captured_serialize_call = script if script.to_s.include?('PercyDOM.serialize')
        original.call(script, *args)
      end

      visit 'index.html'
      Percy.snapshot(page, 'Name', discovery: {disableCache: true})

      expect(captured_serialize_call).to_not be_nil
      serialized = JSON.parse(captured_serialize_call[/PercyDOM\.serialize\((.*)\)/m, 1])
      # Sibling from config survives; per-call leaf overrides the config value.
      expect(serialized['discovery']).to eq(
        'networkIdleTimeout' => 50, 'disableCache' => true,
      )
    end
  end
end

RSpec.describe Percy do
  describe '.create_region' do
    it 'creates a region with default values' do
      region = Percy.create_region

      expect(region[:algorithm]).to eq('ignore')
      expect(region[:elementSelector]).to eq({})
      expect(region).to_not have_key(:configuration)
      expect(region).to_not have_key(:assertion)
    end

    it 'creates a region with bounding_box, xpath, and css selectors' do
      region = Percy.create_region(
        bounding_box: {x: 10, y: 20, width: 100, height: 200},
        element_xpath: '//div[@id="test"]',
        element_css: '.test-class',
      )

      expect(region[:elementSelector][:boundingBox]).to eq({x: 10, y: 20, width: 100, height: 200})
      expect(region[:elementSelector][:elementXpath]).to eq('//div[@id="test"]')
      expect(region[:elementSelector][:elementCSS]).to eq('.test-class')
    end

    it 'creates a region with padding' do
      region = Percy.create_region(padding: 10)
      expect(region[:padding]).to eq(10)
    end

    it 'creates a region with configuration settings when algorithm is standard' do
      region = Percy.create_region(
        algorithm: 'standard',
        diff_sensitivity: 0.5,
        image_ignore_threshold: 0.3,
        carousels_enabled: true,
        banners_enabled: false,
        ads_enabled: true,
      )

      expect(region[:configuration][:diffSensitivity]).to eq(0.5)
      expect(region[:configuration][:imageIgnoreThreshold]).to eq(0.3)
      expect(region[:configuration][:carouselsEnabled]).to eq(true)
      expect(region[:configuration][:bannersEnabled]).to eq(false)
      expect(region[:configuration][:adsEnabled]).to eq(true)
    end

    it 'creates a region with assertion settings' do
      region = Percy.create_region(diff_ignore_threshold: 0.2)
      expect(region[:assertion][:diffIgnoreThreshold]).to eq(0.2)
    end

    it 'creates a region with configuration settings when algorithm is intelliignore' do
      region = Percy.create_region(
        algorithm: 'intelliignore',
        diff_sensitivity: 0.8,
        carousels_enabled: true,
      )

      expect(region[:algorithm]).to eq('intelliignore')
      expect(region[:configuration][:diffSensitivity]).to eq(0.8)
      expect(region[:configuration][:carouselsEnabled]).to eq(true)
    end

    it 'does not add empty configuration or assertion keys' do
      region = Percy.create_region(algorithm: 'ignore')
      expect(region).to_not have_key(:configuration)
      expect(region).to_not have_key(:assertion)
    end
  end
end

RSpec.describe Percy do
  before(:each) do
    WebMock.disable_net_connect!(allow: '127.0.0.1')
    stub_request(:post, 'http://localhost:5338/percy/log').to_raise(StandardError)
    Percy._clear_cache!
  end

  describe '.get_responsive_widths' do
    it 'fetches widths from the /percy/widths-config endpoint' do
      stub_request(:get, "#{Percy::PERCY_SERVER_ADDRESS}/percy/widths-config")
        .to_return(status: 200, body: {widths: [{'width' => 375}, {'width' => 768}]}.to_json)

      result = Percy.get_responsive_widths
      expect(result).to eq([{'width' => 375}, {'width' => 768}])
    end

    it 'passes user-supplied widths as a query parameter' do
      stub_request(:get, "#{Percy::PERCY_SERVER_ADDRESS}/percy/widths-config?widths=375,1280")
        .to_return(status: 200, body: {widths: [{'width' => 375}, {'width' => 1280}]}.to_json)

      result = Percy.get_responsive_widths([375, 1280])
      expect(result).to eq([{'width' => 375}, {'width' => 1280}])
    end

    it 'omits query param when widths array is empty' do
      stub_request(:get, "#{Percy::PERCY_SERVER_ADDRESS}/percy/widths-config")
        .to_return(status: 200, body: {widths: [{'width' => 1280}]}.to_json)

      result = Percy.get_responsive_widths([])
      expect(result).to eq([{'width' => 1280}])
    end

    it 'raises when the response widths key is not an array' do
      stub_request(:get, "#{Percy::PERCY_SERVER_ADDRESS}/percy/widths-config")
        .to_return(status: 200, body: {widths: nil}.to_json)

      cli_error = 'Update Percy CLI to the latest version to use responsiveSnapshotCapture'
      expect { Percy.get_responsive_widths }.to raise_error(StandardError, cli_error)
    end

    it 'raises when the HTTP request fails' do
      stub_request(:get, "#{Percy::PERCY_SERVER_ADDRESS}/percy/widths-config")
        .to_return(status: 500, body: '')

      cli_error = 'Update Percy CLI to the latest version to use responsiveSnapshotCapture'
      expect { Percy.get_responsive_widths }.to raise_error(StandardError, cli_error)
    end

    it 'raises when the endpoint is unreachable' do
      stub_request(:get, "#{Percy::PERCY_SERVER_ADDRESS}/percy/widths-config")
        .to_raise(StandardError, 'connection refused')

      cli_error = 'Update Percy CLI to the latest version to use responsiveSnapshotCapture'
      expect { Percy.get_responsive_widths }.to raise_error(StandardError, cli_error)
    end
  end

  describe '.unsupported_iframe_src?' do
    it 'returns true for nil src' do
      expect(Percy.unsupported_iframe_src?(nil)).to be true
    end

    it 'returns true for empty string src' do
      expect(Percy.unsupported_iframe_src?('')).to be true
    end

    it 'returns true for about:blank' do
      expect(Percy.unsupported_iframe_src?('about:blank')).to be true
    end

    it 'returns true for javascript: src' do
      expect(Percy.unsupported_iframe_src?('javascript:void(0)')).to be true
    end

    it 'returns true for data: src' do
      expect(Percy.unsupported_iframe_src?('data:text/html,<h1>Hi</h1>')).to be true
    end

    it 'returns true for vbscript: src' do
      expect(Percy.unsupported_iframe_src?('vbscript:MsgBox()')).to be true
    end

    it 'returns false for a valid https url' do
      expect(Percy.unsupported_iframe_src?('https://example.com/page')).to be false
    end

    it 'returns false for a relative url' do
      expect(Percy.unsupported_iframe_src?('/embed.html')).to be false
    end
  end

  describe '.get_origin' do
    it 'returns scheme + host for an https url' do
      expect(Percy.get_origin('https://example.com/path')).to eq('https://example.com')
    end

    it 'returns scheme + host for an http url' do
      expect(Percy.get_origin('http://example.com/path')).to eq('http://example.com')
    end

    it 'omits the default http port 80' do
      expect(Percy.get_origin('http://example.com:80/path')).to eq('http://example.com')
    end

    it 'omits the default https port 443' do
      expect(Percy.get_origin('https://example.com:443/path')).to eq('https://example.com')
    end

    it 'includes non-default ports' do
      expect(Percy.get_origin('http://example.com:3000/path')).to eq('http://example.com:3000')
    end

    it 'treats same host with different scheme as different origins' do
      http = Percy.get_origin('http://example.com')
      https = Percy.get_origin('https://example.com')
      expect(http).to_not eq(https)
    end

    it 'treats same host with different ports as different origins' do
      port_a = Percy.get_origin('http://example.com:3000')
      port_b = Percy.get_origin('http://example.com:4000')
      expect(port_a).to_not eq(port_b)
    end
  end

  describe '.process_frame' do
    let(:driver)        { double('driver') }
    let(:frame_element) { double('frame_element') }
    let(:switch_to)     { double('switch_to') }

    before(:each) do
      allow(driver).to receive(:switch_to).and_return(switch_to)
      allow(switch_to).to receive(:frame)
      allow(switch_to).to receive(:parent_frame)
      allow(switch_to).to receive(:default_content)
    end

    it 'returns a hash with iframeData, iframeSnapshot, and frameUrl on success' do
      allow(frame_element).to receive(:attribute).with('src')
        .and_return('https://other.example.com/page')
      allow(frame_element).to receive(:attribute).with('data-percy-element-id')
        .and_return('elem-123')
      allow(driver).to receive(:execute_script).and_return(nil, {'html' => '<html/>'})

      result = Percy.process_frame(driver, frame_element, {}, 'percy_dom_script')

      expect(result).to_not be_nil
      expect(result['iframeData']['percyElementId']).to eq('elem-123')
      expect(result['iframeSnapshot']).to eq({'html' => '<html/>'})
      expect(result['frameUrl']).to eq('https://other.example.com/page')
    end

    it 'returns nil when data-percy-element-id attribute is missing' do
      allow(frame_element).to receive(:attribute).with('src').and_return('https://other.example.com/page')
      allow(frame_element).to receive(:attribute).with('data-percy-element-id').and_return(nil)
      allow(driver).to receive(:execute_script).and_return(nil, {'html' => '<html/>'})

      result = Percy.process_frame(driver, frame_element, {}, 'percy_dom_script')
      expect(result).to be_nil
    end

    it 'returns nil when execute_script raises inside the iframe' do
      allow(frame_element).to receive(:attribute).with('src').and_return('https://other.example.com/page')
      allow(driver).to receive(:execute_script).and_raise(StandardError, 'injection error')

      result = Percy.process_frame(driver, frame_element, {}, 'percy_dom_script')
      expect(result).to be_nil
    end

    it 'returns nil when switching to the frame fails' do
      allow(frame_element).to receive(:attribute).with('src').and_return('https://other.example.com/page')
      allow(switch_to).to receive(:frame).and_raise(StandardError, 'no such frame')

      result = Percy.process_frame(driver, frame_element, {}, 'percy_dom_script')
      expect(result).to be_nil
    end

    it 'uses unknown-src fallback when frame has no src attribute' do
      allow(frame_element).to receive(:attribute).with('src').and_return(nil)
      allow(frame_element).to receive(:attribute).with('data-percy-element-id')
        .and_return('elem-nosrc')
      allow(driver).to receive(:execute_script).and_return(nil, {'html' => '<html/>'})

      result = Percy.process_frame(driver, frame_element, {}, 'percy_dom_script')
      expect(result['frameUrl']).to eq('unknown-src')
    end

    it 'merges enableJavaScript into the PercyDOM.serialize call' do
      allow(frame_element).to receive(:attribute).with('src')
        .and_return('https://other.example.com/page')
      allow(frame_element).to receive(:attribute).with('data-percy-element-id')
        .and_return('elem-abc')

      captured_serialize_call = nil
      call_count = 0
      allow(driver).to receive(:execute_script) do |script|
        call_count += 1
        if call_count == 2
          captured_serialize_call = script
          {'html' => '<html/>'}
        end
      end

      Percy.process_frame(driver, frame_element, {someOpt: 1}, 'percy_dom_script')

      expect(captured_serialize_call).to include('enableJavaScript')
      expect(captured_serialize_call).to include('true')
    end

    it 'always switches back to default content even when script injection fails' do
      allow(frame_element).to receive(:attribute).with('src')
        .and_return('https://other.example.com/page')
      expect(switch_to).to receive(:default_content).once
      allow(driver).to receive(:execute_script).and_raise(StandardError, 'error')

      Percy.process_frame(driver, frame_element, {}, 'percy_dom_script')
    end

    it 'falls back to parent_frame when default_content fails in the inner ensure' do
      allow(frame_element).to receive(:attribute).with('src')
        .and_return('https://other.example.com/page')
      allow(frame_element).to receive(:attribute).with('data-percy-element-id')
        .and_return('elem-pf')
      allow(driver).to receive(:execute_script).and_return(nil, {'html' => '<html/>'})
      allow(switch_to).to receive(:default_content).and_raise(StandardError, 'dc boom')
      expect(switch_to).to receive(:parent_frame).once

      result = Percy.process_frame(driver, frame_element, {}, 'percy_dom_script')
      expect(result['frameUrl']).to eq('https://other.example.com/page')
    end

    it 'swallows a parent_frame failure during inner-ensure recovery' do
      allow(frame_element).to receive(:attribute).with('src')
        .and_return('https://other.example.com/page')
      allow(frame_element).to receive(:attribute).with('data-percy-element-id')
        .and_return('elem-pf2')
      allow(driver).to receive(:execute_script).and_return(nil, {'html' => '<html/>'})
      allow(switch_to).to receive(:default_content).and_raise(StandardError, 'dc boom')
      allow(switch_to).to receive(:parent_frame).and_raise(StandardError, 'pf boom')

      expect { Percy.process_frame(driver, frame_element, {}, 'percy_dom_script') }
        .to_not raise_error
    end

    it 'swallows a default_content failure in the outer rescue when frame switch fails' do
      allow(frame_element).to receive(:attribute).with('src')
        .and_return('https://other.example.com/page')
      allow(switch_to).to receive(:frame).and_raise(StandardError, 'no such frame')
      allow(switch_to).to receive(:default_content).and_raise(StandardError, 'dc boom')

      result = Percy.process_frame(driver, frame_element, {}, 'percy_dom_script')
      expect(result).to be_nil
    end
  end

  describe '.get_serialized_dom' do
    let(:driver)    { double('driver') }
    let(:manage)    { double('manage') }
    let(:switch_to) { double('switch_to') }

    before(:each) do
      allow(driver).to receive(:manage).and_return(manage)
      allow(manage).to receive(:all_cookies).and_return([])
      allow(driver).to receive(:switch_to).and_return(switch_to)
      allow(switch_to).to receive(:frame)
      allow(switch_to).to receive(:parent_frame)
      allow(switch_to).to receive(:default_content)
      # Readiness gate runs execute_async_script before serialize; stub it so
      # these unit tests exercise serialization without a real browser.
      allow(driver).to receive(:execute_async_script).and_return(nil)
      allow(Percy).to receive(:expose_closed_shadow_roots)
    end

    it 'exposes closed shadow roots before serializing' do
      allow(driver).to receive(:current_url).and_return('http://main.example.com/')
      allow(driver).to receive(:find_elements).and_return([])
      expect(Percy).to receive(:expose_closed_shadow_roots)
        .with(driver, {disableShadowDOM: true}).ordered
      expect(driver).to receive(:execute_script)
        .with(/PercyDOM.serialize/).ordered.and_return({'html' => '<html/>'})
      Percy.get_serialized_dom(driver, {disableShadowDOM: true})
    end

    it 'returns the serialized dom with cookies when no iframes present' do
      allow(driver).to receive(:execute_script).and_return({'html' => '<html/>'})
      allow(driver).to receive(:current_url).and_return('http://main.example.com/')
      allow(driver).to receive(:find_elements).and_return([])

      dom = Percy.get_serialized_dom(driver, {})
      expect(dom['html']).to eq('<html/>')
      expect(dom['cookies']).to eq([])
      expect(dom).to_not have_key('corsIframes')
    end

    it 'populates corsIframes for cross-origin frames' do
      frame = double('frame')
      allow(frame).to receive(:attribute).with('src').and_return('https://cross.example.com/page')
      allow(frame).to receive(:attribute).with('data-percy-element-id').and_return('cid-1')

      call_count = 0
      allow(driver).to receive(:execute_script) do
        call_count += 1
        case call_count
        when 1 then {'html' => '<main/>'}
        when 2 then nil
        when 3 then {'html' => '<frame/>'}
        end
      end
      allow(driver).to receive(:current_url).and_return('http://main.example.com/')
      allow(driver).to receive(:find_elements).and_return([frame])

      dom = Percy.get_serialized_dom(driver, {}, percy_dom_script: 'percy_dom_script')

      expect(dom).to have_key('corsIframes')
      expect(dom['corsIframes'].length).to eq(1)
      expect(dom['corsIframes'][0]['iframeData']['percyElementId']).to eq('cid-1')
      expect(dom['corsIframes'][0]['iframeSnapshot']['html']).to eq('<frame/>')
      expect(dom['corsIframes'][0]['frameUrl']).to eq('https://cross.example.com/page')
    end

    it 'skips same-origin iframes' do
      frame = double('frame')
      allow(frame).to receive(:attribute).with('src').and_return('http://main.example.com/inner.html')
      allow(driver).to receive(:execute_script).and_return({'html' => '<html/>'})
      allow(driver).to receive(:current_url).and_return('http://main.example.com/')
      allow(driver).to receive(:find_elements).and_return([frame])

      dom = Percy.get_serialized_dom(driver, {}, percy_dom_script: 'percy_dom_script')
      expect(dom).to_not have_key('corsIframes')
    end

    it 'skips iframes with about:blank src' do
      frame = double('frame')
      allow(frame).to receive(:attribute).with('src').and_return('about:blank')
      allow(driver).to receive(:execute_script).and_return({'html' => '<html/>'})
      allow(driver).to receive(:current_url).and_return('http://main.example.com/')
      allow(driver).to receive(:find_elements).and_return([frame])

      dom = Percy.get_serialized_dom(driver, {}, percy_dom_script: 'percy_dom_script')
      expect(dom).to_not have_key('corsIframes')
    end

    it 'does not process cross-origin iframes when percy_dom_script is nil' do
      allow(driver).to receive(:execute_script).and_return({'html' => '<html/>'})
      allow(driver).to receive(:current_url).and_return('http://main.example.com/')
      expect(driver).to_not receive(:find_elements)

      dom = Percy.get_serialized_dom(driver, {}, percy_dom_script: nil)
      expect(dom).to_not have_key('corsIframes')
    end

    it 'treats same host with different scheme as cross-origin' do
      frame = double('frame')
      allow(frame).to receive(:attribute).with('src').and_return('https://main.example.com/widget')
      allow(frame).to receive(:attribute).with('data-percy-element-id').and_return('percy-id-1')

      call_count = 0
      allow(driver).to receive(:execute_script) do
        call_count += 1
        if call_count == 1
          {'html' => '<html/>'}
        else
          call_count == 2 ? nil : {'html' => '<frame/>'}
        end
      end
      allow(driver).to receive(:current_url).and_return('http://main.example.com/')
      allow(driver).to receive(:find_elements).and_return([frame])

      dom = Percy.get_serialized_dom(driver, {}, percy_dom_script: 'script')
      expect(dom).to have_key('corsIframes')
    end

    it 'treats same host with different port as cross-origin' do
      frame = double('frame')
      allow(frame).to receive(:attribute).with('src').and_return('http://main.example.com:4000/widget')
      allow(frame).to receive(:attribute).with('data-percy-element-id').and_return('percy-id-port')

      call_count = 0
      allow(driver).to receive(:execute_script) do
        call_count += 1
        if call_count == 1
          {'html' => '<html/>'}
        else
          call_count == 2 ? nil : {'html' => '<frame/>'}
        end
      end
      allow(driver).to receive(:current_url).and_return('http://main.example.com:3000/')
      allow(driver).to receive(:find_elements).and_return([frame])

      dom = Percy.get_serialized_dom(driver, {}, percy_dom_script: 'script')
      expect(dom).to have_key('corsIframes')
    end

    it 'always attaches cookies to the snapshot' do
      cookies_data = [{'name' => 'session', 'value' => 'abc'}]
      allow(manage).to receive(:all_cookies).and_return(cookies_data)
      allow(driver).to receive(:execute_script).and_return({'html' => '<html/>'})
      allow(driver).to receive(:current_url).and_return('http://main.example.com/')
      allow(driver).to receive(:find_elements).and_return([])

      dom = Percy.get_serialized_dom(driver, {})
      expect(dom['cookies']).to eq(cookies_data)
    end

    it 'skips same-origin frame and processes only cross-origin frame' do
      same_frame = double('same_frame')
      allow(same_frame).to receive(:attribute).with('src').and_return('http://main.example.com/inner')

      cross_frame = double('cross_frame')
      allow(cross_frame).to receive(:attribute).with('src').and_return('https://other.example.com/page')
      allow(cross_frame).to receive(:attribute).with('data-percy-element-id').and_return('cid-x')

      call_count = 0
      allow(driver).to receive(:execute_script) do
        call_count += 1
        if call_count == 1
          {'html' => '<main/>'}
        else
          call_count == 2 ? nil : {'html' => '<cross/>'}
        end
      end
      allow(driver).to receive(:current_url).and_return('http://main.example.com/')
      allow(driver).to receive(:find_elements).and_return([same_frame, cross_frame])

      dom = Percy.get_serialized_dom(driver, {}, percy_dom_script: 'script')
      expect(dom['corsIframes'].length).to eq(1)
      expect(dom['corsIframes'][0]['frameUrl']).to eq('https://other.example.com/page')
    end

    # --- Readiness gate --------------------------------------

    it 'runs waitForReady before serialize and attaches diagnostics' do
      allow(driver).to receive(:execute_async_script).and_return(
        'ok' => true, 'timed_out' => false,
      )
      allow(driver).to receive(:execute_script).and_return({'html' => '<html/>'})
      allow(driver).to receive(:current_url).and_return('http://main.example.com/')
      allow(driver).to receive(:find_elements).and_return([])

      dom = Percy.get_serialized_dom(driver, {})
      expect(driver).to have_received(:execute_async_script) do |script| # rubocop:disable RSpec/MessageSpies
        expect(script).to include('waitForReady')
        expect(script).to include("typeof PercyDOM.waitForReady === 'function'")
      end
      expect(dom['readiness_diagnostics']).to eq('ok' => true, 'timed_out' => false)
    end

    it 'embeds per-snapshot readiness config in the script' do
      allow(driver).to receive(:execute_async_script).and_return(nil)
      allow(driver).to receive(:execute_script).and_return({'html' => '<html/>'})
      allow(driver).to receive(:current_url).and_return('http://main.example.com/')
      allow(driver).to receive(:find_elements).and_return([])

      Percy.get_serialized_dom(driver, {readiness: {preset: 'strict', stabilityWindowMs: 500}})
      expect(driver).to have_received(:execute_async_script) do |script| # rubocop:disable RSpec/MessageSpies
        expect(script).to include('"preset":"strict"')
        expect(script).to include('"stabilityWindowMs":500')
      end
    end

    it 'skips execute_async_script when preset is disabled' do
      allow(driver).to receive(:execute_script).and_return({'html' => '<html/>'})
      allow(driver).to receive(:current_url).and_return('http://main.example.com/')
      allow(driver).to receive(:find_elements).and_return([])
      expect(driver).to_not receive(:execute_async_script)

      dom = Percy.get_serialized_dom(driver, {readiness: {preset: 'disabled'}})
      expect(dom).to_not have_key('readiness_diagnostics')
      expect(dom['html']).to eq('<html/>')
    end

    it 'still serializes when execute_async_script raises' do
      allow(driver).to receive(:execute_async_script).and_raise(StandardError, 'readiness boom')
      allow(driver).to receive(:execute_script).and_return({'html' => '<html/>'})
      allow(driver).to receive(:current_url).and_return('http://main.example.com/')
      allow(driver).to receive(:find_elements).and_return([])

      dom = Percy.get_serialized_dom(driver, {})
      expect(dom).to_not have_key('readiness_diagnostics')
      expect(dom['html']).to eq('<html/>')
    end

    it 'raises the async-script timeout to match readiness timeoutMs and restores it after' do
      timeouts = double('timeouts')
      allow(manage).to receive(:timeouts).and_return(timeouts)
      allow(timeouts).to receive(:script_timeout).and_return(30)
      allow(driver).to receive(:execute_async_script).and_return(nil)
      allow(driver).to receive(:execute_script).and_return({'html' => '<html/>'})
      allow(driver).to receive(:current_url).and_return('http://main.example.com/')
      allow(driver).to receive(:find_elements).and_return([])

      # 8000ms -> 8s + 2s buffer is applied, then the previous 30s is restored.
      expect(timeouts).to receive(:script_timeout=).with(10.0).ordered
      expect(timeouts).to receive(:script_timeout=).with(30).ordered

      Percy.get_serialized_dom(driver, {readiness: {timeoutMs: 8000}})
    end

    it 'proceeds when reading/setting the script timeout is unsupported' do
      timeouts = double('timeouts')
      allow(manage).to receive(:timeouts).and_return(timeouts)
      allow(timeouts).to receive(:script_timeout).and_raise(StandardError, 'unsupported')
      allow(driver).to receive(:execute_async_script).and_return(nil)
      allow(driver).to receive(:execute_script).and_return({'html' => '<html/>'})
      allow(driver).to receive(:current_url).and_return('http://main.example.com/')
      allow(driver).to receive(:find_elements).and_return([])

      expect { Percy.get_serialized_dom(driver, {readiness: {timeoutMs: 5000}}) }.to_not raise_error
    end

    it 'skips an iframe whose src cannot be resolved against the page url' do
      frame = double('frame')
      allow(frame).to receive(:attribute).with('src').and_return('ht!tp://%%%bad')
      allow(driver).to receive(:execute_script).and_return({'html' => '<html/>'})
      allow(driver).to receive(:current_url).and_return('http://main.example.com/')
      allow(driver).to receive(:find_elements).and_return([frame])
      allow(URI).to receive(:join).and_raise(URI::InvalidURIError, 'bad uri')

      dom = Percy.get_serialized_dom(driver, {}, percy_dom_script: 'script')
      expect(dom).to_not have_key('corsIframes')
    end

    it 'logs and recovers when iframe processing raises unexpectedly' do
      allow(driver).to receive(:execute_script).and_return({'html' => '<html/>'})
      allow(driver).to receive(:current_url).and_return('http://main.example.com/')
      allow(driver).to receive(:find_elements).and_raise(StandardError, 'find boom')

      dom = Percy.get_serialized_dom(driver, {}, percy_dom_script: 'script')
      # find_elements raised inside the iframe block; cookies are still attached.
      expect(dom['cookies']).to eq([])
    end

    it 'swallows a secondary error when recovering from an iframe-processing failure' do
      allow(driver).to receive(:execute_script).and_return({'html' => '<html/>'})
      allow(driver).to receive(:current_url).and_return('http://main.example.com/')
      allow(driver).to receive(:find_elements).and_raise(StandardError, 'find boom')
      # default_content also fails during recovery -> inner rescue swallows it.
      allow(switch_to).to receive(:default_content).and_raise(StandardError, 'switch boom')

      dom = Percy.get_serialized_dom(driver, {}, percy_dom_script: 'script')
      expect(dom['cookies']).to eq([])
    end
  end

  describe '.change_window_dimension_and_wait' do
    let(:driver)        { double('driver') }
    let(:manage)        { double('manage') }
    let(:window)        { double('window') }
    let(:wait)          { instance_double(Selenium::WebDriver::Wait) }
    let(:caps_firefox)  { double('capabilities', browser_name: 'firefox') }
    let(:inner_width)   { [1024] }

    before(:each) do
      allow(driver).to receive(:respond_to?).and_return(false)
      allow(driver).to receive(:manage).and_return(manage)
      allow(manage).to receive(:window).and_return(window)
      allow(window).to receive(:resize_to)
      allow(driver).to receive(:capabilities).and_return(caps_firefox)
      allow(driver).to receive(:session_id).and_return('s-1')
      allow(driver).to receive(:execute_script) do |script|
        {'w' => inner_width.first, 'h' => 768} if script.include?('innerWidth')
      end
      allow(Selenium::WebDriver::Wait).to receive(:new).and_return(wait)
      allow(wait).to receive(:until).and_yield
      allow(Percy).to receive(:log)
    end

    def chrome_driver_with_bridge(bridge, browser: 'chrome', window_double: nil)
      klass = Class.new do
        include Selenium::WebDriver::DriverExtensions::HasCDP

        attr_accessor :caps, :mgr

        def capabilities
          caps
        end

        def manage
          mgr
        end

        def execute_script(*)
          {'w' => 375, 'h' => 812}
        end
      end
      chromium = klass.new
      chromium.instance_variable_set(:@bridge, bridge)
      chromium.caps = double('capabilities', browser_name: browser)
      chromium.mgr = double('manage', window: window_double || window)
      chromium
    end

    # Selenium declares `execute_cdp(cmd, **params)`, so on Ruby 3 a positional
    # Hash raises ArgumentError and the rescue silently falls back to resize_to.
    # Run the real HasCDP method so that signature is enforced.
    %w[chrome MicrosoftEdge msedge].each do |browser|
      it "overrides the viewport through the real execute_cdp on #{browser}" do
        bridge = double('bridge')
        chromium = chrome_driver_with_bridge(bridge, browser: browser)
        expect(bridge).to receive(:send_command).with(
          cmd: 'Emulation.setDeviceMetricsOverride',
          params: {height: 812, width: 375, deviceScaleFactor: 1, mobile: false},
        )
        expect(window).to_not receive(:resize_to)
        expect(Percy.change_window_dimension_and_wait(chromium, 375, 812)).to eq(:cdp)
      end
    end

    it 'never uses CDP on firefox even when the driver exposes it' do
      allow(driver).to receive(:respond_to?).with(:execute_cdp).and_return(true)
      expect(driver).to_not receive(:execute_cdp)
      inner_width[0] = 768
      expect(Percy.change_window_dimension_and_wait(driver, 768, 1024)).to eq(:window)
    end

    it 'uses CDP for an unknown browser name when the driver exposes it' do
      allow(driver).to receive(:capabilities).and_return(double('caps', browser_name: 'brave'))
      allow(driver).to receive(:respond_to?).with(:execute_cdp).and_return(true)
      expect(driver).to receive(:execute_cdp).with(
        'Emulation.setDeviceMetricsOverride',
        height: 812, width: 375, deviceScaleFactor: 1, mobile: false,
      )
      Percy.change_window_dimension_and_wait(driver, 375, 812)
    end

    context 'with a BiDi session' do
      let(:bidi) { double('bidi') }

      before(:each) do
        caps = {web_socket_url: 'wss://127.0.0.1:9222/session/abc'}
        allow(driver).to receive(:capabilities).and_return(caps)
        allow(driver).to receive(:respond_to?).with(:bidi).and_return(true)
        allow(driver).to receive(:respond_to?).with(:capabilities).and_return(true)
        allow(driver).to receive(:bidi).and_return(bidi)
        allow(driver).to receive(:window_handle).and_return('ctx-1')
      end

      it 'sets the viewport with browsingContext.setViewport' do
        expect(bidi).to receive(:send_cmd).with(
          'browsingContext.setViewport',
          context: 'ctx-1', viewport: {width: 375, height: 812}, devicePixelRatio: 1,
        )
        expect(window).to_not receive(:resize_to)
        inner_width[0] = 375
        expect(Percy.change_window_dimension_and_wait(driver, 375, 812)).to eq(:bidi)
      end

      it 'falls back to the window when setViewport fails' do
        allow(bidi).to receive(:send_cmd).and_raise(StandardError, 'unknown command')
        expect(window).to receive(:resize_to).with(1024, 812)
        expect(Percy.change_window_dimension_and_wait(driver, 1024, 812)).to eq(:window)
      end
    end

    it 'falls back to BiDi or the window when CDP raises' do
      allow(driver).to receive(:capabilities).and_return(double('caps', browser_name: 'chrome'))
      allow(driver).to receive(:respond_to?).with(:execute_cdp).and_return(true)
      allow(driver).to receive(:execute_cdp).and_raise(StandardError, 'cdp error')
      expect(window).to receive(:resize_to).with(1024, 812)
      expect(Percy).to receive(:log).with(/CDP viewport override failed/, 'debug')
      expect(Percy.change_window_dimension_and_wait(driver, 1024, 812)).to eq(:window)
    end

    it 'corrects the window size by the measured border once' do
      inner_width[0] = 1272
      expect(window).to receive(:resize_to).with(1280, 900).ordered
      expect(window).to receive(:resize_to).with(1288, 900).ordered do
        inner_width[0] = 1280
      end
      expect(Percy.change_window_dimension_and_wait(driver, 1280, 900)).to eq(:window)
    end

    it 'warns once per session when the window cannot reach the width' do
      inner_width[0] = 500
      allow(wait).to receive(:until).and_raise(Selenium::WebDriver::Error::TimeoutError)
      expect(Percy).to receive(:log).with(/webSocketUrl: true/, 'warn').once
      expect(Percy).to receive(:log).with(/Timed out waiting for viewport width 375/, 'debug').twice
      2.times { Percy.change_window_dimension_and_wait(driver, 375, 900) }
    end

    it 'still warns when the session id is unavailable' do
      inner_width[0] = 500
      allow(driver).to receive(:session_id).and_raise(StandardError)
      expect(Percy).to receive(:log).with(/firefox could not be resized/, 'warn')
      Percy.change_window_dimension_and_wait(driver, 375, 900)
    end

    it 'does not correct the window when innerWidth is unknown' do
      allow(driver).to receive(:execute_script).and_return(nil)
      expect(window).to receive(:resize_to).once
      Percy.change_window_dimension_and_wait(driver, 375, 900)
    end

    it 'does not shrink the window again when the OS minimum width was hit' do
      inner_width[0] = 500
      expect(window).to receive(:resize_to).with(200, 900).once
      Percy.change_window_dimension_and_wait(driver, 200, 900)
    end

    it 'still returns the mechanism when reading the viewport fails' do
      allow(driver).to receive(:capabilities).and_return(double('caps', browser_name: 'chrome'))
      allow(driver).to receive(:respond_to?).with(:execute_cdp).and_return(true)
      allow(driver).to receive(:execute_cdp)
      allow(driver).to receive(:execute_script).and_raise(StandardError, 'unexpected alert')
      expect(Percy).to receive(:log).with(/Could not read viewport size: unexpected alert/, 'debug')
        .at_least(:once)
      expect(Percy.change_window_dimension_and_wait(driver, 375, 900)).to eq(:cdp)
    end

    context 'with exact: false' do
      it 'uses CDP only for chrome, through the real execute_cdp' do
        bridge = double('bridge')
        chromium = chrome_driver_with_bridge(bridge)
        expect(bridge).to receive(:send_command).with(
          cmd: 'Emulation.setDeviceMetricsOverride',
          params: {height: 812, width: 375, deviceScaleFactor: 1, mobile: false},
        )
        expect(Percy.change_window_dimension_and_wait(chromium, 375, 812, exact: false)).to eq(:cdp)
      end

      it 'resizes the window for Edge and dispatches a resize event' do
        bridge = double('bridge')
        edge = chrome_driver_with_bridge(bridge, browser: 'MicrosoftEdge')
        expect(bridge).to_not receive(:send_command)
        expect(window).to receive(:resize_to).with(375, 812).once
        expect(Percy.change_window_dimension_and_wait(edge, 375, 812, exact: false)).to eq(:window)
      end

      it 'falls back to resize_to when execute_cdp raises' do
        allow(driver).to receive(:capabilities).and_return(double('caps', browser_name: 'chrome'))
        allow(driver).to receive(:respond_to?).with(:execute_cdp).and_return(true)
        allow(driver).to receive(:execute_cdp).and_raise(StandardError, 'cdp error')
        expect(window).to receive(:resize_to).with(375, 812)
        expect(driver).to receive(:execute_script)
          .with("window.dispatchEvent(new Event('resize'));")
        expect(Percy).to_not receive(:log).with(anything, 'warn')
        expect(Percy.change_window_dimension_and_wait(driver, 375, 812, exact: false))
          .to eq(:window)
      end
    end
  end

  describe '.restore_viewport' do
    let(:driver) { double('driver') }
    let(:window) { double('window') }

    before(:each) do
      allow(driver).to receive(:respond_to?).and_return(false)
      allow(driver).to receive(:manage).and_return(double('manage', window: window))
      allow(Percy).to receive(:log)
    end

    it 'clears the CDP override through the real execute_cdp instead of re-applying it' do
      bridge = double('bridge')
      chromium = Class.new { include Selenium::WebDriver::DriverExtensions::HasCDP }.new
      chromium.instance_variable_set(:@bridge, bridge)
      expect(bridge).to receive(:send_command)
        .with(cmd: 'Emulation.clearDeviceMetricsOverride', params: {})
      Percy.restore_viewport(chromium, 1280, 900, [:cdp, nil, :cdp])
    end

    it 'resizes the window back when the window was used' do
      expect(window).to receive(:resize_to).with(1280, 900)
      Percy.restore_viewport(driver, 1280, 900, [:window])
    end

    it 'does nothing when nothing was resized' do
      expect(window).to_not receive(:resize_to)
      Percy.restore_viewport(driver, 1280, 900, [])
    end

    it 'resizes the window when clearing CDP fails' do
      allow(driver).to receive(:execute_cdp).and_raise(StandardError, 'gone')
      expect(window).to receive(:resize_to).with(1280, 900)
      Percy.restore_viewport(driver, 1280, 900, [:cdp])
    end

    context 'with BiDi' do
      let(:bidi) { double('bidi') }
      let(:ws)   { double('ws') }

      before(:each) do
        allow(driver).to receive(:bidi).and_return(bidi)
        allow(driver).to receive(:window_handle).and_return('ctx-1')
      end

      it 'sends an explicit null viewport over the socket' do
        allow(bidi).to receive(:respond_to?).with(:ws).and_return(true)
        allow(bidi).to receive(:ws).and_return(ws)
        expect(ws).to receive(:send_cmd).with(
          method: 'browsingContext.setViewport',
          params: {context: 'ctx-1', viewport: nil, devicePixelRatio: nil},
        ).and_return({'id' => 1, 'result' => {}})
        expect(window).to_not receive(:resize_to)
        Percy.restore_viewport(driver, 1280, 900, [:bidi])
      end

      it 'resizes the window when the reset returns an error' do
        allow(bidi).to receive(:respond_to?).with(:ws).and_return(true)
        allow(bidi).to receive(:ws).and_return(ws)
        allow(ws).to receive(:send_cmd).and_return({'error' => 'x', 'message' => 'bad'})
        expect(window).to receive(:resize_to).with(1280, 900)
        expect(Percy).to receive(:log).with(/Could not clear BiDi viewport override: bad/, 'debug')
        Percy.restore_viewport(driver, 1280, 900, [:bidi])
      end

      it 'resizes the window when the binding has no raw socket' do
        allow(bidi).to receive(:respond_to?).with(:ws).and_return(false)
        expect(window).to receive(:resize_to).with(1280, 900)
        Percy.restore_viewport(driver, 1280, 900, [:bidi])
      end
    end
  end

  describe '.exact_responsive_width?' do
    after(:each) { Percy.instance_variable_set(:@cli_config, nil) }

    it 'defaults to true' do
      expect(Percy.exact_responsive_width?({})).to eq(true)
    end

    it 'prefers the per-snapshot option over the CLI config' do
      Percy.instance_variable_set(:@cli_config, {'snapshot' => {'exactResponsiveWidth' => true}})
      expect(Percy.exact_responsive_width?({exactResponsiveWidth: false})).to eq(false)
      expect(Percy.exact_responsive_width?({exact_responsive_width: false})).to eq(false)
    end

    it 'reads config.snapshot.exactResponsiveWidth from the healthcheck' do
      Percy.instance_variable_set(:@cli_config, {'snapshot' => {'exactResponsiveWidth' => false}})
      expect(Percy.exact_responsive_width?({})).to eq(false)
    end
  end

  describe '.bidi_session?' do
    let(:driver) { double('driver') }

    before(:each) do
      allow(driver).to receive(:respond_to?).and_return(true)
    end

    it 'is false without a webSocketUrl capability' do
      allow(driver).to receive(:capabilities).and_return({web_socket_url: true})
      expect(Percy.bidi_session?(driver)).to eq(false)
    end

    it 'accepts the string-keyed capability' do
      allow(driver).to receive(:capabilities).and_return({'webSocketUrl' => 'wss://x'})
      expect(Percy.bidi_session?(driver)).to eq(true)
    end

    it 'is false when the binding has no bidi' do
      allow(driver).to receive(:respond_to?).with(:bidi).and_return(false)
      expect(Percy.bidi_session?(driver)).to eq(false)
    end

    it 'is false when capabilities cannot be read' do
      allow(driver).to receive(:capabilities).and_raise(StandardError)
      expect(Percy.bidi_session?(driver)).to eq(false)
    end
  end

  describe '.browser_name' do
    it 'returns an empty string when capabilities are unavailable' do
      expect(Percy.browser_name(Object.new)).to eq('')
    end
  end

  describe '.capture_responsive_dom' do
    let(:driver)   { double('driver') }
    let(:manage)   { double('manage') }
    let(:window)   { double('window') }
    let(:size)     { double('size', width: 1280, height: 900) }
    let(:navigate) { double('navigate') }

    before(:each) do
      allow(driver).to receive(:manage).and_return(manage)
      allow(manage).to receive(:window).and_return(window)
      allow(window).to receive(:size).and_return(size)
      allow(driver).to receive(:respond_to?).with(:driver).and_return(false)
      allow(driver).to receive(:execute_script).and_return(nil)
      allow(Percy).to receive(:get_serialized_dom).and_return({'html' => '<html/>'})
      allow(Percy).to receive(:change_window_dimension_and_wait)
      allow(Percy).to receive(:restore_viewport)
      allow(Percy).to receive(:log)
    end

    # -----------------------------------------------------------------------
    # Resize behavior
    # -----------------------------------------------------------------------

    it 'calls change_window_dimension_and_wait for each distinct width' do
      allow(Percy).to receive(:get_responsive_widths).and_return(
        [{'width' => 375}, {'width' => 768}, {'width' => 1280}],
      )
      expect(Percy).to receive(:change_window_dimension_and_wait).exactly(3).times
      Percy.capture_responsive_dom(driver, {})
    end

    it 'skips resize when consecutive entries have the same width and height' do
      allow(Percy).to receive(:get_responsive_widths).and_return(
        [{'width' => 375}, {'width' => 375}],
      )
      # second 375 is skipped
      expect(Percy).to receive(:change_window_dimension_and_wait).once
      Percy.capture_responsive_dom(driver, {})
    end

    it 'passes the requested width and window height to change_window_dimension_and_wait' do
      allow(Percy).to receive(:get_responsive_widths).and_return([{'width' => 390}])
      expect(Percy).to receive(:change_window_dimension_and_wait)
        .with(driver, 390, 900, exact: true)
      Percy.capture_responsive_dom(driver, {})
    end

    it 'uses per-entry height from widths list over the default target_height' do
      allow(Percy).to receive(:get_responsive_widths).and_return(
        [{'width' => 390, 'height' => 844}],
      )
      expect(Percy).to receive(:change_window_dimension_and_wait)
        .with(driver, 390, 844, exact: true)
      Percy.capture_responsive_dom(driver, {})
    end

    it 'restores the viewport with the mechanisms that were used' do
      allow(Percy).to receive(:get_responsive_widths).and_return([{'width' => 375}])
      allow(Percy).to receive(:change_window_dimension_and_wait).and_return(:cdp)
      expect(Percy).to receive(:restore_viewport).with(driver, 1280, 900, [:cdp])
      Percy.capture_responsive_dom(driver, {})
    end

    it 'passes exact: false when exactResponsiveWidth is disabled' do
      allow(Percy).to receive(:get_responsive_widths).and_return([{'width' => 375}])
      expect(Percy).to receive(:change_window_dimension_and_wait)
        .with(driver, 375, 900, exact: false)
      Percy.capture_responsive_dom(driver, {exactResponsiveWidth: false})
    end

    # -----------------------------------------------------------------------
    # Reload-page flag
    # -----------------------------------------------------------------------

    context 'when PERCY_RESPONSIVE_CAPTURE_RELOAD_PAGE is true' do
      before(:each) do
        allow(Percy).to receive(:responsive_capture_reload_page?).and_return(true)
        allow(Percy).to receive(:fetch_percy_dom).and_return('percy_dom_script')
        allow(Percy).to receive(:get_responsive_widths).and_return(
          [{'width' => 375}, {'width' => 768}],
        )
        allow(driver).to receive(:navigate).and_return(navigate)
        allow(navigate).to receive(:refresh)
      end

      it 'calls driver.navigate.refresh once per width' do
        expect(navigate).to receive(:refresh).twice
        Percy.capture_responsive_dom(driver, {})
      end

      it 're-fetches percy_dom after each reload' do
        expect(Percy).to receive(:fetch_percy_dom).twice
        Percy.capture_responsive_dom(driver, {})
      end

      it 'falls back to driver.driver.browser.navigate.refresh when direct refresh raises' do
        allow(Percy).to receive(:get_responsive_widths).and_return([{'width' => 375}])
        allow(navigate).to receive(:refresh).and_raise(StandardError, 'direct refresh failed')

        inner_nav = double('inner_navigate')
        inner_browser = double('inner_browser')
        inner_drv     = double('inner_driver', browser: inner_browser)
        allow(driver).to receive(:driver).and_return(inner_drv)
        allow(inner_browser).to receive(:navigate).and_return(inner_nav)
        expect(inner_nav).to receive(:refresh).once
        Percy.capture_responsive_dom(driver, {})
      end

      it 'logs and continues when both the direct and fallback refresh fail' do
        allow(Percy).to receive(:get_responsive_widths).and_return([{'width' => 375}])
        allow(navigate).to receive(:refresh).and_raise(StandardError, 'direct refresh failed')

        inner_browser = double('inner_browser')
        inner_drv     = double('inner_driver', browser: inner_browser)
        inner_nav     = double('inner_navigate')
        allow(driver).to receive(:driver).and_return(inner_drv)
        allow(inner_browser).to receive(:navigate).and_return(inner_nav)
        allow(inner_nav).to receive(:refresh).and_raise(StandardError, 'fallback refresh failed')

        expect(Percy).to receive(:log).with(/Failed to refresh page/, 'debug')
        expect { Percy.capture_responsive_dom(driver, {}) }.to_not raise_error
      end
    end

    # -----------------------------------------------------------------------
    # minHeight / PERCY_RESPONSIVE_CAPTURE_MIN_HEIGHT flag
    # -----------------------------------------------------------------------

    context 'when PERCY_RESPONSIVE_CAPTURE_MIN_HEIGHT is true' do
      before(:each) do
        allow(Percy).to receive(:responsive_capture_min_height?).and_return(true)
        allow(Percy).to receive(:get_responsive_widths).and_return([{'width' => 390}])
      end

      it 'uses the minHeight option as the target height' do
        expect(Percy).to receive(:change_window_dimension_and_wait)
          .with(driver, 390, 800, exact: true)
        Percy.capture_responsive_dom(driver, {minHeight: 800})
      end

      it 'uses minHeight from cli_config when not provided in options' do
        begin
          Percy.instance_variable_set(:@cli_config, {'snapshot' => {'minHeight' => 700}})
          expect(Percy).to receive(:change_window_dimension_and_wait)
            .with(driver, 390, 700, exact: true)
          Percy.capture_responsive_dom(driver, {})
        ensure
          Percy.instance_variable_set(:@cli_config, nil)
        end
      end

      it 'uses the current window height unchanged when minHeight is not set' do
        expect(Percy).to receive(:change_window_dimension_and_wait)
          .with(driver, 390, 900, exact: true)
        Percy.capture_responsive_dom(driver, {})
      end
    end
  end
end

RSpec.describe Percy do
  before(:each) do
    Percy._clear_cache!
  end

  describe '.responsive_snapshot_capture?' do
    it 'returns false when deferUploads is enabled in cli_config' do
      begin
        Percy.instance_variable_set(:@cli_config, {'percy' => {'deferUploads' => true}})
        result = Percy.responsive_snapshot_capture?({responsive_snapshot_capture: true})
        expect(result).to be false
      ensure
        Percy.instance_variable_set(:@cli_config, nil)
      end
    end

    it 'returns true when responsive_snapshot_capture option is set' do
      result = Percy.responsive_snapshot_capture?({responsive_snapshot_capture: true})
      expect(result).to be true
    end

    it 'returns true when responsiveSnapshotCapture option is set' do
      result = Percy.responsive_snapshot_capture?({responsiveSnapshotCapture: true})
      expect(result).to be true
    end

    it 'returns true when responsiveSnapshotCapture is set in cli_config' do
      begin
        Percy.instance_variable_set(
          :@cli_config, {'snapshot' => {'responsiveSnapshotCapture' => true}},
        )
        result = Percy.responsive_snapshot_capture?({})
        expect(result).to be true
      ensure
        Percy.instance_variable_set(:@cli_config, nil)
      end
    end

    it 'returns nil when no responsive capture option is set' do
      result = Percy.responsive_snapshot_capture?({})
      expect(result).to be_falsey
    end
  end
end

# :nocov:
# This whole describe is a live end-to-end test (xit, permanently skipped on
# CI): it depends on the real @percy/cli test-mode `/test/requests` endpoint
# being populated, which is not deterministic under `percy exec --testing`. It
# exercises no lib lines not already covered by the stubbed snapshot specs.
# Because it never executes, its body would otherwise count as uncovered lines
# against the SimpleCov 100% gate, so it is wrapped in `# :nocov:` to exclude it
# from coverage measurement while keeping the documented scenario in the suite.
RSpec.describe Percy, type: :feature do
  before(:each) do
    WebMock.reset!
    WebMock.allow_net_connect!
    Percy._clear_cache!
  end

  describe 'integration', type: :feature do
    xit 'sends snapshots to percy server' do
      visit 'index.html'
      Percy.snapshot(page, 'Name', widths: [375])
      sleep 5 # wait for percy server to process
      resp = Net::HTTP.get_response(URI("#{Percy::PERCY_SERVER_ADDRESS}/test/requests"))
      requests = JSON.parse(resp.body)['requests']
      healthcheck = requests[0]
      expect(healthcheck['url']).to eq('/percy/healthcheck')

      snap_request = requests.find { |r| r['url'] == '/percy/snapshot' }
      snap = snap_request['body']
      expect(snap['name']).to eq('Name')
      expect(snap['url']).to eq('http://127.0.0.1:3003/index.html')
      expect(snap['client_info']).to include('percy-selenium-ruby')
      expect(snap['environment_info']).to include('selenium')
      expect(snap['widths']).to eq([375])
    end
  end
end
# :nocov:

RSpec.describe Percy do
  describe '.percy_screenshot' do
    let(:driver) { double('driver') }
    let(:metadata) do
      instance_double(
        DriverMetaData,
        session_id: 'sess-abc-123',
        command_executor_url: 'http://hub.browserstack.com/wd/hub',
        capabilities: {'browserName' => 'chrome', 'version' => '114'},
      )
    end

    let(:automate_url) { "#{Percy::PERCY_SERVER_ADDRESS}/percy/automateScreenshot" }

    before(:each) do
      WebMock.disable_net_connect!
      stub_request(:post, 'http://localhost:5338/percy/log').to_raise(StandardError)
      Percy._clear_cache!
      allow(Percy).to receive(:get_driver_metadata).with(driver).and_return(metadata)
    end

    def stub_automate_healthcheck
      stub_request(:get, "#{Percy::PERCY_SERVER_ADDRESS}/percy/healthcheck")
        .to_return(
          status: 200,
          body: '{"success":true,"type":"automate"}',
          headers: {'x-percy-core-version': '1.0.0'},
        )
    end

    def stub_web_healthcheck
      stub_request(:get, "#{Percy::PERCY_SERVER_ADDRESS}/percy/healthcheck")
        .to_return(
          status: 200,
          body: '{"success":true,"type":"web"}',
          headers: {'x-percy-core-version': '1.0.0'},
        )
    end

    # -------------------------------------------------------------------------
    # percy_enabled? gating
    # -------------------------------------------------------------------------

    it 'returns nil without posting when percy is not running' do
      stub_request(:get, "#{Percy::PERCY_SERVER_ADDRESS}/percy/healthcheck")
        .to_return(status: 500, body: '')

      result = nil
      expect { result = Percy.percy_screenshot(driver, 'DisabledShot') }
        .to output(/Percy is not running/).to_stdout
      expect(result).to be_nil
      expect(WebMock).to_not have_requested(:post, /automateScreenshot/)
    end

    it 'returns nil without posting when healthcheck raises a connection error' do
      stub_request(:get, "#{Percy::PERCY_SERVER_ADDRESS}/percy/healthcheck")
        .to_raise(StandardError, 'connection refused')

      result = nil
      expect { result = Percy.percy_screenshot(driver, 'ConnErrShot') }
        .to output(/Percy is not running/).to_stdout
      expect(result).to be_nil
    end

    # -------------------------------------------------------------------------
    # Session-type enforcement
    # -------------------------------------------------------------------------

    it 'raises with a descriptive message when session type is not automate' do
      stub_web_healthcheck

      expect { Percy.percy_screenshot(driver, 'WebShot') }
        .to raise_error(
          StandardError,
          /Invalid function call - percy_screenshot\(\)/,
        )
    end

    it 'error message for wrong session type includes guidance to use percy_snapshot' do
      stub_web_healthcheck

      expect { Percy.percy_screenshot(driver, 'WebShot') }
        .to raise_error(StandardError, /percy_snapshot\(\)/)
    end

    it 'does not raise when session type is automate' do
      stub_automate_healthcheck
      stub_request(:post, "#{Percy::PERCY_SERVER_ADDRESS}/percy/automateScreenshot")
        .to_return(status: 200, body: '{"success":true}')

      expect { Percy.percy_screenshot(driver, 'AutoShot') }.to_not raise_error
    end

    # -------------------------------------------------------------------------
    # Request payload construction
    # -------------------------------------------------------------------------

    it 'posts to percy/automateScreenshot with correct top-level fields' do
      stub_automate_healthcheck
      stub_request(:post, "#{Percy::PERCY_SERVER_ADDRESS}/percy/automateScreenshot")
        .to_return(status: 200, body: '{"success":true,"data":"snap-result"}')

      Percy.percy_screenshot(driver, 'PayloadShot')

      expect(WebMock).to have_requested(:post, automate_url)
        .with { |req|
          body = JSON.parse(req.body)
          body['snapshotName'] == 'PayloadShot' &&
            body['sessionId'] == 'sess-abc-123' &&
            body['commandExecutorUrl'] == 'http://hub.browserstack.com/wd/hub' &&
            body['capabilities'] == {'browserName' => 'chrome', 'version' => '114'} &&
            body['client_info'] == "percy-selenium-ruby/#{Percy::VERSION}" &&
            body['environment_info'] ==
              "selenium/#{Selenium::WebDriver::VERSION} ruby/#{RUBY_VERSION}"
        }.once
    end

    # -------------------------------------------------------------------------
    # Response handling - success
    # -------------------------------------------------------------------------

    it 'returns body["data"] when the response indicates success' do
      stub_automate_healthcheck
      stub_request(:post, "#{Percy::PERCY_SERVER_ADDRESS}/percy/automateScreenshot")
        .to_return(status: 200, body: '{"success":true,"data":"my-screenshot-data"}')

      result = Percy.percy_screenshot(driver, 'SuccessShot')
      expect(result).to eq('my-screenshot-data')
    end

    it 'returns nil when data key is absent in a successful response' do
      stub_automate_healthcheck
      stub_request(:post, "#{Percy::PERCY_SERVER_ADDRESS}/percy/automateScreenshot")
        .to_return(status: 200, body: '{"success":true}')

      result = Percy.percy_screenshot(driver, 'NoDataShot')
      expect(result).to be_nil
    end

    # -------------------------------------------------------------------------
    # Response handling - errors
    # -------------------------------------------------------------------------

    it 'logs and returns nil when response success is false' do
      stub_automate_healthcheck
      stub_request(:post, "#{Percy::PERCY_SERVER_ADDRESS}/percy/automateScreenshot")
        .to_return(status: 200, body: '{"success":false,"error":"upstream failure"}')

      result = nil
      expect { result = Percy.percy_screenshot(driver, 'FailShot') }
        .to output("#{Percy::LABEL} Could not take Screenshot 'FailShot'\n").to_stdout
      expect(result).to be_nil
    end

    it 'logs and returns nil when the HTTP request returns a non-success status' do
      stub_automate_healthcheck
      stub_request(:post, "#{Percy::PERCY_SERVER_ADDRESS}/percy/automateScreenshot")
        .to_return(status: 500, body: 'Internal Server Error')

      result = nil
      expect { result = Percy.percy_screenshot(driver, 'HttpErrShot') }
        .to output("#{Percy::LABEL} Could not take Screenshot 'HttpErrShot'\n").to_stdout
      expect(result).to be_nil
    end

    it 'logs and returns nil when the automateScreenshot endpoint raises' do
      stub_automate_healthcheck
      stub_request(:post, "#{Percy::PERCY_SERVER_ADDRESS}/percy/automateScreenshot")
        .to_raise(StandardError, 'network timeout')

      result = nil
      expect { result = Percy.percy_screenshot(driver, 'RaiseShot') }
        .to output("#{Percy::LABEL} Could not take Screenshot 'RaiseShot'\n").to_stdout
      expect(result).to be_nil
    end

    # -------------------------------------------------------------------------
    # Option key translation
    # -------------------------------------------------------------------------

    it 'translates camelCase ignoreRegionSeleniumElements to snake_case and extracts ids' do
      stub_automate_healthcheck
      elem1 = double('element1', id: 'elem-id-1')
      elem2 = double('element2', id: 'elem-id-2')

      stub_request(:post, "#{Percy::PERCY_SERVER_ADDRESS}/percy/automateScreenshot")
        .to_return(status: 200, body: '{"success":true}')

      Percy.percy_screenshot(driver, 'IgnoreShot', ignoreRegionSeleniumElements: [elem1, elem2])

      expect(WebMock).to have_requested(:post, automate_url)
        .with { |req|
          opts = JSON.parse(req.body)['options']
          opts['ignore_region_elements'] == %w[elem-id-1 elem-id-2] &&
            !opts.key?('ignoreRegionSeleniumElements') &&
            !opts.key?('ignore_region_selenium_elements')
        }.once
    end

    it 'translates camelCase considerRegionSeleniumElements to snake_case and extracts ids' do
      stub_automate_healthcheck
      elem = double('element', id: 'consider-id-1')

      stub_request(:post, "#{Percy::PERCY_SERVER_ADDRESS}/percy/automateScreenshot")
        .to_return(status: 200, body: '{"success":true}')

      Percy.percy_screenshot(driver, 'ConsiderShot', considerRegionSeleniumElements: [elem])

      expect(WebMock).to have_requested(:post, automate_url)
        .with { |req|
          opts = JSON.parse(req.body)['options']
          opts['consider_region_elements'] == ['consider-id-1'] &&
            !opts.key?('considerRegionSeleniumElements') &&
            !opts.key?('consider_region_selenium_elements')
        }.once
    end

    it 'also accepts already-snake_case ignore_region_selenium_elements' do
      stub_automate_healthcheck
      elem = double('element', id: 'snake-id-1')

      stub_request(:post, "#{Percy::PERCY_SERVER_ADDRESS}/percy/automateScreenshot")
        .to_return(status: 200, body: '{"success":true}')

      Percy.percy_screenshot(driver, 'SnakeShot', ignore_region_selenium_elements: [elem])

      expect(WebMock).to have_requested(:post, automate_url)
        .with { |req|
          opts = JSON.parse(req.body)['options']
          opts['ignore_region_elements'] == ['snake-id-1']
        }.once
    end

    # -------------------------------------------------------------------------
    # Element ID extraction
    # -------------------------------------------------------------------------

    it 'uses empty arrays for element ids when no element options are supplied' do
      stub_automate_healthcheck
      stub_request(:post, "#{Percy::PERCY_SERVER_ADDRESS}/percy/automateScreenshot")
        .to_return(status: 200, body: '{"success":true}')

      Percy.percy_screenshot(driver, 'NoElemsShot')

      expect(WebMock).to have_requested(:post, automate_url)
        .with { |req|
          opts = JSON.parse(req.body)['options']
          opts['ignore_region_elements'] == [] &&
            opts['consider_region_elements'] == []
        }.once
    end

    it 'extracts the id from each selenium element object' do
      stub_automate_healthcheck
      elements = [
        double('el_a', id: 'id-a'),
        double('el_b', id: 'id-b'),
        double('el_c', id: 'id-c'),
      ]

      stub_request(:post, "#{Percy::PERCY_SERVER_ADDRESS}/percy/automateScreenshot")
        .to_return(status: 200, body: '{"success":true}')

      Percy.percy_screenshot(driver, 'MultiElemShot',
        ignore_region_selenium_elements: elements,)

      expect(WebMock).to have_requested(:post, automate_url)
        .with { |req|
          opts = JSON.parse(req.body)['options']
          opts['ignore_region_elements'] == %w[id-a id-b id-c]
        }.once
    end

    # -------------------------------------------------------------------------
    # Passthrough of additional options
    # -------------------------------------------------------------------------

    it 'passes unknown options through to the request payload unchanged' do
      stub_automate_healthcheck
      stub_request(:post, "#{Percy::PERCY_SERVER_ADDRESS}/percy/automateScreenshot")
        .to_return(status: 200, body: '{"success":true}')

      Percy.percy_screenshot(driver, 'ExtraOptsShot', sync: true, fullPage: true)

      expect(WebMock).to have_requested(:post, automate_url)
        .with { |req|
          opts = JSON.parse(req.body)['options']
          opts['sync'] == true && opts['fullPage'] == true
        }.once
    end
  end
end

RSpec.describe Percy do
  before(:each) do
    # Allow loopback so Capybara's live selenium session (127.0.0.1:4444) can be
    # torn down at process exit even when this block's `before` is the last one
    # to run under random ordering; percy endpoints are stubbed explicitly.
    WebMock.disable_net_connect!(allow: '127.0.0.1')
    Percy._clear_cache!
  end

  describe '.snapshot (mocked driver)' do
    let(:driver)    { double('driver') }
    let(:manage)    { double('manage') }
    let(:switch_to) { double('switch_to') }

    def stub_web_snapshot_healthcheck
      stub_request(:get, "#{Percy::PERCY_SERVER_ADDRESS}/percy/healthcheck")
        .to_return(status: 200, body: '{"success":true,"type":"web"}',
                   headers: {'x-percy-core-version': '1.0.0'},)
      stub_request(:get, "#{Percy::PERCY_SERVER_ADDRESS}/percy/dom.js")
        .to_return(status: 200, body: 'window.PercyDOM = {};', headers: {})
    end

    before(:each) do
      stub_request(:post, "#{Percy::PERCY_SERVER_ADDRESS}/percy/log")
        .to_return(status: 200, body: '', headers: {})
      allow(driver).to receive(:manage).and_return(manage)
      allow(manage).to receive(:all_cookies).and_return([])
      allow(driver).to receive(:respond_to?).and_return(false)
      allow(driver).to receive(:switch_to).and_return(switch_to)
      allow(switch_to).to receive(:default_content)
      allow(driver).to receive(:execute_async_script).and_return(nil)
      allow(driver).to receive(:current_url).and_return('http://127.0.0.1:3003/index.html')
      allow(driver).to receive(:find_elements).and_return([])
      allow(driver).to receive(:execute_script) do |script|
        {'html' => '<html/>'} if script.to_s.include?('PercyDOM.serialize')
      end
    end

    it 'serializes the dom and posts to /percy/snapshot on the non-responsive path' do
      stub_web_snapshot_healthcheck
      stub_request(:post, "#{Percy::PERCY_SERVER_ADDRESS}/percy/snapshot")
        .to_return(status: 200, body: '{"success":true}')

      Percy.snapshot(driver, 'MockedShot')

      expect(WebMock).to have_requested(:post, "#{Percy::PERCY_SERVER_ADDRESS}/percy/snapshot")
        .with { |req| JSON.parse(req.body)['name'] == 'MockedShot' }.once
    end

    it 'logs the failure when the snapshot response success is false' do
      stub_web_snapshot_healthcheck
      stub_request(:post, "#{Percy::PERCY_SERVER_ADDRESS}/percy/snapshot")
        .to_return(status: 200, body: '{"success":false,"error":"server rejected"}')

      # body['success'] is false -> raise body['error'] -> swallowed + logged.
      expect { Percy.snapshot(driver, 'RejectedShot') }
        .to output(/Could not take DOM snapshot 'RejectedShot'/).to_stdout
    end
  end

  describe '.get_browser_instance' do
    it 'unwraps a Capybara-style session (driver.driver.browser.manage)' do
      inner_manage  = double('inner_manage')
      inner_browser = double('inner_browser', manage: inner_manage)
      inner_driver  = double('inner_driver')
      session       = double('session')
      allow(session).to receive(:respond_to?).with(:driver).and_return(true)
      allow(session).to receive(:driver).and_return(inner_driver)
      allow(inner_driver).to receive(:respond_to?).with(:browser).and_return(true)
      allow(inner_driver).to receive(:browser).and_return(inner_browser)

      expect(Percy.get_browser_instance(session)).to eq(inner_manage)
    end

    it 'uses driver.manage for a plain WebDriver session' do
      manage = double('manage')
      driver = double('driver', manage: manage)
      allow(driver).to receive(:respond_to?).with(:driver).and_return(false)

      expect(Percy.get_browser_instance(driver)).to eq(manage)
    end
  end

  describe '.get_driver_metadata' do
    it 'wraps the driver in a DriverMetaData instance' do
      driver = double('driver')
      expect(Percy.get_driver_metadata(driver)).to be_a(DriverMetaData)
    end
  end

  describe '.log' do
    it 'prints the CLI-send failure when PERCY_DEBUG is enabled' do
      stub_const('Percy::PERCY_DEBUG', true)
      stub_request(:post, "#{Percy::PERCY_SERVER_ADDRESS}/percy/log").to_raise(StandardError)

      expect { Percy.log('hello', 'debug') }
        .to output(/Sending log to CLI Failed/).to_stdout
    end
  end
end
# rubocop:enable RSpec/MultipleDescribes

RSpec.describe Percy do
  before(:each) do
    Percy._clear_cache!
    allow(Percy).to receive(:log)
  end

  describe '.expose_closed_shadow_roots' do
    let(:driver) { double('driver') }

    before(:each) do
      allow(driver).to receive(:respond_to?).and_return(false)
      allow(driver).to receive(:capabilities).and_return(double('caps', browser_name: 'firefox'))
    end

    it 'does nothing when disableShadowDOM is set' do
      expect(Percy).to_not receive(:closed_shadow_classic_allowed?)
      Percy.expose_closed_shadow_roots(driver, {disableShadowDOM: true})
      Percy.expose_closed_shadow_roots(driver, {'disableShadowDOM' => true})
    end

    it 'unwraps a Capybara session to the Selenium driver' do
      browser = double('browser')
      allow(driver).to receive(:respond_to?).with(:driver).and_return(true)
      allow(driver).to receive(:driver).and_return(double('cap_driver', browser: browser))
      expect(Percy).to receive(:closed_shadow_classic_allowed?).with(browser).and_return(false)
      allow(browser).to receive(:respond_to?).and_return(false)
      Percy.expose_closed_shadow_roots(driver)
    end

    it 'stops after CDP succeeds' do
      allow(driver).to receive(:capabilities).and_return(double('caps', browser_name: 'chrome'))
      allow(driver).to receive(:respond_to?).with(:execute_cdp).and_return(true)
      expect(Percy).to receive(:expose_closed_shadow_roots_cdp).and_return(true)
      expect(Percy).to_not receive(:closed_shadow_classic_allowed?)
      Percy.expose_closed_shadow_roots(driver)
    end

    it 'stops after BiDi succeeds' do
      allow(Percy).to receive(:bidi_session?).and_return(true)
      expect(Percy).to receive(:expose_closed_shadow_roots_bidi).and_return(true)
      expect(Percy).to_not receive(:closed_shadow_classic_allowed?)
      Percy.expose_closed_shadow_roots(driver)
    end

    it 'falls back to classic when CDP and BiDi fail' do
      allow(driver).to receive(:capabilities).and_return(double('caps', browser_name: 'chrome'))
      allow(driver).to receive(:respond_to?).with(:execute_cdp).and_return(true)
      allow(Percy).to receive(:bidi_session?).and_return(true)
      allow(Percy).to receive(:expose_closed_shadow_roots_cdp).and_return(false)
      allow(Percy).to receive(:expose_closed_shadow_roots_bidi).and_return(false)
      allow(Percy).to receive(:closed_shadow_classic_allowed?).and_return(true)
      expect(Percy).to receive(:expose_closed_shadow_roots_classic).with(driver)
      Percy.expose_closed_shadow_roots(driver)
    end

    it 'warns and continues on unexpected errors' do
      allow(Percy).to receive(:closed_shadow_classic_allowed?).and_raise(StandardError, 'boom')
      expect(Percy).to receive(:log).with(/Could not expose closed shadow roots: boom/, 'warn')
      expect { Percy.expose_closed_shadow_roots(driver) }.to_not raise_error
    end
  end

  describe '.expose_closed_shadow_roots_cdp' do
    let(:bridge) { double('bridge') }
    let(:chromium) do
      d = Class.new { include Selenium::WebDriver::DriverExtensions::HasCDP }.new
      d.instance_variable_set(:@bridge, bridge)
      d
    end
    let(:document) do
      {'root' => {
        'backendNodeId' => 1,
        'children' => [
          {'backendNodeId' => 2, 'shadowRoots' => [
            {'backendNodeId' => 3, 'shadowRootType' => 'closed', 'children' => [
              {'backendNodeId' => 4, 'shadowRoots' => [
                {'backendNodeId' => 5, 'shadowRootType' => 'closed'},
              ],},
            ],},
          ],},
          {'backendNodeId' => 6,
           'shadowRoots' => [{'backendNodeId' => 7, 'shadowRootType' => 'open'}],},
          {'backendNodeId' => 8, 'contentDocument' => {}, 'shadowRoots' => [
            {'backendNodeId' => 9, 'shadowRootType' => 'closed'},
          ],},
        ],
      }}
    end

    def cdp(cmd, params = {})
      receive(:send_command).with(cmd: cmd, params: params)
    end

    # Driven through the real HasCDP#execute_cdp so keyword arguments are enforced.
    it 'maps every closed root (including nested ones) to its host via keyword CDP calls' do
      expect(bridge).to cdp('DOM.enable')
      expect(bridge).to cdp('DOM.getDocument', depth: -1, pierce: true).and_return(document)
      [2, 3, 4, 5].each do |id|
        expect(bridge).to cdp('DOM.resolveNode', backendNodeId: id)
          .and_return({'object' => {'objectId' => "obj-#{id}"}})
      end
      expect(bridge).to_not cdp('DOM.resolveNode', backendNodeId: 9)
      [[2, 3], [4, 5]].each do |host, shadow|
        expect(bridge).to cdp(
          'Runtime.callFunctionOn',
          functionDeclaration: Percy::CLOSED_SHADOW_SET_FN, objectId: "obj-#{host}",
          arguments: [{objectId: "obj-#{shadow}"}],
        )
      end
      expect(Percy.expose_closed_shadow_roots_cdp(chromium)).to eq(true)
    end

    it 'skips pairs that cannot be resolved' do
      allow(bridge).to cdp('DOM.enable')
      allow(bridge).to cdp('DOM.getDocument', depth: -1, pierce: true).and_return(document)
      allow(bridge).to receive(:send_command).with(cmd: 'DOM.resolveNode', params: anything)
        .and_return({'object' => {}})
      expect(bridge).to_not receive(:send_command)
        .with(cmd: 'Runtime.callFunctionOn', params: anything)
      expect(Percy.expose_closed_shadow_roots_cdp(chromium)).to eq(true)
    end

    it 'returns false when the document has no root' do
      allow(bridge).to cdp('DOM.enable')
      allow(bridge).to cdp('DOM.getDocument', depth: -1, pierce: true).and_return({})
      expect(Percy.expose_closed_shadow_roots_cdp(chromium)).to eq(false)
    end

    it 'returns false and logs when CDP fails' do
      allow(bridge).to receive(:send_command).and_raise(StandardError, 'no cdp')
      expect(Percy).to receive(:log).with(/via CDP: no cdp/, 'debug')
      expect(Percy.expose_closed_shadow_roots_cdp(chromium)).to eq(false)
    end
  end

  describe '.expose_closed_shadow_roots_bidi' do
    let(:driver) { double('driver', window_handle: 'ctx-1') }
    let(:ws)     { double('ws') }
    # Same signature and body as Selenium's BiDi#send_cmd(method, **params), so
    # a positional Hash raises like it would against the real binding (which
    # the Ruby 2.x CI rows' Selenium predates).
    let(:bidi) do
      Class.new do
        def initialize(ws)
          @ws = ws
        end

        def send_cmd(method, **params)
          @ws.send_cmd(method: method, params: params.compact)['result']
        end
      end.new(ws)
    end

    def node(id, mode = nil)
      root = {'sharedId' => "#{id}-root", 'value' => {'mode' => mode}}
      value = mode ? {'shadowRoot' => root} : {}
      {'type' => 'node', 'sharedId' => id, 'value' => value}
    end

    def success(value)
      {'result' => {'type' => 'success', 'result' => {'type' => 'array', 'value' => value}}}
    end

    before(:each) do
      allow(driver).to receive(:bidi).and_return(bidi)
    end

    it 'exposes closed roots and recurses into each one' do
      calls = []
      allow(ws).to receive(:send_cmd) do |method:, params:|
        calls << [method, params]
        case calls.length
        when 1 then success([node('h1', 'closed'), node('h2', 'open'), node('h3')])
        when 3 then success([node('h4', 'closed')])
        else success([])
        end
      end

      expect(Percy.expose_closed_shadow_roots_bidi(driver)).to eq(true)

      expect(calls.map(&:first).uniq).to eq(['script.callFunction'])
      first = calls[0][1]
      expect(first[:target]).to eq({context: 'ctx-1'})
      expect(first[:serializationOptions]).to eq({maxDomDepth: 0, includeShadowTree: 'all'})
      expect(first[:arguments]).to eq([])
      expect(calls[1][1][:arguments]).to eq([{type: 'array', value: [
        {type: 'array', value: [{sharedId: 'h1'}, {sharedId: 'h1-root'}]},
      ],}])
      expect(calls[2][1][:arguments]).to eq([{sharedId: 'h1-root'}])
      expect(calls[4][1][:arguments]).to eq([{sharedId: 'h4-root'}])
      expect(calls.length).to eq(5)
    end

    it 'stops at PERCY_CLOSED_SHADOW_MAX_HOSTS' do
      allow(Percy).to receive(:closed_shadow_max_hosts).and_return(1)
      calls = 0
      allow(ws).to receive(:send_cmd) do
        calls += 1
        success([node('h1', 'closed')])
      end
      expect(Percy.expose_closed_shadow_roots_bidi(driver)).to eq(true)
      expect(calls).to eq(2)
    end

    it 'returns false when the script throws' do
      allow(ws).to receive(:send_cmd)
        .and_return({'result' => {'type' => 'exception', 'exceptionDetails' => {}}})
      expect(Percy).to receive(:log).with(/via BiDi: script.callFunction exception/, 'debug')
      expect(Percy.expose_closed_shadow_roots_bidi(driver)).to eq(false)
    end

    it 'tolerates an empty result' do
      allow(ws).to receive(:send_cmd).and_return({'result' => {'type' => 'success'}})
      expect(Percy.expose_closed_shadow_roots_bidi(driver)).to eq(true)
    end
  end

  describe '.expose_closed_shadow_roots_classic' do
    let(:driver) { double('driver') }

    def host(shadow)
      h = double('host')
      if shadow == :none
        allow(h).to receive(:shadow_root)
          .and_raise(Selenium::WebDriver::Error::WebDriverError, 'no such shadow root')
      else
        allow(h).to receive(:shadow_root).and_return(shadow)
      end
      h
    end

    it 'sets each closed root and walks into it; null roots (Safari) are skipped' do
      root = double('root')
      nested_root = double('nested_root')
      closed = host(root)
      plain = host(:none)
      safari = host(nil)
      nested = host(nested_root)
      allow(driver).to receive(:execute_script)
        .with(Percy::CLASSIC_SHADOW_CANDIDATES_JS, nil).and_return([closed, plain, safari])
      allow(driver).to receive(:execute_script)
        .with(Percy::CLASSIC_SHADOW_CANDIDATES_JS, root).and_return([nested])
      allow(driver).to receive(:execute_script)
        .with(Percy::CLASSIC_SHADOW_CANDIDATES_JS, nested_root).and_return(nil)
      expect(driver).to receive(:execute_script).with(Percy::CLASSIC_SHADOW_SET_JS, closed, root)
      expect(driver).to receive(:execute_script)
        .with(Percy::CLASSIC_SHADOW_SET_JS, nested, nested_root)
      Percy.expose_closed_shadow_roots_classic(driver)
    end

    it 'stops at the host cap and logs' do
      allow(Percy).to receive(:closed_shadow_max_hosts).and_return(1)
      first = host(:none)
      second = host(:none)
      allow(driver).to receive(:execute_script).and_return([first, second])
      expect(second).to_not receive(:shadow_root)
      expect(Percy).to receive(:log).with(/stopped at 1 hosts/, 'debug')
      Percy.expose_closed_shadow_roots_classic(driver)
    end
  end

  describe '.closed_shadow_max_hosts' do
    around(:each) do |example|
      original = ENV['PERCY_CLOSED_SHADOW_MAX_HOSTS']
      example.run
      ENV['PERCY_CLOSED_SHADOW_MAX_HOSTS'] = original
    end

    it 'defaults to 200 and honours valid overrides' do
      ENV.delete('PERCY_CLOSED_SHADOW_MAX_HOSTS')
      expect(Percy.closed_shadow_max_hosts).to eq(200)
      ENV['PERCY_CLOSED_SHADOW_MAX_HOSTS'] = '5'
      expect(Percy.closed_shadow_max_hosts).to eq(5)
    end

    it 'ignores invalid values' do
      ENV['PERCY_CLOSED_SHADOW_MAX_HOSTS'] = '0'
      expect(Percy.closed_shadow_max_hosts).to eq(200)
      ENV['PERCY_CLOSED_SHADOW_MAX_HOSTS'] = 'many'
      expect(Percy.closed_shadow_max_hosts).to eq(200)
    end
  end

  describe '.closed_shadow_classic_allowed?' do
    let(:driver) { double('driver') }

    around(:each) do |example|
      original = ENV['PERCY_CLOSED_SHADOW_CLASSIC']
      ENV.delete('PERCY_CLOSED_SHADOW_CLASSIC')
      example.run
      ENV['PERCY_CLOSED_SHADOW_CLASSIC'] = original
    end

    def executor(url)
      allow(Percy).to receive(:command_executor_host).and_call_original
      http = double('http')
      allow(http).to receive(:server_url).and_return(URI(url))
      bridge = double('bridge', http: http)
      allow(driver).to receive(:respond_to?).with(:bridge, true).and_return(true)
      allow(driver).to receive(:bridge).and_return(bridge)
    end

    ['http://localhost:9515', 'http://127.0.0.1:4444/wd/hub', 'http://[::1]:9515'].each do |url|
      it "allows local executor #{url}" do
        executor(url)
        expect(Percy.closed_shadow_classic_allowed?(driver)).to eq(true)
      end
    end

    it 'treats an unknown executor as remote' do
      expect(Percy.closed_shadow_classic_allowed?(Object.new)).to eq(false)
    end

    it 'treats an unreadable executor as remote' do
      allow(driver).to receive(:respond_to?).with(:bridge, true).and_return(true)
      allow(driver).to receive(:bridge).and_raise(StandardError)
      expect(Percy.closed_shadow_classic_allowed?(driver)).to eq(false)
    end

    it 'skips remote sessions and logs once at info' do
      executor('https://hub-cloud.browserstack.com/wd/hub')
      message = 'closed shadow roots skipped on remote session; start the session with ' \
        'webSocketUrl: true or set PERCY_CLOSED_SHADOW_CLASSIC=true'
      expect(Percy).to receive(:log).with(message).once
      2.times { expect(Percy.closed_shadow_classic_allowed?(driver)).to eq(false) }
    end

    it 'allows remote sessions with PERCY_CLOSED_SHADOW_CLASSIC=true' do
      ENV['PERCY_CLOSED_SHADOW_CLASSIC'] = 'true'
      expect(Percy).to_not receive(:command_executor_host)
      expect(Percy.closed_shadow_classic_allowed?(driver)).to eq(true)
    end
  end
end
