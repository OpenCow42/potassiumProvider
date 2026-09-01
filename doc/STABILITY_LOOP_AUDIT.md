# Stability Loop Implementation And Evidence Ledger

This file is the auditable implementation ledger for
[`STABILITY_LOOP_PLAN.md`](STABILITY_LOOP_PLAN.md). It contains no live account
data, private identifiers, URLs containing identifiers, request/response
bodies, or credentials. Live-result cells remain `not run` until an operator
explicitly supplies a development account and lab-owned non-root folder.

## Evidence Revisions

| Source | Pinned revision | Role |
| --- | --- | --- |
| potassiumChannel | tag `0.3.0`, commit `db829f1f2bd8c2113a529c9c521bd5cdfb5ef4dc` | Typed request/service behavior used by this project |
| Infomaniak public API documentation | accessed 2026-08-31; page-data version `f77cce2c8a7919ddbfd690c32bd0a019`; navigation snapshot SHA-256 `b831cb542fedc9f06f2b1e28f98c1ec86a6d9a98ef00d20b2c3de95dac0d178d` | Published route and field contract; no public source revision is exposed |
| Infomaniak iOS | `90c2e2560630b075b77b9e87b46b44d385a05283` | Behavioral comparison only; GPL code is not copied |
| Infomaniak Android | `25e07993e87e8ae50f7c73aeaf4c6802eef1d434`; Core submodule `7037dab1428b8eb23021db74f5881c4a39fdba83` | Behavioral comparison only; GPL code is not copied |
| Infomaniak desktop | `f72372661e79744c243fd4963465aaae92a6eba7` | Behavioral comparison only; GPL code is not copied |

## Ordered Milestones

| Milestone | Implementation state | Focused validation | Adversarial review | Commit |
| --- | --- | --- | --- | --- |
| Stability build profile and JSONL event store | implemented; reviewer fixes applied | 13 macOS `StabilityDiagnosticsTests` passed 2026-08-31 | all actionable findings fixed | `2fd9fbb` |
| Callback and network instrumentation | implemented; final reviewer repairs applied | signed `build-for-testing` passed; 27/27 focused executions passed | final bounded pass: no remaining finding | `c348d0c` |
| Stability Lab and safe root lifecycle | implemented; reviewer fixes applied | Stability graph built; 47/47 focused executions passed | final pass: no remaining actionable defect | `871c04d` |
| Finder Accessibility runner and checkpoints | implemented; reviewer repairs applied | current signed Stability test graph built with Finder-only entitlements; all 33 focused cases reported passed in both scheme executions; standard macOS, iOS Simulator, and generic visionOS app graphs built | all actionable findings fixed | `347b2a3` |
| API evidence matrix and adapter corrections | implemented; reviewer repairs applied | signed Stability graph built; final eight-case API slice reported 16/16 passes; Xcode then hung only in result-log/coverage finalization | final bounded pass: no remaining blocker | `c61cf6e` |
| Cross-platform completion validation | complete; no live checks run | macOS, iPhone 17 iOS 26.5 Simulator, Apple Vision Pro visionOS 26.5 Simulator test graphs built; generic visionOS built; each full unit-test execution emitted only passes before Xcode's post-test finalization hang | final evidence pass: no remaining finding | `5acee67` |

## Architecture Integration Checklist

- Event-store construction sites: app model, File Provider runtime (including
  fallback load), contextual-action runtime, and app-group uninstall cleanup.
- Snapshot SQLite table creation no longer creates activity/conflict tables.
  Snapshots, anchors, enumerator state, and working-set state remain SQLite.
- `Stability` exists on the project and all six targets with `STABILITY`,
  testability, and unoptimized Swift. The two shared Stability schemes contain
  no credential arguments or environment variables.
- The unit-test target cannot import the File Provider extension executable.
  Callback behavior must therefore be implemented in or extracted to the
  shared core and invoked by the extension entry points.
- Runtime callback coverage must include extension initialization/invalidation,
  materialization checks, item lookup, content fetch, create/modify/delete,
  enumerator creation/invalidation, item/anchor/change enumeration, working-set
  refresh, known-folder work, thumbnails, and contextual actions.
- Risks still open for later milestones: permission/checkpoint behavior, safe
  remote-root ownership proof, and ensuring docs/truth-table evidence stays synchronized.
  Callback exactly-once semantics and transfer cancellation now share the
  actor-isolated diagnostic lifecycle and have focused race coverage.
  Active-run, append/read/finish, and retention transitions now share a
  cross-process lifecycle lock and crash-durable file transitions.

## Milestone 1 Decision Records

| Decision | Evidence | Live result | Chosen behavior | Tests | Truth-table impact |
| --- | --- | --- | --- | --- | --- |
| Build/profile isolation | Project target/scheme map at `efd5925`; plan requirements | not applicable | Reuse production IDs/groups/entitlements; define `STABILITY` in a distinct configuration and omit UI automation from its unit Test action | build-settings inspection; `StabilityDiagnosticsTests` | none; no mutation behavior changed |
| Event-store selection | Four production construction sites and existing event protocols | not applicable | Standard uses SQLite; Stability uses only the active run's JSONL and never silently falls back | factory-selection test | cleanup implementation reviewed; mutation/conflict decisions unchanged |
| SQLite boundary | `KDriveSnapshotSQLiteStore.createTables` previously called event-table creation | not applicable | Snapshot/anchor/working-set SQLite remains; activity/conflict tables are independent and JSONL-only in Stability | factory test asserts both JSONL and SQLite exist | none |
| Private-data boundary | `AGENTS.md`, plan invariants, existing support-export model | not applicable | Redact before encoding; closed-enum diagnostic schema; no names, paths, item/request/account/drive identifiers, raw URLs/bodies/headers/data/share links | raw-byte private-value test; enum-only encoding test | conflict event fields are redacted, decision state preserved |
| JSONL durability | Plan requirement for app/extension/actions concurrent writers | not applicable | lifecycle plus event-file locks, complete-record append, `fsync`; ignore and truncate only an unterminated tail; corruption otherwise surfaces; reject before the 250 MiB active-event limit | real subprocess and two-store writers; concurrent coordinators; interrupted-tail, corruption, capacity, post-finish, and symlink tests | unresolved conflict records replay unchanged except private fields |
| Clear/removal and retention | Existing event-store semantics and safe cleanup rules | not applicable | append tombstones; preserve unresolved conflicts; prune only whole completed bundles, never active/incomplete | replay and completed-only retention tests | conflict cleanup semantics unchanged |

## Milestone 2 Decision Records

| Decision | Evidence | Live result | Chosen behavior | Tests | Truth-table impact |
| --- | --- | --- | --- | --- | --- |
| Callback lifecycle | Apple replicated File Provider callback/cancellation contract; existing `FileProviderOperationLifecycle` | not run | start once; first completion/failure/cancellation wins; attempt the terminal append before invoking File Provider completion so run finalization cannot lose it | span terminal-race and lifecycle failure/cancellation tests | observes existing mutation outcomes; no decision changes |
| Correlation | plan privacy boundary and structured-concurrency task inheritance | not applicable | propagate only a random callback UUID through `TaskLocal`; give each nested span a separate stable UUID so concurrent child operations can be paired | nested-correlation and span-identity tests | no mutation/conflict change |
| Typed request evidence | potassiumChannel `0.3.0` service calls and the route map | not run | record only enum operation, route template, option shape, phase, duration, and class; never raw request data | drive-discovery request/diagnostic test; schema/redaction tests | no request behavior change |
| Transfer cancellation | potassiumChannel progress/cancel operation and File Provider progress contract | not run | start lazily when consumed or cancelled; forward progress by deduplicated buckets; race cancel and value completion through one terminal gate | lazy transfer, progress, forwarding, and terminal-race tests | retries and conflict policies unchanged |
| HTTP and callback diagnostic class | API rejection classifier plus `NSFileProviderError.Code`, without retaining body/header/user-info metadata | not run | map closed HTTP and File Provider recovery classes; cancellation records `cancelled`; expected share-link 404 is a successful optional result | closed classifier tests including 429/507 and File Provider recovery cases; optional-404 adapter test | Milestone 5 maps 408/429 and oversized direct uploads to recoverable File Provider errors; diagnostic payloads remain closed |
| Active-run binding | JSONL writers reject sealed runs and a Stability run may start after a long-lived app/extension object | not applicable | resolve the active recorder at callback or service-construction time; never cache a missing or sealed run writer for the object lifetime | factory/run lifecycle tests plus reviewer inspection | no mutation/conflict change |

## Review And Validation Log

### 2026-08-31 — Milestone 1 review and repair

- `xcodebuild -list -project potassiumProvider.xcodeproj`: configuration and
  scheme discovery succeeded.
- `xcodebuild -showBuildSettings ... -configuration Stability`: confirmed
  `STABILITY`, production identity, app group, and entitlements.
- `xcodebuild test -quiet -project potassiumProvider.xcodeproj -scheme
  potassiumProvider-Stability -destination 'platform=macOS,arch=arm64'
  -only-testing:potassiumProviderTests/StabilityDiagnosticsTests`: thirteen
  focused tests passed after the adversarial findings were repaired. An earlier
  unsigned attempt could build but could not materialize the hosted macOS test
  worker; signed local execution succeeded.
- Adversarial findings fixed: compiled out the environment UI fixture, disabled
  legacy unified logs, added lifecycle locking and post-finish refusal,
  truncated interrupted tails, added owner-only/no-symlink/crash-sync file
  handling, bounded the active event file, matched zero-limit/tombstone/paging/
  statistics/observation/export behavior, and added a real child-process writer
  test. Two bounded final-scan turns were interrupted after the reviewer agent
  did not return; the earlier review's complete actionable list is resolved and
  the focused suite/privacy scan were rerun afterward.
- No live network or remote mutation was performed.

### 2026-08-31 — Milestone 2 review and repair

- Signed macOS `build-for-testing` passed for the Stability scheme, including
  Core, app, both extensions, and the unit bundle.
- The final credential-free `test-without-building` command exited normally
  with 27/27 selected executions successful: all diagnostic-span and operation-
  lifecycle tests across the Stability test-plan variants, plus exact lazy
  transfer, optional share-link, and concurrent transfer-start/cancel adapter
  tests. No live or default hosted suite was selected. Earlier focused runs
  encountered a local `DTServiceHub` logarchive-finalization hang after their
  result streams had completed; signing the refreshed hosted bundle allowed the
  final run and result bundle to close normally.
- Reviewer repairs rechecked lifecycle state after a suspended start append,
  moved terminal append attempts ahead of system callbacks, added stable span
  IDs, deduplicated progress buckets, instrumented transfer progress, classified
  File Provider recovery errors, rebound long-lived objects per active run,
  acknowledged materialization promptly after its callback span and kept the
  background work in correlated child spans, covered every SDK changed-field
  shape, separated enumerator lifecycle operations, and corrected cancellation,
  lazy-transfer, and expected-404 outcomes. The final pass also found and fixed
  the deferred-span reentrancy race, restored standard share-link unified spans,
  and made app activity storage resolve the active run dynamically.
- `git diff --check` and the added-line credential/private-URL scan passed.
- No live network or remote mutation was performed.

### 2026-09-01 — Milestone 3 Stability Lab

- Added a Stability-only macOS lab UI backed by the existing manual-token
  Keychain flow. Standard and Stability build identities register only their
  matching ordinary/lab domain purpose.
- Provisioning rejects any saved or registered domain and any external,
  unavailable, duplicate, or maintenance drive before remote mutation. It
  verifies the explicit drive root, creates one unique top-level directory,
  uploads a fixed marker with conflict-as-error, verifies it, persists root and
  marker IDs, and only then registers File Provider. Partial provisioning is
  retained for manual recovery; there is no automatic remote rollback.
- Reset requires an exact typed phrase and a complete bounded listing. The
  reset plan cannot represent root/marker/permanent deletion. Before every
  `trashItem`, the coordinator re-reads internal drive access, system domain
  registration, root, marker, and target parent and aborts on drift. A
  cross-process lifecycle lease blocks an active or newly starting diagnostics
  run for the entire reset. File Provider and action runtimes reject a domain
  purpose that does not match their compiled profile.
- `xcodebuild build-for-testing -quiet -project potassiumProvider.xcodeproj
  -scheme potassiumProvider-Stability -configuration Stability -destination
  'platform=macOS,arch=arm64' -derivedDataPath
  /tmp/potassium-provider-stability-lab-dd
  COMPILER_INDEX_STORE_ENABLE=NO` exited 0.
- The final signed `test-without-building`, restricted to
  `StabilityDiagnosticsTests`, `StabilityLabSafetyTests`, and
  `StabilityLabRemoteCoordinatorTests`, exited 0 with `TEST EXECUTE SUCCEEDED`:
  47 Swift Testing cases passed in three suites and the result bundle finalized
  at `/tmp/potassium-lab-final-v4-20260901.xcresult`. An earlier two-suite run had
  passed before local Xcode stalled during result-bundle finalization; the
  successful final run supersedes that incomplete result artifact.
- No live credential was read, no File Provider domain was registered, and no
  remote mutation was performed.

## Milestone 3 Decision Records

| Decision | Evidence | Live result | Chosen behavior | Tests | Truth-table impact |
| --- | --- | --- | --- | --- | --- |
| Domain/build isolation | shared production identity; File Provider registration map; plan invariant | not run | legacy records decode ordinary; app, File Provider, and action runtimes accept only the current profile's consistent purpose; live registration evidence is re-queried before provision/reset mutations | configuration profile tests; ordinary-domain no-call and domain-change race tests | adds fail-closed lab registration/cleanup row |
| Lab-root ownership | pinned client drive eligibility plus server-authoritative discovery/root/marker metadata | not run | treat discovery as internal membership only; prove lab ownership by this build's random marker plus exact persisted and remote root/marker identity under the explicit drive root | external-drive no-mutation, provision-shape, and marker mismatch tests | adds provisioning predicate without claiming product ownership |
| Ownership marker | plan requirement; remote upload/download and local configuration contracts | not run | marker payload has no name/path/account data; persist marker file ID separately; require local/remote marker equality and preserve the file | marker round-trip, missing/mismatch/parent/duplicate evidence tests | adds marker collision and preservation rows |
| Reset mutation | safe cleanup policy and truth-table trash/permanent-delete distinction | not run | exact confirmation, complete bounded pagination, preserve root/marker, fresh TOCTOU checks, trash only, live domain isolation, and a cross-process inactive-run lease | pagination/cursor, reset preservation, target/root/marker/domain drift, and run-lease tests | documents reversible trash and keeps unconditional permanent delete risk separate |

## Milestone 4 Decision Records

| Decision | Evidence | Live result | Chosen behavior | Tests | Truth-table impact |
| --- | --- | --- | --- | --- | --- |
| Command and credential boundary | plan invariant; existing manual-token Keychain flow | not run | command accepts preflight/run plus local stale-run recovery, permission prompting only where applicable, explicit `--yes-live`, and explicit `--yes-recover`; context loads the saved manual-token credential from Keychain and never accepts credential/account/root inputs; recovery reads no credential and performs no remote action | parser rejection, recovery dispatch, and closed console-status tests | no mutation semantic change |
| macOS permission preflight | Apple Accessibility trust and Apple Events target-permission APIs; File Provider registered/visible-domain APIs | not run | Accessibility, Finder Automation, File Provider registration, consent, and lab safety are typed preflights; the macOS Stability configuration alone carries Automation plus Finder-scoped sandbox Apple Events entitlements; OS consent and variable contextual UI return checkpoint exit 3, not product failure | pure permission/consent/checkpoint evaluator and build-setting/entitlements isolation tests | no conflict decision change |
| Scenario and assertion contract | plan's fixed scenario list; File Provider-visible root; typed remote adapter | not run | execute 16 steps in fixed order; a failure skips later steps while a typed UI checkpoint permits independent later scenarios; checkpoint reasons are restricted to their scenario; every passing step requires Finder-visible plus fresh server-authoritative assertions, correlated baseline/postcondition observations, and scenario-appropriate successful callback/network terminals; enumeration requires both item enumeration and anchor/change evidence; working-set requires a known same-run item and preserve-both requires two distinct Finder-visible candidates; restore/delete/cancel/contextual UI stop at checkpoints instead of substituting direct APIs, starting an unobserved transfer, or using global progress | report order, checkpoint classification, terminal-state, correlation, conjunctive enumeration/anchor evidence, missing/wrong-source diagnostic, round-trip, and immutable-evidence tests | observes mutation/conflict cells without redefining them |
| Finder evidence privacy and durability | Stability JSONL lifecycle and privacy boundary | not applicable | create an exclusive runner-owned run, publish a private per-step cross-process correlation pointer, replace closed assertion/API JSONL files, exclusive-create one immutable validated report as commit marker, verify caller summary counts against that report, then seal summary; on failure retain owner PID/token and the active unsealed bundle; explicit recovery requires a dead owner, writes immutable abandonment evidence, clears a stale step, and prevents ordinary finalization; store no identifiers, names, paths, URLs, bodies, headers, shares, or bytes in report evidence | prohibited-key/canary, duplicate/missing observation and diagnostic, summary mismatch, ownership exclusion, live/dead owner, stale-step abandonment, partial-write/retry, and one-write tests | diagnostics only |
| Live mutation scope | exact lab root/marker preflight and explicit operator confirmation | not run | live sequence is outside CI and operates only through the verified non-root lab; recheck sole saved/system domain, remote root/marker, and cached root URL's root-container/configured-domain binding before every scenario; immediately bind every existing-item mutation URL (and move destination) to its expected File Provider item and configured domain, reusing the single validated identifier for eviction; reset stays trash-only; restore and permanent deletion leave the lab root selected and never open global Trash or direct a destructive action; cancellation leaves an exact evicted item selected without starting a download; contextual actions never call the remote API directly | structural model, single-resolution item/domain drift, root/domain drift, and command safety tests; live validation remains operator-only | runner adds no permanent-delete mutation; `CR-013` remains open for the product callback |

## 2026-09-01 — Milestone 4 Finder runner

- Added the Stability-only macOS command and wrapper, Apple permission
  preflight, File Provider-visible scenario runner, closed 16-step report, and
  immutable assertion/API evidence assembly. No credential or private value is
  accepted on the command line or written to the evidence schema.
- The command exclusively owns its active run, uses a private per-step pointer
  for cross-process diagnostic correlation, and cannot seal a partial evidence
  assembly. Restore, permanent-delete, cancellation, and localized contextual
  UI terminate at explicit Finder/operator checkpoints rather than being
  represented by direct remote calls, an unobserved transfer, or domain-global
  progress.
- Failed/crashed commands retain ownership; explicit local recovery verifies
  the owner process is gone, writes an abandonment marker, removes a stale
  correlation pointer, and prevents ordinary summary finalization. Passing
  steps now require scenario-specific correlated terminal diagnostics;
  enumeration requires both listing and anchor/change terminals. Checkpoint
  reasons are scenario-bound, existing mutation URLs and the move destination
  are rebound to expected File Provider item/domain identities, eviction reuses
  its single validated identifier, the cached lab root is rebound after
  baseline pagination and immediately before execution, and summary sealing
  rejects aggregate counts that differ from the immutable report.
- The current signed Stability graph completed `build-for-testing`, including
  the Stability-only Automation and Finder-scoped sandbox Apple Events
  entitlements. All 33 selected Swift Testing cases reported passed in both
  scheme executions across three suites. Xcode 17.5 then remained blocked while
  finalizing its result log and coverage after printing every successful case,
  so the exact test runner was terminated and did not emit `TEST EXECUTE
  SUCCEEDED`. The Stability app/extension graph also built successfully for a
  standard macOS Debug build, the iPhone 17 iOS 26.5 Simulator Stability build,
  and the generic visionOS Stability build after verifying all Finder-only
  sources are platform-gated. The final read-only adversarial review found no
  remaining code defect; its stale-evidence finding was closed by this current
  rebuild/run. No live credential was read, no Finder operation ran, and no
  remote mutation was performed during automated validation.

## 2026-09-01 — Milestone 5 API evidence and adapters

- Completed the operation-by-operation matrix against the potassiumChannel
  `0.3.0` pin, the captured official documentation revision, and pinned iOS,
  Android, and desktop sources. Reference client code was used only as behavior
  evidence; no GPL implementation was copied. Every live-result cell remains
  `not run` except the already-sanitized advanced-listing observation because
  no development credential or remote-mutation authority was provided.
- Corrected five discrepancies: modeled inherited share access and rejected
  unknown access values; explicitly encoded a cleared share expiration as JSON
  null while retaining the pinned typed route; rejected direct uploads above
  `1_000_000_000` bytes before callback buffering or request construction;
  mapped 408/429 to retryable
  server-unreachable recovery while retaining only safe parsed delta seconds;
  and sent an explicit extension-preserving duplicate name instead of `{}`.
- A fresh signed Stability `build-for-testing` completed successfully. The
  focused `test-without-building` selected `KDriveAPIEvidenceTests` and
  `KDriveContextActionTests`; all 17 unique cases passed in both scheme
  executions (34/34 reported successes). After the HTTP 429 precedence and
  fixture-literal repairs, the then-current seven-case API slice reported 14/14
  passes. After the pre-buffer repair, the final eight-case API slice reported
  all 16 passes across both scheme executions. Xcode 17.5 then repeated the known
  result-log/coverage finalization hang after every case was terminal, so the
  runner was interrupted and did not emit `TEST EXECUTE SUCCEEDED` or finalize
  the result bundle.
- `git diff --check` and the credential/private-value scan were rerun after the
  final repairs. No live API request, File Provider mutation, or remote cleanup
  was performed.

## 2026-09-01 — Cross-platform completion validation

All commands removed the inherited Infomaniak and App Store Connect credential
variables. The four build commands exited successfully:

```sh
env -u INFOMANIAK_TOKEN -u ASC_ISSUER_ID -u ASC_KEY_ID -u ASC_KEY_NAME -u ASC_KEY_PATH -u ASC_TEAM_ID xcodebuild build-for-testing -quiet -project potassiumProvider.xcodeproj -scheme potassiumProvider-Stability -configuration Stability -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/potassium-final-macos COMPILER_INDEX_STORE_ENABLE=NO

env -u INFOMANIAK_TOKEN -u ASC_ISSUER_ID -u ASC_KEY_ID -u ASC_KEY_NAME -u ASC_KEY_PATH -u ASC_TEAM_ID xcodebuild build-for-testing -quiet -project potassiumProvider.xcodeproj -scheme potassiumProvider-Stability -configuration Stability -destination 'platform=iOS Simulator,OS=26.5,name=iPhone 17' -derivedDataPath /tmp/potassium-final-ios COMPILER_INDEX_STORE_ENABLE=NO

env -u INFOMANIAK_TOKEN -u ASC_ISSUER_ID -u ASC_KEY_ID -u ASC_KEY_NAME -u ASC_KEY_PATH -u ASC_TEAM_ID xcodebuild build -quiet -project potassiumProvider.xcodeproj -scheme potassiumProvider-Stability -configuration Stability -destination 'generic/platform=visionOS' -derivedDataPath /tmp/potassium-final-vision-device COMPILER_INDEX_STORE_ENABLE=NO CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO

env -u INFOMANIAK_TOKEN -u ASC_ISSUER_ID -u ASC_KEY_ID -u ASC_KEY_NAME -u ASC_KEY_PATH -u ASC_TEAM_ID xcodebuild build-for-testing -quiet -project potassiumProvider.xcodeproj -scheme potassiumProvider-Stability -configuration Stability -destination 'platform=visionOS Simulator,OS=26.5,name=Apple Vision Pro' -derivedDataPath /tmp/potassium-final-vision COMPILER_INDEX_STORE_ENABLE=NO
```

The full Swift unit-test target was then run without rebuilding on each hosted
destination. Output was filtered only for terminal test/error lines:

```sh
set -o pipefail
env -u INFOMANIAK_TOKEN -u ASC_ISSUER_ID -u ASC_KEY_ID -u ASC_KEY_NAME -u ASC_KEY_PATH -u ASC_TEAM_ID xcodebuild test-without-building -quiet -project potassiumProvider.xcodeproj -scheme potassiumProvider-Stability -configuration Stability -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/potassium-final-macos COMPILER_INDEX_STORE_ENABLE=NO -only-testing:potassiumProviderTests 2>&1 | rg --line-buffered "(Test case .* (passed|failed)|Test Suite|Testing started|error:|TEST EXECUTE|BUILD INTERRUPTED)"

set -o pipefail
env -u INFOMANIAK_TOKEN -u ASC_ISSUER_ID -u ASC_KEY_ID -u ASC_KEY_NAME -u ASC_KEY_PATH -u ASC_TEAM_ID xcodebuild test-without-building -quiet -project potassiumProvider.xcodeproj -scheme potassiumProvider-Stability -configuration Stability -destination 'platform=iOS Simulator,OS=26.5,name=iPhone 17' -derivedDataPath /tmp/potassium-final-ios COMPILER_INDEX_STORE_ENABLE=NO -only-testing:potassiumProviderTests 2>&1 | rg --line-buffered "(Test case .* (passed|failed)|Test Suite|Testing started|error:|TEST EXECUTE|BUILD INTERRUPTED)"

set -o pipefail
env -u INFOMANIAK_TOKEN -u ASC_ISSUER_ID -u ASC_KEY_ID -u ASC_KEY_NAME -u ASC_KEY_PATH -u ASC_TEAM_ID xcodebuild test-without-building -quiet -project potassiumProvider.xcodeproj -scheme potassiumProvider-Stability -configuration Stability -destination 'platform=visionOS Simulator,OS=26.5,name=Apple Vision Pro' -derivedDataPath /tmp/potassium-final-vision COMPILER_INDEX_STORE_ENABLE=NO -only-testing:potassiumProviderTests 2>&1 | rg --line-buffered "(Test case .* (passed|failed)|Test Suite|Testing started|error:|TEST EXECUTE|BUILD INTERRUPTED)"
```

On macOS, iOS Simulator, and visionOS Simulator, the unit-test process exited
after emitting only passing terminal cases and no failure/error line. Xcode
17.5 then remained blocked in its result-log/coverage finalization path, so each
`xcodebuild` wrapper was interrupted and returned 130 without a final `TEST
EXECUTE SUCCEEDED` marker. This is the sole validation limitation. Existing
non-fatal Swift Testing/Sendable warnings remain outside this stability-loop
change. No live credential was consumed, no Finder scenario ran, and no local
or remote File Provider mutation was performed.

## API Decision Ledger

Evidence keys used by the per-operation matrix:

- **P** — the project-pinned OpenCow42 potassiumChannel `0.3.0`, peeled commit
  [`db829f1f`](https://github.com/OpenCow42/potassiumChannel/tree/db829f1f2bd8c2113a529c9c521bd5cdfb5ef4dc).
- **D** — [Infomaniak API reference](https://developer.infomaniak.com/docs/api)
  snapshot identified in Evidence Revisions. The public site exposes no source
  commit; each route was re-read from that captured page-data revision.
- **I** — official [iOS kDrive source](https://github.com/Infomaniak/ios-kDrive/tree/90c2e2560630b075b77b9e87b46b44d385a05283)
  at `90c2e256`; API fetchers and File Provider behavior were compared.
- **A** — official [Android kDrive source](https://github.com/Infomaniak/android-kDrive/tree/25e07993e87e8ae50f7c73aeaf4c6802eef1d434)
  at `25e07993`, including Core submodule `7037dab1`.
- **K** — official [desktop kDrive source](https://github.com/Infomaniak/desktop-kDrive/tree/f72372661e79744c243fd4963465aaae92a6eba7)
  at `f7237266`; network-job request shapes were compared.

Reference-client code is GPL behavioral evidence only. No implementation was
copied. `not run` means no development credential was supplied and therefore
no live request was sent. Dependency request tests at **P** cover unmodified
typed builders; app fixture names identify local adapter or policy coverage.

| Protocol operation | Version-pinned evidence and discrepancy | Live result | Chosen behavior | Affected tests | Truth-table impact |
| --- | --- | --- | --- | --- | --- |
| `listDrives()` | P typed core has no public discovery helper; I/A load eligible drive roles; public D does not expose `/2/drive/init` | not run | retain the small typed app request, accept one internal non-maintenance membership record, and never claim account ownership | `kdriveServiceLoadsDriveRolesFromDriveInitOnly`; Stability Lab external/duplicate/maintenance rejection | lab ownership rows remain fail closed |
| `item(driveID:fileID:)` | P/D/I/A/K agree on stable file ID metadata; ETag is an included resource | not run | request direct metadata with `with=etag`; treat it as authoritative before versioned mutations | mutation coordinator matching/stale-version suites | `C` remains stable ID plus ETag |
| `listDirectory(...)` | P/D/I/A expose per-folder cursor listing; ordinary listing accepts ETag | not run | request ETag first; retry without `with` only for the known 422 compatibility response | `kdriveServiceFallsBackToDirectoryListingWithoutETagAfter422` | no cursor protocol substitution |
| `listAdvancedDirectory(..., cursor:nil, ...)` | P supplies `/listing`; K uses drive-wide advanced listing; D currently has no public route page | prior sanitized observation only: `etag` and `files.etag` rejected; `files.capabilities` accepted | use `files.capabilities`; surface 422 and retain the prior snapshot/anchor | initial advanced-listing and 422 tests | advanced-listing row retained |
| `listAdvancedDirectory(..., cursor:value, ...)` | P supplies `/listing/continue`; K corroborates advanced cursors; D currently has no page | same prior sanitized observation | preserve advanced cursor/action semantics and never fall back to ordinary listing | continued advanced-listing and 422 tests | advanced-listing row retained |
| `listTrash(...)` | P/D/I/A expose cursor-paginated trash listing | not run | order and page through typed trash results; validate pagination before committing state | listing validator; trash enumeration coverage | no mutation change |
| `downloadFile(...)` | P/D/I/A/K agree on stable-ID download | not run | async convenience consumes the same lazy operation | lazy download fixture; transfer diagnostics tests | no conflict change |
| `downloadFileOperation(...)` | P exposes Foundation progress/cancel; I/K corroborate cancellable transfer work | not run | lazy start, one underlying cancellation, deduplicated progress, one terminal diagnostic | lazy transfer/progress/start-cancel tests | retry semantics unchanged |
| `thumbnail(...)` | P/D/I/A expose typed thumbnail size options | not run | use typed request; record only option shape | `kdriveServiceFetchesThumbnailThroughPotassiumRoute` | no mutation change |
| `uploadFile(...)` | P/D/I/A/K direct-upload contract; D says files over 1 GB require a session | not run | async convenience uses the guarded operation | upload request and direct-size boundary tests | adds large-upload fail-closed row |
| `uploadFileOperation(...)` | P encodes total size/conflict/token/hash; D caps direct upload at `1_000_000_000` bytes and documents sessions above it | not run | preflight callback-file size before loading, validate the loaded count again before request construction, and return a mapped synchronization error until a file-backed session adapter exists | upload shape; pure byte boundary; sparse-file pre-buffer rejection | `CR-017` mitigated |
| `replaceFile(...)` | P/D agree `file_id` plus `If-Match`; I/K corroborate conditional replacement | not run | async convenience performs the same guarded stable-ID replacement | conditional replace and race tests | conditional preserve-both rows unchanged |
| `replaceFileOperation(...)` | P/D support ETag condition and direct-upload limit | not run | validate size first; send stable ID, ETag, deterministic token/hash; preserve both on 409/412 | exact replace request; conditional-race tests; size boundary | `C`/409/412 and `CR-017` |
| `createDirectory(...)` | P/D/I/A/K expose parent-ID plus name creation | not run | typed create; recognized collisions receive one explicit conflict name | directory create/collision coordinator tests | directory-collision row unchanged |
| `renameItem(...)` | P/D/I/A/K use stable ID plus explicit name | not run | local same-field intent wins; recognized collision gets one conflict name | rename/refetch/idempotence/drift tests | rename rows unchanged |
| `moveItem(...)` | P/D/I/A/K use stable ID and destination; P supports `conflict=rename` and optional name | not run | merge move-only with remote rename; combined move/rename applies local name | move/rename concurrency suites | move rows unchanged |
| `updateModificationDate(...)` | P/D/I expose integer `last_modified_at` | not run | update only when it is the remaining requested field, then refetch | combined-field coordinator tests | combined-fields date row unchanged |
| `trashItem(...)` | P/D/I/A/K use stable ID and reversible trash | not run | local trash intent wins after requested content/metadata work | trash drift/concurrent-edit tests | reversible trash row unchanged |
| `deleteTrashedItem(...)` | P/D expose stable-ID delete; no source documents ETag/If-Match | not run | retain preflight/refetch rejection, but accepted request remains unconditional | permanent-delete matching/stale tests | `CR-013` remains open |
| `setFavorite(...)` | P/D/I/A expose separate favorite/unfavorite mutations; no conditional token | not run | mutate stable ID, then refetch authoritative metadata and invalidate both possible parents | `favoriteRefetchesMetadataAndInvalidatesBothParents` | adds favorite row |
| `duplicateItem(...)` | P allows an optional name and previously emitted `{}`; I/K always provide an explicit name; A uses copy-to-directory | not run | refetch source, derive an explicit extension-preserving `copy` name, send it, then refetch the created stable ID; never depend on server-selected naming | duplicate coordinator/name-policy and exact request-body tests | `CR-019` resolved |
| `trashedItem(...)` | P/D/I/A expose trashed metadata | not run | re-read the stable trashed item before choosing a restore parent | restore coordinator tests | adds restore row |
| `existingFileIDs(...)` | P/I/A expose batch existence checks | not run | verify the original restore parent, otherwise choose configured drive root | restore original/root fallback tests | adds restore row |
| `restoreTrashedItem(...)` | P/D/I/A use stable ID plus explicit destination | not run | restore to verified original parent or root fallback; never permanently delete | restore original/root failure tests | adds restore row |
| `shareLink(...)` | P/D/I/A expose `public`, `inherit`, and `password`; prior app decoder treated unknown rights as public | not run | decode all three known rights; expected 404 is optional success; unknown rights fail closed | optional-404, inherit decode, unknown-right tests | `CR-018` resolved |
| `createShareLink(...)` | P/D/I/A define known rights and capability fields | not run | validate password mode and encode the selected known right; diagnostics never retain URL/password | share defaults plus exact body tests | adds share-create row |
| `updateShareLink(...)` | D makes `valid_until` nullable; I/A explicitly clear with null; P 0.3.0 synthesized encoding omitted nil | not run | retain P's typed route/response but replace its body with an app adapter that explicitly encodes JSON null; unknown response rights fail closed | exact null/inherit body and response tests | `CR-018` resolved; `CR-021` open for no ETag |
| `deleteShareLink(...)` | P/D/I/A expose unconditional delete and no link-version condition | not run | disable by stable item ID; do not log/share the URL; document stale-editor race | contextual-action and diagnostic tests | adds share-delete row; `CR-021` open |
| `fileVersions(...)` | P/D/I expose page/per-page, descending creation order, and immutable version IDs | not run | use nondeprecated typed route and explicit paging | version-page model/action tests | adds version-list/restore evidence |
| `restoreFileVersion(...)` | P/D/I restore a selected version to an explicit destination/name | not run | always restore as a new copy and refetch its stable ID; current file is unchanged | version action/coordinator tests | adds restore-as-copy row |
| working-set listings | P typed latest/favorite/shared routes; I/A/K corroborate working-set categories | not run | bounded deduplicated union; never infer success from root existence alone | `WorkingSetSyncTests`; Finder working-set assertion tests | no mutation change |
| `listPartialActivities(...)` | P typed `/listing/partial`; D currently has no public page; I/K corroborate change feeds | not run | batch 200 stable IDs; advance watermark only after a validated complete response | partial-activity and failed-poll tests | cursor/anchor fail-closed rows unchanged |
| HTTP rejection mapping | D documents a global 60 requests/minute limit; P retains raw Retry-After metadata | not run | map 408/429 to retryable `.serverUnreachable`; retain only a parsed nonnegative delta-seconds integer, never the raw header/body; other 4xx remain deliberate | table-driven 408/429/507/5xx classifier tests | adds retry mapping row; `CR-020` mitigated |

### Accepted discrepancy corrections

1. Added `inherit` and changed unknown share access from a widening `.public`
   fallback to a typed failure.
2. Added an app-owned update body that explicitly sends `valid_until: null`
   while retaining potassiumChannel's pinned method, path, response, and client.
3. Rejected direct create and replacement callback files above one billion
   bytes before buffering, then rechecked the loaded count before constructing
   an upload operation. Session uploads remain a documented implementation gap;
   the callback source stays File Provider-owned but this early path creates no
   separate conflict-stage copy.
4. Changed HTTP 408 and 429 recovery to `.serverUnreachable` and retained only
   parsed delta seconds from Retry-After.
5. Changed duplicate-in-place to send an explicit derived name instead of an
   empty options body.

The advanced-listing and `/2/drive/init` routes remain client/live-evidence
adapters because the public documentation snapshot does not contain them.
Permanent trash deletion and share update/delete remain marked unconditional;
no conditional primitive is invented without authoritative evidence.
