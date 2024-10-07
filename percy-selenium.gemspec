# coding: utf-8
lib = File.expand_path('../lib', __FILE__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require 'version'

Gem::Specification.new do |spec|
  spec.name          = 'percy-selenium'
  spec.version       = Percy::VERSION
  spec.authors       = ['Perceptual Inc.']
  spec.email         = ['team@percy.io']
  spec.summary       = %q{Percy visual testing for Ruby Selenium}
  spec.description   = %q{}
  spec.homepage      = ''
  spec.license       = 'MIT'
  spec.required_ruby_version = '>= 2.3.0'


  spec.metadata = {
    'bug_tracker_uri' => 'https://github.com/percy/percy-selenium-ruby/issues',
    'source_code_uri' => 'https://github.com/percy/percy-selenium-ruby',
  }

  spec.files         = `git ls-files -z`.split("\x0")
  spec.executables   = spec.files.grep(%r{^bin/}) { |f| File.basename(f) }
  spec.test_files    = spec.files.grep(%r{^(test|spec|features)/})
  spec.require_paths = ['lib']

  spec.add_runtime_dependency 'selenium-webdriver', '>= 4.0.0.beta1'
  spec.add_runtime_dependency 'capybara', '>= 3.0.0'

  spec.add_development_dependency 'bundler', '>= 2.0'
  spec.add_development_dependency 'rake', '~> 13.0'
  spec.add_development_dependency 'rspec', '~> 3.5'
  spec.add_development_dependency 'capybara', '~> 3.35'
  spec.add_development_dependency 'percy-style', '~> 0.7.0'
end
