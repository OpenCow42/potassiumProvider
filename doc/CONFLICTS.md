# Current Conflict Resolution

This document describes the conflict behavior that exists today in
`potassiumProvider`.

The current implementation is mostly server-authoritative. The File Provider
extension forwards create, modify, move, rename, trash, and delete operations to
kDrive, then returns the server result to the system. It does not currently keep
a durable local operation journal, perform full preflight conflict detection, or
materialize local conflict copies before upload.

The listing cache introduced by `KDriveSnapshotSQLiteStore` is a metadata cache.
It helps enumerate folders and diff server changes, but it is not a conflict
resolver and it does not store file contents.

Related docs:

- [File Provider Lifecycle](FILE_PROVIDER_LIFECYCLE.md)
- [Listing And Versioning](LISTING_AND_VERSIONING.md)
- [Mutations](MUTATIONS.md)
- [Persistence](PERSISTENCE.md)

## Relevant Code Paths

- `potassiumProviderFileProvider/PotassiumFileProviderExtension.swift`
  - `createItem(...)`
  - `modifyItem(...)`
  - `deleteItem(...)`
- `PotassiumProviderCore/KDriveRemoteService.swift`
  - `uploadFile(...)`
  - `replaceFile(...)`
  - `createDirectory(...)`
  - `renameItem(...)`
  - `moveItem(...)`
  - `trashItem(...)`
  - `deleteTrashedItem(...)`
- `potassiumProviderFileProvider/FileProviderEnumerator.swift`
  - advanced listing and snapshot reconciliation
- `PotassiumProviderCore/KDriveModels.swift`
  - `KDriveAdvancedActionReducer`

## Current Principles

The implementation currently follows these practical rules:

1. The server is the source of truth for item identity and final metadata.
2. Local mutations are sent directly to kDrive.
3. Server responses are returned to File Provider as the created or modified item.
4. Later enumeration or change sync updates the SQLite snapshot from kDrive state.
5. Name, version, and concurrent-write conflicts are delegated to kDrive unless
   the current operation explicitly handles them.

This means the app currently favors simplicity and server behavior over
preserve-both conflict handling.

## Create Conflicts

### File Create Versus Existing File With Same Name

Flow:

1. File Provider calls `createItem(...)`.
2. The extension resolves the parent kDrive folder ID.
3. For files, it reads the temporary local contents.
4. It calls `runtime.remote.uploadFile(...)`.
5. `PotassiumKDriveService.uploadFile(...)` sends
   `UploadKDriveFileOptions(conflict: "version", directoryId: parentID, fileName:
   itemTemplate.filename, ...)`.

Current behavior:

- The extension does not preflight the parent listing for an existing sibling
  with the same name.
- The extension does not return `NSFileProviderError.filenameCollision`.
- The extension does not create a local conflict copy.
- kDrive receives `conflict=version` and decides the final result.
- The server-returned `KDriveRemoteItem` is returned to File Provider.

Data-safety note:

This is not a preserve-both strategy at the provider layer. It relies on kDrive
server-side versioning to preserve previous bytes. If server version history is
not exposed, not durable enough, or not what the user expects, this can feel like
an overwrite.

### File Create Versus Existing Folder With Same Name

Flow:

Same as file create: `createItem(...)` uploads the file with
`conflict=version`.

Current behavior:

- There is no explicit local handling for "file conflicts with folder".
- The result depends on how kDrive treats an upload with a name already occupied
  by a folder in the same parent.
- Any error is mapped through `providerError(...)` and returned to File Provider.

Data-safety note:

This is ambiguous today. A safer implementation should treat file/folder name
collisions as hard collisions and preserve both by renaming the new item or
returning a filename collision error.

### Folder Create Versus Existing Folder Or File With Same Name

Flow:

1. File Provider calls `createItem(...)`.
2. The extension detects that the item template conforms to folder.
3. It calls `runtime.remote.createDirectory(...)`.
4. `PotassiumKDriveService.createDirectory(...)` sends
   `CreateKDriveDirectoryOptions(name: name)`.

Current behavior:

- No explicit `conflict` option is passed for directory creation.
- The extension does not preflight for existing siblings.
- The extension does not return `NSFileProviderError.filenameCollision`.
- The extension relies on kDrive default behavior.

Data-safety note:

This is weaker than file creation because the desired conflict policy is not
explicit. The current behavior may succeed, fail, merge, or rename depending on
server defaults.

See [Mutations](MUTATIONS.md) for the create flow details.

## Modify Conflicts

### Local Content Modify Versus Remote Content Modify

Flow:

1. File Provider calls `modifyItem(...)` with `.contents`.
2. The extension resolves the item ID from `item.itemIdentifier`.
3. It reads the new local contents.
4. It calls `runtime.remote.replaceFile(...)`.
5. `PotassiumKDriveService.replaceFile(...)` uploads with
   `UploadKDriveFileOptions(conflict: "version", fileId: fileID, ...)`.

Current behavior:

- The provided File Provider `baseVersion` is logged but not used for conflict
  validation.
- The extension does not compare the local base version with a stored remote
  version before upload.
- The extension does not fetch latest metadata to detect that the server changed
  since the local edit began.
- kDrive receives a targeted upload to the existing file ID with
  `conflict=version`.

Data-safety note:

This relies on kDrive versioning. It does not create a separate conflict file
when both local and remote changed. If the server treats the upload as a new
version, both byte streams may be recoverable through server history, but the
provider itself does not guarantee preserve-both semantics.

See [Listing And Versioning](LISTING_AND_VERSIONING.md) for how
`NSFileProviderItemVersion` is currently derived.

### Metadata Modify Without Content

Current behavior:

- Rename calls `renameItem(...)`.
- Move calls `moveItem(...)`.
- Move plus rename calls `moveItem(...)` with the requested name.
- If no recognized changed field is present, the extension refetches the item
  metadata.

The extension does not currently compare the requested metadata change with
concurrent server-side metadata changes.

## Rename Conflicts

### Rename To A Name Already Used In The Same Parent

Flow:

1. File Provider calls `modifyItem(...)` with `.filename`.
2. The extension calls `runtime.remote.renameItem(...)`.
3. `PotassiumKDriveService.renameItem(...)` calls kDrive rename without a local
   preflight.

Current behavior:

- No local sibling-name check.
- No local conflict-copy generation.
- No `filenameCollision` response.
- The server decides whether the rename succeeds, fails, replaces, or applies a
  server-side policy.

Data-safety note:

The safe desired behavior would be to avoid replacing another item. Today that
guarantee is delegated to kDrive.

## Move Conflicts

### Move Into A Folder With A Same-Named Item

Flow:

1. File Provider calls `modifyItem(...)` with `.parentItemIdentifier`.
2. The extension resolves the destination parent ID.
3. It calls `runtime.remote.moveItem(...)`.
4. `PotassiumKDriveService.moveItem(...)` sends `MoveKDriveFileOptions(conflict:
   "rename", name: name)`.

Current behavior:

- Move operations explicitly request `conflict=rename`.
- This is the safest current conflict behavior in the app.
- The server should preserve both by renaming the moved item if a collision
  exists, subject to kDrive's interpretation of `conflict=rename`.

Data-safety note:

This is preserve-both in intent. The app still does not perform local preflight
or locally generate the conflict name; it trusts kDrive to do that.

### Move While Remote Also Moved Same Item

Current behavior:

- The extension sends the local move to kDrive by item ID.
- It does not compare the current remote parent against the local base parent.
- The final parent is whatever kDrive accepts.
- Later advanced listing actions update the SQLite metadata snapshot.

Data-safety note:

This may collapse two independent move decisions into one server-authoritative
result. It should not lose file bytes, but it can lose user intent.

## Delete Conflicts

### Delete Versus Delete

Current behavior:

- Delete is effectively idempotent from the user perspective if kDrive accepts
  the operation or reports that the item no longer exists in a recoverable way.
- The provider does not have special delete-delete handling.

### Local Delete Or Trash Versus Remote Modify

Flow:

- Moving an item to `.trashContainer` in File Provider triggers
  `runtime.remote.trashItem(...)`.
- Permanently deleting a trashed item triggers
  `runtime.remote.deleteTrashedItem(...)`.

Current behavior:

- The extension does not check whether the item changed remotely after the local
  base version.
- The extension does not preserve a local copy before trashing or deleting.
- The server action is treated as authoritative.

Data-safety note:

This can be unsafe if a remote edit happened concurrently with a local delete.
A safer policy would detect the newer remote version and either block the delete,
surface a conflict, or preserve the edited item.

### Remote Delete Versus Local Modify

Current behavior:

- If the local modify targets an item ID that the server has deleted, kDrive may
  return an error.
- The extension maps the error through `providerError(...)`.
- There is no local recovery copy or pending operation journal.

Data-safety note:

This is a risky class. If local edited bytes only exist in the temporary URL
given to `modifyItem(...)`, the provider should preserve them before returning a
failure. It does not currently do that.

## Parent Folder Conflicts

### Parent Deleted While Child Is Created Or Modified Locally

Current behavior:

- The extension resolves the parent ID and sends the child create/modify to
  kDrive.
- If the parent no longer exists, kDrive returns an error.
- The provider maps the error and returns failure.
- It does not recreate the parent, create a recovered folder, or preserve a
  local copy of child contents.

Data-safety note:

This is another risky class for offline or concurrent workflows. A safer
implementation should preserve the child content in a recovered folder or a
conflict copy.

## Listing And Snapshot Conflicts

### Advanced Listing Actions

Normal folders use advanced listing for enumeration and change sync.

The action reducer currently maps:

- delete actions:
  - `file_delete`
  - `file_trash`
  - `file_move_out`
- update actions:
  - `file_create`
  - `file_rename`
  - `file_move`
  - `file_restore`
  - `file_update`
  - favorite, share, collaboration, color, and category changes

Current behavior:

- The reducer processes the first action seen for each file ID as the newest
  action.
- Delete actions remove by file ID even if the response has no matching
  `actions_files` entry.
- Update actions require a matching `actions_files` item. If missing, the action
  is ignored while cursor progress can still continue.
- The SQLite snapshot is updated from the reduced result.

Data-safety note:

This affects metadata visibility, not local bytes. It can still affect user
trust if a server action is skipped because an update lacks `actions_files`.

See [Persistence](PERSISTENCE.md) for the SQLite snapshot shape.

### Invalid Advanced Listing Cursor

Current behavior:

- During normal folder item enumeration, an invalid continuation cursor causes
  the folder to restart from initial advanced listing and replace the snapshot.
- During normal folder change enumeration, an invalid cursor rebuilds the folder
  through advanced listing and local-diffs against the old SQLite snapshot.
- If there is no usable advanced snapshot for change enumeration, the provider
  returns `.syncAnchorExpired`.

Data-safety note:

This is a metadata recovery path. It is conservative enough for listing state,
but it does not resolve mutation conflicts.

## Retry And Ambiguous Success Conflicts

### Operation Succeeds On Server But The Extension Times Out

Current behavior:

- There is no durable pending-operation table.
- There are no idempotency keys in the provider layer.
- Retrying a create may send another create/upload request.
- For file creates, `conflict=version` may turn a retry into another version.
- For folder creates, behavior depends on server defaults.

Data-safety note:

This can create duplicates, unexpected versions, or errors. It is usually safer
than silently dropping data, but it can confuse users and complicate later sync.

## Current Data-Loss Risk Summary

Lower risk today:

- Move into name collision, because moves use `conflict=rename`.
- Delete-delete, assuming server delete operations are idempotent or mapped
  cleanly.
- Metadata snapshot cursor invalidation, because the app rebuilds listings.

Medium risk today:

- File create-create, because files use `conflict=version` and depend on kDrive
  version retention.
- File modify-modify, for the same reason.
- Rename conflicts, because server behavior is authoritative.

Higher risk today:

- Folder create conflicts, because no explicit conflict policy is passed.
- Remote delete versus local modify, because local bytes are not durably
  preserved before failure.
- Parent deleted while child is created or modified, because the local child is
  not saved into a recovery area.
- Operation timeout after server success, because there is no idempotency or
  pending-operation journal.

## Recommended Safe Direction

For a data-loss-averse provider, prefer these future policies:

1. Preserve both sides whenever item content might differ.
2. Use `conflict=rename` for file creates unless the user explicitly chooses to
   create a new server version.
3. Pass an explicit directory conflict policy when creating folders.
4. Return `NSFileProviderError.filenameCollision` for local name collisions that
   File Provider can safely rename.
5. Use `baseVersion` and stored remote metadata to detect modify-modify
   conflicts before upload.
6. Add a SQLite pending-operation journal for creates, modifies, deletes, and
   retries.
7. Store local upload bytes durably before sending operations that may fail after
   the temporary File Provider URL disappears.
8. Treat delete versus modify as a conflict, not as an automatic delete.
9. Generate deterministic conflict names, for example:
   `Report (conflict - This Mac - 2026-07-05).pdf`.
10. Reconcile by stable item ID where possible, and by parent plus filename only
    when the server has not assigned an ID yet.

## Bottom Line

The current implementation is functional but not yet fully conflict-safe. It
delegates most conflict resolution to kDrive and uses server-returned metadata as
truth. For maximum safety, the next iteration should add explicit preserve-both
handling, durable pending operations, and local detection around File Provider
`baseVersion`.
