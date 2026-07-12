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

Listing snapshots use three active tables:

`snapshot_heads` identifies the active generation for each domain/container.

`snapshot_generations` stores immutable metadata for each generation:

- domain and container identifiers
- monotonically increasing generation number
- local anchor and optional server cursor
- fully-enumerated and advanced-listing flags
- commit timestamp

`snapshot_generation_items` stores the ordered item metadata for a particular
generation. Its primary key is domain, container, generation, and item ID.

The active generation and its two predecessors are retained. That keeps item
and change page tokens stable while a newer snapshot commits, while deliberately
expiring tokens and anchors older than the retained window.

The following legacy tables remain present solely for safe in-place migration.
Initialization transactionally moves each legacy container into generation 1
and deletes the migrated legacy rows without changing the working-set, conflict,
or activity tables:

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

New writes use only the generation tables. Domain cleanup removes both legacy
and generation rows.

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
- `correlationID`
- `durationMilliseconds`
- `networkOperation`
- `httpStatusCode`
- `remoteRequestID`

Conflict and activity tables are indexed by domain and event date. Activity rows
are also indexed by related conflict ID, outcome, and correlation ID. Activity
rows are bounded to the newest 5,000 records by default; conflict rows are not
removed by this retention rule.

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
- materialized file and directory identifiers
- working-set membership and anchor
- the last poll attempt and successful-poll watermark
- up to 32 working-set change batches used to advance valid older anchors

Fully enumerated normal-folder snapshots are served from SQLite in stable
keyset pages of at most 200 items. Page tokens bind the domain, container,
generation, and last item position. Snapshot metadata and individual item
lookups do not materialize the full container.

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

The Activities support-log export is a separate redacted JSON view of this data.
It pseudonymizes identifiers with a fresh per-export salt and omits filenames,
paths, staged-upload paths, and raw identifiers. See [Logging](LOGGING.md).

## Snapshot Replacement

Saving a snapshot can be unconditional or guarded by `KDriveSnapshotSaveCondition`.
The default legacy `save(...)` remains unconditional, while enumeration and
change paths use `.missing` or `.matching(anchor:serverCursor:)`.

When the condition is accepted, the store commits a new immutable generation in
one SQLite transaction:

1. Insert generation metadata, including the anchor and server cursor.
2. Insert item membership rows in snapshot order.
3. Point the container head at the completed generation.
4. Remove generations outside the active-plus-two retention window.

Readers therefore see either the complete old generation or the complete new
one; a failed insert cannot expose partial membership or an advanced cursor.
If the stored row no longer matches the requested condition, the store throws
`KDriveSnapshotStoreError.staleSnapshot` and leaves the newer snapshot intact.

Working-set polling extends that transaction boundary across all materialized
containers involved in one poll. Their new snapshot generations and advanced
cursors commit in the same SQLite transaction as the working-set membership,
change batch, anchor, and successful-poll watermark. If partial activity,
another remote request, or a guarded snapshot update fails, no container cursor
from that poll is published.

Change enumeration compares retained source and target generations in bounded
keyset scans. Its token records both generations, update/delete phase, and final
scanned item ID, avoiding whole-container dictionaries and sets.

## Domain Removal Cleanup

When the app removes a domain, it calls
`removeSnapshots(domainIdentifier:)` and `removeEvents(domainIdentifier:)`.
That deletes all snapshot, materialization, working-set poll/change, conflict,
and activity rows for the domain.

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
