# percy-selenium-ruby
[![Gem Version](https://badge.fury.io/rb/percy-selenium.svg)](https://badge.fury.io/rb/percy-selenium)
![Test](https://github.com/percy/percy-selenium-ruby/workflows/Test/badge.svg)

[Percy](https://percy.io) visual testing for Ruby Selenium.

## Installation

npm install `@percy/cli`:

```sh-session
$ npm install --save-dev @percy/cli
```

gem install Percy selenium package:

```ssh-session
$ gem install percy-selenium
```

## Usage

This is an example test using the `Percy.snapshot` method.

``` ruby
require 'percy'

driver = Selenium::WebDriver.for :firefox
driver.navigate.to "https://example.com"

# Take a snapshot
Percy.snapshot(driver, 'homepage')

driver.quit
```

Running the test above normally will result in the following log:

```sh-session
[percy] Percy is not running, disabling snapshots
```

When running with [`percy
exec`](https://github.com/percy/cli/tree/master/packages/cli-exec#percy-exec), and your project's
`PERCY_TOKEN`, a new Percy build will be created and snapshots will be uploaded to your project.

```sh-session
$ export PERCY_TOKEN=[your-project-token]
$ percy exec -- [ruby test command]
[percy] Percy has started!
[percy] Created build #1: https://percy.io/[your-project]
[percy] Snapshot taken "Ruby example"
[percy] Stopping percy...
[percy] Finalized build #1: https://percy.io/[your-project]
[percy] Done!
```

## Configuration

`Percy.snapshot(driver, name[, options])`

- `driver` (**required**) - A selenium-webdriver driver instance
- `name` (**required**) - The snapshot name; must be unique to each snapshot
- `options` - [See per-snapshot configuration options](https://docs.percy.io/docs/cli-configuration#per-snapshot-configuration)
