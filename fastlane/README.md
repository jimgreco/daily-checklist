fastlane documentation
----

# Installation

Make sure you have the latest version of the Xcode command line tools installed:

```sh
xcode-select --install
```

For _fastlane_ installation instructions, see [Installing _fastlane_](https://docs.fastlane.tools/#installing-fastlane)

# Available Actions

## iOS

### ios screenshots

```sh
[bundle exec] fastlane ios screenshots
```

Capture App Store screenshots from deterministic local sample data

### ios upload_metadata

```sh
[bundle exec] fastlane ios upload_metadata
```

Upload source-controlled App Store listing metadata to the editable version

### ios upload_screenshots

```sh
[bundle exec] fastlane ios upload_screenshots
```

Upload generated screenshots to the editable App Store version

### ios screenshots_and_upload

```sh
[bundle exec] fastlane ios screenshots_and_upload
```

Capture screenshots, then upload them to App Store Connect

### ios upload_release_assets

```sh
[bundle exec] fastlane ios upload_release_assets
```

Upload App Store metadata and screenshots

----

This README.md is auto-generated and will be re-generated every time [_fastlane_](https://fastlane.tools) is run.

More information about _fastlane_ can be found on [fastlane.tools](https://fastlane.tools).

The documentation of _fastlane_ can be found on [docs.fastlane.tools](https://docs.fastlane.tools).
