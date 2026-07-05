# Persistence

The app and extension share state through the configured app group and keychain
access group. The app group stores domain configuration and listing snapshots.
The keychain stores OAuth tokens.

## App Group Storage

The app group identifier is defined by `ProviderConstants.appGroupIdentifier`.

Current app group contents:

- `DomainConfigurations/*.json`
- `Snapshots.sqlite3`, including listing snapshots, conflict events, and recent
  provider activity
- `ConflictStaging/*.upload` while a stale-content conflict copy is being sent

## DomainConfigurations

`DomainConfigurationFileStore` stores one JSON file per
`ProviderDomainConfiguration`.

These files are used by:

- the app, to list configured domains
- the extension, to load the drive ID, display name, domain ID, and root file ID
  for the active File Provider domain

Filenames are sanitized from domain identifiers. Removing a domain deletes its
configuration JSON after the File Provider domain is removed.

## Snapshots.sqlite3

`KDriveSnapshotSQLiteStore` stores listing metadata snapshots. The same SQLite
file also stores provider conflict and activity events through
`KDriveProviderEventSQLiteStore`. It is the default snapshot/event database for
both the app and the extension.

On initialization, the store configures SQLite with:

- WAL journal mode, so readers and writers interfere less during File Provider
  callbacks
- a 5 second busy timeout, so short-lived concurrent writers can wait instead of
  failing immediately

The database has four tables.

`container_snapshots`:

- `domainIdentifier`
- `containerIdentifier`
- `anchor`
- `serverCursor`
- `isFullyEnumerated`
- `usesAdvancedListing`
- `updatedAt`

`snapshot_items`:

- `domainIdentifier`
- `containerIdentifier`
- `position`
- `itemID`
- `name`
- `type`
- `status`
- `driveID`
- `parentID`
- `path`
- `size`
- `mimeType`
- `createdAt`
- `modifiedAt`
- `itemUpdatedAt`

The primary key for `container_snapshots` is domain plus container. The primary
key for `snapshot_items` is domain plus container plus item ID.

`conflict_events`:

- `id`
- `detectedAt`
- `resolvedAt`
- `domainIdentifier`
- `driveID`
- `operation`
- `originalItemIdentifier`
- `originalItemName`
- `originalItemPath`
- `conflictItemIdentifier`
- `conflictItemName`
- `conflictItemPath`
- `resolutionState`
- `automaticallyResolved`
- `resolutionKind`
- `resolutionSummary`
- `stagedUploadRelativePath`

`provider_activity_events`:

- `id`
- `occurredAt`
- `domainIdentifier`
- `driveID`
- `kind`
- `itemIdentifier`
- `itemName`
- `itemPath`
- `summary`
- `relatedConflictID`

Conflict and activity tables are indexed by domain and event date. Activity rows
are also indexed by related conflict ID.

## What Is Cached

SQLite caches metadata needed to enumerate and diff containers:

- item IDs
- names
- parent IDs
- type/status
- size and MIME type
- timestamps used for File Provider versions
- advanced-listing cursor state
- whether the container has been fully enumerated
- conflict/audit metadata needed by the app's Activities tab
- recent successful provider activity needed by the app's activity timeline

Fully enumerated normal-folder snapshots can be served directly from SQLite on a
future initial enumeration.

## What Is Not Cached

SQLite does not cache:

- file bytes
- thumbnails
- OAuth tokens
- pending local operations
- kDrive version history
- private kDrive web URLs

File bytes returned from `fetchContents` are written to File Provider temporary
storage and handed back to the system.

The one file-byte exception is stale content conflict handling. Before uploading
a preserve-both conflict copy, the extension writes the local bytes to
`ConflictStaging` in the app group. The staged file is removed after the renamed
upload succeeds and is retained if the conflict upload fails, so the bytes are
not lost merely because the File Provider temporary URL disappears.

Conflict and activity rows may store local filenames, File Provider item
identifiers, kDrive file paths returned by the API, and relative staged-upload
paths. They do not store OAuth tokens, file bytes, or generated web links.

## Snapshot Replacement

Saving a snapshot can be unconditional or guarded by `KDriveSnapshotSaveCondition`.
The default legacy `save(...)` remains unconditional, while enumeration and
change paths use `.missing` or `.matching(anchor:serverCursor:)`.

When the condition is accepted, the store replaces the previous rows for that
domain/container in one SQLite transaction:

1. Delete existing item rows and container row.
2. Insert the new container snapshot row.
3. Insert item rows in snapshot order.

This keeps reads simple and avoids partial per-item update logic in the provider.
If the stored row no longer matches the requested condition, the store throws
`KDriveSnapshotStoreError.staleSnapshot` and leaves the newer snapshot intact.

## Domain Removal Cleanup

When the app removes a domain, it calls
`removeSnapshots(domainIdentifier:)` and `removeEvents(domainIdentifier:)`. That
deletes all snapshot, conflict, and activity rows for the domain.

## Old JSON Snapshot Store

`KDriveSnapshotFileStore` still exists in `SnapshotStore.swift`, mainly as a
legacy/test-friendly implementation of `KDriveSnapshotStoring`. It is no longer
the default store for the app or extension. No migration from old JSON snapshots
is currently performed. The file store also honors conditional saves, which keeps
tests and fallback callers aligned with SQLite behavior.
