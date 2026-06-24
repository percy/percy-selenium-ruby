source "https://rubygems.org"

# Specify your gem's dependencies in percy-selenium.gemspec
gemspec

gem "guard-rspec", require: false

group :test, :development do
  gem "webmock"
  # Capybara 3.36 (the newest Capybara that supports Ruby 2.6, which CI still
  # targets) uses the Puma 5 events API; Puma 6 removed Puma::Events.strings,
  # which broke the Capybara server boot. Pin to Puma 5 for compatibility.
  gem "puma", '~> 5'
  # Puma 5's rack handler requires `rack/handler`, which Rack 3 removed (it
  # moved to the separate `rackup` gem). Pin Rack 2 so Capybara can boot Puma.
  gem "rack", '~> 2.2'
  gem "pry"
  gem "simplecov", require: false
end
