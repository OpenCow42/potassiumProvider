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
| Stability build profile and JSONL event store | implemented; reviewer fixes applied | 13 macOS `StabilityDiagnosticsTests` passed 2026-08-31 | all actionable findings fixed | pending |
| Callback and network instrumentation | pending | pending | pending | pending |
| Stability Lab and safe root lifecycle | pending | pending | pending | pending |
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
  remote-root ownership proof, callback exactly-once semantics, transfer
  cancellation, and ensuring docs/truth-table evidence stays synchronized.
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
