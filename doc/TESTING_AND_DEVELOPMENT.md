# Testing And Development

`potassiumProvider` is an Xcode project. The root project and scheme are the
source of truth.

## Scheme And Targets

- Project: `potassiumProvider.xcodeproj`
- Scheme: `potassiumProvider`
- App target: `potassiumProvider`
- File Provider extension target: `potassiumProviderFileProvider`
- File Provider UI extension target: `potassiumProviderActions`
- Shared framework target: `PotassiumProviderCore`
- Unit test target: `potassiumProviderTests`
- UI test target: `potassiumProviderUITests`

The shared `potassiumProvider` scheme runs `potassiumProviderTests` in its Test
action. UI automation remains a separate Xcode test-target workflow and is not
part of the shared scheme's command-line test path.

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

The project requires the published potassiumChannel 0.2 release line.
`Package.resolved` must stay locked to the validated 0.2.0 release unless a
later compatible package version is adopted and the full validation matrix is
rerun.

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

Run unit tests:

```sh
xcodebuild test \
  -project potassiumProvider.xcodeproj \
  -scheme potassiumProvider \
  -destination 'platform=iOS Simulator,OS=26.5,name=iPhone 17'
```

Run unit tests on Mac as well:

```sh
xcodebuild test \
  -project potassiumProvider.xcodeproj \
  -scheme potassiumProvider \
  -destination 'platform=macOS'
```

Use `xcodebuild -showdestinations` to copy the exact Mac destination if local
Xcode requires a more specific macOS variant.

## Continuous Integration

GitHub Actions runs an unsigned macOS build followed by the macOS unit tests for
every pull request and every push to `main`. The job uses the `macos-26` runner
and its default Xcode 26.5 installation:

```sh
xcodebuild build \
  -project potassiumProvider.xcodeproj \
  -scheme potassiumProvider \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO

xcodebuild test \
  -project potassiumProvider.xcodeproj \
  -scheme potassiumProvider \
  -destination 'platform=macOS' \
  MACOSX_DEPLOYMENT_TARGET=26.4 \
  CODE_SIGNING_ALLOWED=NO
```

The build and test commands run as consecutive steps in the same job and share
the resolved package checkout and DerivedData directory. The CI-only
deployment-target override allows the tests to run on the hosted runner's
macOS 26.4 installation without changing the project's macOS 26.5 deployment
target. UI tests, caching, iOS Simulator and visionOS jobs, and the manual File
Provider release gates remain outside its scope.

## Test Style

- New unit tests should use Swift Testing (`import Testing`).
- UI automation uses XCTest.
- Existing URLProtocol-based tests use shared capture helpers, so the unit suite
  is serialized.
- Live network checks should not be part of the default test path.

## Local State Caveats

- App group availability depends on entitlements and signing.
- Keychain access group behavior depends on provisioning. Multi-account tests
  should prefer `InMemoryOAuthTokenStore` and synthetic local account IDs unless
  they are explicitly validating keychain behavior.
- The local Apple sample folder is a reference tree and should not be treated as
  part of the root project.
- Build products, DerivedData, local caches, `.DS_Store`, and private fixtures
  should not be committed.
- Desktop & Documents known-folder testing requires macOS 15 or later and a test
  drive with an existing root-level directory named `Private`.

Manually verify that Apple presents consent, both folders appear under
`Private`, changes synchronize in both directions, live state survives relaunch
and external domain changes, stopping sync releases both folders, and domain
removal or logout cannot continue after a release failure.

## File Provider Dev Uninstall

Use the dev uninstall wrapper to remove this app's registered File Provider
domains and provider-local state without touching remote kDrive files:

```sh
scripts/uninstall-file-provider.sh --dry-run
scripts/uninstall-file-provider.sh --yes
```

The default mode preserves dirty user data and keeps saved account records and
account-scoped OAuth tokens. See
[File Provider Cleanup](FILE_PROVIDER_CLEANUP.md) for the full mode matrix,
stale archived app registration repair, and safety boundary.

## Documentation Checks

For docs-only changes, run:

```sh
git diff --check
```

Also verify that links from the root `README.md` point to existing files.

## 0.3.0 Manual Action Gates

Use a development account without customer data. On macOS Finder, iOS Files,
and visionOS Files:

1. Verify favorite/unfavorite, duplicate, and restore actions appear only for
   valid single-item states and their results appear without relaunching.
2. Verify trashed items cannot be renamed or trashed again, can be restored,
   and can still be permanently deleted.
3. Verify Download Now and Remove Download are system-provided for normal files
   and folders.
4. Create public and password-protected links, update options, copy/share the
   URL, and disable the link. Inspect activity export and unified logs to ensure
   the URL and password never appear.
5. Page a document's version history and restore a version as a collision-safe
   copy in its current parent. Confirm the current file is unchanged.
6. Exercise Show in Finder/Files and Sync Now for every configured drive.

## 0.2.0 Transfer Gates

Run these checks on macOS with a development File Provider domain and a test
kDrive account. Do not use customer data.

1. Upload and download a file large enough for Finder to display sustained
   progress. Confirm the operation direction is correct, the byte count moves
   monotonically, success clears the indicator, and cancelling from Finder
   stops network activity without a later success callback or duplicate error.
2. Record the File Provider extension's peak resident memory for one large
   transfer, then request two large transfers together. Confirm the second waits
   for the shared one-permit content limiter and the concurrent peak stays at or
   below 125% of the single-transfer baseline.
3. Repeat cancellation while the second transfer is waiting. Confirm it never
   starts and the next transfer can acquire the released permit.

Automated `AsyncOperationLimiter` tests cover the concurrency cap, cancellation
while waiting, and permit release after errors. These manual checks cover the
Finder presentation and process RSS behavior that unit tests cannot establish.

## Encrypted vault gates

Run cryptographic known-answer, envelope/frame tamper, fixed transaction,
randomized DAG replay, Merkle/rollback, streaming cancellation, migration
interruption, recovery, and request-leakage tests before enabling the
development flag. Capture all mocked requests and reject known logical names,
paths, types, dates, hashes, device names, or plaintext bytes. Benchmark 100,000
items, 10,000 siblings, and multi-gigabyte files. Independent review with all
high-severity findings resolved is required before default enablement.
