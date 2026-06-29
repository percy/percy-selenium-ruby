# This must be required & started before any app code (for proper coverage)
require 'simplecov'
SimpleCov.start
SimpleCov.minimum_coverage 100

require 'rack'
require 'percy'
require 'webmock/rspec'
require 'capybara/rspec'
require 'selenium-webdriver'

RSpec.configure do |config|
  config.expect_with :rspec do |expectations|
    # This option will default to `true` in RSpec 4.
    expectations.include_chain_clauses_in_custom_matcher_descriptions = true
  end

  config.mock_with :rspec do |mocks|
    mocks.verify_partial_doubles = true
  end

  config.disable_monkey_patching!
  # config.warnings = true

  # Run specs in random order to surface order dependencies. If you find an
  # order dependency and want to debug it, you can fix the order by providing
  # the seed, which is printed after each run.
  #     --seed 1234
  config.order = :random

  # Seed global randomization in this process using the `--seed` CLI option.
  # Setting this allows you to use `--seed` to deterministically reproduce
  # test failures related to randomization by passing the same `--seed` value
  # as the one that triggered the failure.
  Kernel.srand config.seed

  # See https://github.com/teamcapybara/capybara#selecting-the-driver for other options
  # Default to Firefox headless (matches CI), but when a Chromium/Chrome binary is
  # provided via CHROME_BIN (e.g. the containerised e2e image), register and use a
  # headless Chrome driver pointing at it instead.
  if ENV['CHROME_BIN'] && !ENV['CHROME_BIN'].empty?
    Capybara.register_driver :selenium_chrome_headless_bin do |app|
      options = Selenium::WebDriver::Chrome::Options.new
      options.binary = ENV['CHROME_BIN']
      options.add_argument('--headless=new')
      options.add_argument('--no-sandbox')
      options.add_argument('--disable-gpu')
      options.add_argument('--disable-dev-shm-usage')
      Capybara::Selenium::Driver.new(app, browser: :chrome, options: options)
    end
    Capybara.default_driver = :selenium_chrome_headless_bin
    Capybara.javascript_driver = :selenium_chrome_headless_bin
  else
    Capybara.default_driver = :selenium_headless
    Capybara.javascript_driver = :selenium_headless
  end

  # Setup for Capybara to test Jekyll static files served by Rack
  Capybara.server_port = 3003
  Capybara.server = :puma, { Silent: true }
  Capybara.app = Rack::Files.new(File.join(File.dirname(__FILE__), 'fixture'))
end
