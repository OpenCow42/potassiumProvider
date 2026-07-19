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
- Keychain access group behavior depends on provisioning. Multi-account tests
  should prefer `InMemoryOAuthTokenStore` and synthetic local account IDs unless
  they are explicitly validating keychain behavior.
- The local Apple sample folder is a reference tree and should not be treated as
  part of the root project.
- Build products, DerivedData, local caches, `.DS_Store`, and private fixtures
  should not be committed.
- Desktop & Documents known-folder testing requires macOS 15 or later and a test
  drive with an existing root-level directory named `Private`.
- External File Provider storage testing requires macOS 15 or later and a
  disposable, local, encrypted APFS volume. A disk image is useful for some
  eligibility and interruption checks, but it does not replace disconnecting and
  reconnecting a physical drive.

Manually verify that Apple presents consent, both folders appear under
`Private`, changes synchronize in both directions, live state survives relaunch
and external domain changes, stopping sync releases both folders, and domain
removal or logout cannot continue after a release failure.

## External Storage Validation

Unit tests use injected File Provider and volume services to cover exact prepared
domain identity, generated identifiers, opaque binding validation, eligibility
reason mapping, folder-to-volume normalization, balanced security-scoped access,
journal phases/recovery, cleanup identifiers, status aggregation, and stable UI
identity. Those tests cannot prove Apple's on-disk placement, unplug behavior,
consent UI, preserved-data handling, or another Mac's connection decision.

Run the following physical matrix on macOS 15 or later with disposable kDrive
test data. Start with `scripts/uninstall-file-provider.sh --dry-run`, and record
the selected volume UUID and the current generated domain ID without recording
account or credential data.

1. Add the same test kDrive On This Mac, remove it, then add it to an encrypted
   APFS external drive. Select a nested folder in the picker and confirm the UI
   reports the containing volume—not the folder—as storage. Confirm Finder shows
   the domain and materialization is physically backed by that volume.
2. Try representative ineligible targets: unencrypted APFS, non-APFS, read-only,
   and network storage. When practical also verify quarantined/unknown results.
   Confirm the sheet reports Apple's specific reason and registration remains
   disabled. Use
   [`checkDomainsCanBeStoredOnVolume(at:)`](https://developer.apple.com/documentation/fileprovider/nsfileprovidermanager/checkdomainscanbestoredonvolume(at:))
   as the eligibility source of truth.
3. Relaunch with the external drive attached. Confirm the generated domain ID,
   persisted volume UUID, Status card identity, and kDrive configuration remain
   associated through the stable configuration ID. Confirm no token, account ID,
   or private URL appears in external-domain `userInfo`.
4. Eject the drive while idle, then during a disposable download/upload. Confirm
   the domain becomes unavailable without losing configuration, Status shows an
   actionable disconnected warning, and Setup disables unsafe Remove from Files.
   Confirm account logout is blocked before token deletion. Reattach the same
   UUID and use Repair if required; verify synchronization resumes.
5. Move On This Mac → external → On This Mac. Confirm the source stabilizes,
   offline files can be downloaded again, generated domain IDs change as expected,
   stable configuration/UI identity does not, and any preserved dirty-data URL is
   shown with Reveal in Finder rather than deleted automatically.
6. Interrupt a move after known-folder release, source removal, target save, and
   target registration in separate runs. Relaunch and confirm the journal yields
   Needs Repair, Repair completes or safely restores the source, and stale old
   domain-keyed SQLite rows are removed only after the authoritative placement is
   known.
7. With Desktop & Documents active, repeat both move directions. Confirm both
   folders are released together before removal, reclaimed together afterward,
   renewed Apple consent is handled, and a failed reclaim remains a repairable
   state without rolling back a successfully registered target.
8. Attach the volume to a different Mac or clean test user that lacks this app's
   matching app-group configuration and keychain token. Confirm external-domain
   connection is rejected; the opaque stable binding alone must not authorize
   access.
9. Run cleanup dry-run during normal external placement and again with an
   interrupted relocation journal. Confirm the plan includes actual registered
   IDs, the configuration's current generated domain ID, journal source/target
   IDs, and stable configuration IDs. Plain `--yes` must preserve dirty data and
   report any returned location; reserve `--hard-purge` for deliberately
   destructive local recovery.

Also keep iOS Simulator and visionOS builds in the regression matrix. They must
continue to use On This Mac behavior and must not expose the macOS-only external
storage UI or APIs.

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

## 0.2.0 Manual Release Gates

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
