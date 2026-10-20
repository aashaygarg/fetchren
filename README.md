# FetchRen

FetchRen is an open-source, cross-platform API client built with Flutter.

> **Status:** Early development. The first vertical slice, a single-request
> API workbench with local saving, is implemented and covered by automated
> tests. It has not yet been built or run as a macOS app (see
> [Current limitations](#current-limitations)).

## Features

- Send `GET`, `POST`, `PUT`, `PATCH`, `DELETE`, `HEAD`, and `OPTIONS` requests.
- Edit multiple request headers, each of which can be enabled or disabled.
- Edit the request body for `POST`, `PUT`, `PATCH`, and `DELETE`.
- View the response status, elapsed time, size, headers, and body. JSON is
  pretty-printed, with a raw-text toggle and fallback.
- Configure the request timeout (default 30 s) and the maximum response size
  (default 10 MB) from the settings button in the toolbar.
- Save requests locally and reopen them after restarting the app.

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
  main.dart                 # Entry point: wires the HTTP client, storage, and UI
  src/
    app.dart                # Root MaterialApp
    models/                 # ApiRequest, HeaderEntry, HttpMethod (pure data)
    http/                   # Request building, execution, response formatting
    storage/                # Local JSON persistence of saved requests
    workbench/              # Controller (ChangeNotifier) and UI widgets
    util/                   # Display formatting helpers
test/                       # Mirrors lib/; support/ holds shared fakes
macos/                      # macOS desktop runner (Xcode project)
```

Request execution (`lib/src/http/`) and persistence (`lib/src/storage/`) have
no UI dependencies. The UI talks to them only through `WorkbenchController`,
which receives a `RequestExecutor` and a `RequestStore` by constructor
injection. Tests substitute a mock HTTP transport, a loopback test server, and
an in-memory store.

### Dependencies

| Package | Publisher | License | Purpose |
| --- | --- | --- | --- |
| [`http`](https://pub.dev/packages/http) | dart.dev | BSD-3-Clause | HTTP client and test transport (`MockClient`) |
| [`path_provider`](https://pub.dev/packages/path_provider) | flutter.dev | BSD-3-Clause | Locating the app support directory |

No state-management framework or database is used.

## Networking and security

- Requests go directly from the app to the target server. There is no
  FetchRen proxy or backend.
- Only `http` and `https` URLs are accepted. Other schemes, malformed URLs, and
  missing hosts are rejected before any network activity.
- TLS certificate verification uses the platform defaults and is never
  disabled.
- Header names must be valid HTTP tokens. Values containing line breaks or
  characters outside Latin-1 are rejected to prevent header injection.
- Request headers and bodies are never logged.
- Responses larger than the configured limit are aborted while streaming and
  discarded. The limit applies to the decompressed body.
  Timeouts abort the underlying connection.
- Redirects are **not followed**. A 3xx response is shown with its `Location`
  header. Automatic following is disabled because the platform HTTP client
  forwards custom credential headers such as `X-API-Key` to cross-origin
  redirect targets.
- Saved requests are treated as data only. Nothing in them is executed.
- The macOS app runs in the App Sandbox with the outgoing-network
  (`com.apple.security.network.client`) entitlement.

### Local storage

Saved requests are stored as JSON in `requests.json` inside the platform's
application support directory. On a sandboxed macOS build, that directory is
within `~/Library/Containers/<bundle id>/`. Each request has a random 128-bit ID
and UTC `createdAt`/`updatedAt` timestamps. If the file cannot be read, it is
renamed with a `.corrupt-<timestamp>` suffix rather than overwritten. If the
file exists but cannot be accessed, for example because of permissions, saving
is disabled for the session so the existing data is not overwritten.

Current storage security limitations:

- The file is **plain text and not encrypted**. It relies on operating-system
  user permissions only.
- Values of `Authorization`, `Proxy-Authorization`, `Cookie`, `Set-Cookie`,
  `X-API-Key`, `Api-Key`, and `X-Auth-Token` headers are **not saved**. Only
  the header names are kept, so these values must be re-entered after a
  restart. Within a session, they stay in memory.
- Secrets placed anywhere else, such as the URL (including its query string
  or `user:password@`), the request body, or headers not listed above, **are
  saved as entered**. The URL is also shown as the request name in the
  sidebar.

## Platforms

Only the macOS runner is currently generated. Other platforms can be added
later from the project root without changing the Dart code:

```sh
flutter create --platforms=android,ios,windows,linux .
```

## Current limitations

- **The macOS app has not been built or launched yet**, because full Xcode is
  not installed on the development machine. The request, storage, and UI
  layers are verified by unit, widget, and loopback-server tests only. The
  first `flutter build macos` may also update the Xcode project for plugin
  integration; review those changes before committing them.
- Only macOS is configured as a target platform. Web is not supported, because
  storage uses `dart:io`.
- There are no collections, environments, variables, authentication helpers,
  cookie management, request history, or import/export features yet.
- Saved request names are derived from the URL and cannot be edited.
- Timeout and response-size settings are not persisted between launches.
- The response body view shows at most the first 200,000 characters. JSON
  formatting runs on the UI thread.
- Redirects are not followed (see [Networking and security](#networking-and-security)).
- An in-flight request cannot be cancelled manually; it ends on completion,
  timeout, or size limit.
- No CI pipeline has been set up.
- The license and bundle identifier (`dev.fetchren.fetchren`) are provisional
  and pending maintainer approval.

## License

The [LICENSE](LICENSE) file contains a **provisional** MIT license that is
pending maintainer approval. It is not yet the project's final license.
