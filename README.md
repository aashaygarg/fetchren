# FetchRen

FetchRen is an open-source, cross-platform API client built with Flutter.

> **Status:** Early foundation. The repository currently contains only the
> project skeleton, a placeholder home screen, and a smoke test. No API-client
> features have been implemented yet.

## Prerequisites

- [Flutter](https://docs.flutter.dev/get-started/install) (stable channel,
  3.47 or newer), which includes the Dart SDK (3.13 or newer).
- **macOS desktop:** a full installation of Xcode (not only the Command Line
  Tools), with the license accepted and first-launch setup completed:

  ```sh
  sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer
  sudo xcodebuild -runFirstLaunch
  ```

  CocoaPods is only required once a plugin that depends on it is added.
- Run `flutter doctor` to confirm that your toolchain is ready.

## Setup

```sh
git clone <repository-url> fetchren
cd fetchren
flutter pub get
```

## Run

```sh
flutter run -d macos
```

## Test and verify

```sh
dart format --output=none --set-exit-if-changed .   # formatting check
flutter analyze                                     # static analysis (flutter_lints)
flutter test                                        # unit and widget tests
flutter build macos                                 # macOS release build
```

## Project structure

```text
lib/
  main.dart        # Application entry point
  src/
    app.dart       # Root widget and placeholder home screen
test/
  app_test.dart    # Smoke test for the root widget
macos/             # macOS desktop runner (Xcode project)
analysis_options.yaml  # Lint configuration (package:flutter_lints)
pubspec.yaml       # Package metadata and dependencies
```

Application code lives under `lib/src/` and is exposed through `lib/main.dart`.
Tests mirror the `lib/` layout under `test/`.

## Platforms

Only the macOS runner is currently generated. Other platforms can be added
later from the project root without changing the Dart code:

```sh
flutter create --platforms=android,ios,windows,linux .
```

## Current limitations

- No API request editor, collections, environments, or networking yet.
- Only macOS is configured as a target platform.
- No CI pipeline has been set up.
- The license is provisional; see [License](#license).

## License

The [LICENSE](LICENSE) file contains a **provisional** MIT license that is
pending maintainer approval. It is not yet the project's final license.
