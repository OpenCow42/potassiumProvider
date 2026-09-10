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

Both shared app Test actions set `codeCoverageEnabled="NO"`. This repository
has no coverage-upload or reporting consumer, and explicitly disabling coverage
keeps coverage collection out of macOS Test actions. It does not disable any
test bundle or live-safety gate.

The unit suite is compile-time profile separated. `FinderStabilityCommandTests`
is compiled only for macOS `STABILITY`; ordinary-domain registration, reload,
error-path, and concurrent-add expectations are compiled only for the standard
profile. The Stability profile instead verifies that the ordinary `addDomain`
path fails closed without registration or persisted domain state. Neither
profile's Test action runs a live Finder scenario.

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
existing OAuth or manual-token Keychain login, load an internal non-maintenance drive reached by
that account, and let the lab create one unique folder inside the verified server-created
`Private` directory, plus a fixed-name ownership marker. The
stable root and marker file IDs are stored in the domain configuration; the
domain is registered only after that evidence is durable locally. A failed
registration leaves the ownership record in place and never auto-deletes the
remote folder.

Drive discovery proves internal membership, not product ownership. Lab-root
ownership is instead bound procedurally: this build creates a child of the verified `Private` directory and a random versioned marker, persists the exact root/marker
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

The macOS Stability app runs an opt-in native Accessibility/Apple Events suite.
The ordinary app bundle must be signed; test-host products with XCTest injection
are not valid live builds. The macOS Stability containing app runs outside App
Sandbox because Apple excludes assistive Accessibility APIs from sandboxed apps.
Hardened runtime remains enabled. The File Provider and action extensions remain
sandboxed, as do the standard app profiles. Accessibility, Automation, and screen
recording still require normal macOS consent.

```sh
# Build/reinstall after source changes at the stable LaunchServices location.
scripts/run-finder-stability.sh --build --preflight
# One-time creation, or safe registration resume for an existing owned lab.
scripts/run-finder-stability.sh --provision --yes-live
# Read-only authentication, ownership, domain, and permission checks.
scripts/run-finder-stability.sh --preflight --request-permissions
# Reuse the installed signed Stability bundle without compiling again.
scripts/run-finder-stability.sh --run --yes-live --request-permissions
scripts/run-finder-stability.sh --app "$HOME/Applications/Potassium Stability.app" --watch
scripts/run-finder-stability.sh --recover-stale-run --yes-recover
```

The wrapper launches the app through LaunchServices with a private local console
log, giving the standalone runner its own permission identity. Credentials remain
in the app's Keychain flow; OAuth refresh also stays inside the app. No credential,
account ID, remote URL, or root path is accepted as a runner argument. Exit 0 means
ready or fully passed (according to the chosen mode), 3 means an unresolved
checkpoint, 2 a safety rejection, and 1 failure or incomplete evidence.

The default install is `~/Applications/Potassium Stability.app`; `--build` is
explicit after the first install, refuses a running containing app, retains a
local backup, verifies signing, and registers the installed extensions. `--app`
selects an existing bundle without replacing it. A release copy in `/Applications`
can have the same bundle identifier with a different designated signing
requirement. Grant permissions to the installed Stability path, and compare
signing requirements/registrations when Settings shows an enabled grant that the
running app cannot use. Do not repeatedly compile or reset all privacy settings
as a substitute for identifying the registered app.

Every run creates a fresh owned subtree below the verified lab. The lab root,
ownership marker, and previous contents are preserved. The runner binds each
mutation target to its stable File Provider item and domain and re-fetches the
ancestry of generated sources and destinations. It owns one Finder window, resolves
fresh Accessibility state, and fails when a unique expected control is unavailable.
File creation uses Finder copy/paste; editing opens Finder's selection in TextEdit
and saves only the verified document.

The 16 scenarios cover navigation/change anchors, hydration, eviction, download,
file/directory creation, edit/upload, rename, move, trash, restore, permanent
selected-item deletion, concurrent preserve-both, cancellation/progress, actual
working-set membership, and contextual actions. Trash expects `modifyItem`;
permanent deletion expects `deleteItem`. Restore and deletion require an exactly
identified provider-managed trashed fixture. Deletion additionally pauses for
confirmation of that generated fixture, then rebinds it. Empty Trash is never used.
Unavailable UI or inaccessible trash identity is incomplete coverage, never a pass.

The Stability-only conflict barrier holds the exact local mutation after its real
version preflight while the runner performs a competing typed remote replacement.
Release sends the original real conditional request; no response is fabricated.
The barrier is cancellable and bounded. Cancellation uses a 64 MiB generated
transfer, retries with 256 MiB if necessary, and requires observed progress, actual
Finder cancellation, one cancellation terminal, and a subsequent successful fetch
for the same fixture. Contextual actions exercise favorite/unfavorite, duplicate,
inherited-access share-link create/update/disable, and version restore as a copy.

Ordinary scenario budgets are 90 seconds and transfer budgets 10 minutes. Operator
pauses retain the same monitored run and extend the active deadline only on resume.
The runner panel rechecks permissions and safety before continuing. Polling backs
off and observes retry-after values. Callback waits reject late/double completion.
After a scenario failure later scenarios are skipped and fixtures remain intact;
the runner closes its dedicated Finder window after capturing evidence, on both
success and failure. Cleanup addresses only the created window ID and verifies
Finder's kernel process start time, so relaunches and reused IDs cannot close an
unrelated window. Monitoring continues through closure and callback settlement.
Cleanup failures remain visible and prevent certification. Started work must
settle before final sealing.

Version 2 reports require UI observations, fresh remote verification, item-specific
spans, and the expected extension code hash/process identity. Missing starts,
telemetry, conflicting terminals, cached hydration, root-only working-set evidence,
and untriggered conflict/cancellation cannot certify a pass. Version 1 reports remain
readable as historical evidence. A successful acceptance requires all 16 scenarios
on both a fresh extension and an already running extension; unit tests and permission
checkpoints do not establish live acceptance. See `STABILITY_LOOP_AUDIT.md` for the
current completed evidence and outstanding live coverage.

Screenshots are cropped to generated selected Finder rows and retained locally in
`visual-evidence`, outside ordinary diagnostic exports. Closed failure reasons,
run-local aliases, a chronological diagnostic timeline, and immutable reports support
diagnosis. A writer-health failure latch prevents sealing after a recorder gap.
`--watch` reads active scenario/state, sanitized errors, cancellations, retries,
and lifecycle events. The Test action and
CI never invoke this live command. Stale-run recovery requires the recorded owner
to have exited, preserves an immutable abandonment record, and only releases the
local lease; it performs no remote mutation.

TextEdit editing uses native Select All, Paste, and Save menu-item actions,
without opening a menu-tracking loop or assuming a US physical keyboard layout.
The runner verifies the replacement text before Save, observes the close button's
edited flag clearing, then closes only the bound document. The local menu probe
and the subsequent real provider edit/upload scenario both passed; the full
16-scenario cold/warm acceptance remains open.
Permanent deletion requires absence from active-file, existence, and Trash API
checks; disappearance from Trash alone could mean restoration.

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

Run the isolated Stability unit suite on the same Mac destination:

```sh
xcodebuild test \
  -project potassiumProvider.xcodeproj \
  -scheme potassiumProvider-Stability \
  -configuration Stability \
  -destination 'platform=macOS,arch=arm64'
```

Do not add credentials to either command. Accept a run only when its
`.xcresult` summary reports `result: Passed`, zero failed tests, and zero
cancelled tests. The standard scheme includes its UI action; its completion is
separate from the ordinary and Stability unit-profile acceptance checks. See
[`STABILITY_LOOP_AUDIT.md`](STABILITY_LOOP_AUDIT.md) for the dated macOS result
bundle evidence and any current local-host limitation.

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
4. Create public, inherited-access, and password-protected links. Set and then
   clear an expiration, copy/share the URL, and disable the link. Inspect
   activity export and unified logs to ensure the URL, password, access value,
   and expiration never appear. An unknown returned access value must stop the
   action instead of being displayed as public.
5. Page a document's version history and restore a version as a collision-safe
   copy in its current parent. Confirm the current file is unchanged.
6. Exercise Show in Finder/Files and Sync Now for every configured drive.

## 0.3.0 Transfer Gates

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
4. Confirm a direct create or replacement at exactly `1_000_000_000` bytes is
   admitted by the pure request preflight, while one byte above is rejected
   before callback content loading or request construction with the
   session-required error. Automated coverage uses a sparse oversized file to
   exercise the pre-buffer boundary without allocating or sending a one-gigabyte
   payload. Use an official session-capable client for larger files until this
   provider has a file-backed session path.
5. With a sanitized mock response, confirm HTTP 408 and 429 map to File Provider
   `.serverUnreachable`, a numeric Retry-After value is parsed, and invalid or
   HTTP-date values are discarded without entering diagnostics.

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
