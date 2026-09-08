# Contributing to Origami

Origami is an early-stage native Mac browser. Bug reports, feature discussions, and focused pull requests are welcome.

## Issues and pull requests

Search [existing issues](https://github.com/T-1234567890/origami-browser/issues) before opening a duplicate. For bugs, include the macOS version, build or commit, reproducible steps, and expected versus actual behavior. Use synthetic examples and remove private information from screenshots and logs.

Keep pull requests focused and reasonably small. Explain behavioral or UI changes clearly, include tests where appropriate, and describe what you tested and any remaining limitations. Discuss substantial changes in an issue before investing in a large implementation.

## Project conventions

- Follow the existing Swift style and nearby project conventions.
- Preserve the native SwiftUI/AppKit and WebKit architecture.
- Avoid dependencies that are unnecessary for the change.
- Respect profile isolation, Private Browsing, optional AI, and the no-first-party-telemetry principle.
- Never include API keys, secrets, personal browsing data, local machine configuration, or proprietary assets you do not have permission to contribute.
- Preserve third-party license notices. Contributions to Origami's original code are under MPL-2.0.

## Build and test

See [README.md](README.md) for requirements and setup. Build before submitting:

```sh
xcodebuild -project Origami.xcodeproj -scheme Origami \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath build CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= build
```

Run the unit and integration tests:

```sh
xcodebuild -project Origami.xcodeproj -scheme Origami \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath build CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= test
```

The separate UI suite launches the app and interacts with the desktop:

```sh
xcodebuild -project Origami.xcodeproj -scheme Origami-UI \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath build CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= test
```

The latest local verification passed 187 unit/integration tests, but the two existing UI tests failed on settings-menu and omnibox lookup checks. Report failures honestly; do not treat these commands as a promise of a green suite or weaken tests to hide a failure. UI changes should also receive a manual appearance and accessibility check.

Before submitting, inspect `git status` and your diff. Keep generated build output, test results, and local data out of the change.

## Security reports

Do not report vulnerabilities through public issues or pull requests. Follow [SECURITY.md](SECURITY.md) for private reporting guidance and sanitized reproduction information.
