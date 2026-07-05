# Conflict Cases And Resolution

This document is the source of truth for conflict behavior in
`potassiumProvider`. It describes the cases the File Provider extension can
encounter today, how the current implementation resolves or blocks them, and the
safe direction for future conflict work.

The provider is still mostly server-authoritative for final metadata: create,
replace, move, rename, trash, and delete requests are sent to kDrive, and server
responses are returned to File Provider. The important guardrail now in place is
that stale local mutations are detected before the server is changed.

The listing cache introduced by `KDriveSnapshotSQLiteStore` is a metadata cache.
It helps enumerate folders and diff server changes, but it is not a full sync
database or durable pending-operation journal.

The same SQLite file now also stores a conflict/activity audit log. The app uses
that log for the Activities tab, including resolution state, whether a
conflict was automatically resolved, and local File Provider item identifiers
used to resolve clickable user-visible URLs.

Related docs:

- [File Provider Lifecycle](FILE_PROVIDER_LIFECYCLE.md)
- [Listing And Versioning](LISTING_AND_VERSIONING.md)
- [Mutations](MUTATIONS.md)
- [Persistence](PERSISTENCE.md)

## Resolution Taxonomy

| Category | Meaning | Current examples |
| --- | --- | --- |
| Preserved both | Keep the remote item unchanged and save the local work as a separate item. | Stale content replacement uploads a renamed conflict copy. |
| Blocked/retryable | Refuse a stale local mutation before changing kDrive, then let File Provider refresh and retry. | Stale rename, move, trash, and permanent delete return `.cannotSynchronize`. |
| Delegated to kDrive | Send the operation with the current kDrive conflict flag and trust the server result. | New file upload uses `conflict=version`; move uses `conflict=rename`. |
| Fail-closed | Treat ambiguous listing or cursor state as unsafe and stop before saving a bad snapshot. | Repeated cursors, missing continuation cursors, and unknown advanced actions throw. |
| Unresolved/future work | A known gap that needs durable local state, stronger server tokens, or explicit policy. | Folder create collisions, operation replay after timeout, and failed conflict-copy recovery. |

Audit states stored in SQLite:

| State | Meaning |
| --- | --- |
| `unresolved` | A stale content edit was detected and conflict-copy preservation has started. |
| `automaticallyResolved` | The provider completed a preserve-both action without user input. |
| `blockedRetryable` | The provider refused a stale mutation before changing kDrive. |
| `failed` | The intended conflict-copy preservation failed and staged bytes were retained when available. |

## Relevant Code Paths

- `potassiumProviderFileProvider/PotassiumFileProviderExtension.swift`
  - `createItem(...)`
  - `modifyItem(...)`
  - `deleteItem(...)`
- `PotassiumProviderCore/KDriveRemoteService.swift`
  - `uploadFile(...conflictStrategy:)`
  - `replaceFile(...)`
  - `createDirectory(...)`
  - `renameItem(...)`
  - `moveItem(...)`
  - `trashItem(...)`
  - `deleteTrashedItem(...)`
- `potassiumProviderFileProvider/FileProviderEnumerator.swift`
  - guarded snapshot writes and fail-closed listing validation
- `PotassiumProviderCore/KDriveModels.swift`
  - `KDriveListingValidator`
  - `KDriveAdvancedActionReducer`
  - `KDriveVersionConflictResolver`
  - `KDriveConflictFilename`

## Current Invariants

The implementation follows these practical rules:

1. The server is the source of truth for item identity and final metadata.
2. Existing-item mutations fetch latest metadata before changing the server.
3. File Provider base versions are compared with latest remote versions.
4. Stale content replacement preserves both by uploading a renamed conflict copy.
5. Stale rename, move, trash, and permanent delete are blocked before server
   mutation.
6. Later enumeration or change sync updates the SQLite snapshot from kDrive
   state.

This is a focused conflict-safety pass, not the full sync-database redesign.

## Version Checks

`FileProviderItem` derives versions from kDrive metadata:

- `contentVersion`: `modifiedAt.timeIntervalSince1970`
- `metadataVersion`: `id`, `updatedAt`, `name`, and `parentID`

Before mutating an existing item, the extension fetches latest metadata with
`item(driveID:fileID:)` and compares the relevant base version:

- content replace checks content version
- rename and move check metadata version
- trash and permanent delete check content and metadata versions

These are timestamp-based conflict tokens. A future implementation should prefer
a kDrive revision, etag, checksum, or version ID if one is available.

## Conflict Matrix

### Creates And Name Collisions

| Case | Current behavior | Resolution category | Gap or safer direction |
| --- | --- | --- | --- |
| New file vs existing file with same name | `createItem(...)` uploads with `KDriveUploadConflictStrategy.version`; kDrive decides whether to version, reject, or otherwise resolve. | Delegated to kDrive | Decide whether this provider should prefer preserve-both behavior with `conflict=rename` for local creates. |
| New folder vs existing folder with same name | `createDirectory(...)` is sent without a provider-side sibling preflight or explicit app-local conflict policy. | Delegated to kDrive | Define whether same-name folders should merge, fail with collision, or create a renamed folder. |
| New file vs existing folder, or new folder vs existing file | No provider-side file-versus-folder preflight exists today. | Delegated to kDrive | Add explicit type-aware collision handling and map rejected collisions to File Provider errors when possible. |
| Case-only collisions, such as `Report.txt` vs `report.txt` | No case-folded sibling check exists today. Behavior depends on kDrive and the local platform view. | Unresolved/future work | Add case-normalized collision detection before create, rename, and move. |
| Local create retried after server success but local reply failed | There is no idempotency key or pending-operation journal, so a retry can create duplicates or extra versions. | Unresolved/future work | Store pending operations durably with local operation IDs and reconcile by server item ID. |

### Content Modifications

| Case | Current behavior | Resolution category | Gap or safer direction |
| --- | --- | --- | --- |
| Local content edit vs unchanged remote content | The extension calls `replaceFile(...)`; replace uses kDrive upload with `fileId` and `conflict=version`. | Delegated to kDrive after base-version match | Prefer an authoritative server revision token over timestamps. |
| Local content edit vs remote content edit | The extension stages local bytes in app-group `ConflictStaging`, uploads a renamed conflict copy with `conflict=rename`, returns that item, and leaves the original untouched. | Preserved both | Add a durable retry/recovery workflow for staged conflict bytes. |
| Local content edit vs remote rename or move | Content base version may still match, so the provider replaces the latest item by stable file ID and uses the latest remote parent if a conflict copy is needed. | Delegated to kDrive or preserved both | Decide whether content edits should also check metadata drift when the user-visible path changed. |
| Local content edit vs remote trash or delete | Fetching latest metadata can fail, or the upload can fail if the parent/item is no longer valid. | Delegated to kDrive/error mapping | Stage all upload bytes before network sends and recover parent-deleted cases explicitly. |
| Failed conflict-copy upload | Staged bytes remain in `ConflictStaging`, but nothing automatically retries or surfaces them. | Unresolved/future work | Add a pending-operation table and a user-visible recovery path. |

Conflict names are generated by `KDriveConflictFilename`, for example:

```text
Report (conflict - Alice's MacBook - 2026-07-05 17.58.00).pdf
```

The name preserves the extension, uses the current device name when available,
and is deterministic when the device name, date, and time zone are injected in
tests.

Conflict-copy success is recorded as `automaticallyResolved` with
`preservedBothAsRenamedConflictCopy`. Failed conflict-copy upload is recorded as
`failed` with `retainedStagedUploadAfterFailure` and a relative path under
`ConflictStaging`.

### Metadata Modifications

| Case | Current behavior | Resolution category | Gap or safer direction |
| --- | --- | --- | --- |
| Local rename vs unchanged remote metadata | The extension calls `renameItem(...)`, fetches the item again, and returns server metadata. | Delegated to kDrive after base-version match | Return `NSFileProviderError.filenameCollision` when a same-parent name collision is locally detectable. |
| Local move vs unchanged remote metadata | The extension calls `moveItem(...)`; move passes kDrive `conflict=rename`. | Delegated to kDrive after base-version match | Document and test exact kDrive rename result once the API behavior is confirmed. |
| Local rename or move vs remote rename, move, or metadata update | The metadata base version differs, so the extension does not mutate the server and returns `.cannotSynchronize` with a refresh/retry suggestion. | Blocked/retryable | Consider a richer recoverable error when the platform supports it. |
| Rename or move into an existing sibling name | Move delegates to kDrive with `conflict=rename`; rename has no provider-side sibling preflight. | Delegated to kDrive | Add local sibling lookup and collision mapping before mutating. |
| Rename swap, such as `a -> b` while `b -> a` | No provider-side bounce-rename strategy exists. | Unresolved/future work | Apple sample-style temporary bounce names can preserve both operations during swaps. |
| Move into a deleted or stale parent | Destination parent resolution may fail or kDrive may reject the move. | Delegated to kDrive/error mapping | Treat parent-deleted paths as recovery cases, especially when file bytes are involved. |
| Moving a parent while child changes are pending | There is no explicit child-sync barrier. | Unresolved/future work | Consider a File Provider barrier similar to the Apple sample's `waitForChanges(below:)` pattern. |

### Trash And Permanent Delete

| Case | Current behavior | Resolution category | Gap or safer direction |
| --- | --- | --- | --- |
| Trash vs unchanged remote item | The extension calls `trashItem(...)` after content and metadata versions match. | Delegated to kDrive after base-version match | Keep destructive operations guarded by both content and metadata checks. |
| Trash vs remote edit, rename, or move | The base version differs, so the extension does not mutate the server and returns `.cannotSynchronize`. | Blocked/retryable | A future UI can explain which remote change blocked the trash. |
| Permanent delete of trashed item vs unchanged remote item | The extension calls `deleteTrashedItem(...)` after content and metadata versions match. | Delegated to kDrive after base-version match | Keep permanent delete restricted to trash items. |
| Permanent delete vs remote edit, restore, rename, or move | The base version differs or the latest metadata fetch no longer matches, so the operation is blocked or mapped through `providerError(...)`. | Blocked/retryable or delegated error mapping | Map server rejection to File Provider's rejected-deletion shape where available. |
| Delete-delete or item already gone remotely | kDrive's response is mapped through `providerError(...)`; there is no local special-case success policy. | Delegated to kDrive/error mapping | Decide whether already-gone deletes should be treated as success for idempotency. |

On the current iOS File Provider target, stale destructive mutations are returned
as `.cannotSynchronize` with a recovery suggestion to refresh and retry. This is
the platform-compatible form of the intended "version no longer available"
behavior.

Stale rename, move, trash, and permanent delete attempts are recorded as
`blockedRetryable` with `blockedBeforeServerMutation`.

## Activities Tab

The app has an Activities tab backed by `Snapshots.sqlite3`.

- Conflict rows show the detection date, operation, resolution state, automatic
  resolution marker, summary, and file link when the File Provider item can be
  resolved.
- File links are resolved at display time from stored domain and item
  identifiers through `NSFileProviderManager.getUserVisibleURL(for:)`.
- The Last Activity toggle adds recent successful provider activity from the
  database, including enumeration/change sync and major item operations.
- The tab observes database changes with SQLite.swift's `updateHook` for its
  own connection and SQLite `PRAGMA data_version` polling for writes committed
  by the File Provider extension's separate connection.
- This is an audit/read model only. It does not replay failed operations or
  automatically retry retained staged uploads.

### Listing, Snapshot, And Sync State

| Case | Current behavior | Resolution category | Gap or safer direction |
| --- | --- | --- | --- |
| Advanced listing repeats a cursor | The listing validator throws before committing partial state. | Fail-closed | Keep this invariant so snapshots never advance on ambiguous pagination. |
| `hasMore == true` without a continuation cursor | The listing validator throws before committing partial state. | Fail-closed | Keep returning a recoverable File Provider error so enumeration can rebuild. |
| Unknown advanced action | The reducer throws rather than guessing. | Fail-closed | Add new action names only after mapping them to update or delete semantics. |
| Update action without matching item metadata | The reducer throws because it cannot emit a correct updated item. | Fail-closed | Keep delete actions as the only action kind allowed to omit metadata. |
| Two enumerators save the same container concurrently | Guarded snapshot saves require `.missing` or `.matching(anchor:serverCursor:)`; stale writers receive `KDriveSnapshotStoreError.staleSnapshot`. | Fail-closed | Keep guarded writes before emitting File Provider changes. |
| File Provider asks for stale sync anchor | Normal folder changes validate the stored `serverCursor`; special containers validate local snapshot anchors when possible. | Fail-closed or local rebuild | Prefer `.syncAnchorExpired` when the server cursor can no longer be trusted. |
| Invalid legacy listing loop | Repeated cursor or missing continuation cursor returns `.cannotSynchronize`. | Fail-closed | Keep special-container snapshots from committing partial listings. |

Invalid advanced change payloads return `.syncAnchorExpired`; invalid legacy
listing loops return `.cannotSynchronize`.

### Operational And Service Failures

| Case | Current behavior | Resolution category | Gap or safer direction |
| --- | --- | --- | --- |
| Network timeout before knowing whether the server succeeded | There is no provider-layer idempotency key, so retry behavior is mostly controlled by kDrive. | Unresolved/future work | Add a durable pending-operation journal with idempotency metadata. |
| OAuth missing or expired beyond refresh | Runtime loading fails and maps to a File Provider authentication error. | Blocked/retryable | Keep secrets out of logs and surface reauthentication through app-owned flows. |
| Server unreachable | URL/network errors map to `.serverUnreachable`. | Blocked/retryable | Preserve retryability and avoid committing local snapshot state during failures. |
| Insufficient quota | kDrive errors should map to provider errors when classified by the API layer. | Blocked/retryable | Ensure quota failures are surfaced as `.insufficientQuota` when possible. |
| File bytes disappear before upload completes | Only stale content conflict uploads are staged before upload. Normal creates/replaces read bytes and send them directly. | Unresolved/future work | Store local upload bytes durably before every network send. |

## Lessons From Other Projects

The current policy intentionally borrows the safest parts of other sync systems
without claiming feature parity.

- [Nextcloud conflicts](https://raw.githubusercontent.com/nextcloud/documentation/master/user_manual/desktop/conflicts.rst)
  and [ownCloud conflict docs](https://doc.owncloud.com/desktop/latest/conflicts.html)
  describe a conservative pattern: the base file follows the remote version,
  while the local edit is kept as a conflict copy that the user must merge.
- [Syncthing synchronization conflicts](https://docs.syncthing.net/users/syncing.html#conflicting-changes)
  explicitly covers edit/edit, edit/delete, case-sensitivity conflicts, and
  temporary files. Its conflict copies become normal files that sync onward.
- [Seafile file conflicts](https://help.seafile.com/syncing_client/file_conflicts/)
  preserves the first cloud-synced version and renames the other version with
  author and time information.
- Apple's local `SynchronizingFilesUsingFileProviderExtensions/` sample shows
  File Provider-specific tools that this project does not yet implement:
  `filenameCollision` errors, rejected deletion errors, conflict-version listing
  and keep-version actions, bounce renames for swaps, and barriers before moving
  parents with children still syncing.

The shared theme is data preservation first. When the provider cannot prove a
mutation is safe, it should preserve both versions, block and refresh, or fail
closed rather than silently overwrite remote or local work.

## Current Data-Loss Risk Summary

Lower risk today:

- Stale content replace, because the provider creates a renamed conflict copy.
- Stale rename, move, trash, and delete, because the provider blocks the server
  mutation before overwriting newer remote state.
- Cursor races, because guarded snapshot saves prevent stale cache writers from
  regressing stored cursor state.
- Malformed listing pages, because cursor/action anomalies fail closed.

Medium risk today:

- File create-create, because files use `conflict=version` and depend on kDrive
  version retention.
- Rename-to-existing-name, because sibling collision behavior is still delegated
  to kDrive unless the stale metadata check catches a concurrent change.
- Operation timeout after server success, because there is no idempotency or
  pending-operation journal.

Higher risk today:

- Folder create conflicts, because no explicit conflict policy is passed.
- Parent deleted while child is created or modified, because there is no
  recovered folder policy.
- Failed conflict upload recovery, because staged bytes are retained but not yet
  surfaced through an automatic retry UI.
- Case-only name conflicts, because there is no case-folded sibling policy.

## Recommended Safe Direction

For a data-loss-averse provider, future work should still:

1. Add a SQLite pending-operation journal for creates, modifies, deletes, and
   retries.
2. Store local upload bytes durably before every network send, not only stale
   content conflict copies.
3. Prefer `conflict=rename` for file creates when preserve-both is desired.
4. Pass an explicit directory conflict policy when creating folders.
5. Return `NSFileProviderError.filenameCollision` for local name collisions that
   File Provider can safely rename.
6. Move from timestamp-derived versions to authoritative kDrive revision tokens
   if available.
7. Treat parent-deleted scenarios as recovery cases with staged child contents.
8. Add case-normalized collision checks for create, rename, and move.
9. Consider bounce-rename handling for rename swaps.
10. Reconcile by stable item ID where possible, and by parent plus filename only
    before the server assigns an ID.

## Bottom Line

The three high-risk guardrails are now addressed for snapshot races, malformed
listing state, and stale existing-item mutations. The provider is still not a
full conflict-safe sync engine until pending operations, broader staged uploads,
explicit create collision handling, stronger server version tokens, and local
name-collision policy are in place.
