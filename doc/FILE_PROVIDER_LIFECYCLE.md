# File Provider Lifecycle

The extension implements `NSFileProviderReplicatedExtension`. The system owns the
local file-provider storage and calls the extension when it needs metadata,
bytes, mutations, or enumeration.

## Runtime Loading

Most callbacks begin by loading `FileProviderRuntime`:

1. Load the domain configuration from app group JSON.
2. Load the account-scoped OAuth token from keychain using the domain
   configuration's `accountIdentifier`.
3. Refresh that account's token when needed and possible.
4. Create `PotassiumKDriveService`.
5. Open `KDriveSnapshotSQLiteStore`.

If configuration or credentials are missing, the callback fails with a mapped
File Provider error. Runtime-loading and authentication failures are also
recorded as sanitized failure activity when the activity database can be opened.

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
- Return a cancellable file-kind `Progress` immediately so Finder can present a
  download operation before runtime or network setup finishes.
- Wait for the shared content-transfer limiter. The extension permits one
  whole-file download, create upload, or replacement upload at a time.
- Fetch metadata and reject a requested content version that is no longer
  available.
- Create `downloadFileOperation(...)`, attach its live URL session progress to
  the returned parent, and await its bytes.
- Fetch metadata again and reject bytes whose content version changed during
  the download.
- Write bytes to `manager.temporaryDirectoryURL()` using a unique temporary
  filename, then release the limiter permit. Remove the file if cancellation
  wins the completion race.
- Return the temporary URL and matching `FileProviderItem`.

SQLite: not touched. SQLite stores listing metadata only, not file contents.

## `createItem`

Purpose: create a new file or folder from a File Provider template.

Behavior:

- Resolve the parent File Provider identifier to a kDrive parent ID.
- For folders, call `createDirectory(...)`.
- For files, expose upload byte progress, read the provided contents with mapped
  storage where available, and call `uploadFileOperation(...)` under the shared
  transfer permit.
- Return the server-created `KDriveRemoteItem` as a `FileProviderItem`.

SQLite: not updated directly. Listing/change enumeration later reconciles the
server-created item into snapshots.

## `modifyItem`

Purpose: update contents, parent, name, or metadata for an existing item.

Behavior:

- If the item is moved to `.trashContainer`, call `trashItem(...)` and return.
- If `.contents` changed, expose upload byte progress, read the local contents
  URL with mapped storage where available, and call `replaceFileOperation(...)`
  under the shared transfer permit.
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

## Progress and Cancellation

Every replicated-extension callback returns a parent `Progress` synchronously
and retains its Swift task until one terminal callback wins. Metadata-only work
uses one discrete unit. File work uses byte units, `.file` kind, the appropriate
upload/download operation kind, and the local URL when available.

The parent adopts potassiumChannel's live `URLSessionTask.progress` as a child.
Cancelling it cancels the retained Swift task and then the underlying request.
Success, failure, and cancellation are gated so File Provider completion
handlers run exactly once. Failed and cancelled progress remains incomplete.

Whole-file `Data` remains the transfer representation in 0.2.0. The shared
single-transfer permit bounds concurrent buffers, but one large file can still
determine peak memory. Streaming and upload sessions remain deferred.

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

The extension uses the same mapping decision to create a sanitized activity
diagnostic. File Provider callback behavior stays unchanged: recording failures
is best-effort, database write errors are sent only to `OSLog`, and the original
mapped callback error is still returned to the system.

Generic failure activity is recorded at File Provider callback boundaries:

- metadata lookups
- content fetches
- creates, modifies, trashes, and deletes
- item enumeration, change enumeration, and sync-anchor lookup
- thumbnail requests
- runtime loading, snapshot invalidation, and enumerator signaling

Cancellations are not recorded as failures. Conflict-specific failures that
already have `conflict_events` rows, such as stale mutation blocks and failed
conflict-copy uploads, are not duplicated as generic failure activity.
