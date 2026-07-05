# File Listing And Caching Improvements

This document captures possible improvements for file listing, metadata caching,
reliability, and conflict resolution in `potassiumProvider`.

The current implementation is intentionally simple: kDrive is the source of
truth, File Provider callbacks call kDrive directly, and `Snapshots.sqlite3`
stores metadata snapshots used for listing and change diffs. That gives the app a
working baseline, but several reliability and conflict-resolution behaviors need
stronger local guarantees before this can be considered durable sync
infrastructure.

## Goals

The next iteration should aim for these properties:

- never advance a sync cursor after applying an incomplete or ambiguous listing
- never lose local bytes because an upload failed, timed out, or raced with a
  remote delete
- detect stale local mutations before overwriting newer remote state
- preserve both user intents when content or name conflicts cannot be merged
- keep File Provider listings stable, paged, and recoverable across extension
  restarts
- make cache updates deterministic and safe under concurrent enumerators

## Implemented High-Risk Guardrails

The 2026-07-05 hardening pass addressed the highest-risk listing, cache, and
stale-mutation issues without attempting the full sync-database redesign.

Implemented:

- `KDriveSnapshotStoring.save(...condition:)` with `.missing`,
  `.matching(anchor:serverCursor:)`, and `.unconditional`
- `KDriveSnapshotStoreError.staleSnapshot` when a guarded writer no longer
  matches the stored row
- guarded enumeration/change saves before File Provider observers receive
  updates or deletes
- SQLite WAL mode and a 5 second busy timeout during snapshot store
  initialization
- `KDriveListingValidator` for repeated cursors, missing continuation cursors,
  unknown advanced actions, and update actions missing metadata
- fail-closed invalid advanced change payloads mapped to `.syncAnchorExpired`
- invalid legacy listing loops mapped to `.cannotSynchronize`
- `KDriveVersionConflictResolver` base-version checks before existing-item
  mutations
- preserve-both stale content handling through app-group staging plus renamed
  `conflict=rename` upload
- stale rename, move, trash, and delete blocked before server mutation
- explicit `KDriveUploadConflictStrategy` for file uploads

Partially addressed:

- conflict bytes are staged for stale content conflict copies only; there is not
  yet a durable pending-operation table or automatic staged-byte retry workflow
- stale destructive/metadata mutations return a platform-compatible
  `.cannotSynchronize` error with recovery text on this target, rather than a
  more specific version-unavailable error
- conditional saves still replace whole snapshots; the item/membership schema is
  not yet split into the proposed sync database

## Current Risk Areas

### Whole-Snapshot Replacement

`KDriveSnapshotSQLiteStore.save(...)` deletes and reinserts all rows for a
domain/container in one transaction. Conditional saves now prevent stale writers
from replacing a newer row, but the storage model is still coarse:

- small advanced-listing changes rewrite the entire folder snapshot
- there is no per-item update path or child-membership table yet
- callers that intentionally use `.unconditional` can still replace a snapshot
  without a compare-and-swap guard

### Per-Instance Actor Isolation

`FileProviderRuntime.load(...)` opens a new snapshot store for each callback.
The store is an actor, but that only serializes calls through that one actor
instance. It does not serialize all SQLite access across runtime loads or across
extension processes. SQLite WAL, a busy timeout, and conditional snapshot writes
now reduce the risk of cursor regression, but they do not replace a dedicated
sync transaction model.

### Partial Listings Can Become Trusted State

Repeated cursors, impossible cursors, malformed action payloads, and missing
metadata for required update actions now fail the sync attempt instead of
advancing the stored cursor.

Remaining risk: the provider still relies on the current snapshot shape, so
recovering from invalid advanced change payloads expires the sync anchor rather
than applying a partial action stream.

### Cache Freshness After Mutations

Create, modify, move, rename, trash, and delete operations return server results
to File Provider but do not update or invalidate affected snapshots directly.
The metadata cache eventually catches up through later enumeration.

That can leave cached normal-folder listings stale, especially because fully
enumerated advanced snapshots can be returned directly from SQLite.

### Lightweight Version Mapping

`NSFileProviderItemVersion` currently derives from timestamps and metadata fields.
The mutation callbacks now compare incoming `baseVersion` values with freshly
fetched kDrive metadata before content, metadata, trash, and delete mutations.

Remaining risk: timestamps and derived metadata strings are weaker than an
authoritative server revision, etag, checksum, or version ID.

### No Durable Pending-Operation Journal

Most local mutation bytes are still read from File Provider temporary URLs and
sent directly to kDrive. Stale content conflict copies are staged before upload,
but normal creates/replaces do not yet have a durable pending operation.

If the upload succeeds server-side but the extension times out, a retry can
create duplicate versions or duplicate items. If a non-conflict upload fails
after the temporary URL disappears, the provider has no local recovery copy.

## Proposed Cache Model

Replace the current snapshot-only cache with a small sync database. The exact
schema can evolve, but the cache should represent these concepts separately.

### Containers

Track one row per enumerated container:

- domain identifier
- container identifier
- kDrive folder ID when applicable
- listing mode: legacy, advanced, trash, working set
- current server cursor
- local generation
- fully enumerated flag
- last successful refresh time
- last failed refresh time and error category

### Items

Track one row per known kDrive item:

- stable item ID
- drive ID
- parent ID
- name
- type/status
- size and MIME type
- created, modified, and updated timestamps
- server revision, etag, checksum, or other authoritative version fields when
  available
- tombstone state when the item is deleted, trashed, or moved out

### Child Membership

Track child membership separately from item metadata:

- domain identifier
- container identifier
- child item ID
- sort key
- position or rank when needed

This allows a single item metadata update to affect multiple views without
rewriting a whole container snapshot.

### Pending Operations

Add a durable operation journal:

- operation ID
- operation type: create, replace, rename, move, trash, delete
- target item ID when known
- parent item ID
- requested name
- local staged content URL or blob identifier
- File Provider base version
- server version observed before the mutation
- retry count and next retry time
- operation state: staged, sending, sent, confirmed, conflicted, failed

### Staged Content

Before uploads or replace operations, copy local file bytes into app-group
storage controlled by the provider. The pending operation should reference this
staged file until the server result is confirmed or a conflict copy is created.

## Proposed Listing Behavior

### Initial Enumeration

For a normal folder:

1. If a fully enumerated local cache exists and no invalidation is pending, page
   from SQLite.
2. If the cache is missing, stale, incomplete, or invalidated, fetch from kDrive.
3. Store fetched pages incrementally.
4. Mark the container fully enumerated only after a complete listing finishes
   without cursor anomalies.

For root, trash, and working set:

1. Prefer a server-backed cursor model if kDrive exposes one.
2. If legacy listing remains necessary, treat local anchors as local cache
   generations only.
3. Do not claim precise remote change anchors when the source API cannot provide
   them.

### Local Paging

When serving a fully enumerated folder from SQLite, return stable local pages
instead of emitting the entire cached snapshot at once. The local page token can
encode:

- domain identifier
- container identifier
- local generation
- offset or last sort key

If the generation no longer matches, expire the local page and restart
enumeration.

### Change Enumeration

For advanced folders:

1. Verify that the requested anchor equals the stored server cursor.
2. Fetch kDrive changes from that cursor.
3. Apply actions in a database transaction guarded by the expected cursor.
4. Advance the cursor only after all actions are applied successfully.
5. If any action is unknown or lacks required metadata, rebuild before advancing
   or return `.syncAnchorExpired`.

For invalid cursors:

1. Keep the old snapshot until a rebuild completes.
2. Rebuild into a temporary generation.
3. Diff old versus rebuilt state.
4. Swap the rebuilt generation into place atomically.

### Cursor Safety Rules

Never mark a container fully enumerated or advance a sync anchor when:

- the server repeats a continuation cursor
- `hasMore == true` but no next cursor is present
- an advanced update action lacks required item metadata
- an action type is unknown and may affect visibility or identity
- SQLite compare-and-swap detects that another task already advanced the cursor

## Proposed Mutation Behavior

### Write-Through Cache Updates

After a successful mutation, update affected cached containers in the same
conceptual operation:

- create: insert or update the item and add it to the parent membership
- replace contents: update item metadata and content version
- rename: update name, metadata version, and sort key
- move: remove from old parent membership, add to new parent membership
- trash: mark removed from old parent and add to trash if trash is cached
- permanent delete: tombstone or remove the item from trash

If write-through is not possible, mark affected containers invalidated and signal
their enumerators.

### Enumerator Signaling

Use `NSFileProviderManager` signaling after local mutations:

- signal the parent folder after create
- signal old and new parents after move
- signal the item and parent after rename or content replace
- signal old parent and trash after trash
- signal trash after permanent delete

This reduces the time that File Provider can serve stale cached listings.

### Base-Version Checks

Before modifying, trashing, or deleting an item:

1. Decode the File Provider `baseVersion`.
2. Compare it with the stored server version for the item.
3. Fetch latest metadata if the cache is missing or stale.
4. If the server changed since the local base version, resolve the conflict
   before sending the mutation.

The best version source is a server revision, etag, checksum, or version ID from
kDrive. Timestamps are a fallback, not a strong conflict token.

## Conflict-Resolution Policy

### Content Conflicts

When local content changed and remote content also changed:

- preserve both by creating a conflict copy, or
- upload as a new server version only when that behavior is explicit and
  recoverable in the user experience

Recommended conflict filename:

```text
Report (conflict - Alice's MacBook - 2026-07-05 17.58.00).pdf
```

The exact device label and timestamp should be deterministic enough for retries
to find the same pending operation.

### Name Conflicts

For create, rename, and move into an occupied parent:

- prefer `conflict=rename` when the server supports preserve-both behavior
- return `NSFileProviderError.filenameCollision` when File Provider can safely
  recover by choosing another name
- treat file-versus-folder collisions as hard conflicts unless kDrive documents a
  safe preserve-both behavior

### Delete Conflicts

If a local delete or trash races with a newer remote edit:

- do not automatically delete the newer remote state
- surface a conflict or preserve the remote-edited item
- keep local staged bytes until the conflict is resolved

If the item was already deleted remotely, treat delete as idempotent only when no
new local content needs to be preserved.

### Parent Conflicts

If a parent was deleted while a child is created or modified locally:

- keep staged child contents
- create a recovered folder or conflict copy if policy allows
- otherwise return a recoverable File Provider error while preserving local bytes

## Database Reliability Improvements

Add these SQLite behaviors before increasing cache responsibility:

- enable WAL mode
- set a reasonable busy timeout
- add schema versioning and migrations
- add indexes for parent, container, item ID, and sort key lookups
- make cursor advancement compare-and-swap based
- add invariant checks in tests, especially around duplicate children and cursor
  regressions

## Phased Implementation Plan

### Phase 1: Guardrails

Status: addressed for the high-risk cases.

- Repeated cursors and impossible pagination are sync failures.
- Partial advanced rebuilds are not marked fully enumerated after cursor
  anomalies.
- Ambiguous advanced action payloads fail closed without advancing the cursor.
- Tests cover repeated cursors, missing cursors, missing action metadata, stale
  base versions, and stale snapshot saves.

### Phase 2: Stronger SQLite Store

Status: partially addressed.

- WAL and busy timeout are configured.
- Expected-anchor/cursor checks guard enumeration and change snapshot saves.
- Schema versioning and indexes remain future work.
- Add local paging from cached folders.
- Split container state from item rows enough to avoid whole-folder rewrites for
  simple action updates.

### Phase 3: Mutation Reconciliation

Status: partially addressed for stale preflight checks.

- Add cache invalidation or write-through updates after successful mutations.
- Signal affected enumerators after create, modify, move, rename, trash, and
  delete.
- Use stored or freshly fetched versions to reject stale metadata and content
  writes before upload. Fresh remote metadata checks are implemented; write-through
  cache updates are not.

### Phase 4: Pending Operations And Staged Bytes

Status: partially addressed for stale content conflicts only.

- Add a pending-operation table.
- Copy upload bytes into app-group staging before network sends. Implemented for
  stale content conflict copies; still needed for normal uploads.
- Make retries idempotent from the provider's point of view.
- Reconcile ambiguous server success by looking up server state before retrying.

### Phase 5: Preserve-Both Conflict Handling

Status: partially addressed.

- Implement deterministic conflict names. Done for stale content conflict copies.
- Use explicit kDrive conflict policies for files and folders.
- Create conflict copies for content races. Done for stale content replacement.
- Add user-visible recovery behavior for delete-vs-modify and parent-deleted
  scenarios.

## Test Matrix

The improvement work should include unit tests for cache logic and integration
tests with a fake `KDriveFileProviding` implementation.

Important scenarios:

- initial listing completes and caches all pages
- repeated cursor fails without advancing the anchor
- invalid cursor rebuilds atomically
- advanced update action without item metadata does not silently advance
- two concurrent change enumerations cannot regress the stored cursor
- cached folder paging remains stable across page requests
- create updates or invalidates parent listing
- move updates old and new parents
- local replace detects newer remote content
- remote delete versus local replace preserves local bytes
- server success followed by timeout does not duplicate a retry
- folder create collision follows explicit conflict policy

## Success Criteria

The cache and conflict system is reliable enough when:

- every stored cursor corresponds to a completely applied database state
- every local mutation has either a confirmed server result or a durable pending
  operation
- every conflict with possible data loss preserves both sides or returns a
  recoverable error
- cached listings can be rebuilt without losing File Provider identity
- tests cover the cursor, cache, and mutation races most likely to happen in the
  field
