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
| Stability Lab and safe root lifecycle | implemented; reviewer fixes applied | Stability graph built; 47/47 focused executions passed | final pass: no remaining actionable defect | this milestone commit |
| Finder Accessibility runner and checkpoints | pending | pending | pending | pending |
| API evidence matrix and adapter corrections | evidence pinned; implementation pending | pending | pending | pending |
| Cross-platform completion validation | pending | pending | pending | pending |

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
| HTTP and callback diagnostic class | API rejection classifier plus `NSFileProviderError.Code`, without retaining body/header/user-info metadata | not run | map closed HTTP and File Provider recovery classes; cancellation records `cancelled`; expected share-link 404 is a successful optional result | closed classifier tests including 429/507 and File Provider recovery cases; optional-404 adapter test | diagnostic-only; File Provider error behavior remains unchanged pending API milestone |
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

## API Decision Ledger

The complete per-operation matrix is added in the final API-evidence milestone.
Current high-risk discrepancies are tracked now so they cannot be lost:

| API decision | Evidence | Live result | Provisional behavior | Required tests | Truth-table impact |
| --- | --- | --- | --- | --- | --- |
| Share-link `right=inherit` and unknown rights | official create/update docs plus all pinned clients | not run | add explicit inherit; fail closed for unknown values, never default to public | encode/decode/unknown response tests | add share create/update rows and fail-open finding |
| Clear share expiration | update docs define nullable `valid_until`; iOS/Android explicitly serialize null; potassium 0.3.0 omits nil | not run | adapter must send JSON null when clearing | exact body test | add share-update recovery row |
| Direct upload size | upload docs cap `total_size` at 1,000,000,000; clients use sessions/chunks above it | not run | block direct request above limit until a session/file-backed adapter exists | boundary/no-request test | add high-risk large-upload finding |
| Rate limiting | Infomaniak Getting Started documents 60 requests/minute; potassium retains Retry-After metadata | not run | decide retryable 408/429 mapping; retain only parsed safe delay metadata | table-driven 408/429 tests | update retry/error-mapping cells |
| Listing 422 fallback | public ordinary listing supports ETag; only sanitized prior live evidence shows advanced-listing field rejection | prior sanitized result: `etag`/`files.etag` rejected for advanced listing, `files.capabilities` accepted | do not retry ordinary listing without `with` for every unrelated 422 | known-field versus unrelated-422 tests | refresh listing/version evidence |
| Permanent trashed-item deletion | docs expose no ETag/If-Match condition | not run | remain explicitly unconditional and keep CR-013 open | preflight/refetch/rejection tests | CR-013 remains open |
