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

2026-09-11 operator-directed selection: original Finder runs now defer permanent
deletion before any re-trash or confirmation, then continue the independent
preserve-both, transfer, working-set, and contextual-action scenarios. Explicit
`--include-permanent-deletion` retains exact-item confirmation and `deleteItem`
evidence. Report schema 3 records an untested deletion, never a pass; schemas 1/2
remain readable. Selection, command forwarding, version compatibility, and strict
telemetry regressions cover this change. CR-013 remains open and no deletion
contract or conflict resolution policy changes.

CI `34578669227` passed both Mac profiles and iOS, but the visionOS cancellation
test threw a synthetic gate timeout (retained xcresult: 380 passed, one failed).
The five-second fake replacement/arrival gates and worker polling are replaced
with cancellable signals plus a one-minute overall test limit. Cancellation is
still checked after gate release, the worker terminal is awaited, and server bytes,
staged recovery bytes, no Trash mutation, and exactly one completion are required.
New gate-ordering coverage checks release-before-arrival and cancellation/release
races. The corrected suite finalized 475 passing Stability Mac tests and 384
passing tests on each requested simulator, with zero failures/skips; the signed
generic visionOS build also succeeded. Standard Mac UI validation remains pending.

2026-09-11 continuation: working-set preparation now permits at most four
independent materialized-folder reads at once using the existing
InfomaniakConcurrency dependency. Results retain folder order and still commit in
one transaction guarded by every container snapshot and the starting working-set
anchor. Failure/cancellation discards the batch without advancing cursors or the
successful watermark; throttling propagates its Retry-After metadata without a
poll-local retry. A superseding journal stops new folder work; up to four reads
may already be in flight. `WorkingSetSyncTests` adds gated overlap, ordered state,
partial-batch nonpublication, cancellation, and throttling regressions. The retained
large-crawl failure motivates this latency correction; live mitigation of CR-022
remains pending until a complete original-suite rerun. No conflict policy or
permanent-delete guarantee changes. The 381-test iOS and visionOS Simulator runs
finalized successfully on this runtime (`potassium-finish-ios-01.xcresult` and
`potassium-finish-vision-sim-01.xcresult`); CI `34573732948` also passes unit coverage
on all platforms. The subsequent full standard Mac run finalized 415 passing tests
including UI, and the Stability profile finalized 465 passing tests; both have zero
failures/skips. Original live acceptance on the new runtime remains pending.

Diagnostic subscriptions now capture their initial file state before returning the
stream, preventing an immediately appended event from being absorbed into a later
worker baseline. The cross-store regression appends without a startup sleep.
The real SQLite WAL-contention regression uses dedicated opener/release queues so
its synchronous busy wait cannot starve the cooperative task that releases its
own test lock. Production SQLite timeout/transaction behavior is unchanged.
The poll-scheduling regression now uses cancellable fake-I/O gates and a bounded
overall test deadline after a CI-only timing failure; it still requires a subsequent
poll for arrivals during I/O, no poll for cancelled waiters, and an empty final queue.
Production scheduling policy is unchanged; CI `34576895561` passed the gated
regressions on both Mac profiles and the requested simulators.

2026-09-10 conflict-matrix continuation: the production plaintext and vault
`modifyItem` sequences now run through shared injected executors. Regression
coverage checks combined contents/name/parent changes, pending fields, contents
plus Trash, invalid missing-content requests, cancellation, and the production
error mapper. The vault callback previously took an early Trash branch and returned
no pending fields, silently ignoring combined edits. It now commits supported
edits first, then trashes using the returned revisions; a failed edit never invokes
Trash. Unsupported fields, including currently unsupported standalone vault dates,
remain pending. This is a callback correctness fix, not a new vault conflict policy.
`ModificationCallbackTests` records the affected decision cells below.

`CreationCallbackTests` and the catalog's `.mayAlreadyExist` cases exercise the
production plaintext create router. Reconciliation hints preserve the existing
conservative create policy: existing bytes are never overwritten by name; file
replay depends on the modeled upload token, while directory replay can create a
second usable directory. CR-009 remains mitigated with explicit unresolved gaps.
Vault replay regressions now check the independent canonical metadata winner and
preserved original content winner, minimize content-preservation failures as well
as replay divergence, and verify duplicate journal rejection leaves SQLite state
unchanged. No resolution policy changed for these cases.

Permanent-delete preflight now uses the typed Trash metadata endpoint when supplied
by the remote service, instead of treating active-item 404 as authoritative absence
of a trashed identity. `ConflictDeletionTests` keeps active metadata unavailable
while verifying deletion against the exact Trash identity and repeated authoritative
absence. Existing version guards and the open CR-013 server race remain unchanged.

The edit/move conflict profile now treats a stale local destination URL as pending
within its existing deadline, using the same exact parent/name predicate as Restore.
A completed server mutation alone cannot prove Finder has applied the returned
parent. `FinderRestoreObservationTests.delayedMoveLocationCannotPassUntilParentAndNameBothMatch`
rejects stale paths and wrong names and preserves cancellation. Run-specific
reproduction and supporting successful backend spans are in the local audit.
The bounded live rerun still timed out with a mismatching local parent; extending
the observation did not resolve it. Successful plaintext modify terminals now
include the existing run-salted metadata fingerprint to distinguish returned
callback metadata from server state, without recording names or identifiers.
`FileProviderOperationLifecycleTests.successfulCallbackRecordsReturnedMetadataOnce`
checks that only the first successful terminal retains that fingerprint. The
original preserve-both scenario shares the independent conflict path's cancellable
gate scheduling and byte-checked reopening. No resolution policy changed.

Instrumented live edit/move confirmed a returned-metadata mismatch, but an
experimental post-upload metadata lookup did not resolve it and was removed.
The typed move API returns a cancellable operation response. The harness now
verifies the competing mutation's metadata and bytes before releasing the held
local callback; request acceptance alone never establishes commit ordering.
Attempt-scoped read-back evidence is required by conflict profile version 3 and
newly sealed original preserve-both results. Barrier/profile regressions reject
missing, unrelated, cancelled, late, and stale-attempt proof. Historical bundles
remain readable but do not establish this stronger ordering requirement.

Subsequent settled-cache evidence matched the returned callback fingerprint. The
earlier harness comparison used metadata obtained before waiting for upload bytes;
it now refetches metadata after byte verification. Destination observation first
opens the bound parent in Finder, then verifies the actual parent URL resolves to
the expected stable item and domain, together with the exact filename. A different
parent/domain remains pending; URL spelling alone does not define provider identity.
`FinderRestoreObservationTests.providerParentIdentityHandlesURLAliasesAndRejectsStaleParents`
covers alias spelling, wrong parent/domain, and wrong name. These are harness fixes;
no production mutation policy changed.

Working-set delivery now publishes confirmed plaintext modify/direct-action results
to the existing SQLite change journal before signaling. The merge requires that
the journal's item still matches the caller's pre-mutation observation (or already
equals the result); a competing writer is never overwritten. Publication neither
advances remote cursors nor changes poll timestamps, and failure cannot replay an
already committed remote mutation. Configured roots are not published as ordinary
children. Poll commits compare their starting working-set anchor transactionally
so an older in-flight crawl cannot overwrite the publication. Enumeration delivers
available journal changes before starting another crawl. An in-flight poll checks
for a superseding journal between folder/activity requests, discards its prepared
container changes, and returns without advancing its successful watermark. Refresh
remains within enumeration; no detached delivery worker survives that callback.
Empty journals retain normal polling and expired anchors remain errors.
`WorkingSetMutationDeliveryTests` and `WorkingSetSyncTests` cover persistence,
competing writers, stale-poll rollback, watermark preservation, immediate delivery,
supersession during remote reads, and expired anchors. This changes notification
latency, not remote mutation or conflict policy. The complete fresh and already-running
conflict profiles pass on `05e8e5f`; the original sixteen-scenario acceptance remains
separate and in progress.

Live evidence settling now uses a local one-second quiet interval after exactly
one start and terminal per span, checked every 500 ms. Server Retry-After/backoff
is unchanged. `StabilityDiagnosticSettlementTests` rejects pending work, missing
starts, duplicate terminals, and premature quiet periods after new events.
Version-2 launch evidence certifies extension **process** continuity using kernel
birth, signing, and diagnostic identity. Apple's replicated-provider contract
permits object invalidation/recreation inside one process; those events require
complete successful spans and remain in the timeline. A process replacement,
missing identity, mismatched build, failed lifecycle callback, or incomplete
lifecycle telemetry still rejects acceptance. Version-1 proofs retain their original
stricter object-lifetime interpretation and remain readable. The live warm false
rejection has a failing old-code regression in `StabilityExtensionLaunchEvidenceTests`;
corrected validation/reruns are recorded in the audit. Rejected candidates remain
ineligible for acceptance; CR-013 stays open.

Fresh live content races subsequently identified SQLite `BUSY` (primary code 5)
while opening the snapshot store for `currentSyncAnchor`. Snapshot connections now
install their existing five-second busy timeout before requesting WAL, so the
initial database query can wait for transient cleanup/recovery contention.
`SnapshotInitializationContentionTests` opens the production store under a real
exclusive WAL lock, releases the lock, and checks retained data plus subsequent
snapshot use. The regression failed on the previous order and passed after the
correction on both macOS profiles and the iOS/visionOS simulators. All six fresh and
six already-running conflict cases subsequently passed without a recurring SQLite
failure. No transaction guard, schema, conflict policy, or remote
mutation retry is changed. The precise lock owner in the live run is unobserved.

The original Finder suite subsequently passed navigation and hydration but timed
out before invoking eviction. Its domain-wide stabilization prerequisite completed
no UI actions for that scenario. Hydration now closes its generated TextEdit
document after byte verification; a failed close cannot complete the step.
Eviction then uses fresh item/domain binding and the real Finder action without
waiting for unrelated domain work. Non-hydrating download-state verification and
final diagnostic settling are unchanged. `FinderHydrationSequenceTests` covers
presenter release and failure gating. This is a macOS Stability harness correction,
not a provider eviction or conflict-policy change; live rerun evidence is recorded
in the audit and no new sixteen-scenario pass is inferred.
The following live run verified eviction and a new download, then stopped at
Restore navigation after successful exact trashed-item binding. Ten scenarios
passed; no Restore action or permanent deletion occurred. Closed navigation-stage
diagnostics support the next reproduction without weakening target assertions.
The diagnostic reproduction located that timeout at Go to Folder destination
verification. Bound trashed fixtures now use the existing-window native Finder
target command, retaining exact parent verification and fresh item/domain binding
after navigation. `FinderTrashedItemSequenceTests` rejects identity replacement
during navigation and prevents actions after an unavailable parent. Restore still
requires its provider callback and complete remote/local destination proof;
permanent deletion retains its separate exact-item confirmation and subsequent
revalidation. This UI route is pending live verification and changes no server policy.

The deterministic matrix and independent live conflict profile are documented in
`CONFLICT_TESTING.md`. Targeted runs explicitly skip unrelated scenarios and cannot
certify the original sixteen-scenario suite. Current validation and preserved live
failure/rerun evidence are in `STABILITY_LOOP_AUDIT.md`.

An earlier live run passed ten scenarios through Trash, then failed Restore
because the metadata callback queried the active-item endpoint for a trashed
identity (HTTP 404 mapped to `.cannotSynchronize`). Metadata lookup now falls
back to the typed Trash endpoint only after active-item HTTP 404, validating the
same drive and item identity before returning a Trash parent. Only HTTP 404 from
both identity endpoints becomes `.noSuchItem`; permissions, transport failures,
cancellation, unavailable fallback, and mismatched identities fail closed.
Content and mutation preflights continue to require active metadata. The
`KDriveItemMetadataLookupTests` regressions cover these decisions. Live run
`dc49fe60-e9e5-45fe-8261-85fd4339f5cc` verified successful Trash metadata
fallback, exact Finder selection, and a completed Restore callback. Its independent
active-item verification raced restoration and received 404. The harness now waits
for the attested, item-specific Restore completion before checking active metadata;
404 remains pending within the existing deadline, never success. Authentication,
other operational failures, and wrong identity/drive/destination still fail.
`FinderRestoreObservationTests` covers that boundary. A later run verified remote
restoration but exposed a UI assertion gap: an identity-bound local URL could still
point into Trash. Restore now also requires the expected local parent and filename
before selecting the item. The regression rejects stale Trash locations and wrong
names; its live rerun remains pending. The earlier eleven-scenario report cannot
establish this stronger Restore acceptance. The preserved spans are recorded in
`STABILITY_LOOP_AUDIT.md`; no change to the open CR-013 guarantee is claimed.

Immediate materialization notifications, working-set enumeration, and the timer
can request overlapping polls; `minimumInterval: 0` is not an in-flight lock.
Polls are serialized per domain with the existing cancellation-aware
`AsyncOperationLimiter`. The registry releases an idle domain after its last
caller. Snapshot transactions and the bounded enumeration-race retries remain
required. `WorkingSetSyncTests.immediateMaterializationPollsCannotOverlapEachOther`
checks four simultaneous forced polls and a maximum of one active remote request.

The live continuation also exposed redundant queued materialization polls taking
up to 61 seconds. Pending materialization requests may reuse a successful poll
only when that poll started after their materialized-set observations were
persisted. A request arriving during remote I/O requires a subsequent poll;
failed or throttled polls cannot satisfy queued observations. Other explicit
polls retain their original behavior. `WorkingSetPollSchedulingTests` covers
coalescing, failed-first-poll recovery, arrivals during I/O, and cancellation.
No snapshot transaction guard or successful watermark is bypassed.

An additional live failure identified materialization work continuing after its
replicated instance was invalidated. The acknowledged callback launched an
untracked task that retained the instance; `invalidate()` cancelled only its
periodic poll. An instance-owned `FileProviderBackgroundWork` scope now rejects
new work and synchronously requests cancellation of registered refresh tasks on
invalidation. A short registration mutex bridges the synchronous system callback;
task bodies and cancellation handlers execute outside it. A replacement instance
owns a separate scope. The materialization acknowledgement still completes once
before background refresh; it is never held for remote work or repeated on cancel.
Cancellation is checked before loading refresh state and after reading materialized
items, while existing poll checks and transaction guards remain in force. Cancelled
working-set refreshes receive a cancellation terminal. `FileProviderBackgroundWorkTests`
covers no subsequent request after cancellation, repeated invalidation, rejected
late work, independent replacement instances, and immediate-completion registration.
Live rerun is required; this does not establish why the prior process exited.

`StabilityConflictBarrierTests` isolates the Stability-only conflict barrier from
the live active-run pointer and covers exact item/correlation matching, wrong-run
release rejection, successful release, cancellation, and deadline expiry. This
does not change the server's conditional mutation contract or close CR-013.

2026-09-10 live follow-up: real folder navigation reproduced a working-set
snapshot compare-and-swap rejection after successful remote calls. The atomic
rollback is retained. A claimed poll may repeat the full read/prepare/commit up
to two times after `staleSnapshot`, with cancellable backoff and observable
`concurrentSnapshot` checkpoints; it never retries a stale write or advances the
watermark on a rejected transaction. Persistent contention still fails.
`WorkingSetSyncTests.concurrentEnumerationIsRetriedWithoutAdvancingARejectedWatermark`
covers both convergence and exhausted retries with actual concurrent SQLite saves.
Current live validation is recorded in `STABILITY_LOOP_AUDIT.md`. CR-013 remains open.

If concurrent enumeration already committed the exact prepared server result,
the working-set transaction retains that newer container generation and commits
its change batch without rewriting the container. This exception requires both
snapshots to be fully enumerated advanced listings, the same non-nil server cursor,
and equality of every item and metadata field independent of row order. Different
contents, missing cursors, or different cursors still reject and roll back.
`WorkingSetSyncTests.equivalentServerResultPreservesNewerGenerationButDifferentContentsStillReject`
checks unchanged local generation/anchor and rejected deletions with equal cursors.

The live comparison in `e02376a2-19db-45c5-b213-72165a517fe4` accepted a regular
file's unchanged timestamp and rejected date updates for two positively
correlated directory subjects with HTTP 400. Omitting the optional directory
date did not stop the callbacks and that experiment was reverted. Directory
timestamps now resolve to a freshly fetched authoritative server value without
calling the file-only mutation route. Apple's SDK contract for `modifyItem`
explicitly propagates a differing returned field to disk when it is not pending.
This applies to automatic and explicitly touched plaintext directory dates:
the server value wins. File dates and encrypted-vault metadata are unchanged.
`KDriveMutationCoordinatorTests.directoryTimestampResolvesToServerValueWithoutFileOnlyMutation`
covers both directory spellings; `fileTimestampMutationIsAppliedAndRefetched`
protects file behavior. Repeated live passes of the first five scenarios,
including `abb74c1a-43a8-4f04-a994-53fbf9042656`, verified this fix without
recurrence of the directory date 400. Full 16-scenario acceptance remains open.

2026-09-10 live diagnostic follow-up: partial-activity requests now use the
upstream `with=file` expansion instead of `file,file.etag`, with exact request
coverage in `KDriveAPIEvidenceTests.partialActivitiesRequestsOnlySupportedFileExpansion`.
The first live navigation run recorded partial-activity 422 and standalone
modification-date 400 failures. A failed response still leaves the working-set
watermark unchanged; no error is suppressed and no destructive decision changes.
The reproduced request defects have live rerun evidence above. CR-013 remains
open; no underlying server permanent-delete guarantee has changed.

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
| File Provider callback combines supported edits and Trash | Commit supported edits first; trash only after success using the committed content and metadata revisions. Failed edits prevent Trash; unsupported fields remain pending. | Reversible Trash only after successful edit | `ModificationCallbackTests.vaultCombinedTrashUsesCommittedRevisionsAndPreservesUnsupportedFields`, `vaultMissingContentsCannotTrashOrModify` |
| File Provider callback contains unsupported fields or standalone vault modification date | Return those fields pending; never acknowledge a mutation the vault service did not perform. | No | `ModificationCallbackTests.vaultUnsupportedFieldsAndDateAreNotFalselyAcknowledged` |
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
  suites. The 2026-09-08 profile-reliability run later produced a finalized
  standard macOS unit result with 319 passed and zero failures, superseding the
  earlier incomplete local-host observation. Its exact commands and result
  bundle evidence are recorded in `STABILITY_LOOP_AUDIT.md`.
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

- Last source audit: 2026-08-31
- Audited baseline: `codex/file-provider-stability-loop` milestone 3 working
  tree, retaining the 2026-08-13 mutation decisions
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
  - 2026-08-31 Stability diagnostics validation passed thirteen focused macOS
    tests, including a real subprocess writer, interrupted-tail recovery,
    tombstone parity, unresolved-conflict preservation, paging/statistics,
    cross-store observation, export/redaction, and completed-only retention.
    In Stability only, activity and conflict evidence moves from SQLite to a
    redacted append-only JSONL run bundle. Snapshot, anchor, enumerator, and
    working-set state remains SQLite. Clear/domain removal use tombstones and
    retain unresolved, blocked, and failed conflict events exactly as the
    standard event-store contract requires. Uninstall cleanup removes only
    local event/snapshot state through the selected store; no remote mutation,
    conflict decision, staged-content cleanup, or hard purge was added.
  - 2026-08-31 callback and typed-network instrumentation added actor-isolated
    start/terminal spans and TaskLocal correlation. Diagnostic sink failures are
    swallowed, File Provider completions remain exactly-once, and cancellation
    races select only one terminal phase. `NSFileProviderError` recovery cases
    are classified without retaining user info, expected share-link absence is
    successful, and lazy transfers do not emit start-only evidence before
    consumption. The instrumentation observes the
    existing changed-field, conditional-mutation, preserve-both, and cleanup
    decisions; it does not retry, replay, or alter any mutation. Focused span,
    lifecycle, request-shape, and redaction tests are the regression evidence.
  - 2026-09-01 Stability Lab validation passed 47 focused macOS tests across
    diagnostics/run leasing, pure safety, and injected remote-lifecycle suites after the complete
    Stability app/extension/test graph built successfully. Provision rejects
    ordinary/existing lab domains and external or maintenance drives before a
    mutation. Drive discovery establishes internal membership, while exact
    locally persisted and remote root/marker evidence establishes lab-root
    ownership. Provisioned roots are direct drive-root children; marker upload
    uses conflict-as-error. Reset requires exact confirmation, complete bounded
    pagination, matching local/remote marker evidence, and fresh root/marker/
    child-parent plus system-registration validation before each reversible
    trash request. A cross-process lifecycle lease excludes active/new runs
    for the full reset. Root, marker,
    and permanent-delete endpoints are not representable in the reset plan.
    No live account or remote mutation was used for this validation. The final
    signed hosted command exited 0 with `TEST EXECUTE SUCCEEDED` and a finalized
    result bundle.
  - 2026-09-01 Finder-runner implementation added a 16-step validated report,
    immutable closed-schema assertions/API observations, read-only permission
    preflight, and an explicit `--yes-live` command gate. Automated validation
    uses only model, evidence-writer, parser, and checkpoint tests; it reads no
    credential and performs no Finder or remote action. A live run was not
    performed. Saved/system domain plus root/marker safety is rechecked before
    every scenario. The runner never calls permanent deletion directly: restore
    and permanent-delete scenarios retain the verified lab-root selection and
    checkpoint without opening the user-global Trash or directing a destructive
    action. Cancellation leaves the exact evicted item selected in Finder and
    checkpoints without starting a transfer that could outlive the report;
    contextual actions likewise checkpoint rather than invoking the remote API.
    Existing-item mutation URLs (including the move destination) must resolve
    to their expected File Provider item and configured domain immediately
    before mutation; eviction reuses that single validated identifier. The
    cached lab-root URL is rebound as the configured domain's root container
    after baseline pagination and immediately before scenario execution.
    Enumeration requires both item-listing and anchor/change terminal evidence,
    and checkpoint reasons are scenario-bound.
    Final sealing verifies all assertion/failure/checkpoint totals against the
    immutable report. The historical 2026-09-01 focused Finder evidence run
    reported all 33 cases passed before its Xcode result-log finalization issue.
    It is superseded for macOS by the 2026-09-08 finalized full Stability unit
    result: 327 passed with zero failures. The iPhone 17 iOS 26.5 Simulator and
    generic visionOS Stability app/extension graphs also built successfully.
    No live credential, Finder action, or remote mutation was used.
    `CR-013` stays open for the product callback.
  - 2026-09-01 API-evidence validation pinned the complete provider/context
    operation matrix to potassiumChannel 0.3.0, the captured public API
    revision, and the official iOS/Android/desktop commits recorded in
    `STABILITY_LOOP_AUDIT.md`. Adapter fixtures cover inherited and unknown
    share access, explicit-null expiration clearing, explicit duplicate names,
    the one-billion-byte direct-upload boundary, and retry-safe 408/429
    classification. A signed Stability test graph built successfully; the
    historical selected API slices reported 34/34 and then 16/16 passes. The
    2026-09-08 finalized full Stability macOS unit result (327 passed, zero
    failures) supersedes the earlier incomplete macOS result-log evidence. No
    live credential, network request, or remote mutation was used. `CR-017`
    through `CR-020` record the corrected/mitigated discrepancies; `CR-021`
    remains open because share mutations expose no documented conditional
    version token.
  - 2026-09-01 completion validation built the signed Stability test graph and
    ran the full unit-test target on macOS, iPhone 17 iOS 26.5 Simulator, and
    Apple Vision Pro visionOS 26.5 Simulator; it also built the generic visionOS
    graph with signing disabled. That historical cross-platform run emitted only
    passing terminal cases, but its incomplete result logs are not current
    macOS acceptance evidence. The 2026-09-08 finalized macOS profile results
    report 319 standard and 327 Stability passes, each with zero failures; exact
    commands and the current local-host limitation are in
    `STABILITY_LOOP_AUDIT.md`. No live or remote mutation check ran. A final
    added-line privacy scan also replaced the last credential-shaped test
    literal with a runtime-only UUID canary; both affected suites then reported
    46/46 passes and the reviewer returned PASS.
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
- [`ProviderEventStore`](../PotassiumProviderCore/ProviderEventStore.swift),
  [`StabilityDiagnostics`](../PotassiumProviderCore/StabilityDiagnostics.swift),
  and the Activities UI record conflict state but do not replay failed
  mutations. Stability serialization removes private item/account context while
  retaining the decision state needed for this register.

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

### 2026-09-10 live-run implementation evidence

The PR-based live runner now uses Finder/Accessibility and TextEdit, item aliases,
parent spans, process/build identity, strict v2 report validation, and the cancellable
Stability-only post-preflight conflict barrier. New lab roots are created under
verified `Private` using the authorized existing OAuth Keychain account. Initial
live provisioning exposed fractional-date ownership-marker mismatch; canonical
seconds plus registration resume corrected it, with codec/parent safety regression
coverage. Real authentication, marker readback, and domain registration succeeded.
The first permission-blocked run records zero passed scenarios. Live 16/16 cold/warm
acceptance remains outstanding until finalized bundles demonstrate it. See the
implementation audit for updated run/test results. `CR-013` is still **Open**.

## Legacy Plaintext Core Mutation Truth Table

### Stability Lab Provisioning And Cleanup

| Request or conflict | Predicate | Current action | Server mutation | Data-loss assessment | User recovery |
| --- | --- | --- | --- | --- | --- |
| Provision lab root | No saved or registered domain; selected drive has one internal non-maintenance discovery record; explicit drive root resolves as a directory | Verify the server-created `Private` directory and its drive-root parent, create one unique child below it, upload the fixed random marker with `conflict=error`, re-read both, persist exact root/marker evidence, then register File Provider | Creates a directory and marker file | Low. Internal discovery proves membership, while created-and-matched root/marker evidence proves lab ownership. Partial provisioning is never auto-cleaned, so a failed local save/registration can leave an orphaned development folder but cannot delete unrelated data. | Inspect the dedicated development drive and remove an abandoned folder manually only after verifying its marker. |
| Marker collision or incomplete provisioning | Marker upload/verification fails | Stop, retain any created root, and do not register it or issue compensating deletion | No additional mutation after failure | Low data-loss risk; possible empty/orphaned lab root. | Verify the marker and remove the orphan manually from the dedicated account. |
| Reset lab contents | Exact confirmation; root is a non-root child of its verified `Private` parent (or a historical top-level lab) and has matching created-and-persisted ownership evidence; marker and registered lab domain match; complete bounded listing | Exclude root and marker; before each action re-fetch root, marker, and target parent; call reversible trash only for a still-immediate child | Trashes verified immediate children | Low. There remains an unavoidable request-time race after the final metadata fetch, but trash is reversible and the target stable ID was inside the verified lab root at preflight. | Restore an item from kDrive trash if the reset intent was wrong. |
| Missing/ordinary/unknown domain, wrong-profile runtime, encrypted domain, stale marker/root, partial/cyclic listing, moved target, or active run | Any safety predicate fails; registration is re-queried and the run lifecycle lock is held through reset | Reject before the affected mutation; never hard purge or permanently delete | No | Safe fail-closed behavior. | Use the documented dry-run plus safe uninstall path, repair registration/marker state, then retry. |
| Finder Stability existing-item mutation | Explicit `--yes-live`; exact lab preflight is fresh; the user-visible URL resolves once immediately before the mutation to the expected stable item ID and configured domain, and that validated identifier is reused for eviction. A move also resolves its destination directory to the expected stable ID and domain. | Perform the scenario mutation only while both bindings match; otherwise fail the step before changing local or remote state. | Edit, rename, move, and trash use the normal File Provider callback path. Eviction is local only. Preserve-both setup deliberately combines a direct conditional remote replacement with a bound local write. | Low. Stable-ID/domain binding closes same-path replacement drift; a narrow request-time race remains after the final lookup, while trash remains reversible and content/version conflicts retain the existing preserve-both policy. | Correct the lab/Finder state and retry. Restore trash or compare preserved versions if a later callback fails. |
| Finder Stability root-targeted create | Explicit `--yes-live`; immediately before each scenario the cached visible root URL still resolves as the File Provider root-container identifier in the configured lab domain, in addition to fresh saved/registered/remote lab evidence | Create the scenario file or directory only below that bound root URL; otherwise fail before the local write | Normal File Provider create callback path | Low. The repeated root-container/domain binding prevents a stale cached mount path from redirecting a write outside the lab; a narrow request-time race remains after resolution. | Repair File Provider registration/consent or the lab mount, then retry. |
| Finder Stability restore/permanent-delete scenarios | Explicit live opt-in; generated run ownership and ancestry; trashed item resolves to the exact stable ID and provider domain; exact selected fixture confirmation before irreversible deletion and fresh binding afterward | Invoke Restore or selected-item Delete Immediately through Finder. Restore requires the completed item-specific callback, matching remote identity/parent/bytes, and exact local destination parent/name before UI selection. A stale Trash URL cannot pass. Native deletion dialogs must match the complete quoted display name read from the bound URL, including Finder's hidden-extension behavior, and exactly one scoped dialog with Cancel/Delete controls. URL/domain/item binding remains independent of display text (`FinderDeletionDialogTests`). Retain a blocked/failed result when exact identity or control is unavailable. Never Empty Trash. | Provider restore action or `deleteItem` callback; no direct API substitute | `CR-013` remains open: a disposable-file success does not create a server-side conditional-delete guarantee. | Retain evidence and run fixtures on failure; inspect the exact item without broadening Trash selection. |
| Stability conflict ordering barrier | macOS Stability lab only; active run/case/step, attempt, scheduling point, and salted item alias match | Hold content before/after preflight or metadata after preflight until the competing remote operation completes; release on error/cancellation and enforce a deadline | Original real conditional request after release; normal preserve-both policy handles the response | No production policy change. Missing barrier arrival or missing two-version evidence cannot pass the live test. | Stop the run, retain staged/generated data, and inspect correlated spans. |
| Ownership marker codec compatibility | Remote numeric dates and local ISO-8601 dates identify the same marker but differ below one second | Normalize only creation-time precision to the persisted seconds; continue exact UUID, root, drive, and parent matching | None for an existing marker | Fixes self-rejection without changing the mutation target or rewriting remote evidence. | Retry registration using the saved ownership record. |

| Request or conflict | Predicate | Current action | Server mutation | Data-loss assessment | User recovery |
| --- | --- | --- | --- | --- | --- |
| New file with no collision known locally | Always | Stage first, then upload by parent/name with `conflict=rename`, SHA-256, and deterministic `client_token`; request `with=etag`. Remove the stage only after success. | Creates an item | Low. The returned server item is authoritative and replay uses the same token. | None if successful; a failed create retains an unindexed staged copy. |
| New file collides with an existing name or type | Server applies rename policy | Create a visible uniquely named item; never request server-side overwrite/versioning. | Creates a second item | Low byte-loss risk; a safe duplicate is possible for `.mayAlreadyExist`. | Compare/delete the duplicate if it represents the same file. |
| Direct create or replacement exceeds `1_000_000_000` bytes | Callback URL file size or loaded payload byte count is above the documented direct-upload maximum | Reject before mapping an oversized callback file into `Data`, retain the post-read count check for size/read races, and return `.cannotSynchronize` until a file-backed session adapter exists | No | No unsupported request is sent. The callback source remains File Provider-owned, but this early rejection does not create a separate provider conflict-stage copy; availability is blocked for large files. | Keep the File Provider source available and use a session-capable official client, or retry after session uploads are implemented. |
| New directory collides by name or type | Recognized HTTP 409, or named 422 collision | Retry once with a conflict filename. | Creates a second directory | Low byte-loss risk, but response-shape coverage is not live-validated. | Rename/merge folders if the response was not recognized. |
| Local content edit; remote unchanged | `C`, conditional upload succeeds | Stage first, then replace by `file_id` with `If-Match`, SHA-256, and deterministic token; remove stage only after success. | Conditional content replace | Low. A remote race cannot silently pass the checked ETag. | None. |
| Advanced folder enumeration | API rejects `etag` or `files.etag` in advanced-listing `with` | Request `files.capabilities`; if the advanced route still returns HTTP 422, surface `.cannotSynchronize` and retain the prior snapshot/anchor. Do not substitute ordinary-directory pagination because it omits advanced actions and has incompatible cursor semantics. Snapshot items have no authoritative content ETag, so later content mutations preserve both or fail on conflict until direct ETag metadata is refreshed. | No mutation | Low byte-loss risk; synchronization pauses rather than committing an actionless response against an advanced anchor. | Retry after the service or provider is corrected; conflict copies retain local bytes when direct ETag metadata is still unavailable. |
| Remote changes after preflight | `C`, conditional upload rejects with 409/412 | Refetch and upload a renamed conflict copy from the same staged bytes. | Creates a second item | Low. Both versions are preserved. | Compare or merge the visible files. |
| Local content edit vs already-changed remote content | `!C && U` | Upload a renamed conflict copy and leave the original unchanged. | Creates a second item | Low. Both versions are preserved. | Compare or merge the visible files. |
| `.failOnConflict` content conflict | `!C`, or conditional 409/412 | Do not mutate kDrive; return `.localVersionConflictingWithServer`; keep staged bytes and record recovery path. | No | Low immediate loss risk. This is intentional user-intervention behavior. | Reveal/export recovery copy, compare versions, then retry the desired change. |
| Staging fails | Stage write fails before any server mutation | Propagate local storage failure. | No | High: provider could not obtain its own durable copy, though File Provider still owns the callback URL. | Free local space and retry; no provider copy exists. |
| Preflight lookup fails after staging | `item(...)` fails | Return mapped retryable error and retain deterministic staged bytes. | No | Medium: bytes survive, but an event cannot always be indexed without authoritative parent metadata. | Let File Provider retry; unindexed copies require support/developer recovery. |
| Replace/conflict upload fails after staging | `!U` | Return mapped retryable error; retain stage; indexed conflict failures appear in Activities. | No confirmed success | Low immediate loss risk; provider-owned scheduling is still absent. | File Provider retries; Activities can reveal/export indexed recovery bytes. |
| Replacement committed but response lost | Restart still has the old base ETag; current remote bytes may already equal the attempted edit | Conservatively take stale-content preserve-both path. Do not infer remote success solely from equal bytes | May create a redundant conflict copy | Bytes are preserved, but no-duplicate-effect acceptance is not met. `ConflictMatrixTests` records this CR-009 limitation; the model does not establish a server retry guarantee. | Compare the two preserved versions before removing an unwanted duplicate. |
| Directory create committed but response lost | Restart retries parent/name without a persisted server-assigned identity | Existing collision policy creates a second conflict-named directory | May create a second directory | No byte loss, but child placement/reconciliation remains a CR-009 limitation. Deterministic tests verify both original and retry directory remain usable. | Merge or rename after inspecting both directories. |
| Rename vs remote rename/move | Stable file ID exists | Local name intent wins. Retry a recognized collision with a unique conflict name, then refetch. | Renames item | Low byte-loss risk. The remote same-field name loses by explicit policy. | Inspect final unique name; no byte merge required. |
| Retried rename already reflected remotely | `D` | Return latest item without another mutation. | No | Safe idempotent success. | None. |
| Move-only vs remote rename | Destination differs; local name unchanged | Move stable ID with `name=nil`, preserving the remote rename; kDrive uses `conflict=rename`. | Moves item | Low. Independent fields merge automatically. | None. |
| Combined move+rename vs remote metadata | Stable file ID exists | Local destination and name win; move uses `conflict=rename`; refetch authoritative item. | Moves/renames item | Low byte-loss risk. Same-field metadata follows explicit local intent. | Inspect server-selected unique name if collision occurs. |
| Trash vs remote content/metadata | Stable file ID exists | Apply local trash intent after other requested fields. Remote bytes remain recoverable in trash. | Trashes item | Low immediate risk; trash is reversible. | Restore from trash if the intent was wrong. |
| Permanent delete; remote matches base | `C && B` | Delete trashed item by stable ID. | Destructive delete | Residual high-impact race: Infomaniak documents no conditional delete token. | None after accepted deletion. |
| Permanent delete vs remote change | `!(C && B)` | Do not delete; return `.deletionRejected` containing latest trashed item. | No | Low. File Provider can recreate the item locally. | Review the recreated item and retry deletion if still desired. |
| Permanent delete already completed | Authoritative Trash identity lookup returns 404 | Return idempotent success. | No | Safe; prevents ghost/stuck deletion. | None. |
| Favorite or unfavorite | Stable item ID exists; no conditional favorite version is documented | Apply the explicit local favorite intent, refetch authoritative metadata, and invalidate both the old and returned parent containers | Changes favorite state only | Low. A same-field remote race is last-writer-wins, but no file bytes or hierarchy are changed. | Toggle the favorite state again if the final value is not desired. |
| Duplicate contextual action | Source metadata refetch succeeds | Derive an explicit extension-preserving `copy` name, send it in the duplicate body, then refetch the returned stable ID; never rely on `{}` or server-selected naming | Creates one new item | Low. The source is unchanged. A destination-name collision may reject the operation without a confirmed mutation. | Choose another name or remove the colliding copy, then retry. |
| Restore from trash | Trashed metadata is fresh; original parent still exists, otherwise configured drive root is used | Restore stable ID to the explicit verified destination and invalidate trash plus destination | Moves one item out of trash | Low and reversible. The original item bytes are not replaced; destination choice may fall back to root. | Move the restored item to the desired folder or trash it again. |
| Create share link | No current link; configuration has a documented `public`, `inherit`, or valid password access mode | Create the link with explicit capabilities and known access; reject invalid password configuration | Creates link metadata | Medium privacy impact if the chosen access is too broad, but the adapter never widens an unknown value and no file bytes change. | Disable the link immediately and create a corrected one. |
| Update share link | Current link exists; selected access is documented | Send the complete selected capabilities and explicit access. Encode a cleared expiration as JSON null. Refetch; fail closed if the server returns an unknown access value | Replaces link metadata | Medium. The endpoint exposes no conditional link version, so a stale editor can overwrite concurrent settings. The previous fail-open access decoder and uncleared expiration are resolved. | Reopen authoritative link settings, correct them, or disable the link. |
| Delete share link | Stable item ID exists; no conditional link version is documented | Delete link metadata unconditionally and record only closed diagnostics | Disables the current share URL | Medium availability impact. A concurrent editor has no ETag protection and the old URL cannot be restored by the provider. | Create a new link and redistribute its URL. |
| Restore historical version as copy | Selected immutable version ID, explicit current parent, and explicit destination name | Restore the historical revision to a new item and refetch its stable ID; never replace the current item | Creates one new item | Low. Current bytes and version chain remain unchanged; a name collision may reject without overwriting. | Rename the copy or delete it after comparison. |
| HTTP 408 or 429 | Typed API rejection, with optional Retry-After metadata | Map to `.serverUnreachable` so File Provider can retry. Retain only a parsed nonnegative delta-seconds integer; discard invalid/HTTP-date values and never persist the raw header/body | No confirmed mutation; idempotent tokens and conditional writes govern retries | Low immediate loss risk. A request might have reached the server, so creates reuse deterministic tokens and replacements remain conditional. There is no provider-owned retry scheduler. | Let File Provider retry; use Activities recovery/export if staged content remains blocked. |

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
| Standalone directory content-modification date | Refetch authoritative directory metadata | No timestamp write; resolve the local date to the server's date | None; explicit server-wins policy | Return that date with no pending date field; the SDK propagates it to disk. No directory bytes or child identity change. |
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
| `CR-001` | Critical | Combined `changedFields` were mutually exclusive and falsely reported complete. | The production callback executor now has deterministic combined-field regression coverage for both engines, including the corrected vault early-Trash defect. OS-driven combined callback delivery and full live coverage remain required. | **Mitigated** |
| `CR-002` | High | Existing-item mutations had a fetch-then-mutate race. | Content now uses ETag/`If-Match`; permanent delete still lacks a documented conditional server primitive. | **Mitigated** |
| `CR-003` | High | Content replacement addressed latest parent/name instead of stable ID. | Replacement now uses `file_id`, authoritative ETag, and `If-Match`; conditional races preserve both. | **Resolved** |
| `CR-004` | High | Content versions used only `modifiedAt`, and the first ETag implementation did not persist ETags through SQLite snapshot round trips. | Versions now contain stable item ID plus ETag; snapshot schemas and in-place migrations retain ETag/revision metadata; legacy/missing ETags fail closed. | **Resolved** |
| `CR-005` | High | Latest lookup happened before staging. | Bytes now stage first, but a preflight failure may leave an unindexed recovery copy because parent metadata is unavailable. | **Mitigated** |
| `CR-006` | High | Contents+trash ignored the new bytes. | Content is replaced/preserved before trash; conflict item and original are both trashed when required. | **Resolved** |
| `CR-007` | Medium | Failed uploads stranded private staged bytes. | Indexed failures have Activities reveal/export and deterministic replay; provider-owned scheduling and Retry Now remain absent. | **Mitigated** |
| `CR-008` | Medium | Stale delete/collision errors caused avoidable soft locks. | Stale permanent delete returns `.deletionRejected`; recognized collisions auto-rename. No `filenameCollision` bounce is needed for handled cases. | **Resolved** |
| `CR-009` | Medium | Mutation replay was not idempotent. | Direct file create/replace/conflict copy use deterministic client tokens and hashes; directory create, ambiguous replacement success, and `.mayAlreadyExist` identity reconciliation remain gaps. | **Mitigated** |
| `CR-010` | Medium | Recoverable errors had no resolution signal. | Successful metadata/content/mutation operations signal authentication, quota, reachability, and synchronization errors resolved. | **Resolved** |
| `CR-011` | Low | Listing cursor, action, and snapshot anomalies fail closed. | Folder availability can be temporarily blocked, but ambiguous snapshots are not committed and remote data is not mutated. | **Mitigated** |
| `CR-012` | Low | Stale content edits use staged renamed preserve-both. | Both byte streams are preserved, including a 409/412 race after preflight. | **Resolved** |
| `CR-013` | High | Infomaniak documents no conditional ETag for permanent delete. | A remote change between delete preflight and accepted deletion could be irrecoverable. | **Open** |
| `CR-014` | Medium | Unsupported File Provider metadata remains pending without an implementation. | The change is not lost, but File Provider can repeatedly resubmit it and soft-lock the item. | **Open** |
| `CR-015` | Medium | Retry cadence is delegated to File Provider; there is no provider-owned indefinite scheduler or Retry Now action. | Staged bytes survive, but recovery can depend on system resubmission or manual export. | **Open** |
| `CR-016` | Medium | New-file create bytes were not provider-staged before the initial upload. | Creates now stage deterministically before request construction and remove the copy only after confirmed success; regression coverage verifies failed creates retain bytes. | **Resolved** |
| `CR-017` | Medium | Direct uploads had no documented one-billion-byte guard and the provider has no session/chunk adapter. | File Provider create and replace now reject an oversized callback URL before buffering and recheck the loaded count before request construction. The callback source remains File Provider-owned, but this early path creates no separate conflict stage. A file-backed session adapter is still required for availability. | **Mitigated** |
| `CR-018` | High | Unknown share access widened to public, `inherit` was unavailable, and clearing expiration omitted nullable `valid_until`. | All documented rights are modeled, unknown values fail closed, and update sends explicit JSON null with exact fixture coverage. | **Resolved** |
| `CR-019` | Medium | Duplicate-in-place sent an empty options body and depended on undocumented server-selected naming. | The coordinator refetches the source, derives an explicit extension-preserving copy name, sends it, and refetches the result. | **Resolved** |
| `CR-020` | Medium | HTTP 408/429 were treated as nonretryable synchronization failures and Retry-After recovery metadata was dropped. | They now map to `.serverUnreachable`; only parsed delta seconds survive. Provider-owned retry cadence remains absent. | **Mitigated** |
| `CR-021` | Medium | Share update/delete have no documented ETag or conditional version and can race another editor. | Request bodies and response access now fail closed, but accepted share mutations remain last-writer-wins until the API exposes a conditional primitive. | **Open** |
| `CR-022` | Medium | Working-set change delivery waited behind long materialized-folder crawls despite confirmed local mutation results. | Live callbacks exceeded 90 seconds. Confirmed results now enter the journal with per-item comparison; poll-anchor comparison prevents an older crawl from overwriting them. Available deltas are delivered before polling. Deterministic regressions and complete fresh/already-running conflict profiles pass within the existing deadlines. A later cold original-suite run exposed 359–360-directory serial crawls and a preparation deadline; large materialized-set latency remains unresolved. An earlier original-suite continuation on `d4b5323` sealed failed during deep-seed preparation: the first working-set callback spent 61,235 ms on 423 advanced folder-list requests; all spans eventually completed. Exact visible-URL blocking dependencies remain unconfirmed (see audit). A later harness correction uses Apple’s required working-set signal for remote fixtures and separates targeted conflicts from unused deep-seed preparation; the updated build passed all six fresh and six already-running conflict cases. A subsequent pool of at most four independent folder reads preserved one guarded commit and cleared preparation on `716f907`; the fresh run passed eleven scenarios before a separate deletion-dialog automation failure. Complete fresh/warm acceptance remains pending. The native refresh target must not widen item-specific scenario evidence; all other spans remain required by global settling. | **Mitigated** |
| `CR-023` | Medium | Live current-sync-anchor callbacks failed immediately on SQLite `BUSY` while opening the snapshot store. | Bounded cause inspection identified primary code 5 in two fresh content races. A real-lock production-store regression failed with the old initialization order and passed after installing the existing timeout before WAL setup. Both macOS profiles and iOS/visionOS targets pass, followed by all six fresh and six already-running conflict cases without recurrence. The precise live lock owner is unobserved. Failed bundles remain evidence. | **Mitigated** |
| `CR-024` | Medium | Acknowledged materialization callbacks launched untracked work that retained invalidated provider instances. | Instance-scoped cancellation and registration regressions pass on both macOS profiles and iOS/visionOS simulators; generic visionOS builds. A live materialization child now records exactly one cancellation during invalidation, with all 30 prior child requests terminal and none afterward. The failed preparation bundle remains failed. The original process-exit cause is unconfirmed. | **Mitigated** |

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
