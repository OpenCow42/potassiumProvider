# Persistence

The app and extension share state through the configured app group and keychain
access group. The app group stores local account records, domain configuration,
and listing snapshots. The keychain stores account-scoped OAuth tokens.

## App Group Storage

The app group identifier is defined by `ProviderConstants.appGroupIdentifier`.

Current app group contents:

- `Accounts/*.json`
- `DomainConfigurations/*.json`
- `Snapshots.sqlite3`, including listing snapshots, conflict events, and recent
  provider/app activity
- `ConflictStaging/*.upload` while a stale-content conflict copy is being sent

## Accounts

`ProviderAccountFileStore` stores one JSON file per local `ProviderAccount`.
These records intentionally contain only local metadata:

- local account identifier
- user-editable display name
- authentication kind, either OAuth or manual access token
- local creation and update dates

Account records do not store remote Infomaniak account IDs, email addresses,
profile data, bearer tokens, refresh tokens, or ID tokens. Tokens are stored
separately in the keychain using the account identifier as part of the keychain
account name.

## DomainConfigurations

`DomainConfigurationFileStore` stores one JSON file per
`ProviderDomainConfiguration`.

These files are used by:

- the app, to list configured domains
- the extension, to load the drive ID, display name, domain ID, and root file ID
  for the active File Provider domain
- the extension, to load the account identifier used for account-scoped token
  lookup

Filenames are sanitized from domain identifiers. Removing a domain deletes its
configuration JSON after the File Provider domain is removed.

Legacy domain JSON that does not contain `accountIdentifier` decodes to the fixed
`legacy-account` local account. The app rewrites those configurations during
reload so future extension loads can use explicit account-scoped token lookup.

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

After successful local mutations, the extension removes affected container
snapshots and signals their File Provider enumerators so stale cached base
versions are rebuilt from kDrive instead of reused for later mutations.

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
- `scope`
- `outcome`
- `severity`
- `itemIdentifier`
- `itemName`
- `itemPath`
- `summary`
- `relatedConflictID`
- `errorCategory`
- `providerErrorCode`
- `underlyingErrorDomain`
- `underlyingErrorCode`
- `recoverySuggestion`
- `diagnosticSummary`

Conflict and activity tables are indexed by domain and event date. Activity rows
are also indexed by related conflict ID and outcome.

Activity rows support both domain-scoped provider events and app-scoped setup
events. App-scoped rows use `ProviderConstants.appActivityDomainIdentifier` and
`driveID = 0`, so domain cleanup does not remove app-level failures.

The app reads Status dashboard totals through aggregate protocols implemented by
the SQLite stores:

- `KDriveSnapshotStatisticsProviding` reports per-domain snapshot container
  counts, cached item row counts, fully enumerated containers, advanced-listing
  containers, and the latest snapshot update date.
- `KDriveProviderEventStatisticsProviding` reports per-domain conflict counts,
  retained success/failure activity counts, and latest conflict/activity dates.

These aggregate helpers are read-only and use the same sanitized local metadata
already stored for File Provider enumeration, conflict tracking, and activity
display. They do not expose OAuth tokens, remote account profile data, private
links, file bytes, or thumbnail bytes.

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
- recent sanitized provider/app failures needed by the app's activity timeline

Fully enumerated normal-folder snapshots can be served directly from SQLite on a
future initial enumeration.

## What Is Not Cached

SQLite does not cache:

- file bytes
- thumbnails
- OAuth tokens
- remote account profile data
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
identifiers, kDrive file paths returned by the API, relative staged-upload
paths, sanitized error categories, numeric error codes, recovery suggestions,
and short diagnostic summaries. They do not store OAuth tokens, raw API response
bodies, file bytes, private URLs, bearer-bearing request data, or generated web
links.

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
`removeSnapshots(domainIdentifier:)` and `removeEvents(domainIdentifier:)`.
That deletes all snapshot, conflict, and activity rows for the domain.

For local development resets, `scripts/uninstall-file-provider.sh` invokes the
signed app's hidden uninstall command. That command removes registered File
Provider domains through `NSFileProviderManager`, deletes matching
`DomainConfigurations` JSON files, and removes per-domain SQLite snapshot,
conflict, and activity rows. It preserves account records, `ConflictStaging`,
and account-scoped OAuth tokens by default;
`--hard-purge` removes `ConflictStaging`, and `--full-logout` or `--hard-purge`
deletes all account-scoped tokens, the legacy single-token key, and stored
account records. See
[File Provider Cleanup](FILE_PROVIDER_CLEANUP.md) for the full script behavior.

## Old JSON Snapshot Store

`KDriveSnapshotFileStore` still exists in `SnapshotStore.swift`, mainly as a
legacy/test-friendly implementation of `KDriveSnapshotStoring`. It is no longer
the default store for the app or extension. No migration from old JSON snapshots
is currently performed. The file store also honors conditional saves, which keeps
tests and fallback callers aligned with SQLite behavior.
