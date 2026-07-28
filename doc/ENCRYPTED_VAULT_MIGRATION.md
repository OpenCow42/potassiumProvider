# Encrypted Vault Migration

Migration never converts a plaintext File Provider domain in place. The source
remains a separately registered legacy domain while a new encrypted domain gets
new logical UUIDs and random physical kDrive objects.

## Preflight

Before copying, inventory item and version counts, plaintext bytes, estimated
padding overhead, available quota, inaccessible/shared items, and active
Desktop/Documents ownership. Shared items and historical versions may require
separate access and purge decisions. Do not start a known-folder cutover until
both source and destination can be reconciled.

The resumable migration journal is itself encrypted with the destination
vault's local-state key. Each source item moves monotonically through:

```text
inventoried → encrypted → uploaded → committed → verified → source-purged
```

The record uses an opaque source identifier and stable destination UUID.
Ciphertext staging details, logical names, revisions, and digests are inside the
encrypted journal. A missing local ciphertext stage causes safe re-download and
re-encryption. Opaque upload tokens make retries idempotent. A transaction
commit retried after an interrupted local journal update is an idempotent
base-less upsert of the same logical item.

## Copy and verification

For a file:

1. Download source plaintext to a File Provider/protected temporary file.
2. Stream-encrypt it into authenticated frames and immediately remove plaintext.
3. Upload randomized ciphertext.
4. Publish its encrypted logical transaction.
5. Download/decrypt the committed object to a separate protected temporary
   file.
6. Compare exact size and SHA-256 against the authenticated staged result.
7. Mark the record verified.

The coordinator checks the source revision before staging, before commit, after
the authenticated destination round-trip, and immediately before a separately
confirmed source purge. A changed source raises `sourceChanged`; the caller
re-inventories and recopies from the new base. Directories are committed before
their children and are marked verified only after their immutable transaction
is observed back through a complete journal synchronization.

The copy/resume API has no source-deletion path. `purgeVerifiedSource` is a
separate explicit operation, refuses every state except `verified`, and
revalidates the exact source revision. Therefore source deletion cannot precede
an authenticated round-trip or erase an edit made after verification.

## Desktop and Documents

Known-folder migration must:

1. pause/coordinate source ownership;
2. copy the initial tree;
3. reconcile a final source delta;
4. claim the encrypted logical `Private/<Mac>/Desktop` and `Documents`;
5. verify local availability through File Provider;
6. only then offer source purge.

The encrypted-domain known-folder resolver creates these names as logical vault
transactions. No physical `Private/<Mac>` path is sent to kDrive.

## Plaintext purge

Purge is separately confirmed and best effort. It should disable reachable
share links, remove accessible versions, trash and permanently delete live
items, and then re-inventory to report anything still reachable. kDrive APIs may
not expose server backups or every historical copy.

Migration cannot retroactively hide prior server observations, backups, deleted
versions, external shares, downloaded copies, or recipient copies. Recovery
rotation does not revoke old root-key wrappers. Lost-device revocation requires
a replacement root-key epoch, complete verified re-encryption, and explicit
purge of the old vault where possible.

## Failure policy

- Quota exhaustion pauses without changing or deleting the source.
- Verification failure keeps both source and ciphertext for diagnosis/retry.
- Cancellation removes partial plaintext and leaves the last durable journal
  state.
- Uncommitted ciphertext remains invisible and becomes eligible for
  checkpoint-covered garbage collection after retention.
- Source purge failures remain visible as `verified`, never as
  `source-purged`.
