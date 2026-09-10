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

Live edit, rename, and move evidence requires the corresponding `contents`,
`filename`, or `parent` field on a successful `modifyItem` callback. Incidental
last-used or timestamp callbacks cannot satisfy those scenarios. Finder Trash
requires both `parent` and `trash`; permanent deletion requires `deleteItem`.

`Stability` defines the `STABILITY` compilation condition on the app, shared
core, File Provider, actions, unit-test, and UI-test targets. It preserves
bundle identifiers, app groups, and the Keychain credential flow. The macOS
Stability host alone runs outside App Sandbox to use assistive Accessibility;
both extensions and the standard host remain sandboxed.
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
append-only; `summary.json` marks completion. The Finder runner owns a newly
created run through a private random-token and process-ID coordination file, atomically
replaces the reserved `api-observations.jsonl` and `assertions.jsonl` files, and
exclusive-creates immutable `finder-report.json` as their commit marker before
the run is sealed. Final sealing decodes that report and rejects assertion,
failure, or checkpoint totals that do not match it. A failed assembly never
creates `summary.json` and retains
ownership. Explicit stale-run recovery first proves the recorded owner process
has exited, creates immutable `finder-abandoned.json`, removes any stale step
pointer, and only then releases the active-run lease. An abandoned bundle stays
incomplete and cannot be finalized by the ordinary app lifecycle.
The `current-run.json` pointer contains only a random run UUID. Retention keeps the
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

The Stability Lab stores its remote root and ownership-marker identifiers only
in the local domain configuration. The remote marker contains a random marker
UUID plus drive/root identity, but no account identifier, display name, path,
URL, or credential. None of these operational identifiers or marker bytes are
copied into diagnostic events. Lab provisioning and reset use the same closed
typed-network spans as other requests, so only route and option shapes are
durable.

Finder report version 2 adds run-local item aliases, observed UI action counts,
expected extension code hashes, cancellation/conflict/working-set observations, and
closed failure categories/reasons with supporting span IDs. Diagnostics version 3
adds subject aliases, parent spans, process-instance UUIDs, code hashes, and safe
numeric error codes. An optional `validationFields` array contains only known
request-field classes from a 400 or 422 response; messages, values, and unknown keys
are discarded. Version 1 Finder reports and older diagnostic records remain
readable. New live reports require the newer evidence fields.

`concurrentSnapshot` identifies a rejected snapshot compare-and-swap without
exporting the error's domain/container identifiers. Bounded working-set retries
emit this class on nonterminal checkpoints; exhaustion emits a failed terminal.
It never hides a remote failure or changes a successful watermark. Finder's
scoped eviction alert maps to the closed `resourceBusy` failure reason; native
Apple Event failures print numeric codes without private command text.

Each passing step requires a baseline and postcondition, Finder-visible and remote
assertions, and successful item-specific callback evidence from the expected build.
Cancellation accepts the expected cancelled fetch and requires real progress plus a
later successful fetch for that same item. Trash uses `modifyItem`; permanent
selected-item deletion uses `deleteItem`. Root enumeration cannot substitute for
an actual working-set member event. Missing starts/terminals or contradictory
terminals reject certification. Checkpoints are incomplete coverage.

The timeline retains active-item HTTP 404 during Trash-aware metadata lookup.
It is a handled intermediate failure only when the same subject, process/build,
and enclosing metadata span have a subsequent successful `trashedItem` request
and successful metadata callback. Missing or mismatched recovery, another status,
or a failed enclosing callback remains a failure. This exception cannot satisfy
the required Restore mutation evidence.

`live-status.json` is a replaceable closed status snapshot for the read-only watch
command. Watch shows scenario transitions, errors, cancellations, retry checkpoints,
and extension lifecycle events; routine request successes stay in the timeline.
The run recorder starts before context preflight can emit callbacks. A context
preflight failure retains the incomplete unsealed bundle for explicit stale-owner
recovery. This ordering alone does not attest a fresh extension launch, because
registration may have launched it before the command starts.
Selection diagnostics retain the last live window/parent binding flags, list-view
state, and exact-name match counts. They contain no paths, titles, or row contents;
an expired post-failure query cannot overwrite those observations.
`diagnostic-timeline.json` is ordered by timestamp and event ID, and becomes
immutable with the final report. `diagnostic-health.failed` latches a failed append;
subsequent successful writes cannot erase that gap or certify the bundle. The runner
retains monitoring through operator pauses and waits for outstanding spans to settle.
Local screenshots live separately under `visual-evidence`; they are cropped to
positively identified generated content and are excluded from ordinary exports.

Successful plaintext modify callbacks also attach their returned item's
`itemMetadataAlias` to the terminal event, allowing comparison with independently
verified remote state. This reuses the optional version 3 field; historical
events without it remain readable. The value contains no raw item metadata.

Version 3 diagnostics optionally include `itemMetadataAlias`, a run-salted
commitment to item identity, name, parent, and size. No raw metadata values are
exported. The live report's optional `expectedWorkingSetMetadataAlias` becomes
mandatory to certify scenario 15: its matching member terminal must be a child
of a completed working-set enumeration. A newly introduced remote name change
prevents stale membership from passing. Historical bundles remain decodable.

The shared `ProviderDiagnosticSpan` emits one best-effort start and at most one
terminal event even when completion, failure, and cancellation race. Every
span has its own stable random span UUID; a separate Task-local random UUID
correlates nested callback and request spans. During each Finder scenario, a
private owner-only step pointer makes the same random correlation UUID visible
to the app, File Provider extension, and action-extension processes; callback
spans fall back to that value when there is no inherited task-local context.
The pointer contains no domain, item, name, or path value and is removed before
evidence finalization. Recorder
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
For an HTTP rejection, durable diagnostics keep only the numeric status and
closed recovery class. The API adapter may retain a parsed nonnegative
Retry-After delta-seconds integer for retry decisions, but never copies the raw
header value or response body into JSONL, unified logs, activities, or exports.
Share adapter diagnostics likewise never retain the selected access value,
expiration, password, or returned URL.

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
or response bodies, raw Retry-After values, bearer tokens, refresh tokens,
remote account identifiers, or file bytes. The service does not currently
expose a kDrive request ID, so the
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

### Targeted conflict profile evidence

`conflict-profile.json` schema 2 declares the run ID, selected closed conflict
case, and optional required extension launch mode. Historical schema 1 is readable. `conflict-request.json` carries only run/case/correlation identifiers, a salted
subject alias, scheduling point, and unique attempt UUID. Attempt-specific arrival,
release, and cancellation files prevent an earlier release from satisfying a later
case. Report sealing verifies the selected case and gate against its actual
callback evidence. Other entries are `notSelectedForConflictProfile`; the full
sixteen-scenario certificate is unchanged. Failures and local screenshots retain
the existing privacy and immutability boundaries.

Both `--run` and `--conflicts` may require `--extension-state fresh|running`.
The original runner declares this in `extension-launch-request.json` schema 1;
conflict runs declare it in their profile. Missing requested evidence cannot pass. The immutable
`extension-launch.json` (schema 1) records microsecond integer timestamps (preserving kernel birth ordering), the signed
build hash, diagnostic process UUID, and preparation fence. Fresh evidence requires
an initialization terminal before the tested mutation in a newly born process.
Running evidence requires an earlier callback, an unchanged kernel process, and no
initialization or invalidation during the run. Missing or mixed process evidence
prevents certification; a historical profile without this requirement remains a
targeted result without cold/warm certification. No PID, path, account, or raw
item identifier is exported by this record.

Conflict profile version 3 requires a version 1
`conflict-<attempt>-competitor-verified.json` record. It carries the exact ticket
and a salted metadata fingerprint, written only after independent metadata/byte
verification while that attempt is held. Cancellation invalidates it. The original
preserve-both scenario requires the same record at sealing. Historical profile
versions 1/2 remain readable; their results do not certify this stronger ordering.

Confirmed plaintext mutation results can enter the existing working-set SQLite
journal without waiting for a remote crawl. This is not itself working-set
membership telemetry: item-specific `workingSetRefresh` events still arise only
when a real enumeration delivers the item. Journal publication preserves poll
watermarks; poll commits validate their original working-set anchor. No database
schema migration or diagnostic schema change is needed for this delivery path.
When a newer journal supersedes an in-flight poll, the poll stops between
folder/activity requests, discards its prepared container changes, and preserves
its previous successful watermark. Enumeration awaits that work before delivering
the newer journal; it creates no detached refresh worker. Only actual emitted
working-set members carry membership metadata.

Live step validation selects callbacks by run-local subject, step correlation, and start time, then retains their complete spans through monitored settling. Missing starts or terminals and contradictory late terminals still reject acceptance. A sealing rejection retains `finder-evidence-rejected.json` (schema 1, `eligibleForAcceptance: false`) with the candidate report, observations, and a closed error reason; this file never substitutes for the immutable final report and summary. External error descriptions are excluded.

Local recorder settling uses a one-second quiet interval after every span has exactly one start and terminal, sampled every 500 ms within the existing deadline. It does not use server Retry-After/backoff. New events reset the interval; missing or duplicate span records cannot settle. Extension lifecycle validation remains strict through sealing.

The fallback XPC-reply-invalid wrapper is inspected through at most four underlying errors for diagnostic classification. Known SQLite errors retain only their numeric result code and storage category; their message and statement are discarded. This uses existing version-3 fields, and historical opaque wrapper records remain readable. It changes diagnostics, not the error returned to File Provider.

Finder destination observation prints only a closed lookup phase (`resolveItemURL`
or `bindDestinationParent`), diagnostic category, and numeric error code when a
lookup fails. Local paths, error descriptions, and user-info are excluded. A logged
lookup failure is not evidence of a remote API failure or a successful move.
