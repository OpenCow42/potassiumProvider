# Mutations

Mutations enter through `PotassiumFileProviderExtension` via Apple's replicated
File Provider callbacks. The extension is the File Provider adapter: it loads
runtime state, converts File Provider inputs, records activity/conflict audit
events, and delegates conflict-sensitive kDrive decisions to
`KDriveMutationCoordinator` in `PotassiumProviderCore`.

The current implementation does not maintain its own pending-operation
scheduler; retry cadence remains delegated to File Provider. File content bytes
are staged durably before create upload or existing-item mutation preflight.
SQLite snapshots are not updated
directly after mutations; later enumeration reconciles kDrive state.

## Create

`createItem(...)` handles both files and folders.

For folders:

- Resolve the parent File Provider identifier to a kDrive parent ID.
- Call `createDirectory(driveID:parentID:name:)`.
- Return the created `KDriveRemoteItem` as `FileProviderItem`.

For files:

- Resolve the parent File Provider identifier to a kDrive parent ID.
- Read bytes from the local contents URL supplied by File Provider.
- Stage the bytes deterministically in app-group `ConflictStaging` before the
  first network send.
- Call `uploadFile(driveID:parentID:fileName:contents:lastModifiedAt:conflictStrategy:)`.
- Upload uses `conflict: "rename"`, a SHA-256 `total_chunk_hash`, and a
  deterministic `client_token`, so a collision preserves both visible files
  and replay is idempotent at the API boundary.
- Remove the staged copy only after the server confirms success; retain it if
  request construction or upload fails.
- Return the created server item as `FileProviderItem`.

SQLite snapshots are not directly edited after create. The created item appears
in snapshots when enumeration or advanced listing changes see it.

## Modify Contents

When `modifyItem(...)` includes `.contents`, `KDriveMutationCoordinator`:

- Stages the local bytes in app-group `ConflictStaging` before any network
  preflight.
- Computes a SHA-256 `total_chunk_hash` and deterministic `client_token`.
- Fetches the latest kDrive metadata with `with=etag`.
- Compares the File Provider content `baseVersion` with the latest remote
  content version by stable item ID and authoritative ETag. Legacy timestamp
  versions and missing ETags fail closed into preserve-both handling.
- If the versions match, calls
  `replaceFile(driveID:fileID:expectedETag:clientToken:contentHash:...)`.
- Replacement uses kDrive upload with `file_id` and `If-Match`, not a
  potentially stale parent/name pair.
- The server-returned item is returned to File Provider.
- If remote content changed, or a 409/412 conditional race is lost, uploads the
  staged bytes as a renamed conflict copy with `conflict: "rename"`.
  The original remote item is left untouched and the conflict item is returned.
- If File Provider requests `.failOnConflict`, no conflict copy is uploaded;
  `.localVersionConflictingWithServer` is returned and staged bytes remain for
  user recovery.
- Successful replacement or conflict-copy upload removes the staged bytes.
- Failed uploads retain a deterministic staged copy. File Provider can retry
  the callback, and indexed copies can be revealed/exported from Activities.

`modifyItem(...)` applies combined fields in this order: move/rename, contents,
standalone modification date, then trash. It returns every unapplied field in
`stillPendingFields` instead of acknowledging it as completed.

The provider does not yet maintain a provider-owned retry schedule. See
[Persistence](PERSISTENCE.md).

The exact decision matrix, combined-field behavior, and open data-safety
findings are maintained in
[Conflict Resolution Truth Table And Safety Register](CONFLICT_RESOLUTION_TRUTH_TABLE.md).

## Base-Version Checks

`KDriveVersionConflictResolver` compares the incoming
`NSFileProviderItemVersion` with freshly fetched `KDriveRemoteItem` versions:

- content replacement checks the authoritative `(itemID, ETag)` tuple
- rename, move, and trash apply local intent to the latest stable item ID
- permanent delete checks both authoritative content and metadata versions

Stale permanent deletes throw `KDriveMutationConflictError.staleVersion` before
the server mutation. The adapter returns `.deletionRejected` with the latest
trashed item so File Provider can recreate it. Already-missing deletes succeed
idempotently.

## Rename

When `modifyItem(...)` includes `.filename` and not a parent change:

- The extension fetches fresh item metadata and applies the local name to the
  stable item ID (local same-field intent wins).
- A recognized 409/422 collision retries with a deterministic conflict name.
- It then fetches fresh item metadata with `item(...)`.
- The fetched item is returned to File Provider.

No local sibling-name preflight is currently performed.

## Move

When `modifyItem(...)` includes `.parentItemIdentifier`:

- The extension fetches fresh metadata and resolves the destination parent ID.
- It calls `moveItem(driveID:fileID:destinationParentID:name:)`.
- Move uses `conflict: "rename"`.
- If the filename also changed, the local name is sent with the move. For a
  move-only request, an independent remote rename is preserved.
- The extension fetches fresh item metadata and returns it.

Move still has the most preserve-both-friendly server conflict flag because it
asks kDrive to rename on collision.

## Trash

When `modifyItem(...)` changes the parent to `.trashContainer`:

- The extension fetches fresh item metadata.
- It applies the local trash intent to the stable item ID. Concurrent remote
  edits are preserved in trash and remain restorable.
- For combined content+trash, content is replaced or preserved as a conflict
  copy before both affected items are moved to trash.
- It completes without returning an updated item.

Later enumeration reconciles the item removal from its old container and its
appearance in trash.

## Permanent Delete

`deleteItem(...)` is used for permanent deletion of an item already in trash:

- Resolve the kDrive file ID.
- Fetch fresh item metadata.
- Compare both content and metadata base versions with the latest remote
  versions.
- If the versions match, call `deleteTrashedItem(driveID:fileID:)`.
- If the item changed, return File Provider's `.deletionRejected` error with the
  latest trashed item so the system can restore local consistency.
- If the item is already absent, return idempotent success.

This does not delete regular non-trash items directly. Moving to trash is handled
through `modifyItem(...)`.

Stale deletes are blocked before server mutation. Infomaniak does not document
a conditional ETag parameter for the permanent-delete endpoint, so a final
fetch-to-delete race remains a known limitation.

## Server-Authoritative Return Flow

The mutation callbacks still use server state for returned metadata:

- Create and non-conflicted content replace return the `KDriveRemoteItem`
  returned by kDrive.
- Stale content replace returns the renamed conflict item returned by kDrive.
- Rename and move fetch the item again after the server operation.
- Trash and delete return success without directly editing snapshots.

This keeps the local provider from inventing metadata. Conditional ETag upload
closes the content replacement race; metadata applies the selected local-intent
policy; permanent deletion retains a documented residual race. See
[Conflicts](CONFLICTS.md).

## Reconciliation After Mutation

Normal folder metadata eventually reconciles through advanced listing:

- `file_create`, `file_update`, `file_rename`, `file_move`, and related actions
  update snapshot rows.
- `file_delete`, `file_trash`, and `file_move_out` delete snapshot rows.

Root, working set, and trash reconcile through full legacy listing plus local
diff.
