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

    it 'logs an error  when sending a snapshot fails' do
      stub_request(:get, "#{Percy::PERCY_SERVER_ADDRESS}/percy/healthcheck")
        .to_return(status: 200, body: '{"success": "true" }',
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
        .to_return(status: 200, body: '{"success": "true" }', headers: {
                     'x-percy-core-version': '1.0.0',
                   },)

      stub_request(:get, "#{Percy::PERCY_SERVER_ADDRESS}/percy/dom.js")
        .to_return(
          status: 200,
          body: fetch_script_string,
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
        body: '{"success": "true", "widths": { "mobile": [390], "config": [765, 1280]} }',
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
        .to_return(status: 200, body: '{"success": "true" }', headers: {})

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
        body: '{"success": "true", "widths": { "mobile": [390], "config": [765, 1280]} }',
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
        .to_return(status: 200, body: '{"success": "true" }', headers: {})

      driver = Selenium::WebDriver.for :firefox

      driver.navigate.to 'http://localhost:5338/test/snapshot'
      driver.manage.add_cookie({name: 'cookie-name', value: 'cookie-value'})
      data = Percy.snapshot(driver, 'Name', {responsive_snapshot_capture: true})

      expected_cookie = {name: 'cookie-name', value: 'cookie-value', path: '/',
                         domain: 'localhost', "expires": nil, "same_site": 'Lax',
                         "http_only": false, "secure": false,}
      expected_dom = '<html><head></head><body><p>Snapshot Me!</p></body></html>'
      expect(WebMock).to have_requested(:post, "#{Percy::PERCY_SERVER_ADDRESS}/percy/snapshot")
        .with(
          body: {
            name: 'Name',
            url: 'http://localhost:5338/test/snapshot',
            dom_snapshot: [
              {'cookies': [expected_cookie], 'html': expected_dom, 'width': 390},
              {'cookies': [expected_cookie], 'html': expected_dom, 'width': 765},
              {'cookies': [expected_cookie], 'html': expected_dom, 'width': 1280},
            ],
            client_info: "percy-selenium-ruby/#{Percy::VERSION}",
            environment_info: "selenium/#{Selenium::WebDriver::VERSION} ruby/#{RUBY_VERSION}",
            responsive_snapshot_capture: true,
          }.to_json,
        ).once

      expect(data).to eq(nil)
    end

    it 'sends snapshots for sync' do
      stub_request(:get, "#{Percy::PERCY_SERVER_ADDRESS}/percy/healthcheck")
        .to_return(status: 200, body: '{"success": "true" }',
                   headers: {'x-percy-core-version': '1.0.0'},)

      stub_request(:get, "#{Percy::PERCY_SERVER_ADDRESS}/percy/dom.js")
        .to_return(
          status: 200,
          body: fetch_script_string,
          headers: {},
        )

      stub_request(:post, 'http://localhost:5338/percy/snapshot')
        .to_return(status: 200, body: '{"success": "true", "data": "sync_data" }', headers: {})

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

    it 'does not add empty configuration or assertion keys' do
      region = Percy.create_region(algorithm: 'ignore')
      expect(region).to_not have_key(:configuration)
      expect(region).to_not have_key(:assertion)
    end
  end
end

RSpec.describe Percy do
  before(:each) do
    WebMock.disable_net_connect!
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

      expect { Percy.get_responsive_widths }
        .to raise_error(StandardError,
                        'Update Percy CLI to the latest version to use responsiveSnapshotCapture')
    end

    it 'raises when the HTTP request fails' do
      stub_request(:get, "#{Percy::PERCY_SERVER_ADDRESS}/percy/widths-config")
        .to_return(status: 500, body: '')

      expect { Percy.get_responsive_widths }
        .to raise_error(StandardError,
                        'Update Percy CLI to the latest version to use responsiveSnapshotCapture')
    end

    it 'raises when the endpoint is unreachable' do
      stub_request(:get, "#{Percy::PERCY_SERVER_ADDRESS}/percy/widths-config")
        .to_raise(StandardError, 'connection refused')

      expect { Percy.get_responsive_widths }
        .to raise_error(StandardError,
                        'Update Percy CLI to the latest version to use responsiveSnapshotCapture')
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
      expect(Percy.get_origin('http://example.com'))
        .to_not eq(Percy.get_origin('https://example.com'))
    end

    it 'treats same host with different ports as different origins' do
      expect(Percy.get_origin('http://example.com:3000'))
        .to_not eq(Percy.get_origin('http://example.com:4000'))
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
    end

    it 'returns a hash with iframeData, iframeSnapshot, and frameUrl on success' do
      allow(frame_element).to receive(:attribute).with('src').and_return('https://other.example.com/page')
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
      allow(frame_element).to receive(:attribute).with('src').and_return('https://other.example.com/page')
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

    it 'always switches back to parent frame even when script injection fails' do
      allow(frame_element).to receive(:attribute).with('src').and_return('https://other.example.com/page')
      allow(driver).to receive(:execute_script).and_raise(StandardError, 'error')
      expect(switch_to).to receive(:parent_frame).once

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
        elsif call_count == 2
          nil
        else
          {'html' => '<frame/>'}
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
        elsif call_count == 2
          nil
        else
          {'html' => '<frame/>'}
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
        elsif call_count == 2
          nil
        else
          {'html' => '<cross/>'}
        end
      end
      allow(driver).to receive(:current_url).and_return('http://main.example.com/')
      allow(driver).to receive(:find_elements).and_return([same_frame, cross_frame])

      dom = Percy.get_serialized_dom(driver, {}, percy_dom_script: 'script')
      expect(dom['corsIframes'].length).to eq(1)
      expect(dom['corsIframes'][0]['frameUrl']).to eq('https://other.example.com/page')
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
