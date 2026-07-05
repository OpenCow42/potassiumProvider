# File Provider Lifecycle

The extension implements `NSFileProviderReplicatedExtension`. The system owns the
local file-provider storage and calls the extension when it needs metadata,
bytes, mutations, or enumeration.

## Runtime Loading

Most callbacks begin by loading `FileProviderRuntime`:

1. Load the domain configuration from app group JSON.
2. Load the OAuth token from keychain.
3. Refresh the token when needed and possible.
4. Create `PotassiumKDriveService`.
5. Open `KDriveSnapshotSQLiteStore`.

If configuration or credentials are missing, the callback fails with a mapped
File Provider error.

## `item(for:)`

Purpose: resolve metadata for one item identifier.

Behavior:

- `.rootContainer` returns a synthetic `FileProviderItem` from
  `ProviderDomainConfiguration`.
- Other identifiers are parsed as `KDriveItemIdentifier.item(fileID)`.
- The extension calls `PotassiumKDriveService.item(...)`, which uses
  `KDriveService.getFile(...)`.
- The result is wrapped as `FileProviderItem`.

SQLite: not touched.

## `fetchContents`

Purpose: materialize file bytes for a file the system wants to open or download.

Behavior:

- Parse the File Provider item identifier into a kDrive file ID.
- Call `downloadFile(...)`.
- Fetch fresh metadata through `item(...)`.
- Write bytes to `manager.temporaryDirectoryURL()` using a unique temporary
  filename.
- Return the temporary URL and updated `FileProviderItem`.

SQLite: not touched. SQLite stores listing metadata only, not file contents.

## `createItem`

Purpose: create a new file or folder from a File Provider template.

Behavior:

- Resolve the parent File Provider identifier to a kDrive parent ID.
- For folders, call `createDirectory(...)`.
- For files, read the provided local contents URL and call `uploadFile(...)`.
- Return the server-created `KDriveRemoteItem` as a `FileProviderItem`.

SQLite: not updated directly. Listing/change enumeration later reconciles the
server-created item into snapshots.

## `modifyItem`

Purpose: update contents, parent, name, or metadata for an existing item.

Behavior:

- If the item is moved to `.trashContainer`, call `trashItem(...)` and return.
- If `.contents` changed, read the local contents URL and call
  `replaceFile(...)`.
- If parent changed, call `moveItem(...)`; if the filename also changed, pass
  the new name in the move options.
- If only the filename changed, call `renameItem(...)`.
- Otherwise fetch latest metadata with `item(...)`.
- Return the server-updated item when one is available.

SQLite: not updated directly. Later enumeration/change sync reconciles metadata.

## `deleteItem`

Purpose: permanently remove an item already in trash.

Behavior:

- Parse the item ID.
- Call `deleteTrashedItem(...)`.
- Return success or a mapped error.

SQLite: not updated directly. Later trash/root/folder enumeration reconciles the
missing item.

## `enumerator(for:)`

Purpose: create an `NSFileProviderEnumerator` for a container.

Behavior:

- The extension returns `FileProviderEnumerator`.
- The enumerator later handles `enumerateItems`, `currentSyncAnchor`, and
  `enumerateChanges`.

SQLite: enumeration uses SQLite for metadata snapshots and advanced-listing
state. See [Listing And Versioning](LISTING_AND_VERSIONING.md).

## Error Mapping

`providerError(...)` preserves existing `NSFileProviderError` values, maps URL
errors to `.serverUnreachable`, preserves Cocoa/File Provider errors, and wraps
unexpected errors as an XPC reply invalid error.
