# Testing And Development

`potassiumProvider` is an Xcode project. The root project and scheme are the
source of truth.

## Scheme And Targets

- Project: `potassiumProvider.xcodeproj`
- Scheme: `potassiumProvider`
- App target: `potassiumProvider`
- File Provider extension target: `potassiumProviderFileProvider`
- Shared framework target: `PotassiumProviderCore`
- Unit test target: `potassiumProviderTests`
- UI test target: `potassiumProviderUITests`

Do not use Tuist or root-level SwiftPM commands for validation unless the
project is intentionally migrated.

## Dependencies

Swift package dependencies are resolved by Xcode:

- `potassiumChannel`
  - `PotassiumChannelCore`
  - `PotassiumKDrive`
  - `PotassiumOAuth`
- `SQLite.swift`
- `InfomaniakConcurrency`

The app imports split potassiumChannel modules directly. It should not import an
old monolithic `potassiumChannel` module name.

## Commands

List project information:

```sh
xcodebuild -list -project potassiumProvider.xcodeproj
```

Show destinations:

```sh
xcodebuild -showdestinations \
  -project potassiumProvider.xcodeproj \
  -scheme potassiumProvider
```

Build:

```sh
xcodebuild build \
  -project potassiumProvider.xcodeproj \
  -scheme potassiumProvider \
  -destination 'platform=iOS Simulator,OS=26.5,name=iPhone 17'
```

Build on Mac as well:

```sh
xcodebuild build \
  -project potassiumProvider.xcodeproj \
  -scheme potassiumProvider \
  -destination 'platform=macOS'
```

Run all tests:

```sh
xcodebuild test \
  -project potassiumProvider.xcodeproj \
  -scheme potassiumProvider \
  -destination 'platform=iOS Simulator,OS=26.5,name=iPhone 17'
```

Run all tests on Mac as well:

```sh
xcodebuild test \
  -project potassiumProvider.xcodeproj \
  -scheme potassiumProvider \
  -destination 'platform=macOS'
```

Run only unit tests:

```sh
xcodebuild test \
  -project potassiumProvider.xcodeproj \
  -scheme potassiumProvider \
  -destination 'platform=iOS Simulator,OS=26.5,name=iPhone 17' \
  -only-testing:potassiumProviderTests
```

If the full scheme stalls during simulator/UI-test cleanup, retry with:

```sh
xcodebuild test \
  -project potassiumProvider.xcodeproj \
  -scheme potassiumProvider \
  -destination 'platform=iOS Simulator,OS=26.5,name=iPhone 17' \
  -parallel-testing-enabled NO
```

Use `xcodebuild -showdestinations` to copy the exact Mac destination if local
Xcode requires a more specific macOS variant.

## Test Style

- New unit tests should use Swift Testing (`import Testing`).
- UI automation uses XCTest.
- Existing URLProtocol-based tests use shared capture helpers, so the unit suite
  is serialized.
- Live network checks should not be part of the default test path.

## Local State Caveats

- App group availability depends on entitlements and signing.
- Keychain access group behavior depends on provisioning.
- The local Apple sample folder is a reference tree and should not be treated as
  part of the root project.
- Build products, DerivedData, local caches, `.DS_Store`, and private fixtures
  should not be committed.

## Documentation Checks

For docs-only changes, run:

```sh
git diff --check
```

Also verify that links from the root `README.md` point to existing files.
