# File Provider Lifecycle

The extension implements `NSFileProviderReplicatedExtension`. The system owns the
local file-provider storage and calls the extension when it needs metadata,
bytes, mutations, or enumeration.

## Local And External Storage

On macOS 15 or later, the containing app can create a domain with Apple's
[`NSFileProviderDomain(displayName:userInfo:volumeURL:)`](https://developer.apple.com/documentation/fileprovider/nsfileproviderdomain/init(displayname:userinfo:volumeurl:))
initializer. `volumeURL` is the normalized volume root. It tells File Provider
which volume should hold the system-managed domain; it does not select a folder
inside that volume and does not map an arbitrary local folder into kDrive.

The app first calls
[`NSFileProviderManager.checkDomainsCanBeStoredOnVolume(at:)`](https://developer.apple.com/documentation/fileprovider/nsfileprovidermanager/checkdomainscanbestoredonvolume(at:)).
Eligible targets are writable, local, encrypted APFS volumes. The implementation
maps Apple's complete unsupported-reason set: unknown, non-APFS, unencrypted,
read-only, network, and quarantined. Security-scoped access obtained by the
picker remains balanced and covers preparation plus registration; the selected
folder URL is used only for the security-scoped access grant while the operation
uses its volume root.

Apple generates the external domain identifier. The app saves that exact value
as the configuration's current `domainIdentifier` and always passes the same
prepared `NSFileProviderDomain` instance to registration. Existing external
operations look up the registered system domain by that identifier instead of
reconstructing one.

The opaque external-domain `userInfo` has two non-secret fields: binding schema
version and stable `configurationIdentifier`. It contains no account identifier,
credential, path, URL, or customer data. The extension's
`NSFileProviderExternalVolumeHandling` connection callback approves the domain
only when this Mac has the matching configuration, the generated domain ID and
volume UUID agree, and the associated keychain credential is usable. Otherwise
it fails closed as not authenticated.

## Runtime Loading

Most callbacks begin by loading `FileProviderRuntime`:

1. Load the domain configuration from app group JSON. Local domains resolve by
   current domain identifier; external domains resolve by the stable opaque
   configuration binding and verify the generated domain ID and volume UUID.
2. Load the account-scoped OAuth token from keychain using the domain
   configuration's `accountIdentifier`.
3. Refresh that account's token when needed and possible.
4. Create `PotassiumKDriveService`.
5. Open `KDriveSnapshotSQLiteStore`.

If configuration or credentials are missing, the callback fails with a mapped
File Provider error. Runtime-loading and authentication failures are also
recorded as sanitized failure activity when the activity database can be opened.

External placement state is refreshed from registered domains and mounted-volume
identity. A missing external registration with an absent configured volume is
reported as External Drive Disconnected. A connected volume with a missing or
mismatched domain, or a durable interrupted relocation, is reported as Needs
Repair. Registering and Moving remain informational. The app blocks removal and
account logout while the external volume is unavailable so it does not delete
local identity or credentials before system-domain cleanup can finish.

## Desktop & Documents Known Folders

On macOS 15 or later, registered domains advertise support for Desktop and
Documents together. The app owns explicit claim/release controls and reads
`NSFileProviderDomain.replicatedKnownFolders` for live state; this state is not
stored in app-group JSON or SQLite.

The extension adopts `NSFileProviderKnownFolderSupporting` on macOS.
`getKnownFolderLocations` resolves the existing root-level kDrive directory
named `Private`, then returns `Desktop` and `Documents` locations with that
directory as their shared parent. It returns locations only for the folders
requested by macOS. A missing or non-directory `Private` item fails closed.

Apple's [`NSFileProviderKnownFolderSupporting`](https://developer.apple.com/documentation/fileprovider/nsfileproviderknownfoldersupporting)
documentation is the source of truth for this callback and transition behavior.

File Provider reuses existing directory children or creates them at those
locations, keeps its default binary-compatibility symlink behavior, and manages
the local known-folder transition. Ordinary enumeration and mutation callbacks
then synchronize their contents like other provider items.

A storage move records whether known folders were active, releases both before
the source domain is removed, and attempts to reclaim both after the target is
registered. Consent may be required again. Failure to reclaim is a durable
repair state; it does not erase the successful storage placement.

## Storage Change Lifecycle

File Provider has no in-place placement change, so the app uses a durable
remove-and-recreate transaction:

1. Write a relocation journal and wait for source stabilization.
2. Release active Desktop & Documents and persist that phase.
3. Prepare the exact target domain and journal its generated/current domain ID.
4. Remove the source with `.preserveDirtyUserData`; surface any returned
   preserved-data URL to the user.
5. Save the new `domainIdentifier` and storage location under the unchanged
   `configurationIdentifier`, then register the exact prepared target.
6. Delete snapshot/event state keyed by the old domain identifier.
7. Reclaim known folders and remove the journal only when all required work is
   complete.

If the target cannot be registered after source removal, recovery attempts to
recreate the original placement; recovering an external source requires the
same volume UUID to be mounted. Relaunch converts any unfinished journal into a
Needs Repair state. Repair can finish cleanup for an already registered target,
recreate a missing target/source as the journal allows, or retry known-folder
reclaim. It never guesses based only on a volume display name.

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
  available. macOS receives `.versionNoLongerAvailable`; platforms where that
  File Provider error is unavailable receive the retryable `.cannotSynchronize`.
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

## Materialization And Remote Discovery

`materializedItemsDidChange` acknowledges File Provider immediately and then
enumerates the system-owned materialized set in the background. The identifiers
and container flags are persisted in SQLite. The active extension performs a
domain-throttled working-set poll every 60 seconds and signals only
`.workingSet` when it finds remote changes. Local mutations also invalidate the
affected cached snapshots and signal `.workingSet`, rather than signaling root,
trash, or arbitrary folder enumerators.

This release intentionally uses client polling only. File Provider can receive
updates late when the containing app and extension are suspended.

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
