# Mutations

Mutations are handled by `PotassiumFileProviderExtension` through Apple's
replicated File Provider callbacks. The extension sends each mutation directly to
kDrive and returns server metadata to File Provider.

The current implementation does not maintain a durable pending-operation queue.
It also does not update SQLite snapshots directly after mutations. Instead,
later listing or change enumeration reconciles snapshots from kDrive state.

## Create

`createItem(...)` handles both files and folders.

For folders:

- Resolve the parent File Provider identifier to a kDrive parent ID.
- Call `createDirectory(driveID:parentID:name:)`.
- Return the created `KDriveRemoteItem` as `FileProviderItem`.

For files:

- Resolve the parent File Provider identifier to a kDrive parent ID.
- Read bytes from the local contents URL supplied by File Provider.
- Call `uploadFile(driveID:parentID:fileName:contents:lastModifiedAt:conflictStrategy:)`.
- Upload uses `conflict: "version"`.
- Return the created server item as `FileProviderItem`.

SQLite snapshots are not directly edited after create. The created item appears
in snapshots when enumeration or advanced listing changes see it.

## Modify Contents

When `modifyItem(...)` includes `.contents`:

- The extension fetches the latest kDrive item metadata.
- It compares the File Provider content `baseVersion` with the latest remote
  content version.
- If the versions match, it reads the local contents URL and calls
  `replaceFile(driveID:fileID:contents:lastModifiedAt:)`.
- Replace uses kDrive upload with `fileId` and `conflict: "version"`.
- The server-returned item is returned to File Provider.
- If the remote content changed, the extension stages the local bytes in the app
  group and uploads them as a renamed conflict copy with `conflict: "rename"`.
  The original remote item is left untouched and the conflict item is returned.

The provider does not yet maintain a durable pending-operation table for the
staged conflict upload. See [Persistence](PERSISTENCE.md).

## Base-Version Checks

`KDriveVersionConflictResolver` compares the incoming
`NSFileProviderItemVersion` with freshly fetched `KDriveRemoteItem` versions:

- content replacement checks `contentVersion`
- rename and move check `metadataVersion`
- trash and permanent delete check both content and metadata versions

Stale metadata, trash, and delete mutations are blocked before sending a server
mutation. On the current target, this is returned as `.cannotSynchronize` with a
recovery suggestion to refresh and retry.

## Rename

When `modifyItem(...)` includes `.filename` and not a parent change:

- The extension fetches fresh item metadata.
- It compares the File Provider metadata `baseVersion` with the latest remote
  metadata version.
- If the versions match, it calls `renameItem(driveID:fileID:name:)`.
- It then fetches fresh item metadata with `item(...)`.
- The fetched item is returned to File Provider.

No local sibling-name preflight is currently performed.

## Move

When `modifyItem(...)` includes `.parentItemIdentifier`:

- The extension fetches fresh item metadata.
- It compares the File Provider metadata `baseVersion` with the latest remote
  metadata version.
- If the versions match, it resolves the destination parent ID.
- It calls `moveItem(driveID:fileID:destinationParentID:name:)`.
- Move uses `conflict: "rename"`.
- If the filename also changed, the new name is sent with the move.
- The extension fetches fresh item metadata and returns it.

Move still has the most preserve-both-friendly server conflict flag because it
asks kDrive to rename on collision.

## Trash

When `modifyItem(...)` changes the parent to `.trashContainer`:

- The extension fetches fresh item metadata.
- It compares both content and metadata base versions with the latest remote
  versions.
- If the versions match, it calls `trashItem(driveID:fileID:)`.
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
- Return success or a mapped error.

This does not delete regular non-trash items directly. Moving to trash is handled
through `modifyItem(...)`.

Stale deletes are blocked before server mutation.

## Server-Authoritative Return Flow

The mutation callbacks still use server state for returned metadata:

- Create and non-conflicted content replace return the `KDriveRemoteItem`
  returned by kDrive.
- Stale content replace returns the renamed conflict item returned by kDrive.
- Rename and move fetch the item again after the server operation.
- Trash and delete return success without directly editing snapshots.

This keeps the local provider from inventing metadata, while the base-version
preflight prevents stale destructive or metadata mutations from overwriting newer
remote state. See [Conflicts](CONFLICTS.md).

## Reconciliation After Mutation

Normal folder metadata eventually reconciles through advanced listing:

- `file_create`, `file_update`, `file_rename`, `file_move`, and related actions
  update snapshot rows.
- `file_delete`, `file_trash`, and `file_move_out` delete snapshot rows.

Root, working set, and trash reconcile through full legacy listing plus local
diff.
