# Conflict Resolution Truth Table

Status: normative data-safety register for encrypted vault format v2 on
`codex/encrypted-kdrive-vault`. Last reviewed: 2026-08-02.

This table is a release gate. Any change to encrypted File Provider mutations,
versions, conflict policy, journal replay, trash, rollback, cleanup, recovery,
or activation must update the applicable row and its regression evidence in
the same pull request. An inaccurate row is a release-blocking defect.

The table deliberately does not claim that unmerged legacy-plaintext conflict
hardening exists on this branch. Legacy plaintext behavior remains documented
in [CONFLICTS.md](CONFLICTS.md); encrypted v2 must never route through that
implementation.

## Normative decisions

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

## Finding register

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

## Audit evidence

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

## Maintenance rule

For each affected row, reviewers must verify canonical replay convergence,
failure atomicity, stale-base behavior, File Provider error mapping, recovery
path, and absence of remote deletion. New destructive behavior requires a new
explicit row, adversarial regression coverage, documentation, and independent
security approval before it can be enabled.
