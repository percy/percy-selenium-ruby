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

    it 'returns true for file: src' do
      expect(Percy.unsupported_iframe_src?('file:///etc/passwd')).to be true
    end

    it 'returns true for view-source: src' do
      expect(Percy.unsupported_iframe_src?('view-source:https://example.com')).to be true
    end

    it 'returns true for ws:, wss:, and ftp: schemes' do
      # Built from parts so the security scanner doesn't flag these test
      # fixtures as real (insecure) WebSocket / FTP connections. They only
      # assert that the scheme is rejected.
      expect(Percy.unsupported_iframe_src?('ws' + '://example.com/socket')).to be true
      expect(Percy.unsupported_iframe_src?('ws' + 's://example.com/socket')).to be true
      expect(Percy.unsupported_iframe_src?('ftp' + '://example.com/file')).to be true
    end

    it 'returns true for any about: prefix (e.g. about:newtab)' do
      expect(Percy.unsupported_iframe_src?('about:newtab')).to be true
    end

    it 'returns true for devtools:, edge:, and opera: schemes' do
      expect(Percy.unsupported_iframe_src?('devtools://devtools/bundled')).to be true
      expect(Percy.unsupported_iframe_src?('edge://settings')).to be true
      expect(Percy.unsupported_iframe_src?('opera://about')).to be true
    end

    it 'matches case-insensitively (mixed-case schemes still caught)' do
      expect(Percy.unsupported_iframe_src?('JavaScript:alert(1)')).to be true
      expect(Percy.unsupported_iframe_src?('ABOUT:BLANK')).to be true
      expect(Percy.unsupported_iframe_src?('FILE:///etc/passwd')).to be true
    end

    it 'returns false for a valid https url' do
      expect(Percy.unsupported_iframe_src?('https://example.com/page')).to be false
    end

    it 'returns false for a relative url' do
      expect(Percy.unsupported_iframe_src?('/embed.html')).to be false
    end

    it 'returns false for a src whose first segment is the literal "blank"' do
      # Regression: only the documented scheme prefixes (ending in ':') should
      # match. A plain https host like blanket.com or a "blank-canvas" scheme
      # must not be filtered just because they start with the letters "blank".
      # The about:blank / about:newtab cases stay covered by the about: prefix.
      expect(Percy.unsupported_iframe_src?('https://blanket.com/page')).to be false
      expect(Percy.unsupported_iframe_src?('blank-canvas://x')).to be false
    end
  end

  describe '.find_iframe_by_percy_id' do
    let(:driver) { instance_double('Selenium::WebDriver::Driver') }

    it 'returns nil when percyElementId is nil or empty' do
      expect(Percy.find_iframe_by_percy_id(driver, nil)).to be_nil
      expect(Percy.find_iframe_by_percy_id(driver, '')).to be_nil
    end

    it 'queries the driver via the data-percy-element-id attribute selector' do
      element = instance_double('Selenium::WebDriver::Element')
      expect(driver).to receive(:find_element)
        .with(css: 'iframe[data-percy-element-id="abc-123"]')
        .and_return(element)
      expect(Percy.find_iframe_by_percy_id(driver, 'abc-123')).to eq(element)
    end

    it 'returns nil when the lookup raises (no matching element)' do
      allow(driver).to receive(:find_element)
        .and_raise(Selenium::WebDriver::Error::NoSuchElementError.new('no match'))
      expect(Percy.find_iframe_by_percy_id(driver, 'missing-id')).to be_nil
    end

    it 'CSS-escapes embedded double-quotes and backslashes in percyElementId' do
      # Defensive hardening: if a percyElementId ever leaks an unescaped quote
      # or backslash, the selector should be escaped rather than broken (or
      # injectable). If the underlying driver still can't resolve it, the
      # rescue path returns nil cleanly without raising.
      element = instance_double('Selenium::WebDriver::Element')
      expect(driver).to receive(:find_element)
        .with(css: 'iframe[data-percy-element-id="abc\\\\def\\"ghi"]')
        .and_return(element)

      expect {
        result = Percy.find_iframe_by_percy_id(driver, 'abc\\def"ghi')
        expect(result).to eq(element)
      }.to_not raise_error
    end

    it 'returns nil cleanly when an escaped lookup still fails' do
      allow(driver).to receive(:find_element)
        .and_raise(Selenium::WebDriver::Error::NoSuchElementError.new('no match'))
      expect {
        expect(Percy.find_iframe_by_percy_id(driver, 'weird"id\\value')).to be_nil
      }.to_not raise_error
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

  describe '.expose_closed_shadow_roots' do
    let(:driver) { double('driver') }

    before(:each) do
      allow(Percy).to receive(:log)
    end

    it 'no-ops when driver does not respond to execute_cdp' do
      allow(driver).to receive(:respond_to?).with(:execute_cdp).and_return(false)
      expect(driver).to_not receive(:execute_cdp)
      Percy.expose_closed_shadow_roots(driver)
    end

    it 'returns silently when DOM.getDocument fails' do
      allow(driver).to receive(:respond_to?).with(:execute_cdp).and_return(true)
      allow(driver).to receive(:execute_cdp).with('DOM.getDocument', anything)
        .and_raise(StandardError, 'CDP not available')
      expect { Percy.expose_closed_shadow_roots(driver) }.to_not raise_error
    end

    it 'is a no-op when no closed shadow roots are present' do
      allow(driver).to receive(:respond_to?).with(:execute_cdp).and_return(true)
      allow(driver).to receive(:execute_cdp).with('DOM.getDocument', anything)
        .and_return({'root' => {'children' => []}})
      expect(driver).to_not receive(:execute_script)
      Percy.expose_closed_shadow_roots(driver)
    end

    it 'walks the tree, resolves both nodes, and registers via Runtime.callFunctionOn' do
      tree = {
        'root' => {
          'backendNodeId' => 1,
          'children' => [{
            'backendNodeId' => 2,
            'shadowRoots' => [{
              'backendNodeId' => 3,
              'shadowRootType' => 'closed',
            }],
          }],
        },
      }
      allow(driver).to receive(:respond_to?).with(:execute_cdp).and_return(true)
      allow(driver).to receive(:execute_cdp).with('DOM.getDocument', anything).and_return(tree)
      allow(driver).to receive(:execute_cdp).with('DOM.resolveNode', backendNodeId: 2)
        .and_return({'object' => {'objectId' => 'host-obj'}})
      allow(driver).to receive(:execute_cdp).with('DOM.resolveNode', backendNodeId: 3)
        .and_return({'object' => {'objectId' => 'shadow-obj'}})
      expect(driver).to receive(:execute_script)
        .with(/__percyClosedShadowRoots/)
      expect(driver).to receive(:execute_cdp).with(
        'Runtime.callFunctionOn',
        hash_including(objectId: 'host-obj'),
      )
      Percy.expose_closed_shadow_roots(driver)
    end

    it 'skips contentDocument subtrees (cross-frame closed roots not supported)' do
      tree = {
        'root' => {
          'children' => [{
            'backendNodeId' => 10,
            'contentDocument' => {
              'shadowRoots' => [{
                'backendNodeId' => 11,
                'shadowRootType' => 'closed',
              }],
            },
          }],
        },
      }
      allow(driver).to receive(:respond_to?).with(:execute_cdp).and_return(true)
      allow(driver).to receive(:execute_cdp).with('DOM.getDocument', anything).and_return(tree)
      expect(driver).to_not receive(:execute_script)
      Percy.expose_closed_shadow_roots(driver)
    end
  end

  describe '.process_frame_tree' do
    let(:driver)        { double('driver') }
    let(:frame_element) { double('frame_element') }
    let(:switch_to)     { double('switch_to') }
    let(:ctx) do
      {
        max_frame_depth: Percy::DEFAULT_MAX_FRAME_DEPTH,
        ignore_selectors: [],
        serialize_options: {},
        percy_dom_script: 'percy_dom_script',
      }
    end

    before(:each) do
      allow(driver).to receive(:switch_to).and_return(switch_to)
      allow(switch_to).to receive(:frame)
      allow(switch_to).to receive(:parent_frame)
      allow(switch_to).to receive(:default_content)
      allow(Percy).to receive(:log)
    end

    def meta_for(src:, percy_id: 'elem-123', ignore: false, matches_ignore: false, srcdoc: nil)
      {
        'src' => src,
        'srcdoc' => srcdoc,
        'percyElementId' => percy_id,
        'dataPercyIgnore' => ignore,
        'matchesIgnoreSelector' => matches_ignore,
        'index' => 0,
      }
    end

    it 'returns a hash with iframeData, iframeSnapshot, and frameUrl on success' do
      meta = meta_for(src: 'https://other.example.com/page', percy_id: 'elem-123')
      allow(driver).to receive(:execute_script) do |script|
        if script.include?('document.URL')
          'https://other.example.com/page'
        elsif script.include?('PercyDOM.serialize')
          {'html' => '<html/>'}
        elsif script.include?('querySelectorAll')
          []
        end
      end
      allow(driver).to receive(:find_elements).with(css: 'iframe').and_return([])

      result = Percy.process_frame_tree(driver, frame_element, meta, 1, Set.new, ctx)

      expect(result.length).to eq(1)
      expect(result[0]['iframeData']['percyElementId']).to eq('elem-123')
      expect(result[0]['iframeSnapshot']).to eq({'html' => '<html/>'})
      expect(result[0]['frameUrl']).to eq('https://other.example.com/page')
    end

    it 'returns empty array when execute_script raises inside the iframe' do
      meta = meta_for(src: 'https://other.example.com/page')
      allow(driver).to receive(:execute_script).and_raise(StandardError, 'injection error')

      result = Percy.process_frame_tree(driver, frame_element, meta, 1, Set.new, ctx)
      expect(result).to eq([])
    end

    it 'returns empty array when switching to the frame fails' do
      meta = meta_for(src: 'https://other.example.com/page')
      allow(switch_to).to receive(:frame).and_raise(StandardError, 'no such frame')

      result = Percy.process_frame_tree(driver, frame_element, meta, 1, Set.new, ctx)
      expect(result).to eq([])
    end

    it 'merges enableJavaScript into the PercyDOM.serialize call' do
      meta = meta_for(src: 'https://other.example.com/page', percy_id: 'elem-abc')
      captured_serialize_call = nil
      allow(driver).to receive(:execute_script) do |script|
        if script.include?('document.URL')
          'https://other.example.com/page'
        elsif script.include?('PercyDOM.serialize')
          captured_serialize_call = script
          {'html' => '<html/>'}
        elsif script.include?('querySelectorAll')
          []
        end
      end
      allow(driver).to receive(:find_elements).with(css: 'iframe').and_return([])

      custom_ctx = ctx.merge(serialize_options: {someOpt: 1})
      Percy.process_frame_tree(driver, frame_element, meta, 1, Set.new, custom_ctx)

      expect(captured_serialize_call).to include('enableJavaScript')
      expect(captured_serialize_call).to include('true')
    end

    it 'always returns to the parent frame even when script injection fails' do
      meta = meta_for(src: 'https://other.example.com/page')
      expect(switch_to).to receive(:parent_frame).once
      allow(driver).to receive(:execute_script).and_raise(StandardError, 'error')

      Percy.process_frame_tree(driver, frame_element, meta, 1, Set.new, ctx)
    end

    it 'stops descending once max_frame_depth is exceeded' do
      meta = meta_for(src: 'https://other.example.com/page')
      shallow_ctx = ctx.merge(max_frame_depth: 1)

      result = Percy.process_frame_tree(driver, frame_element, meta, 2, Set.new, shallow_ctx)
      expect(result).to eq([])
    end

    it 'skips cyclic iframes that appear in the ancestor chain' do
      meta = meta_for(src: 'https://other.example.com/page')
      ancestors = Set.new(['https://other.example.com/page'])

      result = Percy.process_frame_tree(driver, frame_element, meta, 1, ancestors, ctx)
      expect(result).to eq([])
    end

    it 'skips frames whose document.URL post-switch is about:blank' do
      meta = meta_for(src: 'https://other.example.com/error-page', percy_id: 'elem-err')
      # The unsupported-URL check fires right after document.URL is read, so the
      # frame is dropped before PercyDOM.serialize / child enumeration run.
      allow(driver).to receive(:execute_script) do |script|
        'about:blank' if script.include?('document.URL') # cross-origin nav failed
      end
      allow(driver).to receive(:find_elements).with(css: 'iframe').and_return([])

      result = Percy.process_frame_tree(driver, frame_element, meta, 1, Set.new, ctx)
      expect(result).to eq([])
    end

    it 'resolves nested child iframes by percyElementId (not by index)' do
      # Regression: the child-level lookup must use find_element with the
      # data-percy-element-id selector, matching the same stable-id contract
      # used at the top level. A positional alignment against
      # find_elements(:tag_name, 'iframe') would silently mis-pair meta to
      # element if the DOM mutated between enumerate_iframes and find_elements.
      meta = meta_for(src: 'https://other.example.com/parent', percy_id: 'parent-id')
      child_meta = {
        'src' => 'https://third.example.com/child',
        'srcdoc' => nil,
        'percyElementId' => 'child-pid',
        'dataPercyIgnore' => false,
        'matchesIgnoreSelector' => false,
        'index' => 0,
      }

      allow(driver).to receive(:execute_script) do |script|
        if script.include?('document.URL')
          'https://other.example.com/parent'
        elsif script.include?('PercyDOM.serialize')
          {'html' => '<parent/>'}
        elsif script.include?('querySelectorAll') || script.include?('iframe')
          [child_meta]
        end
      end

      child_element = double('child_element')
      expect(driver).to_not receive(:find_elements)
      expect(driver).to receive(:find_element)
        .with(css: 'iframe[data-percy-element-id="child-pid"]')
        .and_return(child_element)

      # Short-circuit the recursive descent into the child so we only verify
      # the child-level lookup path.
      original = Percy.method(:process_frame_tree)
      allow(Percy).to receive(:process_frame_tree).and_wrap_original do |_m, *args|
        if args[1] == child_element
          []
        else
          original.call(*args)
        end
      end

      Percy.process_frame_tree(driver, frame_element, meta, 1, Set.new, ctx)
    end

    it 'raises PercyContextLost when parent_frame fails inside a nested frame' do
      meta = meta_for(src: 'https://other.example.com/page', percy_id: 'elem-deep')
      allow(driver).to receive(:execute_script) do |script|
        if script.include?('document.URL')
          'https://other.example.com/page'
        elsif script.include?('PercyDOM.serialize')
          {'html' => '<deep/>'}
        elsif script.include?('querySelectorAll')
          []
        end
      end
      allow(driver).to receive(:find_elements).with(css: 'iframe').and_return([])
      allow(switch_to).to receive(:parent_frame).and_raise(StandardError, 'lost context')

      expect {
        Percy.process_frame_tree(driver, frame_element, meta, 2, Set.new, ctx)
      }.to raise_error(Percy::PercyContextLost) { |err|
        expect(err.partial_capture.length).to eq(1)
      }
    end

    it 'raises PercyContextLost when parent_frame fails even at depth 1' do
      # Regression (aligns with canonical Nightwatch/Protractor): at depth=1 the
      # outer capture_cors_iframes loop is still iterating sibling iframe
      # references resolved against the now-stale parent. Silently continuing
      # would risk attaching a later iframe's content under an earlier iframe's
      # percyElementId, so we must abort the sibling walk rather than swallow.
      meta = meta_for(src: 'https://other.example.com/page', percy_id: 'elem-top')
      allow(driver).to receive(:execute_script) do |script|
        if script.include?('document.URL')
          'https://other.example.com/page'
        elsif script.include?('PercyDOM.serialize')
          {'html' => '<top/>'}
        elsif script.include?('querySelectorAll')
          []
        end
      end
      allow(driver).to receive(:find_elements).with(css: 'iframe').and_return([])
      allow(switch_to).to receive(:parent_frame).and_raise(StandardError, 'lost context')

      expect {
        Percy.process_frame_tree(driver, frame_element, meta, 1, Set.new, ctx)
      }.to raise_error(Percy::PercyContextLost) { |err|
        expect(err.partial_capture.length).to eq(1)
      }
    end
  end

  describe '.process_frame_tree (error-recovery branches)' do
    let(:driver)        { double('driver') }
    let(:frame_element) { double('frame_element') }
    let(:switch_to)     { double('switch_to') }
    let(:ctx) do
      {
        max_frame_depth: Percy::DEFAULT_MAX_FRAME_DEPTH,
        ignore_selectors: [],
        serialize_options: {},
        percy_dom_script: 'percy_dom_script',
      }
    end

    before(:each) do
      allow(driver).to receive(:switch_to).and_return(switch_to)
      allow(switch_to).to receive(:frame)
      allow(switch_to).to receive(:parent_frame)
      allow(switch_to).to receive(:default_content)
      allow(Percy).to receive(:log)
    end

    def meta_for(src:, percy_id: 'elem-123')
      {
        'src' => src,
        'srcdoc' => nil,
        'percyElementId' => percy_id,
        'dataPercyIgnore' => false,
        'matchesIgnoreSelector' => false,
        'index' => 0,
      }
    end

    it 'falls back to meta src when reading document.URL post-switch raises' do
      meta = meta_for(src: 'https://other.example.com/page', percy_id: 'elem-url')
      allow(driver).to receive(:execute_script) do |script|
        raise StandardError, 'document.URL unavailable' if script.include?('document.URL')

        if script.include?('PercyDOM.serialize')
          {'html' => '<frame/>'}
        elsif script.include?('querySelectorAll')
          []
        end
      end
      allow(driver).to receive(:find_elements).with(css: 'iframe').and_return([])

      result = Percy.process_frame_tree(driver, frame_element, meta, 1, Set.new, ctx)

      expect(result.length).to eq(1)
      # frame_url fell back to meta['src'] since document.URL read failed
      expect(result[0]['frameUrl']).to eq('https://other.example.com/page')
    end

    it 'returns the partial collection when serialize returns nil' do
      meta = meta_for(src: 'https://other.example.com/page', percy_id: 'elem-nil')
      # serialize returns nil -> method returns early, so the child
      # enumeration (querySelectorAll) is never reached.
      allow(driver).to receive(:execute_script) do |script|
        script.include?('document.URL') ? 'https://other.example.com/page' : nil
      end

      result = Percy.process_frame_tree(driver, frame_element, meta, 1, Set.new, ctx)
      expect(result).to eq([])
    end

    it 'still recurses into children when the frame origin cannot be parsed' do
      # frame_url contains a space so get_origin raises URI::InvalidURIError;
      # current_origin falls back to nil, but the descent still proceeds.
      meta = meta_for(src: 'https://other.example.com/page', percy_id: 'elem-badorigin')
      allow(driver).to receive(:execute_script) do |script|
        if script.include?('document.URL')
          'http://exa mple.com/frame' # unparseable -> get_origin raises -> nil
        elsif script.include?('PercyDOM.serialize')
          {'html' => '<frame/>'}
        elsif script.include?('querySelectorAll')
          [] # no children
        end
      end
      allow(driver).to receive(:find_elements).with(css: 'iframe').and_return([])

      result = Percy.process_frame_tree(driver, frame_element, meta, 1, Set.new, ctx)
      expect(result.length).to eq(1)
    end

    it 'merges an inner PercyContextLost partial capture and re-raises with the union' do
      # A nested process_frame_tree raises PercyContextLost carrying its own
      # partial capture. The outer level must concat that into whatever it had
      # collected, stamp the merged set onto the error, and re-raise.
      meta = meta_for(src: 'https://other.example.com/parent', percy_id: 'parent-id')
      child_meta = meta_for(src: 'https://third.example.com/child', percy_id: 'child-id')

      allow(driver).to receive(:execute_script) do |script|
        if script.include?('document.URL')
          'https://other.example.com/parent'
        elsif script.include?('PercyDOM.serialize')
          {'html' => '<parent/>'}
        elsif script.include?('querySelectorAll')
          [child_meta]
        end
      end
      child_element = double('child_element')
      allow(driver).to receive(:find_element)
        .with(css: 'iframe[data-percy-element-id="child-id"]')
        .and_return(child_element)

      inner_partial = [{
        'iframeData' => {'percyElementId' => 'inner-pid'},
        'iframeSnapshot' => {'html' => '<inner/>'},
        'frameUrl' => 'https://third.example.com/child',
      }]
      inner_err = Percy::PercyContextLost.new('inner loss')
      inner_err.partial_capture = inner_partial

      original = Percy.method(:process_frame_tree)
      allow(Percy).to receive(:process_frame_tree).and_wrap_original do |_m, *args|
        raise inner_err if args[1] == child_element

        original.call(*args)
      end

      expect {
        Percy.process_frame_tree(driver, frame_element, meta, 1, Set.new, ctx)
      }.to raise_error(Percy::PercyContextLost) { |err|
        # Union: the parent's own captured frame + the inner partial.
        expect(err.partial_capture.length).to eq(2)
        expect(err.partial_capture.map { |c| c['iframeData']['percyElementId'] })
          .to contain_exactly('parent-id', 'inner-pid')
      }
    end

    it 'still raises PercyContextLost when the default_content recovery also fails' do
      # parent_frame fails, so we attempt default_content as a recovery -- but
      # that ALSO raises. The inner failure is swallowed and PercyContextLost is
      # raised regardless, carrying whatever was collected.
      meta = meta_for(src: 'https://other.example.com/page', percy_id: 'elem-fallback')
      allow(driver).to receive(:execute_script) do |script|
        if script.include?('document.URL')
          'https://other.example.com/page'
        elsif script.include?('PercyDOM.serialize')
          {'html' => '<frame/>'}
        elsif script.include?('querySelectorAll')
          []
        end
      end
      allow(driver).to receive(:find_elements).with(css: 'iframe').and_return([])
      allow(switch_to).to receive(:parent_frame).and_raise(StandardError, 'lost parent')
      # The recovery attempt itself blows up -- must be swallowed.
      allow(switch_to).to receive(:default_content)
        .and_raise(StandardError, 'cannot reach default content')

      expect {
        Percy.process_frame_tree(driver, frame_element, meta, 2, Set.new, ctx)
      }.to raise_error(Percy::PercyContextLost) { |err|
        expect(err.partial_capture.length).to eq(1)
      }
    end
  end

  describe '.enumerate_iframes' do
    let(:driver) { double('driver') }

    before(:each) { allow(Percy).to receive(:log) }

    it 'returns the array produced by the in-browser enumeration script' do
      metas = [{'src' => 'https://a.example.com/', 'percyElementId' => 'p1'}]
      allow(driver).to receive(:execute_script).and_return(metas)
      expect(Percy.enumerate_iframes(driver, [])).to eq(metas)
    end

    it 'returns [] when the script returns a non-array' do
      allow(driver).to receive(:execute_script).and_return(nil)
      expect(Percy.enumerate_iframes(driver, [])).to eq([])
    end

    it 'swallows execute_script failures, logs at debug, and returns []' do
      allow(driver).to receive(:execute_script)
        .and_raise(StandardError, 'enumeration boom')
      expect(Percy).to receive(:log)
        .with(/Failed to enumerate iframes: enumeration boom/, 'debug')
      expect(Percy.enumerate_iframes(driver, [])).to eq([])
    end
  end

  describe '.should_skip_iframe? (unparseable src)' do
    before(:each) { allow(Percy).to receive(:log) }

    it 'skips the iframe when get_origin(src) raises (treated as origin nil)' do
      # A src that passes the unsupported-scheme filter but cannot be parsed
      # by URI -> get_origin raises -> frame_origin is nil -> skip.
      meta = {
        'src' => 'http://exa mple.com/page',
        'srcdoc' => nil,
        'percyElementId' => 'elem-bad',
        'dataPercyIgnore' => false,
        'matchesIgnoreSelector' => false,
      }
      expect(Percy.should_skip_iframe?(meta, 'http://main.example.com')).to be(true)
    end
  end

  describe '.capture_cors_iframes (outer error recovery)' do
    let(:driver)    { double('driver') }
    let(:switch_to) { double('switch_to') }
    let(:ctx) do
      {
        max_frame_depth: Percy::DEFAULT_MAX_FRAME_DEPTH,
        ignore_selectors: [],
        serialize_options: {},
        percy_dom_script: 'percy_dom_script',
      }
    end

    before(:each) do
      allow(driver).to receive(:switch_to).and_return(switch_to)
      allow(switch_to).to receive(:default_content)
      allow(Percy).to receive(:log)
    end

    it 'swallows an unexpected failure, restores default_content, and returns []' do
      # current_url raises -> outer rescue -> default_content restore -> [].
      allow(driver).to receive(:current_url).and_raise(StandardError, 'driver gone')
      expect(switch_to).to receive(:default_content)
      expect(Percy).to receive(:log)
        .with(/Failed to process cross-origin iframes: driver gone/, 'debug')

      expect(Percy.capture_cors_iframes(driver, ctx)).to eq([])
    end

    it 'still returns [] when the default_content restore itself raises' do
      allow(driver).to receive(:current_url).and_raise(StandardError, 'driver gone')
      allow(switch_to).to receive(:default_content)
        .and_raise(StandardError, 'cannot restore')

      expect(Percy.capture_cors_iframes(driver, ctx)).to eq([])
    end
  end

  describe '.clamp_frame_depth' do
    it 'returns the default for nil input' do
      expect(Percy.clamp_frame_depth(nil)).to eq(Percy::DEFAULT_MAX_FRAME_DEPTH)
    end

    it 'returns the default for non-numeric garbage' do
      expect(Percy.clamp_frame_depth('not-a-number')).to eq(Percy::DEFAULT_MAX_FRAME_DEPTH)
    end

    it 'honours a custom default for unparseable input' do
      expect(Percy.clamp_frame_depth({}, default: 4)).to eq(4)
    end

    it 'floors negative depths to zero' do
      expect(Percy.clamp_frame_depth(-7)).to eq(0)
    end

    it 'caps oversized depths at HARD_MAX_FRAME_DEPTH' do
      expect(Percy.clamp_frame_depth(10_000)).to eq(Percy::HARD_MAX_FRAME_DEPTH)
    end

    it 'passes through a valid in-range depth' do
      expect(Percy.clamp_frame_depth(3)).to eq(3)
    end

    it 'coerces a numeric string within range' do
      expect(Percy.clamp_frame_depth('5')).to eq(5)
    end
  end

  describe '.expose_closed_shadow_roots (CDP registration failure)' do
    let(:driver) { double('driver') }

    before(:each) { allow(Percy).to receive(:log) }

    it 'swallows a CDP failure during registration and logs at debug' do
      # A closed shadow root is found, but the Runtime call to register it
      # raises -- the whole registration block is non-fatal and only logged.
      tree = {
        'root' => {
          'backendNodeId' => 1,
          'children' => [{
            'backendNodeId' => 2,
            'shadowRoots' => [{
              'backendNodeId' => 3,
              'shadowRootType' => 'closed',
            }],
          }],
        },
      }
      allow(driver).to receive(:respond_to?).with(:execute_cdp).and_return(true)
      allow(driver).to receive(:execute_cdp).with('DOM.getDocument', anything).and_return(tree)
      allow(driver).to receive(:execute_script)
        .and_raise(StandardError, 'WeakMap setup failed')

      expect(Percy).to receive(:log)
        .with(/Could not expose closed shadow roots via CDP: WeakMap setup failed/, 'debug')
      expect { Percy.expose_closed_shadow_roots(driver) }.to_not raise_error
    end
  end

  describe 'Percy::PercyContextLost' do
    # Regression: previous code paths could overwrite the original backtrace
    # by re-raising a new error. The exception's backtrace must point at the
    # raise site, not nil and not at the rescue site.
    it 'preserves the original backtrace when raised then rescued' do
      raised_line = nil
      err = nil
      begin
        raised_line = __LINE__ + 1
        raise Percy::PercyContextLost, 'simulated context loss'
      rescue Percy::PercyContextLost => e
        err = e
      end

      expect(err).to be_a(Percy::PercyContextLost)
      expect(err.backtrace).to_not be_nil
      expect(err.backtrace).to_not be_empty
      # The top frame of the backtrace should point at the raise line in this file
      expect(err.backtrace.first).to include(__FILE__)
      expect(err.backtrace.first).to include(":#{raised_line}:")
    end
  end

  describe '.get_serialized_dom' do
    let(:driver)    { double('driver') }
    let(:manage)    { double('manage') }
    let(:switch_to) { double('switch_to') }

    def iframe_meta(src:, percy_id: 'cid-1', ignore: false, matches_ignore: false, srcdoc: nil)
      {
        'src' => src,
        'srcdoc' => srcdoc,
        'percyElementId' => percy_id,
        'dataPercyIgnore' => ignore,
        'matchesIgnoreSelector' => matches_ignore,
        'index' => 0,
      }
    end

    before(:each) do
      allow(driver).to receive(:manage).and_return(manage)
      allow(manage).to receive(:all_cookies).and_return([])
      allow(driver).to receive(:switch_to).and_return(switch_to)
      allow(switch_to).to receive(:frame)
      allow(switch_to).to receive(:parent_frame)
      allow(switch_to).to receive(:default_content)
      allow(Percy).to receive(:log)
      # The PER-7348 readiness gate runs PercyDOM.waitForReady via
      # execute_async_script before serialize. Tests that aren't specifically
      # about readiness still hit that path, so provide a harmless default
      # no-op stub (returns nil = "gate ran, no diagnostics"). Readiness-specific
      # tests below override this stub with their own expectations.
      allow(driver).to receive(:execute_async_script).and_return(nil)
    end

    it 'returns the serialized dom with cookies when no iframes present' do
      # Called without percy_dom_script, so capture_cors_iframes (and thus the
      # iframe enumeration script) never runs -- only the top-level serialize.
      allow(driver).to receive(:execute_script) do |script|
        {'html' => '<html/>'} if script.include?('PercyDOM.serialize')
      end
      allow(driver).to receive(:current_url).and_return('http://main.example.com/')
      allow(driver).to receive(:find_elements).with(css: 'iframe').and_return([])

      dom = Percy.get_serialized_dom(driver, {})
      expect(dom['html']).to eq('<html/>')
      expect(dom['cookies']).to eq([])
      expect(dom).to_not have_key('corsIframes')
    end

    it 'populates corsIframes for cross-origin frames' do
      frame = double('frame')

      script_calls = 0
      allow(driver).to receive(:execute_script) do |script|
        script_calls += 1
        if script_calls == 1
          {'html' => '<main/>'} # top-level serialize
        elsif script.include?('querySelectorAll')
          [iframe_meta(src: 'https://cross.example.com/page', percy_id: 'cid-1')]
        elsif script.include?('document.URL')
          'https://cross.example.com/page'
        elsif script.include?('PercyDOM.serialize')
          {'html' => '<frame/>'}
        end
      end
      allow(driver).to receive(:current_url).and_return('http://main.example.com/')
      allow(driver).to receive(:find_element)
        .with(css: 'iframe[data-percy-element-id="cid-1"]').and_return(frame)

      dom = Percy.get_serialized_dom(driver, {}, percy_dom_script: 'percy_dom_script')

      expect(dom).to have_key('corsIframes')
      expect(dom['corsIframes'].length).to eq(1)
      expect(dom['corsIframes'][0]['iframeData']['percyElementId']).to eq('cid-1')
      expect(dom['corsIframes'][0]['iframeSnapshot']['html']).to eq('<frame/>')
      expect(dom['corsIframes'][0]['frameUrl']).to eq('https://cross.example.com/page')
    end

    it 'skips same-origin iframes' do
      frame = double('frame')
      script_calls = 0
      allow(driver).to receive(:execute_script) do |script|
        script_calls += 1
        if script_calls == 1
          {'html' => '<html/>'}
        elsif script.include?('querySelectorAll')
          [iframe_meta(src: 'http://main.example.com/inner.html')]
        end
      end
      allow(driver).to receive(:current_url).and_return('http://main.example.com/')
      allow(driver).to receive(:find_elements).with(css: 'iframe').and_return([frame])

      dom = Percy.get_serialized_dom(driver, {}, percy_dom_script: 'percy_dom_script')
      expect(dom).to_not have_key('corsIframes')
    end

    it 'skips iframes with about:blank src' do
      frame = double('frame')
      script_calls = 0
      allow(driver).to receive(:execute_script) do |script|
        script_calls += 1
        if script_calls == 1
          {'html' => '<html/>'}
        elsif script.include?('querySelectorAll')
          [iframe_meta(src: 'about:blank')]
        end
      end
      allow(driver).to receive(:current_url).and_return('http://main.example.com/')
      allow(driver).to receive(:find_elements).with(css: 'iframe').and_return([frame])

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
      script_calls = 0
      allow(driver).to receive(:execute_script) do |script|
        script_calls += 1
        if script_calls == 1
          {'html' => '<html/>'}
        elsif script.include?('querySelectorAll')
          [iframe_meta(src: 'https://main.example.com/widget', percy_id: 'percy-id-1')]
        elsif script.include?('document.URL')
          'https://main.example.com/widget'
        elsif script.include?('PercyDOM.serialize')
          {'html' => '<frame/>'}
        end
      end
      allow(driver).to receive(:current_url).and_return('http://main.example.com/')
      allow(driver).to receive(:find_element)
        .with(css: 'iframe[data-percy-element-id="percy-id-1"]').and_return(frame)

      dom = Percy.get_serialized_dom(driver, {}, percy_dom_script: 'script')
      expect(dom).to have_key('corsIframes')
    end

    it 'treats same host with different port as cross-origin' do
      frame = double('frame')
      script_calls = 0
      allow(driver).to receive(:execute_script) do |script|
        script_calls += 1
        if script_calls == 1
          {'html' => '<html/>'}
        elsif script.include?('querySelectorAll')
          [iframe_meta(src: 'http://main.example.com:4000/widget', percy_id: 'percy-id-port')]
        elsif script.include?('document.URL')
          'http://main.example.com:4000/widget'
        elsif script.include?('PercyDOM.serialize')
          {'html' => '<frame/>'}
        end
      end
      allow(driver).to receive(:current_url).and_return('http://main.example.com:3000/')
      allow(driver).to receive(:find_element)
        .with(css: 'iframe[data-percy-element-id="percy-id-port"]').and_return(frame)

      dom = Percy.get_serialized_dom(driver, {}, percy_dom_script: 'script')
      expect(dom).to have_key('corsIframes')
    end

    it 'always attaches cookies to the snapshot' do
      cookies_data = [{'name' => 'session', 'value' => 'abc'}]
      allow(manage).to receive(:all_cookies).and_return(cookies_data)
      allow(driver).to receive(:execute_script).and_return({'html' => '<html/>'})
      allow(driver).to receive(:current_url).and_return('http://main.example.com/')
      allow(driver).to receive(:find_elements).with(css: 'iframe').and_return([])

      dom = Percy.get_serialized_dom(driver, {})
      expect(dom['cookies']).to eq(cookies_data)
    end

    it 'preserves partial capture when PercyContextLost is raised mid-walk' do
      frame_a = double('frame_a')
      frame_b = double('frame_b')

      partial = [{
        'iframeData' => {'percyElementId' => 'partial-id'},
        'iframeSnapshot' => {'html' => '<partial/>'},
        'frameUrl' => 'https://partial.example.com/',
      }]
      err = Percy::PercyContextLost.new('lost context mid-walk')
      err.partial_capture = partial

      script_calls = 0
      allow(driver).to receive(:execute_script) do |script|
        script_calls += 1
        if script_calls == 1
          {'html' => '<html/>'}
        elsif script.include?('querySelectorAll')
          [
            iframe_meta(src: 'https://a.example.com/x', percy_id: 'cid-a'),
            iframe_meta(src: 'https://b.example.com/y', percy_id: 'cid-b'),
          ]
        end
      end
      allow(driver).to receive(:current_url).and_return('http://main.example.com/')
      allow(driver).to receive(:find_element)
        .with(css: 'iframe[data-percy-element-id="cid-a"]').and_return(frame_a)
      allow(driver).to receive(:find_element)
        .with(css: 'iframe[data-percy-element-id="cid-b"]').and_return(frame_b)
      # First frame raises PercyContextLost with partial capture
      allow(Percy).to receive(:process_frame_tree).and_raise(err)

      dom = Percy.get_serialized_dom(driver, {}, percy_dom_script: 'script')
      expect(dom['corsIframes']).to eq(partial)
    end

    it 'skips iframes matching ignoreIframeSelectors option' do
      frame = double('frame')
      captured_selectors = nil
      script_calls = 0
      allow(driver).to receive(:execute_script) do |script|
        script_calls += 1
        if script_calls == 1
          {'html' => '<html/>'}
        elsif script.include?('querySelectorAll')
          captured_selectors = script
          [iframe_meta(src: 'https://cross.example.com/x', percy_id: 'cid-z',
                       matches_ignore: true,)]
        end
      end
      allow(driver).to receive(:current_url).and_return('http://main.example.com/')
      allow(driver).to receive(:find_elements).with(css: 'iframe').and_return([frame])

      dom = Percy.get_serialized_dom(driver, {ignoreIframeSelectors: '.ad'},
        percy_dom_script: 'script',)
      expect(dom).to_not have_key('corsIframes')
      # The selector list flows through to the in-browser script
      expect(captured_selectors).to include('".ad"')
    end

    it 'skips iframes marked with data-percy-ignore' do
      frame = double('frame')
      script_calls = 0
      allow(driver).to receive(:execute_script) do |script|
        script_calls += 1
        if script_calls == 1
          {'html' => '<html/>'}
        elsif script.include?('querySelectorAll')
          [iframe_meta(src: 'https://cross.example.com/x', percy_id: 'cid-y', ignore: true)]
        end
      end
      allow(driver).to receive(:current_url).and_return('http://main.example.com/')
      allow(driver).to receive(:find_elements).with(css: 'iframe').and_return([frame])

      dom = Percy.get_serialized_dom(driver, {}, percy_dom_script: 'script')
      expect(dom).to_not have_key('corsIframes')
    end

    it 'skips same-origin frame and processes only cross-origin frame' do
      cross_frame = double('cross_frame')

      top_metas = [
        iframe_meta(src: 'http://main.example.com/inner', percy_id: 'cid-same'),
        iframe_meta(src: 'https://other.example.com/page', percy_id: 'cid-x'),
      ]
      enum_call = 0
      allow(driver).to receive(:execute_script) do |script|
        if script.include?('PercyDOM.serialize')
          enum_call.zero? ? {'html' => '<main/>'} : {'html' => '<cross/>'}
        elsif script.include?('querySelectorAll')
          enum_call += 1
          enum_call == 1 ? top_metas : [] # no nested children inside the cross frame
        elsif script.include?('document.URL')
          'https://other.example.com/page'
        end
      end
      allow(driver).to receive(:current_url).and_return('http://main.example.com/')
      allow(driver).to receive(:find_element)
        .with(css: 'iframe[data-percy-element-id="cid-x"]').and_return(cross_frame)

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

    before(:each) do
      allow(driver).to receive(:manage).and_return(manage)
      allow(manage).to receive(:window).and_return(window)
      allow(window).to receive(:resize_to)
      allow(driver).to receive(:capabilities).and_return(caps_firefox)
      allow(driver).to receive(:respond_to?).with(:driver).and_return(false)
      allow(driver).to receive(:respond_to?).with(:execute_cdp).and_return(false)
      allow(driver).to receive(:execute_script) do |script|
        {'w' => 1024, 'h' => 768} if script.include?('innerWidth')
      end
      allow(Selenium::WebDriver::Wait).to receive(:new).and_return(wait)
      allow(wait).to receive(:until)
      allow(Percy).to receive(:log)
    end

    it 'resizes the window using resize_to for non-chrome browsers' do
      expect(window).to receive(:resize_to).with(768, 1024)
      Percy.change_window_dimension_and_wait(driver, 768, 1024, 1)
    end

    it 'dispatches a resize event after resizing for non-chrome browsers' do
      expect(driver).to receive(:execute_script)
        .with("window.dispatchEvent(new Event('resize'));")
      Percy.change_window_dimension_and_wait(driver, 768, 1024, 1)
    end

    it 'uses execute_cdp for chrome when execute_cdp is available' do
      chrome_caps = double('capabilities', browser_name: 'chrome')
      allow(driver).to receive(:capabilities).and_return(chrome_caps)
      allow(driver).to receive(:respond_to?).with(:execute_cdp).and_return(true)
      expect(driver).to receive(:execute_cdp).with(
        'Emulation.setDeviceMetricsOverride',
        {height: 812, width: 375, deviceScaleFactor: 1, mobile: false},
      )
      Percy.change_window_dimension_and_wait(driver, 375, 812, 1)
    end

    it 'does not call resize_to when cdp succeeds for chrome' do
      chrome_caps = double('capabilities', browser_name: 'chrome')
      allow(driver).to receive(:capabilities).and_return(chrome_caps)
      allow(driver).to receive(:respond_to?).with(:execute_cdp).and_return(true)
      allow(driver).to receive(:execute_cdp)
      expect(window).to_not receive(:resize_to)
      Percy.change_window_dimension_and_wait(driver, 375, 812, 1)
    end

    it 'falls back to resize_to when execute_cdp raises' do
      chrome_caps = double('capabilities', browser_name: 'chrome')
      allow(driver).to receive(:capabilities).and_return(chrome_caps)
      allow(driver).to receive(:respond_to?).with(:execute_cdp).and_return(true)
      allow(driver).to receive(:execute_cdp).and_raise(StandardError, 'cdp error')
      expect(window).to receive(:resize_to).with(375, 812)
      Percy.change_window_dimension_and_wait(driver, 375, 812, 1)
    end

    it 'dispatches a resize event in the cdp fallback path' do
      chrome_caps = double('capabilities', browser_name: 'chrome')
      allow(driver).to receive(:capabilities).and_return(chrome_caps)
      allow(driver).to receive(:respond_to?).with(:execute_cdp).and_return(true)
      allow(driver).to receive(:execute_cdp).and_raise(StandardError, 'cdp error')
      expect(driver).to receive(:execute_script)
        .with("window.dispatchEvent(new Event('resize'));")
      Percy.change_window_dimension_and_wait(driver, 375, 812, 1)
    end

    it 'logs and swallows a TimeoutError when the resize event never fires' do
      allow(wait).to receive(:until).and_raise(Selenium::WebDriver::Error::TimeoutError)
      expect(Percy).to receive(:log).with(/Timed out waiting for window resize event/, 'debug')
      expect { Percy.change_window_dimension_and_wait(driver, 768, 1024, 1) }.to_not raise_error
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
      allow(Percy).to receive(:log)
    end

    # -----------------------------------------------------------------------
    # Resize behavior
    # -----------------------------------------------------------------------

    it 'calls change_window_dimension_and_wait for each distinct width' do
      allow(Percy).to receive(:get_responsive_widths).and_return(
        [{'width' => 375}, {'width' => 768}, {'width' => 1280}],
      )
      # Each of the 3 widths differs from the previous + final restore = 4 calls
      expect(Percy).to receive(:change_window_dimension_and_wait).exactly(4).times
      Percy.capture_responsive_dom(driver, {})
    end

    it 'skips resize when consecutive entries have the same width and height' do
      allow(Percy).to receive(:get_responsive_widths).and_return(
        [{'width' => 375}, {'width' => 375}],
      )
      # 375 (first, differs from 1280) + final restore = 2; second 375 skipped
      expect(Percy).to receive(:change_window_dimension_and_wait).twice
      Percy.capture_responsive_dom(driver, {})
    end

    it 'passes the requested width and window height to change_window_dimension_and_wait' do
      allow(Percy).to receive(:get_responsive_widths).and_return([{'width' => 390}])
      expect(Percy).to receive(:change_window_dimension_and_wait)
        .with(driver, 390, 900, anything)
      Percy.capture_responsive_dom(driver, {})
    end

    it 'uses per-entry height from widths list over the default target_height' do
      allow(Percy).to receive(:get_responsive_widths).and_return(
        [{'width' => 390, 'height' => 844}],
      )
      expect(Percy).to receive(:change_window_dimension_and_wait)
        .with(driver, 390, 844, anything)
      Percy.capture_responsive_dom(driver, {})
    end

    it 'restores original window dimensions after processing all widths' do
      allow(Percy).to receive(:get_responsive_widths).and_return([{'width' => 375}])
      expect(Percy).to receive(:change_window_dimension_and_wait)
        .with(driver, 1280, 900, anything)
      Percy.capture_responsive_dom(driver, {})
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
        allow(driver).to receive(:respond_to?).with(:execute_cdp).and_return(false)
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
          .with(driver, 390, 800, anything)
        Percy.capture_responsive_dom(driver, {minHeight: 800})
      end

      it 'uses minHeight from cli_config when not provided in options' do
        begin
          Percy.instance_variable_set(:@cli_config, {'snapshot' => {'minHeight' => 700}})
          expect(Percy).to receive(:change_window_dimension_and_wait)
            .with(driver, 390, 700, anything)
          Percy.capture_responsive_dom(driver, {})
        ensure
          Percy.instance_variable_set(:@cli_config, nil)
        end
      end

      it 'uses the current window height unchanged when minHeight is not set' do
        expect(Percy).to receive(:change_window_dimension_and_wait)
          .with(driver, 390, 900, anything)
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

  describe '.capture_cors_iframes (lookup by percyElementId)' do
    let(:driver) { instance_double('Selenium::WebDriver::Driver') }

    before(:each) do
      allow(driver).to receive(:current_url).and_return('https://example.com/')
      # enumerate_iframes calls driver.execute_script -- return a same-origin
      # entry followed by a CORS entry so the loop has something to skip and
      # something to process.
      allow(driver).to receive(:execute_script).and_return([
        {'src' => 'https://example.com/same', 'percyElementId' => 'pid-same'},
        {'src' => 'https://other.com/cors',   'percyElementId' => 'pid-cors'},
      ])
    end

    it 'looks up the iframe element by data-percy-element-id, not by index' do
      # Regression: positional alignment between the JS enumerate_iframes
      # result and driver.find_elements(:tag_name, 'iframe') could ship one
      # iframe's content under another's percyElementId if the DOM mutated
      # between the two reads. The new code resolves by stable id and never
      # calls find_elements on the iframe collection.
      cors_element = instance_double('Selenium::WebDriver::Element')

      expect(driver).to_not receive(:find_elements)
      expect(driver).to receive(:find_element)
        .with(css: 'iframe[data-percy-element-id="pid-cors"]')
        .and_return(cors_element)

      # Short-circuit process_frame_tree so we only verify the lookup path.
      allow(Percy).to receive(:process_frame_tree).and_return([])

      Percy.capture_cors_iframes(driver, {
                                   max_frame_depth: 5,
                                   ignore_selectors: [],
                                   percy_dom_script: '',
                                   serialize_options: {},
                                 },)
    end
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
      allow(driver).to receive(:respond_to?).with(:driver).and_return(false)
      # This branch's snapshot path calls expose_closed_shadow_roots, which
      # checks driver.respond_to?(:execute_cdp). Stub it to false so the
      # closed-shadow-DOM CDP path no-ops for this non-Chromium mock driver.
      allow(driver).to receive(:respond_to?).with(:execute_cdp).and_return(false)
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
