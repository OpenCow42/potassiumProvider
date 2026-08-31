# Logging

`potassiumProvider` uses complementary diagnostic layers selected by build
profile:

- Unified logging (`OSLog`) for developer diagnostics in the app and File
  Provider extension.
- `Snapshots.sqlite3` activity/conflict rows for the user-visible Activities
  timeline and retained support context.
- A redacted JSON support-log export created from the Activities tab.
- In the opt-in `Stability` profile only, one versioned JSONL run bundle in the
  app-group container for activity, conflict, callback, and API-shape evidence.

These layers are deliberately separate. Unified logging can be more granular
for local development, while durable trails and exported documents carry only
the small set of sanitized fields that are useful to users and support.

## Stability Run Bundles

`Stability` defines the `STABILITY` compilation condition on the app, shared
core, File Provider, actions, unit-test, and UI-test targets. It does not change
bundle identifiers, app groups, entitlements, or the Keychain credential flow.
The standard profile continues to store activity and conflict history in
`Snapshots.sqlite3`.

All existing unified `Logger` instances resolve to `OSLog.disabled` in
Stability. The older debug log call sites include raw identifiers and localized
error descriptions, so enabling them would violate the Stability privacy
contract. Debug and Release keep unified logging; Stability uses only the
closed-schema recorder. The environment-driven Debug UI fixture is also
compiled out of Stability, even though the profile otherwise inherits Debug
settings.

After the operator explicitly starts a Stability run, every production event
store construction site selects `KDriveProviderEventJSONLStore`. Snapshot,
sync-anchor, enumerator, and working-set state still use SQLite; their table
creation is intentionally independent from event-table creation. With no
active run, the Stability factory returns no durable event recorder rather than
falling back to SQLite or inventing a run.

Each run is a complete directory under the app-group `StabilityRuns/runs`
folder. `run.json` is exclusive-created and immutable; `events.jsonl` is
append-only; `summary.json` marks completion. Empty
`api-observations.jsonl` and `assertions.jsonl` files reserve the final bundle
shape until later milestones add their typed append APIs. The
`current-run.json` pointer contains only a random run UUID. Retention keeps the
newest 20 completed bundles within 250 MiB and never prunes the active or an
incomplete bundle. The active event file also rejects an append before it would
exceed 250 MiB, preserving a replayable run that the operator can finish.

JSONL writers use an advisory exclusive lock, one complete encoded record per
write transaction, and `fsync`; readers take a shared lock. A second lifecycle
lock serializes active-run selection, finish, append/read, and retention across
the app, File Provider, and actions processes. Run paths reject symlinks and
non-regular files, use owner-only permissions, and synchronize file and
directory transitions. Replay ignores only an unterminated final record, which
represents an interrupted append; the next writer truncates that tail before
appending. A corrupt complete record is surfaced. Activity paging, statistics,
observation, clear, domain removal, and support export use replay through the
existing protocols; clear/removal are append-only tombstones.

The Stability serializer removes names, paths, item and request identifiers,
drive identifiers, recovery strings, staged paths, and arbitrary error domains
before bytes reach the log. Domain identifiers become run-salted SHA-256
pseudonyms, which remain stable only within that run. Callback/API diagnostics
use closed enums for operation, phase,
field/option shape, route template, and error/status class. They may include a
random correlation UUID, bounded duration/progress values, booleans describing
cursor/anchor state, and numeric status/error codes. They never include raw
URLs, headers, request or response bodies, account identifiers, share links, or
file data.

The shared `ProviderDiagnosticSpan` emits one best-effort start and at most one
terminal event even when completion, failure, and cancellation race. Every
span has its own stable random span UUID; a separate Task-local random UUID
correlates nested callback and request spans. Recorder
failure never changes an API result. A terminal append is attempted before the
system callback so finishing a run cannot silently turn a completed callback
into start-only evidence.
Task-local UUID propagation correlates a callback with its runtime-load and
typed network spans without carrying domain, item, name, or path context.
Instrumented surfaces include extension initialization/invalidation, runtime
load, metadata, fetch, create/modify/delete, item/change/anchor enumeration,
materialized and working-set refresh, thumbnails, known-folder resolution, and
contextual actions. Long-lived app/extension/enumerator objects resolve the
current Stability writer when each callback, app activity, view access, or
service begins, so starting or rotating a run does not retain a missing or
sealed writer. Transfer diagnostics
start only when the lazy transfer is consumed or cancelled and use the same
span for deduplicated progress, cancellation, and completion. An expected
missing share link is recorded as a successful optional result.

## Categories And Correlation

`ProviderLog` is the shared logging namespace. Its categories are `app`,
`authentication`, `domain`, `runtime`, `file-provider`, `enumeration`,
`mutation`, `network`, `persistence`, `conflict`, `thumbnail`, and `export`.

`ProviderLogContext` creates a correlation ID, operation name, optional domain,
drive, and item context, plus a start time. File Provider activity rows receive
a correlation ID and measured duration. The `PotassiumKDriveService` records
sanitized unified-log spans in standard builds and closed-schema JSONL spans in
Stability for every typed kDrive request. Durable spans contain an enum
operation/route/option shape, correlation UUID, bounded duration, phase, and
status/error class; they never retain an error domain or description.

Network spans never include request URLs, query parameters, filenames, request
or response bodies, bearer tokens, refresh tokens, remote account identifiers,
or file bytes. The service does not currently expose a kDrive request ID, so the
optional durable `remoteRequestID` field remains empty unless a future typed API
surface provides one safely.

## Durable Activity Data

`KDriveProviderActivityEvent` records the operation, scope, outcome, severity,
and sanitized diagnostic data already shown in Activities. It additionally has
optional `correlationID`, `durationMilliseconds`, `networkOperation`,
`httpStatusCode`, and `remoteRequestID` fields. Existing databases migrate these
columns as nullable values.

In the standard profile, `KDriveProviderEventSQLiteStore` retains the newest
5,000 activity rows by default. In Stability, whole completed run bundles are
retained instead. In both profiles unresolved, blocked, and failed conflict
events remain visible, and Clear removes activity plus automatically resolved
conflicts while preserving unresolved conflict state.

The Activities screen pages over this retained history in batches of 50. This
only limits UI decoding and rendering; it does not reduce retention or support
export coverage. Live notifications refresh and merge the newest page, and
ordinary scrolling does not resolve File Provider item URLs.

Timeline actions expose model-backed availability and repeat those guards inside
the action methods. Destructive Clear cannot overlap loading, Refresh, or
Export, while the read-only Refresh and Export operations may overlap. Action
errors are displayed independently from initial-load and paging errors, and all
operation progress state is cleared after success, failure, cancellation, or a
superseded filter generation.

## Support Export

The Activities toolbar exports a JSON document via the system file picker. Each
export receives a fresh salt and pseudonymizes domain, drive, item, correlation,
and request identifiers. It omits names, paths, staged-upload paths, and raw
conflict identifiers. Summaries and diagnostic text are scrubbed of known item
values, URLs, and paths before export.

On macOS, the containing app enables sandboxed user-selected file read/write
access so the save panel can create the support log at the chosen destination.

The document includes event timestamps, operation kinds, outcomes, severities,
sanitized summaries, numeric error codes, duration, network operation, HTTP
status, and conflict-resolution state. It is not an export of the Apple unified
log and cannot be used to recover omitted secrets or private URLs.

## Rules For New Logging

- Use `ProviderLog` rather than creating a second subsystem/category namespace.
- Mark user-provided names, paths, account identifiers, and URLs private in
  unified logs; prefer logging counts, operations, and numeric codes.
- Durable summaries must be generic and safe to show in the Activities UI.
- Do not add tokens, raw API bodies, request headers, request URLs, file bytes,
  remote account information, or customer data to either logging layer.
- Add a migration and redaction test whenever a new durable diagnostic field is
  introduced.
