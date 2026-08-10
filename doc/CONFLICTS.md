# Conflict Cases And Resolution

This document provides the design narrative for conflict behavior in
`potassiumProvider`. The mission-critical, normative decision matrix and open
safety findings are maintained in
[Conflict Resolution Truth Table And Safety Register](CONFLICT_RESOLUTION_TRUTH_TABLE.md).
If these documents disagree, the audited truth table takes precedence and the
inconsistency must be corrected.

The provider is still mostly server-authoritative for final metadata: create,
replace, move, rename, trash, and delete requests are sent to kDrive, and server
responses are returned to File Provider. Content replacement is guarded by a
server ETag and `If-Match`; metadata follows the documented local-intent policy;
permanent delete remains preflight-only because no conditional delete is
documented by Infomaniak.

The listing cache introduced by `KDriveSnapshotSQLiteStore` is a metadata cache.
It helps enumerate folders and diff server changes, but it is not a full sync
database or durable pending-operation journal.

The same SQLite file now also stores a conflict/activity audit log. The app uses
that log for the Activities tab, including resolution state, whether a
conflict was automatically resolved, and local File Provider item identifiers
used to resolve clickable user-visible URLs.

Related docs:

- [Conflict Resolution Truth Table And Safety Register](CONFLICT_RESOLUTION_TRUTH_TABLE.md)
- [File Provider Lifecycle](FILE_PROVIDER_LIFECYCLE.md)
- [Listing And Versioning](LISTING_AND_VERSIONING.md)
- [Mutations](MUTATIONS.md)
- [Persistence](PERSISTENCE.md)

## Resolution Taxonomy

| Category | Meaning | Current examples |
| --- | --- | --- |
| Preserved both | Keep the remote item unchanged and save the local work as a separate item. | Stale content replacement uploads a renamed conflict copy. |
| Blocked/retryable | Refuse a mutation before changing kDrive, retain local bytes where applicable, then let File Provider refresh and retry. | `.failOnConflict`, transient upload failures, and stale permanent delete. |
| Automatic local-intent merge | Apply the user's same-field intent to the latest stable item ID and preserve independent remote fields. | Rename wins the name field; move-only preserves a remote rename; move uses `conflict=rename`. |
| Fail-closed | Treat ambiguous listing or cursor state as unsafe and stop before saving a bad snapshot. | Repeated cursors, missing continuation cursors, and unknown advanced actions throw. |
| Unresolved/future work | A known gap that needs a provider-owned retry schedule or a missing server primitive. | Recovered folders, unsupported metadata, large upload sessions, and conditional permanent delete. |

Audit states stored in SQLite:

| State | Meaning |
| --- | --- |
| `unresolved` | A stale content edit was detected and conflict-copy preservation has started. |
| `automaticallyResolved` | The provider completed a preserve-both action without user input. |
| `blockedRetryable` | The provider refused a stale mutation before changing kDrive. |
| `failed` | The intended conflict-copy preservation failed and staged bytes were retained when available. |

## Relevant Code Paths

- `potassiumProviderFileProvider/PotassiumFileProviderExtension.swift`
  - `createItem(...)`
  - `modifyItem(...)`
  - `deleteItem(...)`
- `PotassiumProviderCore/KDriveMutationCoordinator.swift`
  - conflict-sensitive create, replace, rename, move, trash, and delete
    decisions
- `PotassiumProviderCore/KDriveRemoteService.swift`
  - `uploadFile(...conflictStrategy:)`
  - `replaceFile(...)`
  - `createDirectory(...)`
  - `renameItem(...)`
  - `moveItem(...)`
  - `trashItem(...)`
  - `deleteTrashedItem(...)`
- `potassiumProviderFileProvider/FileProviderEnumerator.swift`
  - guarded snapshot writes and fail-closed listing validation
- `PotassiumProviderCore/KDriveModels.swift`
  - `KDriveListingValidator`
  - `KDriveAdvancedActionReducer`
  - `KDriveVersionConflictResolver`
  - `KDriveConflictFilename`

## Current Invariants

The implementation follows these practical rules:

1. The server is the source of truth for item identity and final metadata.
2. Local content bytes are staged before existing-item network preflight.
3. Content base versions compare stable item ID plus authoritative ETag.
4. Matching content replacement uses `file_id` plus `If-Match`; stale or raced
   content preserves both unless `.failOnConflict` was requested.
5. Rename, move, and trash apply local intent; permanent delete requires an
   unchanged strong base and returns `.deletionRejected` otherwise.
6. Later enumeration or change sync updates the SQLite snapshot from kDrive
   state.
7. Conflict-sensitive mutation decisions are covered by deterministic unit tests
   with a recording `KDriveFileProviding` fake and temporary conflict stager.

This is a focused conflict-safety pass, not the full sync-database redesign.

## Version Checks

`FileProviderItem` derives versions from kDrive metadata:

- `contentVersion`: versioned JSON containing item ID, ETag, `revisedAt`, and
  size. Item ID plus ETag are authoritative; legacy timestamps fail closed.
- `metadataVersion`: versioned JSON containing ID, `updatedAt`, name, and parent
  ID, with legacy decoding for rolling upgrades.

Before mutating an existing item, the extension fetches latest metadata with
`item(driveID:fileID:)` and compares the relevant base version:

- content replace checks item ID plus ETag and sends the ETag as `If-Match`
- rename and move apply the requested local fields to the latest stable item ID
- trash applies local intent because trash is recoverable
- permanent delete keeps content and metadata checks strict

Infomaniak documents `with=etag` on file/detail/listing routes and `If-Match` on
direct upload. The API does not document conditional rename, move, trash, or
permanent delete.

## Conflict Matrix

### Creates And Name Collisions

| Case | Current behavior | Resolution category | Gap or safer direction |
| --- | --- | --- | --- |
| New file vs existing file with same name | Upload uses `conflict=rename`, SHA-256, and deterministic `client_token`; both remain visible. | Preserved both automatically | Add identity reconciliation for `.mayAlreadyExist` to avoid safe but unnecessary duplicates. |
| New folder vs existing folder with same name | A recognized 409/422 collision retries with a conflict name. | Preserved both automatically | Live-validate every kDrive collision response shape; unrecognized rejection remains an error. |
| New file vs existing folder, or new folder vs existing file | File upload uses rename policy; directory collision retry is type-agnostic. | Preserved both or retryable error | Add explicit type-aware preflight for clearer results. |
| Case-only collisions, such as `Report.txt` vs `report.txt` | No case-folded sibling check exists today. Behavior depends on kDrive and the local platform view. | Unresolved/future work | Add case-normalized collision detection before create, rename, and move. |
| Local create retried after server success but local reply failed | File creates reuse a deterministic `client_token` and content hash. Directory create has no equivalent token. | Idempotent file retry; directory gap | Add provider-owned identity reconciliation and a directory replay primitive. |

### Content Modifications

| Case | Current behavior | Resolution category | Gap or safer direction |
| --- | --- | --- | --- |
| Local content edit vs unchanged remote content | Bytes are staged first, the current `(itemID, ETag)` is checked, then upload replaces by `file_id` with `If-Match`, SHA-256, and an idempotency token. | Automatic conditional replace | None for the direct-upload path; large upload sessions still need equivalent integration. |
| Local content edit vs remote content edit | The provider uploads a renamed conflict copy with `conflict=rename`, returns that item, and leaves the original untouched. | Preserved both automatically | The user may still need to compare or merge the visible files. |
| Local content edit vs remote rename or move | Replacement addresses the stable file ID. Metadata changes compose before content, and a move-only edit preserves an independent remote rename. | Automatic local-intent merge | kDrive does not document conditional rename/move, so same-field metadata is policy-based rather than transactional. |
| Local content edit vs remote trash or delete | Bytes are staged before lookup. A missing item or failed lookup returns an error without deleting the recovery copy. | Retryable with staged safety copy | A failure before conflict indexing can leave an unindexed staged file; provider-owned retry scheduling remains future work. |
| Failed conflict-copy upload | The deterministic staged copy remains; File Provider can retry, and Activities can reveal/export indexed copies. | Retryable plus user recovery | Add a provider-owned retry schedule and explicit “Retry now” action. |

Conflict names are generated by `KDriveConflictFilename`, for example:

```text
Report (conflict - Alice's MacBook - 2026-07-05 17.58.00).pdf
```

The name preserves the extension, uses the current device name when available,
and is deterministic when the device name, date, and time zone are injected in
tests.

Conflict-copy success is recorded as `automaticallyResolved` with
`preservedBothAsRenamedConflictCopy`. Failed conflict-copy upload is recorded as
`failed` with `retainedStagedUploadAfterFailure` and a relative path under
`ConflictStaging`.

### Metadata Modifications

| Case | Current behavior | Resolution category | Gap or safer direction |
| --- | --- | --- | --- |
| Local rename vs unchanged remote metadata or `updatedAt`-only drift | The extension calls `renameItem(...)`, fetches the item again, and returns server metadata. | Automatic local-intent merge | Keep collision response classification covered as the API evolves. |
| Retried local rename already reflected on the server | The extension treats the desired final name and parent as success and returns latest metadata without another server rename. | Idempotent success | Keep this limited to exact desired final state. |
| Local move vs unchanged remote metadata or `updatedAt`-only drift | The extension calls `moveItem(...)`; move passes kDrive `conflict=rename`. | Automatic local-intent merge | Document and live-test exact server-selected rename results. |
| Retried local move already reflected on the server | The extension treats the desired final parent and optional name as success and returns latest metadata without another server move. | Idempotent success | Keep this limited to exact desired final state. |
| Local rename vs remote rename or move | The requested local name is applied to the latest stable item ID; an independent remote parent move is preserved. | Automatic local-intent merge | The remote same-field name loses by explicit policy. |
| Move-only vs remote rename | The provider passes no name, so the remote rename is preserved while the local destination is applied. | Automatic field merge | Keep regression coverage for independent field composition. |
| Combined move+rename vs remote metadata | The requested local parent and name are applied to the latest stable item ID. | Automatic local-intent merge | Same-field remote metadata loses by explicit policy. |
| Rename or move into an existing sibling name | Move delegates to kDrive with `conflict=rename`; recognized rename collision responses retry with a unique conflict name. | Preserved both names automatically | Add case-folded/type-aware sibling lookup for clearer preflight behavior. |
| Rename swap, such as `a -> b` while `b -> a` | No provider-side bounce-rename strategy exists. | Unresolved/future work | Apple sample-style temporary bounce names can preserve both operations during swaps. |
| Move into a deleted or stale parent | Destination parent resolution may fail or kDrive may reject the move. | Delegated to kDrive/error mapping | Treat parent-deleted paths as recovery cases, especially when file bytes are involved. |
| Moving a parent while child changes are pending | There is no explicit child-sync barrier. | Unresolved/future work | Consider a File Provider barrier similar to the Apple sample's `waitForChanges(below:)` pattern. |

#### Move Coverage Checklist

These are the user-visible move shapes this provider should keep explicit in
tests or future support work:

| Move shape | Current support | Follow-up support to remember |
| --- | --- | --- |
| Move one item from parent `X` to parent `Y` while latest remote metadata still has the base name and parent, except `updatedAt` drift | Supported by stable-ID local intent. | Keep regression coverage for `updatedAt`-only drift. |
| Move several freshly created or uploaded folders into a new folder | Supported for folder `updatedAt` drift; successful mutations invalidate affected parent snapshots and signal File Provider containers. | Add a durable pending-operation journal if child uploads and parent moves need ordering across extension restarts. |
| File Provider retries a move that the server already applied | Supported as idempotent success when latest remote name and parent exactly match the requested final state. | Keep the success condition exact so unrelated remote moves do not pass. |
| Move and rename in one operation | Supported; both local same-field intents apply to the latest stable item ID. | Add case-folded/type-aware sibling collision checks before the server mutation. |
| Move requested but source is already in the requested parent with the requested name | Returned as idempotent success without another mutation. | Keep the desired-state check exact. |
| Remote renamed or moved the source somewhere else first | Local same-field intent wins; move-only preserves an independent remote rename. | Keep this explicit policy covered by tests. |
| Destination parent was deleted, trashed, or is otherwise unavailable | Parent resolution or the kDrive move call fails through normal error mapping. | Add parent-deleted recovery policy, especially for folders with pending child changes. |
| Move into an occupied sibling name, including case-only collisions | Delegated to kDrive for move with `conflict=rename`; rename has no provider-side sibling preflight. | Define local filename collision behavior for exact, case-folded, file/folder, and folder/folder collisions. |
| Move a folder while children below it still have pending uploads or modifications | `updatedAt` drift from child activity is tolerated, but there is no explicit subtree barrier. | Add a pending-operation barrier before moving parent folders when children are still syncing. |
| Cross-domain or cross-drive drag | Out of scope for the same-drive move API; File Provider should model this as create/delete or the server should reject it. | Define copy/delete reconciliation before supporting it as a semantic move. |
| Source item was deleted or trashed remotely before the local move | Latest metadata fetch or the server move call fails through normal error mapping. | Decide whether any already-gone cases can be treated as idempotent success for delete-like operations only. |

### Trash And Permanent Delete

| Case | Current behavior | Resolution category | Gap or safer direction |
| --- | --- | --- | --- |
| Trash vs unchanged remote item or `updatedAt`-only metadata drift | The extension calls `trashItem(...)` after applying other fields requested in the same callback. | Automatic local-intent mutation | Trash remains reversible. |
| Trash vs remote edit, rename, or move | The provider applies local trash intent to the latest stable item ID. | Automatic local-intent mutation | Restore from trash if the local intent was wrong. |
| Permanent delete of trashed item vs unchanged remote item or `updatedAt`-only metadata drift | The extension calls `deleteTrashedItem(...)` after content matches and item ID, name, and parent still match. | Delegated to kDrive after semantic base-version match | Keep permanent delete restricted to trash items. |
| Permanent delete vs remote edit, restore, rename, or move | The provider rejects deletion before mutation and returns `.deletionRejected` with the latest item. | Rejected safely for user review | Infomaniak still documents no conditional delete, so a post-preflight race remains. |
| Delete-delete or item already gone remotely | A 404 latest lookup is treated as idempotent success. | Idempotent success | Keep this limited to authoritative not-found responses. |

Stale permanent delete is the destructive case that deliberately needs user
review: `.deletionRejected` lets File Provider recreate the latest server item.
Rename, move, and trash follow the automatic local-intent policy above.

## Activities Tab

The app has an Activities tab backed by `Snapshots.sqlite3`.

- The timeline loads 50 mixed conflict/activity entries initially and
  automatically prefetches older keyset-paged entries near the end. Appending
  history and merging live database changes preserve the visible event anchor.
- Entries are grouped by day and use compact summaries. Expanding an entry
  reveals conflict state, diagnostics, recovery guidance, identifiers, copy,
  and item actions without making every row expensive to render.
- Unresolved staged uploads older than 24 hours display **Needs Attention**.
  Indexed staged bytes can be revealed in Finder on macOS or exported through
  the share sheet on iOS and visionOS; paths are accepted only from the app
  group's `ConflictStaging` directory.
- File links are resolved from stored domain and item identifiers through
  `NSFileProviderManager.getUserVisibleURL(for:)` only after the user selects
  **Open in Finder** on macOS or **Open in Files** on iOS and visionOS.
  macOS then asks `NSWorkspace` to reveal and select the item in Finder rather
  than opening the document in its default app. Resolution or Finder-selection
  failures show an inline message explaining that the item may have moved or
  been deleted. A rejected Files presentation on iOS or visionOS also returns
  the row to a retryable state and displays an inline unavailable-item message.
  Scrolling the timeline does not perform File Provider URL lookups.
- The default Errors filter shows conflicts and non-conflict failure activity.
  All Activity also includes successful enumeration, change sync, and item
  operations.
- New live entries are merged silently without moving a user who is reading
  older history. **Back to Latest** returns to the newest entry.
- The Clear button removes activity event rows and automatically resolved
  conflict rows while preserving unresolved, blocked, and failed conflict rows.
  Clear is exclusive with loading, refresh, and export; the reader returns to
  the newest position only after the store confirms that clearing succeeded.
- The Export button creates a redacted JSON support log. It pseudonymizes
  identifiers and omits item names, paths, staged-upload paths, and raw conflict
  identifiers. Export and Refresh may run together because both are read-only.
- Action failures use a dismissible banner above every timeline state,
  including empty, initial-error, and unavailable-database views. Paging errors
  remain attached to the paging footer. Copy feedback changes to **Copied**
  only after the platform clipboard accepts the write; a rejected write stays
  retryable and displays an inline error.
- Failure rows store sanitized diagnostics such as category, severity, mapped
  provider error code, underlying error domain/code, recovery suggestion, and a
  short diagnostic summary. They do not store tokens or raw response bodies.
- App setup and domain-management failures are app-scoped rows. They are shown
  as app activity and do not attempt File Provider item-link resolution.
- The tab observes database changes with SQLite.swift's `updateHook` for its
  own connection and SQLite `PRAGMA data_version` polling for writes committed
  by the File Provider extension's separate connection. Bursts are coalesced
  before the newest page is refreshed.
- This is an audit/read model only. It does not replay failed operations or
  automatically retry retained staged uploads.

For unified-log categories, durable activity fields, retention, and support
export privacy rules, see [Logging](LOGGING.md).

### Listing, Snapshot, And Sync State

| Case | Current behavior | Resolution category | Gap or safer direction |
| --- | --- | --- | --- |
| Advanced listing repeats a cursor | The listing validator throws before committing partial state. | Fail-closed | Keep this invariant so snapshots never advance on ambiguous pagination. |
| `hasMore == true` without a continuation cursor | The listing validator throws before committing partial state. | Fail-closed | Keep returning a recoverable File Provider error so enumeration can rebuild. |
| Unknown advanced action | The reducer throws rather than guessing. | Fail-closed | Add new action names only after mapping them to update or delete semantics. |
| Update action without matching item metadata | The reducer throws because it cannot emit a correct updated item. | Fail-closed | Keep delete actions as the only action kind allowed to omit metadata. |
| Two enumerators save the same container concurrently | Guarded snapshot saves require `.missing` or `.matching(anchor:serverCursor:)`; stale writers receive `KDriveSnapshotStoreError.staleSnapshot`. | Fail-closed | Keep guarded writes before emitting File Provider changes. |
| File Provider asks for stale sync anchor | Normal folder changes validate the stored `serverCursor`; special containers validate local snapshot anchors when possible. | Fail-closed or local rebuild | Prefer `.syncAnchorExpired` when the server cursor can no longer be trusted. |
| Invalid legacy listing loop | Repeated cursor or missing continuation cursor returns `.cannotSynchronize`. | Fail-closed | Keep special-container snapshots from committing partial listings. |

Invalid advanced change payloads return `.syncAnchorExpired`; invalid legacy
listing loops return `.cannotSynchronize`.

### Operational And Service Failures

| Case | Current behavior | Resolution category | Gap or safer direction |
| --- | --- | --- | --- |
| Network timeout before knowing whether the server succeeded | Direct file create/replace/conflict-copy requests reuse deterministic tokens and hashes; staged content remains after failures. | Idempotent retry at API boundary | Add a provider-owned pending scheduler and equivalent large-upload-session support. |
| OAuth missing or expired beyond refresh | Runtime loading fails and maps to a File Provider authentication error. | Blocked/retryable | Keep secrets out of logs and surface reauthentication through app-owned flows. |
| Server unreachable | URL/network errors map to `.serverUnreachable`. | Blocked/retryable | Preserve retryability and avoid committing local snapshot state during failures. |
| Insufficient quota | kDrive errors should map to provider errors when classified by the API layer. | Blocked/retryable | Ensure quota failures are surfaced as `.insufficientQuota` when possible. |
| File Provider callback URL disappears before upload completes | File creates and existing-item replacement copy the bytes into deterministic app-group staging before the network request. | Provider-owned bytes retained | Index preflight/create failures in a complete pending-operation journal. |

## Lessons From Other Projects

The current policy intentionally borrows the safest parts of other sync systems
without claiming feature parity.

- [Nextcloud conflicts](https://raw.githubusercontent.com/nextcloud/documentation/master/user_manual/desktop/conflicts.rst)
  and [ownCloud conflict docs](https://doc.owncloud.com/desktop/latest/conflicts.html)
  describe a conservative pattern: the base file follows the remote version,
  while the local edit is kept as a conflict copy that the user must merge.
- [Syncthing synchronization conflicts](https://docs.syncthing.net/users/syncing.html#conflicting-changes)
  explicitly covers edit/edit, edit/delete, case-sensitivity conflicts, and
  temporary files. Its conflict copies become normal files that sync onward.
- [Seafile file conflicts](https://help.seafile.com/syncing_client/file_conflicts/)
  preserves the first cloud-synced version and renames the other version with
  author and time information.
- Apple's local `SynchronizingFilesUsingFileProviderExtensions/` sample shows
  File Provider-specific tools that this project does not yet implement:
  conflict-version listing and keep-version actions, bounce renames for swaps,
  and barriers before moving parents with children still syncing. This provider
  now handles common collisions automatically and uses rejected deletion for a
  stale permanent delete.

The shared theme is data preservation first. When the provider cannot prove a
mutation is safe, it should preserve both versions, block and refresh, or fail
closed rather than silently overwrite remote or local work.

## Current Data-Loss Risk Summary

Lower risk today:

- Stale and raced content replacement, because the provider uses ETag/If-Match
  and creates a renamed conflict copy.
- Rename, move, and trash conflicts, because local intent is applied to stable
  IDs and collisions preserve both.
- Stale permanent delete, because it is blocked and returned as
  `.deletionRejected`.
- Cursor races, because guarded snapshot saves prevent stale cache writers from
  regressing stored cursor state.
- Malformed listing pages, because cursor/action anomalies fail closed.

Medium risk today:

- Provider restart after repeated upload failure, because bytes survive but
  retry scheduling still belongs to File Provider.
- Directory creates, because the API offers no provider idempotency token.
- Case-only collisions, because there is no case-folded sibling policy.

Higher risk today:

- Permanent delete still has a fetch-then-delete race because Infomaniak does
  not document conditional ETag deletion.
- Failed preflight requests retain staged bytes but cannot always index a
  recovery event before remote metadata (especially the parent) is known.
- Unsupported File Provider metadata is returned as still pending but has no
  kDrive/local metadata implementation, which can produce a soft lock.
- Parent deleted while child is created or modified, because there is no
  recovered-folder policy.

## Recommended Safe Direction

For a data-loss-averse provider, future work should still:

1. Add a provider-owned pending-operation scheduler with exponential backoff,
   indefinite retry, a 24-hour Needs Attention transition, and Retry Now.
2. Add type-aware and case-normalized collision preflight.
3. Treat parent-deleted scenarios as recovered-folder cases with staged child
   contents.
4. Add conditional/revision parity for large upload sessions.
5. Seek or design a conditional permanent-delete contract with Infomaniak.
6. Add bounce-rename handling for rename swaps.
7. Implement or explicitly reject every unsupported File Provider metadata
   field so it cannot remain pending forever.

## Bottom Line

Guardrails are now in place for strong content versions, conditional content
replacement, collision-safe creates, combined fields, fail-on-conflict,
deletion rejection, staged recovery copies, error-resolution signalling,
snapshot races, and malformed listings. The provider is still not a complete
conflict-safe sync engine until provider-owned retry scheduling, recovered
folders, unsupported-metadata handling, large-upload conditional parity, and a
conditional permanent-delete primitive are addressed. The maintained finding
list is in
[Conflict Resolution Truth Table And Safety Register](CONFLICT_RESOLUTION_TRUTH_TABLE.md).
