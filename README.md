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
- `options` - [See per-snapshot configuration options](https://www.browserstack.com/docs/percy/take-percy-snapshots/overview#per-snapshot-configuration)

## Running Percy on Automate
`Percy.percy_screenshot(driver, name, options)` [ needs @percy/cli 1.27.0-beta.0+ ]

This is an example test using the `percy_screenshot` method.

``` ruby
require 'percy'

capabilities = {
  'browserName' => 'chrome',
  'bstack:options' => {
    'userName' => '<your-username>',
    'accessKey' => '<your-access-key>'
  }
}

driver = Selenium::WebDriver.for(
  :remote,
  url: 'https://hub-cloud.browserstack.com/wd/hub',
  capabilities: capabilities
)

driver.navigate.to "https://example.com"

# Take a Percy screenshot
Percy.percy_screenshot(driver, 'Screenshot 1')

driver.navigate.to "https://google.com"
Percy.percy_screenshot(driver, 'Screenshot 2')

driver.quit
```

- `driver` (**required**) - A Selenium driver instance
- `name` (**required**) - The screenshot name; must be unique to each screenshot
- `options` (**optional**) - There are various options supported by `percy_screenshot` to serve further functionality.
    - `sync` - Boolean value by default it falls back to `false`, Gives the processed result around screenshot [From CLI v1.28.0-beta.0+]
    - `fullPage` - Boolean value by default it falls back to `false`, Takes full page screenshot [From CLI v1.27.6+]
    - `freezeAnimatedImage` - Boolean value by default it falls back to `false`, you can pass `true` and Percy will freeze image based animations.
    - `freezeImageBySelectors` - List of selectors. Images will be frozen which are passed using selectors. For this to work `freezeAnimatedImage` must be set to true.
    - `freezeImageByXpaths` - List of xpaths. Images will be frozen which are passed using xpaths. For this to work `freezeAnimatedImage` must be set to true.
    - `percyCSS` - Custom CSS to be added to DOM before the screenshot being taken. Note: This gets removed once the screenshot is taken.
    - `ignoreRegionXpaths` - List of xpaths. Elements in the DOM can be ignored using xpath.
    - `ignoreRegionSelectors` - List of selectors. Elements in the DOM can be ignored using selectors.
    - `ignoreRegionSeleniumElements` - List of Selenium WebElement. Elements can be ignored using selenium elements.
    - `customIgnoreRegions` - List of custom objects. Elements can be ignored using custom boundaries. Just passing a simple hash for it like below.
      - example: `{top: 10, right: 10, bottom: 120, left: 10}`
      - In the above example it will draw a rectangle of ignore region as per given coordinates.
        - `top` (int): Top coordinate of the ignore region.
        - `bottom` (int): Bottom coordinate of the ignore region.
        - `left` (int): Left coordinate of the ignore region.
        - `right` (int): Right coordinate of the ignore region.
    - `considerRegionXpaths` - List of xpaths. Elements in the DOM can be considered for diffing and will be ignored by Intelli Ignore using xpaths.
    - `considerRegionSelectors` - List of selectors. Elements in the DOM can be considered for diffing and will be ignored by Intelli Ignore using selectors.
    - `considerRegionSeleniumElements` - List of Selenium WebElement. Elements can be considered for diffing and will be ignored by Intelli Ignore using selenium elements.
    - `customConsiderRegions` - List of custom objects. Elements can be considered for diffing and will be ignored by Intelli Ignore using custom boundaries.
      - example: `{top: 10, right: 10, bottom: 120, left: 10}`
      - In the above example a rectangle of consider region will be drawn.
      - Parameters:
        - `top` (int): Top coordinate of the consider region.
        - `bottom` (int): Bottom coordinate of the consider region.
        - `left` (int): Left coordinate of the consider region.
        - `right` (int): Right coordinate of the consider region.
    - `regions` - Parameter that allows users to apply snapshot options to specific areas of the page. This parameter is an array where each object defines a custom region with configurations.
      - Parameters:
        - `elementSelector` (optional, only one of the following must be provided, if this is not provided then full page will be considered as region)
            - `boundingBox` (hash): Defines the coordinates and size of the region.
              - `x` (number): X-coordinate of the region.
              - `y` (number): Y-coordinate of the region.
              - `width` (number): Width of the region.
              - `height` (number): Height of the region.
            - `elementXpath` (string): The XPath selector for the element.
            - `elementCSS` (string): The CSS selector for the element.
        - `algorithm` (mandatory)
            - Specifies the snapshot comparison algorithm.
            - Allowed values: `standard`, `layout`, `ignore`, `intelliignore`.
        - `configuration` (required for `standard` and `intelliignore` algorithms, ignored otherwise)
            - `diffSensitivity` (number): Sensitivity level for detecting differences.
            - `imageIgnoreThreshold` (number): Threshold for ignoring minor image differences.
            - `carouselsEnabled` (boolean): Whether to enable carousel detection.
            - `bannersEnabled` (boolean): Whether to enable banner detection.
            - `adsEnabled` (boolean): Whether to enable ad detection.
        - `assertion` (optional)
            - Defines assertions to apply to the region.
            - `diffIgnoreThreshold` (number): The threshold for ignoring minor differences.

### Example Usage for regions

``` ruby
region1 = {
  elementSelector: {
    elementCSS: '.ad-banner'
  },
  algorithm: 'intelliignore',
  configuration: {
    diffSensitivity: 2,
    imageIgnoreThreshold: 0.2,
    carouselsEnabled: true,
    bannersEnabled: true,
    adsEnabled: true
  },
  assertion: {
    diffIgnoreThreshold: 0.4
  }
}

# Using Percy.create_region helper
region2 = Percy.create_region(
  algorithm: 'intelliignore',
  diff_sensitivity: 3,
  ads_enabled: true,
  diff_ignore_threshold: 0.4
)

Percy.percy_screenshot(driver, 'Screenshot 1', regions: [region1, region2])
```

### Creating Percy on Automate build
Note: Automate Percy Token starts with `auto` keyword. The command can be triggered using `exec` keyword.

```sh-session
$ export PERCY_TOKEN=[your-project-token]
$ percy exec -- [ruby test command]
[percy] Percy has started!
[percy] [Ruby example] : Starting automate screenshot ...
[percy] Screenshot taken "Ruby example"
[percy] Stopping percy...
[percy] Finalized build #1: https://percy.io/[your-project]
[percy] Done!
```

Refer to docs here: [Percy on Automate](https://www.browserstack.com/docs/percy/integrate/functional-and-visual)
