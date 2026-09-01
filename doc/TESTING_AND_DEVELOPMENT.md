# Testing And Development

`potassiumProvider` is an Xcode project. The root project and scheme are the
source of truth.

## Scheme And Targets

- Project: `potassiumProvider.xcodeproj`
- Scheme: `potassiumProvider`
- Stability schemes: `potassiumProvider-Stability` and
  `potassiumProviderFileProvider-Stability`
- App target: `potassiumProvider`
- File Provider extension target: `potassiumProviderFileProvider`
- File Provider UI extension target: `potassiumProviderActions`
- Shared framework target: `PotassiumProviderCore`
- Unit test target: `potassiumProviderTests`
- UI test target: `potassiumProviderUITests`

The existing `potassiumProvider` scheme includes both unit and UI test bundles.
The `potassiumProvider-Stability` Test action intentionally includes only the
unit test bundle so a diagnostic-store test never drives Finder or consumes a
live credential. The File Provider Stability scheme has no Test action because
the unit target imports the shared core, not the extension executable.

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

The project requires potassiumChannel 0.3.0. `Package.resolved` is locked to
tag `0.3.0` at commit
`db829f1f2bd8c2113a529c9c521bd5cdfb5ef4dc`. Changing that pin requires the
adapter evidence matrix and full validation matrix to be rerun.

## Stability Profile

The `Stability` configuration is an opt-in debug-shaped build profile. It uses
the production app identity, app group, entitlements, and manual-token Keychain
flow, while adding the `STABILITY` Swift compilation condition. It never reads
credentials from scheme arguments, environment variables, scripts, or test
fixtures. The Debug-only UI fixture and all existing unified loggers are
compiled out/disabled in this profile. Live checks stay outside CI.

List and inspect it with:

```sh
xcodebuild -list -project potassiumProvider.xcodeproj
xcodebuild -showBuildSettings \
  -project potassiumProvider.xcodeproj \
  -scheme potassiumProvider-Stability \
  -configuration Stability \
  -destination 'platform=macOS'
```

Run only the profile/JSONL unit slice on macOS:

```sh
xcodebuild test \
  -project potassiumProvider.xcodeproj \
  -scheme potassiumProvider-Stability \
  -destination 'platform=macOS,arch=arm64' \
  -only-testing:potassiumProviderTests/StabilityDiagnosticsTests
```

An active run must be created by the Stability Lab tab or command before production
runtime processes append JSONL. The factory deliberately returns no event
store when no run exists. Ordinary Debug and Release builds keep SQLite
activity/conflict history. `Snapshots.sqlite3` remains the store for snapshots,
anchors, and working-set state in every profile.

`StabilityDiagnosticsTests` covers run-manifest/pointer selection, concurrent
coordinators, a real subprocess writer, two in-process writers, interrupted
tail recovery, complete-line corruption, capacity refusal, symlink rejection,
post-finish append refusal, retention, redaction, paging/filtering, statistics,
cross-store observation, tombstone clear/domain removal, export, and factory
selection. Its subprocess check uses Xcode's bundled Python executable only to
act as an independent POSIX-locking process; production code has no Python or
script dependency.

Run the callback/network and Lab safety slices without live credentials:

```sh
xcodebuild test \
  -project potassiumProvider.xcodeproj \
  -scheme potassiumProvider-Stability \
  -destination 'platform=macOS,arch=arm64' \
  -only-testing:potassiumProviderTests/ProviderDiagnosticSpanTests \
  -only-testing:potassiumProviderTests/FileProviderOperationLifecycleTests \
  -only-testing:potassiumProviderTests/StabilityLabSafetyTests \
  -only-testing:potassiumProviderTests/StabilityLabRemoteCoordinatorTests
```

The exact network-outcome checks use Swift Testing identifiers including their
parentheses:

```sh
xcodebuild test-without-building \
  -project potassiumProvider.xcodeproj \
  -scheme potassiumProvider-Stability \
  -destination 'platform=macOS' \
  '-only-testing:potassiumProviderTests/PotassiumProviderCoreTests/kdriveServiceExposesLazyObservableDownloadOperation()' \
  '-only-testing:potassiumProviderTests/PotassiumProviderCoreTests/missingShareLinkIsRecordedAsSuccessfulOptionalResult()' \
  '-only-testing:potassiumProviderTests/PotassiumProviderCoreTests/concurrentLazyTransferStartAndCancelShareOneDiagnosticSpan()'
```

These tests use only in-memory recorders, fake kDrive services, and pure root observations. They do
not read Keychain credentials, register a File Provider domain, or mutate a
remote account. The hosted macOS test bundle must be signed on machines where
the unsigned XCTest worker cannot materialize.

### Stability Lab safety workflow

The macOS Stability build exposes a dedicated Stability Lab tab. Provisioning
is enabled only when no saved or system-registered File Provider domain is
present. Connect the dedicated non-customer development account through the
existing manual-token UI, load an internal non-maintenance drive reached by
that account, and let the
lab create one unique top-level folder plus a fixed-name ownership marker. The
stable root and marker file IDs are stored in the domain configuration; the
domain is registered only after that evidence is durable locally. A failed
registration leaves the ownership record in place and never auto-deletes the
remote folder.

Drive discovery proves internal membership, not product ownership. Lab-root
ownership is instead bound procedurally: this build creates the direct
drive-root child and a random versioned marker, persists the exact root/marker
IDs locally, and requires those remote objects and marker bytes to match on
every preflight.

Before using a shared-identity Stability build, inspect ordinary domains with:

```sh
scripts/uninstall-file-provider.sh --dry-run
```

If the plan is correct, use the explicit safe cleanup path:

```sh
scripts/uninstall-file-provider.sh --yes
```

The app, File Provider extension, and contextual-action runtime all reject a
saved domain whose purpose does not match the current build profile. The lab
never invokes `--hard-purge`. Reset requires the exact phrase
`DELETE STABILITY LAB CONTENTS`. It fully consumes the root listing, preserves
the root and marker, and immediately re-fetches the root, marker, and each
planned child's current parent before calling the reversible trash endpoint.
It also re-queries system registration isolation immediately before each
mutation. It never calls permanent deletion. A cross-process lifecycle lease
prevents a diagnostics run from starting during reset and rejects reset while a
run is active. Live provisioning/reset is opt-in and was not executed by the
automated test suite.

### Finder Stability runner

The macOS Stability app has a command mode and a wrapper script. Preflight is
read-only: it loads exactly one compatible lab domain, reads the existing
manual-token Keychain entry, re-verifies the remote root and marker, checks the
system File Provider registration and visible-domain consent, and inspects
Accessibility and Finder Automation permission state.
Only the macOS Stability configuration carries the hardened-runtime Automation
entitlement and the sandbox's Finder-scoped Apple Events exception; ordinary
Debug/Release builds retain their existing entitlements.

```sh
scripts/run-finder-stability.sh --preflight
scripts/run-finder-stability.sh --preflight --request-permissions
scripts/run-finder-stability.sh --recover-stale-run --yes-recover
```

Exit `0` means ready, `3` is an operator checkpoint for macOS consent or
variable Finder UI, `2` is a safety rejection, and `1` is a failed run. No
credential, account ID, root path, or private URL is accepted as an argument,
environment variable, script fixture, or scheme setting.

Only an operator with an explicitly provisioned development account and the
verified disposable non-root lab may run the mutation sequence:

```sh
scripts/run-finder-stability.sh --run --yes-live
```

The 16 ordered scenarios cover enumeration/change anchors, hydrate, evict,
download, file/directory creation, edit/upload, rename, move, trash, restore,
permanent deletion, concurrent preserve-both behavior, cancellation/progress,
working-set refresh, and supported contextual actions. Stable operations use
the File Provider-visible root while Finder is opened and raised through
Accessibility. Restore and permanent deletion keep the verified lab root
selected and stop without opening the user-global Trash or directing any
destructive action. Transfer cancellation stops with an exact evicted item
selected in Finder without starting a download, and contextual actions stop at
the selected Finder item. These are typed operator
checkpoints because the localized/OS-owned UI has no stable automation contract;
the runner never starts a transfer that could outlive the sealed report,
substitutes a direct remote request, or uses domain-global progress and calls it
Finder evidence. Before every
scenario, the runner freshly rechecks the sole saved/system domain plus the
remote root and marker; drift stops the sequence before that step's mutation.
Immediately before overwriting, renaming, moving, recycling, or evicting an
existing visible item, it also resolves the URL and requires the expected File
Provider item identifier and configured domain. Move binds its destination
directory too, and eviction reuses the same validated identifier instead of
resolving again. Before every scenario, the cached lab-root URL must also
re-resolve as File Provider's root-container identifier in the configured lab
domain. Item/domain or root-mount drift therefore fails before the local
mutation.
OS-owned consent and variable Finder UI are checkpoints, not false product
failures. A checkpoint terminates that step but independent later scenarios
remain eligible; a failed step skips all later scenarios. Every
passing step requires both Finder-visible and freshly fetched
server-authoritative evidence plus a correlated successful terminal diagnostic
for the scenario's expected File Provider callback or typed network operation.
Enumeration requires both item-enumeration and anchor/change terminal evidence,
and persisted checkpoint reasons must match the scenario that owns them.
The working-set step must contain a known same-run item; preserve-both must
resolve two distinct same-step server candidates as Finder-visible items. The
immutable report, assertion JSONL, and API
observation JSONL contain only closed enums, correlation IDs, timestamps,
booleans, and bucketed counts. A runner-owned active run cannot be reused or
sealed by another coordinator, and each step publishes a private cross-process
correlation pointer until its terminal result. The report is the evidence
commit marker; final sealing also verifies the summary's assertion, failure,
and checkpoint totals against that immutable report. An assembly failure leaves an unsealed active bundle for
explicit inspection rather than producing a misleading completed summary. The
runner retains its private owner marker after failure. If the process exits,
`--recover-stale-run --yes-recover` verifies that PID is gone, writes an
immutable abandonment marker, clears any stale step pointer, and releases only
the local active-run lease. It performs no Finder or remote mutation, and an
abandoned bundle can never be ordinarily finalized.

The Stability scheme never runs this command or its live scenarios from the
Test action or CI. Unit coverage validates the report model, evidence writer,
argument safety, owned-run exclusion, stale-owner abandonment, partial-write
recovery, step correlation, required diagnostic terminals, and checkpoint
classification using no Keychain credential,
File Provider registration, Finder action, or network mutation.

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
randomized DAG replay, cyclic-move rejection, trash provenance, collision-name
allocation, Merkle/rollback, padded-checkpoint, streaming cancellation,
fresh-revision restore, activation-warning, recovery, and request-leakage tests
before enabling the development flag. Capture all mocked requests and reject
known logical names, paths, types, dates, hashes, device names, or plaintext
bytes. Benchmark 100,000 items, 10,000 siblings, and multi-gigabyte files. Safe
migration/rekey design and independent review with all high-severity findings
resolved are required before default enablement.
