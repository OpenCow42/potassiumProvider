# Conflict Resolution Truth Table And Safety Register

Status: normative data-safety register for legacy plaintext domains and
encrypted vault format v2. Merge integration reviewed: 2026-08-10.

This table is a release gate. Any change to encrypted File Provider mutations,
versions, conflict policy, journal replay, trash, rollback, cleanup, recovery,
or activation must update the applicable row and its regression evidence in
the same pull request. An inaccurate row is a release-blocking defect.

Legacy plaintext and encrypted domains use separate mutation and conflict
engines. Each request must remain within its configured engine; encrypted v2
must never route through the plaintext implementation. The maintained tables
below are independently normative for their respective domain type.

## Merge Integration Audit Status

- Integration reviewed: 2026-08-10.
- Merge inputs: encrypted-vault head `a0e0839` and `origin/main` at `f042b7e`.
- macOS `build-for-testing` and the complete `potassiumProviderTests` target
  passed with signing and indexing disabled.
- The iOS Simulator app and unit-test bundle built successfully. An initial
  full local run did not launch because CoreSimulator's IPC server died. After
  CI exposed a probabilistic support-log assertion, the corrected focused test
  rebuilt and passed locally; the pull-request workflow remains the required
  full clean-runner evidence.
- The generic visionOS app build passed with signing and indexing disabled.
- Live kDrive validation was not performed. Server-dependent findings remain
  open as documented below.

## Encrypted-Vault Normative Decisions

| Scenario | Required deterministic result | Destructive action permitted? | Regression evidence |
|---|---|---:|---|
| Concurrent edits change the same file content from one base | Canonical winner retains the logical UUID; every loser becomes a stable conflict copy with independently authenticated metadata. Replay order cannot change the result. | No | `VaultJournalTests.concurrentContentEditsConvergeForEveryReplayOrder` |
| One concurrent edit changes content and another changes metadata | Merge both independent changes. | No | `VaultJournalTests.independentConcurrentContentAndMetadataEditsMerge` |
| Concurrent metadata edits disagree | Canonical transaction ordering selects the visible metadata and emits an opaque metadata conflict. | No | Existing randomized reducer coverage; dedicated expansion remains desirable. |
| Move targets itself, a non-directory, a missing parent, a trashed parent, or a descendant | Reject the invalid parent change and emit `invalidMove`; preserve the last valid parent graph. | No | Parent-graph validation plus `VaultJournalTests.concurrentDirectoryMovesCannotCreateAParentCycle` |
| Two concurrent moves would jointly create a directory cycle | Apply only the canonically first valid move; reject the move that would close the cycle. Every replay permutation converges. | No | `VaultJournalTests.concurrentDirectoryMovesCannotCreateAParentCycle` |
| Folder deletion races with a new visible child outside its causal history | Preserve the folder and child; emit `folderDeletionRejected`. | No | `VaultJournalTests.staleDeleteLosesToEditAndFolderDeleteLosesToChild` |
| File deletion races with an edit | Preserve the edit and emit `deletionRejected`. | No | `VaultJournalTests.staleDeleteLosesToEditAndFolderDeleteLosesToChild` |
| A child is trashed independently, then an ancestor is trashed and restored | Restore only descendants carrying the ancestor trash operation's provenance. Keep the independently trashed child in trash. | No | `VaultJournalTests.restoringFolderPreservesIndependentlyTrashedDescendant` |
| Purge is requested with stale content or metadata revisions | Reject purge and preserve the item. | No | Reducer revision guards; dedicated end-to-end expansion remains desirable. |
| A historical file version is restored | Authenticate and decrypt the selected immutable revision, then encrypt and publish it as a fresh content object with a fresh logical revision. A stale client holding the historical revision must not pass an ABA check. | No old ciphertext deletion | `VaultProvisioningTests.restoringVersionPublishesFreshRevisionAndRejectsABAStaleWrite` |
| Siblings normalize to the same filename, including a pre-existing generated conflict name | Keep every item. Reserve all existing normalized names, then allocate deterministic numbered suffixes until unique. | No | `VaultJournalTests.siblingConflictAllocatorSkipsExistingGeneratedName` |
| Remote journal omits a transaction previously trusted by this device | Reject synchronization as rollback; never fill the omission from cache and call it current. | No | `VaultProvisioningTests.returningDeviceRejectsOmittedRemoteJournalObject` |
| Maintenance observes ciphertext unreferenced by this device's current state | Record/report it only. Never delete it because an offline device may later publish a valid reference. | **No** | `VaultProvisioningTests.maintenanceNeverDeletesCiphertextThatAnOfflineDeviceMayReference` |
| A checkpoint is uploaded or opened | Use authenticated 64 KiB–256 MiB power-of-two padding. Reject unpadded, malformed, tampered, or out-of-range objects. | No | `VaultCryptographyTests.checkpointsHideExactMetadataSizeAndRejectUnpaddedObjects` |
| User creates a vault or opens one with a recovery kit or iCloud Keychain | Show the complete-data-loss/no-support warning and enforce at least five seconds of monotonic elapsed time before any activation side effect. | No side effect before delay | `VaultUXAppModelTests.failedCloudPublicationKeepsRegisteredVaultAndRecoveryBoundary`, `recoveryAndICloudOpenCannotBypassRiskDelay`, and the warning UI test |
| Saved configuration identifies experimental vault v1 | Recognize it only to report unsupported format. Do not re-register, enumerate, mutate, claim known folders, or route through plaintext code. Leave an already registered system domain inert until explicit user removal. | **No** | Runtime and embedded-format guards, `VaultUXAppModelTests.reloadDoesNotReactivateAnUnsupportedV1Domain`, and configuration tests; full extension-host regression remains open. |

## Encrypted-Vault Finding Register

| ID | Severity | State | Finding and disposition |
|---|---:|---|---|
| EV-001 | Critical | Resolved in v2 | Concurrent reciprocal directory moves could create a parent cycle. Parent changes are now validated during canonical replay and the final graph is checked. |
| EV-002 | Critical | Resolved in v2 | Version restore reused an old content revision, permitting an ABA stale-write match. Restore now publishes fresh ciphertext and a fresh revision. |
| EV-003 | High | Resolved in v2 | Restoring a folder revived descendants trashed independently. Trash-root provenance now scopes recursive restore. |
| EV-004 | High | Resolved in v2 | Generated conflict names could collide with existing siblings. Allocation now reserves all normalized names and increments deterministically. |
| EV-005 | High | Resolved in v2 | Checkpoint ciphertext length exposed exact aggregate metadata size. Checkpoints now use authenticated power-of-two padding. |
| EV-006 | Critical | Resolved in v2 | Recovery-kit and iCloud activation bypassed the mandatory risk warning; iCloud could also bypass the main gate. All activation routes now share one monotonic five-second gate. |
| EV-007 | Critical | Resolved by removal | Retention-based deletion could destroy ciphertext referenced later by an offline device. Remote content and journal deletion are disabled. |
| EV-008 | Critical | Resolved by removal | Documentation presented an incomplete migration/purge coordinator as a safe product workflow. The coordinator, purge path, UI claims, and migration document were removed. |
| EV-009 | High | Open release gate | A new device has no independent witness for history hidden before first trust. Document the limitation and design an external witness before any production claim. |
| EV-010 | High | Open release gate | Journal growth is unbounded because safe remote compaction is not implemented. Complete large-scale benchmarks and design reviewed immutable proof retrieval before deletion. |
| EV-011 | High | Open release gate | Recovery rewrapping does not revoke old bootstraps, backups, or devices. Full root-key epoch rotation and reachable-content re-encryption are not implemented. |
| EV-012 | High | Open release gate | Safe plaintext-to-vault migration and destructive source purge are unavailable. Do not offer ownership cutover from a legacy Potassium domain. |
| EV-013 | High | Open release gate | Account/drive identity, object counts and buckets, timing, IP metadata, access patterns, and fetched-object linkage remain visible to the service. This is an accepted architectural limitation, not zero-knowledge storage. |
| EV-014 | Critical | Open release gate | Independent cryptographic and adversarial synchronization review has not approved v2. Both feature flags must remain off by default. |

## Encrypted-Vault Audit Evidence

Local success does not close EV-014.

- macOS: `xcodebuild build-for-testing -destination 'platform=macOS'` succeeded
  with signing and indexing disabled. Direct execution then passed 33 focused
  tests: all journal, provisioning/maintenance, cryptography, and domain-format
  suites. The normal local macOS test host ran the activation-model assertions
  but hung while finalizing its Xcode result bundle, so this evidence does not
  claim a clean full-host exit.
- iOS Simulator: the complete `potassiumProviderTests` target passed on
  `platform=iOS Simulator,OS=26.5,name=iPhone 17` with signing and indexing
  disabled.
- visionOS Simulator: the complete `potassiumProviderTests` target passed on
  `platform=visionOS Simulator,OS=26.5,name=Apple Vision Pro`; the format,
  cryptography, and activation-model suites were rerun successfully after the
  final fail-closed guards.
- Builds: iOS Simulator and generic visionOS builds succeeded with signing
  disabled.
- UI warning automation: the targeted macOS UI test passed and verifies the
  warning copy and disabled continuation for creation; route unification and
  the monotonic delay are covered in unit tests.
- Independent security review: not completed.

### Encrypted-Vault Maintenance Rule

For each affected row, reviewers must verify canonical replay convergence,
failure atomicity, stale-base behavior, File Provider error mapping, recovery
path, and absence of remote deletion. New destructive behavior requires a new
explicit row, adversarial regression coverage, documentation, and independent
security approval before it can be enabled.

## Legacy Plaintext Domains

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

## Legacy Plaintext Audit Status

- Last source audit: 2026-08-13
- Audited baseline: `codex/conflict-resolution-hardening` working tree
- Validation:
  - `potassiumChannel`: `swift test` — 559 tests passed
  - macOS: `KDriveMutationCoordinatorTests` — 25 tests passed (the selected
    test plan executes this suite twice)
  - macOS app build passed with code signing disabled
  - iOS Simulator app build passed on iPhone 17 / iOS 26.5 with code signing
    disabled
  - generic visionOS app build passed with code signing disabled
  - The first GitHub macOS run exposed that snapshot persistence omitted the
    new ETag/revision fields; the schema, migration, and round-trip regression
    have been updated. macOS `build-for-testing` passed against merged
    `potassiumChannel` revision `81014d3`; the GitHub test rerun was pending at
    this audit commit.
  - The local full-scheme UI runner could not finish because the host disk was
    full; focused tests avoid that environment-specific runner failure.
  - Guarded live ETag validation on 2026-08-11 passed against the configured
    disposable test folder: direct file lookup and ordinary directory listing
    return `etag`; a matching `If-Match` replacement succeeds and changes the
    ETag; a stale ETag is rejected with 409 or 412. The advanced listing routes
    reject both `etag` and `files.etag` include resources with HTTP 422. The
    provider uses the desktop-compatible `files.capabilities` resource. A
    remaining 422 is surfaced as `.cannotSynchronize`, rather than mixing an
    advanced change cursor with ordinary-listing pagination. Advanced-listing
    snapshot ETags remain nullable and content mutations fail closed until
    direct metadata refresh supplies an authoritative ETag.
  - 2026-08-13 regression validation passed on macOS, iOS Simulator, and
    visionOS Simulator using the `potassiumProviderTests` target. It covers
    initial and continued advanced listings, ETag exclusion, and propagation
    of an unexpected 422 without changing listing protocols.
- Finding state vocabulary: **Open**, **Mitigated**, or **Resolved**

Unit tests validate isolated coordinator operations, including a remote change
between preflight and conditional upload. They do not yet invoke combined File
Provider `changedFields` through an end-to-end extension callback or prove
system retry/backoff behavior across extension restarts.

## Legacy Plaintext Scope And Evidence

The table is derived from these implementation boundaries:

- [`PotassiumFileProviderExtension`](../potassiumProviderFileProvider/PotassiumFileProviderExtension.swift)
  dispatches create, modify, trash, and delete callbacks and reports their
  completion state to File Provider.
- [`KDriveMutationCoordinator`](../PotassiumProviderCore/KDriveMutationCoordinator.swift)
  compares base versions and selects mutation or conflict-copy behavior.
- [`KDriveVersionConflictResolver`](../PotassiumProviderCore/KDriveModels.swift)
  defines content and metadata equality.
- [`KDriveSnapshotSQLiteStore`](../PotassiumProviderCore/SQLiteSnapshotStore.swift)
  persists ETags and revisions across cached enumeration and process restarts.
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

## Legacy Plaintext Predicate Legend

| Symbol | Meaning |
| --- | --- |
| `C` | The versioned File Provider base contains the same stable item ID and authoritative ETag as the latest remote item. |
| `B` | The base item ID, name, and parent equal the latest remote state. `updatedAt`-only drift is ignored. |
| `D` | The latest remote name and parent already equal the requested final state. |
| `U` | The selected remote mutation or upload succeeds. |

`contentVersion` is versioned JSON. Item ID plus ETag are authoritative;
`revisedAt` and size are diagnostic. Legacy timestamp versions and missing
ETags fail closed into preserve-both or `.failOnConflict` behavior.

## Legacy Plaintext Core Mutation Truth Table

| Request or conflict | Predicate | Current action | Server mutation | Data-loss assessment | User recovery |
| --- | --- | --- | --- | --- | --- |
| New file with no collision known locally | Always | Stage first, then upload by parent/name with `conflict=rename`, SHA-256, and deterministic `client_token`; request `with=etag`. Remove the stage only after success. | Creates an item | Low. The returned server item is authoritative and replay uses the same token. | None if successful; a failed create retains an unindexed staged copy. |
| New file collides with an existing name or type | Server applies rename policy | Create a visible uniquely named item; never request server-side overwrite/versioning. | Creates a second item | Low byte-loss risk; a safe duplicate is possible for `.mayAlreadyExist`. | Compare/delete the duplicate if it represents the same file. |
| New directory collides by name or type | Recognized HTTP 409, or named 422 collision | Retry once with a conflict filename. | Creates a second directory | Low byte-loss risk, but response-shape coverage is not live-validated. | Rename/merge folders if the response was not recognized. |
| Local content edit; remote unchanged | `C`, conditional upload succeeds | Stage first, then replace by `file_id` with `If-Match`, SHA-256, and deterministic token; remove stage only after success. | Conditional content replace | Low. A remote race cannot silently pass the checked ETag. | None. |
| Advanced folder enumeration | API rejects `etag` or `files.etag` in advanced-listing `with` | Request `files.capabilities`; if the advanced route still returns HTTP 422, surface `.cannotSynchronize` and retain the prior snapshot/anchor. Do not substitute ordinary-directory pagination because it omits advanced actions and has incompatible cursor semantics. Snapshot items have no authoritative content ETag, so later content mutations preserve both or fail on conflict until direct ETag metadata is refreshed. | No mutation | Low byte-loss risk; synchronization pauses rather than committing an actionless response against an advanced anchor. | Retry after the service or provider is corrected; conflict copies retain local bytes when direct ETag metadata is still unavailable. |
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

### Advanced-Listing Compatibility Regression Evidence

`PotassiumProviderCoreTests` verifies that the initial `/listing` and continued
`/listing/continue` requests explicitly exclude ETags. It also verifies that
an HTTP 422 is propagated after one advanced request, without replacing an
advanced action/cursor stream with ordinary directory pagination.

## Legacy Plaintext Combined `changedFields` Truth Table

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

## Legacy Plaintext Open Safety Findings

| ID | Severity | Finding | Consequence | State |
| --- | --- | --- | --- | --- |
| `CR-001` | Critical | Combined `changedFields` were mutually exclusive and falsely reported complete. | The implementation now applies move/rename, content/date, and trash in order and returns unsupported fields pending. End-to-end extension callback coverage is still required. | **Mitigated** |
| `CR-002` | High | Existing-item mutations had a fetch-then-mutate race. | Content now uses ETag/`If-Match`; permanent delete still lacks a documented conditional server primitive. | **Mitigated** |
| `CR-003` | High | Content replacement addressed latest parent/name instead of stable ID. | Replacement now uses `file_id`, authoritative ETag, and `If-Match`; conditional races preserve both. | **Resolved** |
| `CR-004` | High | Content versions used only `modifiedAt`, and the first ETag implementation did not persist ETags through SQLite snapshot round trips. | Versions now contain stable item ID plus ETag; snapshot schemas and in-place migrations retain ETag/revision metadata; legacy/missing ETags fail closed. | **Resolved** |
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

## Legacy Plaintext User-Recovery Matrix

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

## Legacy Plaintext Required Maintenance Procedure

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
