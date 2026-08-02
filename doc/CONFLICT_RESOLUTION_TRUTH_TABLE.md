# Conflict Resolution Truth Table And Safety Register

> [!IMPORTANT]
> This is a mission-critical data-safety document. It must describe the behavior
> of the current implementation, including known unsafe or incomplete paths. Any
> change that can alter conflict detection, mutation ordering, server conflict
> policy, retry behavior, or user recovery must update this file in the same
> change.

This document is the normative conflict-resolution truth table and open safety
register for `potassiumProvider`. [Conflict Cases And Resolution](CONFLICTS.md)
provides the broader design narrative; when the two documents disagree, this
audited truth table takes precedence and the inconsistency must be corrected.

## Audit Status

- Last source audit: 2026-08-02
- Audited baseline: `codex/conflict-resolution-hardening` working tree
- Validation:
  - `potassiumChannel`: `swift test` — 558 tests passed
  - macOS: `KDriveMutationCoordinatorTests` — 25 tests passed (the selected
    test plan executes this suite twice)
  - macOS app build passed with code signing disabled
  - iOS Simulator app build passed on iPhone 17 / iOS 26.5 with code signing
    disabled
  - generic visionOS app build passed with code signing disabled
  - Full macOS unit run: conflict/version/recovery tests passed; three existing
    snapshot-store tests were flaky under parallel execution and the full
    scheme UI runner could not finish because the host disk was full
- Live kDrive collision validation: not performed; server-dependent behavior is
  identified explicitly below
- Finding state vocabulary: **Open**, **Mitigated**, or **Resolved**

Unit tests validate isolated coordinator operations, including a remote change
between preflight and conditional upload. They do not yet invoke combined File
Provider `changedFields` through an end-to-end extension callback or prove
system retry/backoff behavior across extension restarts.

## Scope And Evidence

The table is derived from these implementation boundaries:

- [`PotassiumFileProviderExtension`](../potassiumProviderFileProvider/PotassiumFileProviderExtension.swift)
  dispatches create, modify, trash, and delete callbacks and reports their
  completion state to File Provider.
- [`KDriveMutationCoordinator`](../PotassiumProviderCore/KDriveMutationCoordinator.swift)
  compares base versions and selects mutation or conflict-copy behavior.
- [`KDriveVersionConflictResolver`](../PotassiumProviderCore/KDriveModels.swift)
  defines content and metadata equality.
- [`PotassiumKDriveService`](../PotassiumProviderCore/KDriveRemoteService.swift)
  selects kDrive conflict flags and constructs requests.
- [`FileProviderRuntime`](../potassiumProviderFileProvider/FileProviderRuntime.swift)
  maps provider and API failures to File Provider errors.
- [`FileProviderEnumerator`](../potassiumProviderFileProvider/FileProviderEnumerator.swift)
  validates listing, cursor, and snapshot state.
- [`ProviderEventStore`](../PotassiumProviderCore/ProviderEventStore.swift) and
  the Activities UI record conflict state but do not replay failed mutations.

Apple's replicated File Provider contract is also normative:

- [`modifyItem`](https://developer.apple.com/documentation/fileprovider/nsfileproviderreplicatedextension/modifyitem(_:baseversion:changedfields:contents:options:request:completionhandler:))
  may contain content, filename, and parent changes together. Filename and
  contents must be synchronized together, and unapplied fields must be returned
  as still pending.
- [`deletionRejected`](https://developer.apple.com/documentation/fileprovider/nsfileprovidererror/deletionrejected)
  lets the system recreate a deletion that the provider rejected.
- [`filenameCollision`](https://developer.apple.com/documentation/fileprovider/nsfileprovidererror/code/filenamecollision)
  lets the system resolve a collision and retry.

Infomaniak's public API contract documents the primitives used here:

- [`Get File/Directory`](https://developer.infomaniak.com/docs/api/get/3/drive/%7Bdrive_id%7D/files/%7Bfile_id%7D)
  and [`Get files in directory`](https://developer.infomaniak.com/docs/api/get/3/drive/%7Bdrive_id%7D/files/%7Bfile_id%7D/files)
  list `etag` as an opt-in `with` resource and return `revised_at`.
- [`Upload`](https://developer.infomaniak.com/docs/api/post/3/drive/%7Bdrive_id%7D/upload)
  documents `If-Match` as the ETag of a specific file version, accepts stable
  `file_id`, `client_token`, and `total_chunk_hash`, and can return `etag`.
- Infomaniak does not specify one exclusive stale-`If-Match` response status;
  the provider treats both HTTP 409 and 412 as conditional conflicts.
- No conditional ETag parameter is documented for rename, move, trash, or
  permanent delete. That absence is why permanent-delete race risk remains
  explicitly open.

## Predicate Legend

| Symbol | Meaning |
| --- | --- |
| `C` | The versioned File Provider base contains the same stable item ID and authoritative ETag as the latest remote item. |
| `B` | The base item ID, name, and parent equal the latest remote state. `updatedAt`-only drift is ignored. |
| `D` | The latest remote name and parent already equal the requested final state. |
| `U` | The selected remote mutation or upload succeeds. |

`contentVersion` is versioned JSON. Item ID plus ETag are authoritative;
`revisedAt` and size are diagnostic. Legacy timestamp versions and missing
ETags fail closed into preserve-both or `.failOnConflict` behavior.

## Core Mutation Truth Table

| Request or conflict | Predicate | Current action | Server mutation | Data-loss assessment | User recovery |
| --- | --- | --- | --- | --- | --- |
| New file with no collision known locally | Always | Stage first, then upload by parent/name with `conflict=rename`, SHA-256, and deterministic `client_token`; request `with=etag`. Remove the stage only after success. | Creates an item | Low. The returned server item is authoritative and replay uses the same token. | None if successful; a failed create retains an unindexed staged copy. |
| New file collides with an existing name or type | Server applies rename policy | Create a visible uniquely named item; never request server-side overwrite/versioning. | Creates a second item | Low byte-loss risk; a safe duplicate is possible for `.mayAlreadyExist`. | Compare/delete the duplicate if it represents the same file. |
| New directory collides by name or type | Recognized HTTP 409, or named 422 collision | Retry once with a conflict filename. | Creates a second directory | Low byte-loss risk, but response-shape coverage is not live-validated. | Rename/merge folders if the response was not recognized. |
| Local content edit; remote unchanged | `C`, conditional upload succeeds | Stage first, then replace by `file_id` with `If-Match`, SHA-256, and deterministic token; remove stage only after success. | Conditional content replace | Low. A remote race cannot silently pass the checked ETag. | None. |
| Remote changes after preflight | `C`, conditional upload rejects with 409/412 | Refetch and upload a renamed conflict copy from the same staged bytes. | Creates a second item | Low. Both versions are preserved. | Compare or merge the visible files. |
| Local content edit vs already-changed remote content | `!C && U` | Upload a renamed conflict copy and leave the original unchanged. | Creates a second item | Low. Both versions are preserved. | Compare or merge the visible files. |
| `.failOnConflict` content conflict | `!C`, or conditional 409/412 | Do not mutate kDrive; return `.localVersionConflictingWithServer`; keep staged bytes and record recovery path. | No | Low immediate loss risk. This is intentional user-intervention behavior. | Reveal/export recovery copy, compare versions, then retry the desired change. |
| Staging fails | Stage write fails before any server mutation | Propagate local storage failure. | No | High: provider could not obtain its own durable copy, though File Provider still owns the callback URL. | Free local space and retry; no provider copy exists. |
| Preflight lookup fails after staging | `item(...)` fails | Return mapped retryable error and retain deterministic staged bytes. | No | Medium: bytes survive, but an event cannot always be indexed without authoritative parent metadata. | Let File Provider retry; unindexed copies require support/developer recovery. |
| Replace/conflict upload fails after staging | `!U` | Return mapped retryable error; retain stage; indexed conflict failures appear in Activities. | No confirmed success | Low immediate loss risk; provider-owned scheduling is still absent. | File Provider retries; Activities can reveal/export indexed recovery bytes. |
| Rename vs remote rename/move | Stable file ID exists | Local name intent wins. Retry a recognized collision with a unique conflict name, then refetch. | Renames item | Low byte-loss risk. The remote same-field name loses by explicit policy. | Inspect final unique name; no byte merge required. |
| Retried rename already reflected remotely | `D` | Return latest item without another mutation. | No | Safe idempotent success. | None. |
| Move-only vs remote rename | Destination differs; local name unchanged | Move stable ID with `name=nil`, preserving the remote rename; kDrive uses `conflict=rename`. | Moves item | Low. Independent fields merge automatically. | None. |
| Combined move+rename vs remote metadata | Stable file ID exists | Local destination and name win; move uses `conflict=rename`; refetch authoritative item. | Moves/renames item | Low byte-loss risk. Same-field metadata follows explicit local intent. | Inspect server-selected unique name if collision occurs. |
| Trash vs remote content/metadata | Stable file ID exists | Apply local trash intent after other requested fields. Remote bytes remain recoverable in trash. | Trashes item | Low immediate risk; trash is reversible. | Restore from trash if the intent was wrong. |
| Permanent delete; remote matches base | `C && B` | Delete trashed item by stable ID. | Destructive delete | Residual high-impact race: Infomaniak documents no conditional delete token. | None after accepted deletion. |
| Permanent delete vs remote change | `!(C && B)` | Do not delete; return `.deletionRejected` containing latest trashed item. | No | Low. File Provider can recreate the item locally. | Review the recreated item and retry deletion if still desired. |
| Permanent delete already completed | Latest lookup returns 404 | Return idempotent success. | No | Safe; prevents ghost/stuck deletion. | None. |

## Combined `changedFields` Truth Table

File Provider can send multiple changes in one `modifyItem` callback. The
extension applies all supported fields in this order:

1. parent move plus optional filename, or filename-only rename
2. contents plus its modification date
3. standalone modification date
4. move to trash

Applied fields are removed from `stillPendingFields`. Unsupported fields remain
pending and are never falsely acknowledged.

| Fields in one callback | Branch executed | Applied remotely | Silently unhandled | Assessment |
| --- | --- | --- | --- | --- |
| Contents + filename | Rename, then contents | Both; content replaces the same stable file ID under the requested name | None | Automatic. Conditional content race still preserves both. |
| Contents + parent | Move, then contents | Both; move-only preserves an independent remote rename | None | Automatic. |
| Contents + filename + parent | Combined move/rename, then contents | All three | None | Automatic. |
| Contents + move to trash | Contents first, trash last | New contents are conditionally replaced or preserved as a conflict item; affected item(s) are then trashed | None | No silent byte loss; conflict copies remain recoverable in trash. |
| Filename + parent | Combined move/rename | Both | None | Automatic with `conflict=rename`. |
| Content modification date only | Date update | `last_modified_at` | None | Automatic; returned item is refetched with ETag. |
| Unsupported metadata fields only | Refetch | Nothing | All unsupported fields returned pending | No false success, but repeated pending fields can soft-lock until support is implemented. |

## Open Safety Findings

| ID | Severity | Finding | Consequence | State |
| --- | --- | --- | --- | --- |
| `CR-001` | Critical | Combined `changedFields` were mutually exclusive and falsely reported complete. | The implementation now applies move/rename, content/date, and trash in order and returns unsupported fields pending. End-to-end extension callback coverage is still required. | **Mitigated** |
| `CR-002` | High | Existing-item mutations had a fetch-then-mutate race. | Content now uses ETag/`If-Match`; permanent delete still lacks a documented conditional server primitive. | **Mitigated** |
| `CR-003` | High | Content replacement addressed latest parent/name instead of stable ID. | Replacement now uses `file_id`, authoritative ETag, and `If-Match`; conditional races preserve both. | **Resolved** |
| `CR-004` | High | Content versions used only `modifiedAt`. | Versions now contain stable item ID plus ETag; legacy/missing ETags fail closed. | **Resolved** |
| `CR-005` | High | Latest lookup happened before staging. | Bytes now stage first, but a preflight failure may leave an unindexed recovery copy because parent metadata is unavailable. | **Mitigated** |
| `CR-006` | High | Contents+trash ignored the new bytes. | Content is replaced/preserved before trash; conflict item and original are both trashed when required. | **Resolved** |
| `CR-007` | Medium | Failed uploads stranded private staged bytes. | Indexed failures have Activities reveal/export and deterministic replay; provider-owned scheduling and Retry Now remain absent. | **Mitigated** |
| `CR-008` | Medium | Stale delete/collision errors caused avoidable soft locks. | Stale permanent delete returns `.deletionRejected`; recognized collisions auto-rename. No `filenameCollision` bounce is needed for handled cases. | **Resolved** |
| `CR-009` | Medium | Mutation replay was not idempotent. | Direct file create/replace/conflict copy use deterministic client tokens and hashes; directory create and `.mayAlreadyExist` identity reconciliation remain gaps. | **Mitigated** |
| `CR-010` | Medium | Recoverable errors had no resolution signal. | Successful metadata/content/mutation operations signal authentication, quota, reachability, and synchronization errors resolved. | **Resolved** |
| `CR-011` | Low | Listing cursor, action, and snapshot anomalies fail closed. | Folder availability can be temporarily blocked, but ambiguous snapshots are not committed and remote data is not mutated. | **Mitigated** |
| `CR-012` | Low | Stale content edits use staged renamed preserve-both. | Both byte streams are preserved, including a 409/412 race after preflight. | **Resolved** |
| `CR-013` | High | Infomaniak documents no conditional ETag for permanent delete. | A remote change between delete preflight and accepted deletion could be irrecoverable. | **Open** |
| `CR-014` | Medium | Unsupported File Provider metadata remains pending without an implementation. | The change is not lost, but File Provider can repeatedly resubmit it and soft-lock the item. | **Open** |
| `CR-015` | Medium | Retry cadence is delegated to File Provider; there is no provider-owned indefinite scheduler or Retry Now action. | Staged bytes survive, but recovery can depend on system resubmission or manual export. | **Open** |
| `CR-016` | Medium | New-file create bytes were not provider-staged before the initial upload. | Creates now stage deterministically before request construction and remove the copy only after confirmed success; regression coverage verifies failed creates retain bytes. | **Resolved** |

## User-Recovery Matrix

| State | Automatic recovery | User can fix in current app | External/manual recovery |
| --- | --- | --- | --- |
| Successful renamed conflict copy | Both versions are created automatically; no semantic merge is attempted. | Open both visible files and decide which content to keep. | Finder/Files or kDrive clients can merge/delete copies. |
| `.failOnConflict` | Mutation is deliberately stopped and staged bytes retained. | Activities reveals/exports indexed recovery bytes; user chooses the winning/merged content and retries. | Finder/Files or another kDrive client can resolve the versions. |
| Stale rename or move | Local same-field intent applies automatically; move-only preserves remote rename. | Usually none; inspect a collision-selected unique name if desired. | Resolve unusual case-only/type collisions in another client. |
| Trash after remote change | Trash intent applies and remains reversible. | Restore from trash if the local intent was wrong. | Restore through any kDrive client. |
| Stale permanent delete | `.deletionRejected` asks File Provider to recreate the latest item. | Review the recreated item and retry deletion. | Another kDrive client can inspect/delete it. |
| Failed indexed content upload | File Provider receives a retryable error and can resubmit with the same token/hash. | Activities reveals/exports the staged copy; after 24 hours it is labelled Needs Attention. | Support can recover an unindexed stage from app-group `ConflictStaging`. |
| Failed new-file create | File Provider can resubmit with the same deterministic token/hash and provider-owned bytes remain staged. | No indexed Activities action yet. | Support can recover the stage from app-group `ConflictStaging`. |
| Name collision rejected in an unrecognized shape | Recognized 409/422 collisions auto-rename. | Choose a unique name and retry. | Resolve collision through another kDrive client. |
| Invalid listing or cursor state | Anchor reset/rebuild occurs for supported cases. | Usually no direct fix beyond retrying later. | Server/provider correction may be required for repeatedly invalid responses. |
| Missing authentication | Token refresh is attempted when possible. | Yes: sign in again. | Account or credential repair may be required. |
| Quota exhausted | No upload until quota is available. | Yes, outside the provider: free space or increase quota. | kDrive account management. |
| Unsupported metadata remains pending | File Provider can resubmit, but the provider has no handler. | No reliable current fix; undo the originating metadata action if possible. | Requires a provider update; this is a soft-lock class, not byte loss. |

## Required Maintenance Procedure

This file must be reviewed and updated in the same change whenever any of the
following changes:

- `createItem`, `modifyItem`, or `deleteItem` dispatch and completion handling;
- `changedFields`, `stillPendingFields`, or File Provider callback options;
- content or metadata version construction and comparison;
- create, replace, rename, move, trash, or delete request construction;
- kDrive conflict flags, stable identifiers, ETags, revisions, checksums, or
  idempotency tokens;
- error classification or File Provider error mapping;
- conflict staging, persistence, retry, cleanup, or user-recovery UI;
- enumeration validation, sync anchors, snapshot races, or reconciliation;
- tests that prove or invalidate any row or finding.

Every applicable change must:

1. Update the affected truth-table rows and finding states.
2. Add or update regression tests for every changed decision cell.
3. Record the new audit date, validation command, and server-validation status.
4. Re-check Apple's current replicated File Provider documentation.
5. Keep uncertain kDrive behavior marked server-dependent until a guarded live
   test or authoritative API contract proves it.
6. Treat an inaccurate or stale table as a release-blocking data-safety defect.

A finding may move to **Resolved** only when the implementation, tests, user
recovery behavior, and this document agree. Do not close a finding solely
because an error is logged, bytes happen to remain in a private directory, or a
server currently appears to preserve an older version.
