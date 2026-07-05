# Persistence

The app and extension share state through the configured app group and keychain
access group. The app group stores domain configuration and listing snapshots.
The keychain stores OAuth tokens.

## App Group Storage

The app group identifier is defined by `ProviderConstants.appGroupIdentifier`.

Current app group contents:

- `DomainConfigurations/*.json`
- `Snapshots.sqlite3`

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

`KDriveSnapshotSQLiteStore` stores listing metadata snapshots. It is the default
snapshot store for both the app and the extension.

The database has two tables.

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

Fully enumerated normal-folder snapshots can be served directly from SQLite on a
future initial enumeration.

## What Is Not Cached

SQLite does not cache:

- file bytes
- thumbnails
- OAuth tokens
- pending local operations
- conflict copies
- kDrive version history

File bytes returned from `fetchContents` are written to File Provider temporary
storage and handed back to the system.

## Snapshot Replacement

Saving a snapshot replaces the previous rows for that domain/container in one
SQLite transaction:

1. Delete existing item rows and container row.
2. Insert the new container snapshot row.
3. Insert item rows in snapshot order.

This keeps reads simple and avoids partial per-item update logic in the provider.

## Domain Removal Cleanup

When the app removes a domain, it calls
`removeSnapshots(domainIdentifier:)`. That deletes all `snapshot_items` and
`container_snapshots` rows for the domain.

## Old JSON Snapshot Store

`KDriveSnapshotFileStore` still exists in `SnapshotStore.swift`, mainly as a
legacy/test-friendly implementation of `KDriveSnapshotStoring`. It is no longer
the default store for the app or extension. No migration from old JSON snapshots
is currently performed.
