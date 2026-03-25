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

      driver = Selenium::WebDriver.for :firefox
      begin
        # Use the Capybara fixture server (already running for this describe block)
        # instead of the percy test-mode server endpoint which is not available under
        # normal percy exec.
        driver.navigate.to 'http://127.0.0.1:3003/index.html'
        driver.manage.add_cookie({name: 'cookie-name', value: 'cookie-value'})
        data = Percy.snapshot(driver, 'Name', {responsive_snapshot_capture: true})

        expect(received_body['name']).to eq('Name')
        expect(received_body['url']).to eq('http://127.0.0.1:3003/index.html')
        expect(received_body['dom_snapshot'].length).to eq(3)
        expect(received_body['dom_snapshot'].map { |s| s['width'] }).to eq([390, 765, 1280])
        expect(received_body['dom_snapshot'].first['cookies'].first['name']).to eq('cookie-name')
        expect(data).to eq(nil)
      ensure
        begin
          driver.quit
        rescue StandardError
          nil
        end
      end
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
      frame = double('frame')
      allow(frame).to receive(:attribute).with('src').and_return('https://cross.example.com/page')
      allow(frame).to receive(:attribute).with('data-percy-element-id').and_return(nil)
      allow(driver).to receive(:execute_script).and_return({'html' => '<html/>'})
      allow(driver).to receive(:current_url).and_return('http://main.example.com/')
      allow(driver).to receive(:find_elements).and_return([frame])

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
        stub_const('Percy::PERCY_RESPONSIVE_CAPTURE_RELOAD_PAGE', 'true')
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
    end

    # -----------------------------------------------------------------------
    # minHeight / PERCY_RESPONSIVE_CAPTURE_MIN_HEIGHT flag
    # -----------------------------------------------------------------------

    context 'when PERCY_RESPONSIVE_CAPTURE_MIN_HEIGHT is true' do
      before(:each) do
        stub_const('Percy::PERCY_RESPONSIVE_CAPTURE_MIN_HEIGHT', 'true')
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
# rubocop:enable RSpec/MultipleDescribes
