# Mutations

Mutations are handled by `PotassiumFileProviderExtension` through Apple's
replicated File Provider callbacks. The extension sends each mutation directly
to kDrive and returns the server result to File Provider.

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
- Call `uploadFile(driveID:parentID:fileName:contents:lastModifiedAt:)`.
- Upload uses `conflict: "version"`.
- Return the created server item as `FileProviderItem`.

SQLite snapshots are not directly edited after create. The created item appears
in snapshots when enumeration or advanced listing changes see it.

## Modify Contents

When `modifyItem(...)` includes `.contents`:

- The extension reads the local contents URL.
- It calls `replaceFile(driveID:fileID:contents:lastModifiedAt:)`.
- Replace uses kDrive upload with `fileId` and `conflict: "version"`.
- The server-returned item is returned to File Provider.

The File Provider `baseVersion` is currently logged but not used to reject stale
writes.

## Rename

When `modifyItem(...)` includes `.filename` and not a parent change:

- The extension calls `renameItem(driveID:fileID:name:)`.
- It then fetches fresh item metadata with `item(...)`.
- The fetched item is returned to File Provider.

No local sibling-name preflight is currently performed.

## Move

When `modifyItem(...)` includes `.parentItemIdentifier`:

- The extension resolves the destination parent ID.
- It calls `moveItem(driveID:fileID:destinationParentID:name:)`.
- Move uses `conflict: "rename"`.
- If the filename also changed, the new name is sent with the move.
- The extension fetches fresh item metadata and returns it.

Move currently has the most preserve-both-friendly conflict flag because it asks
kDrive to rename on collision.

## Trash

When `modifyItem(...)` changes the parent to `.trashContainer`:

- The extension calls `trashItem(driveID:fileID:)`.
- It completes without returning an updated item.

Later enumeration reconciles the item removal from its old container and its
appearance in trash.

## Permanent Delete

`deleteItem(...)` is used for permanent deletion of an item already in trash:

- Resolve the kDrive file ID.
- Call `deleteTrashedItem(driveID:fileID:)`.
- Return success or a mapped error.

This does not delete regular non-trash items directly. Moving to trash is handled
through `modifyItem(...)`.

## Server-Authoritative Return Flow

The mutation callbacks trust the server response:

- Create and content replace return the `KDriveRemoteItem` returned by kDrive.
- Rename and move fetch the item again after the server operation.
- Trash and delete return success without directly editing snapshots.

This keeps the local provider from inventing metadata. It also means conflicts
and ambiguous outcomes are mostly controlled by kDrive behavior. See
[Conflicts](CONFLICTS.md).

## Reconciliation After Mutation

Normal folder metadata eventually reconciles through advanced listing:

- `file_create`, `file_update`, `file_rename`, `file_move`, and related actions
  update snapshot rows.
- `file_delete`, `file_trash`, and `file_move_out` delete snapshot rows.

Root, working set, and trash reconcile through full legacy listing plus local
diff.
