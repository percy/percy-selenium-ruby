# This must be required & started before any app code (for proper coverage)
require 'simplecov'
SimpleCov.start
SimpleCov.minimum_coverage 100

require 'rack'
require 'percy'
require 'webmock/rspec'
require 'capybara/rspec'
require 'selenium-webdriver'

# Capybara's :selenium_headless driver registers an at_exit handler that quits
# the browser session via a real `DELETE http://127.0.0.1:4444/session/...` to
# the local WebDriver. webmock/rspec blocks all net connections by default, so
# that teardown raised WebMock::NetConnectNotAllowedError and failed the whole
# process with exit code 1 even when every example passed (only intermittently,
# because `config.order = :random` controls whether a session-starting spec runs
# before exit). Allow localhost so session teardown and the Capybara Puma test
# server can connect; stubbed requests still take precedence, so external HTTP
# stays blocked.
WebMock.disable_net_connect!(allow_localhost: true)

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
  Capybara.default_driver = :selenium_headless
  Capybara.javascript_driver = :selenium_headless

  # Setup for Capybara to test Jekyll static files served by Rack
  Capybara.server_port = 3003
  Capybara.server = :puma, { Silent: true }
  Capybara.app = Rack::Files.new(File.join(File.dirname(__FILE__), 'fixture'))
end
