# Encrypted Vault Format v1

Status: implemented behind `EncryptedVaultsEnabled`; **not approved for
production use**. Independent cryptographic review and resolution of all
high-severity findings are release gates. This document is the versioned format
specification for format version 1.

## Security boundary

An encrypted domain is an opaque client-side vault. Finder and Files receive
decrypted logical items from the trusted Apple endpoint. kDrive receives only
random physical container names, random object tokens, `.bin` ciphertext
objects, `application/octet-stream`, server-required account/drive identifiers,
and transfer protocol fields.

The following logical data is encrypted: content, names, paths, extensions,
MIME/UTI data, parent relationships, dates, exact sizes, favorites, logical
trash, logical versions, thumbnails, device identifiers, conflict information,
and Desktop/Documents namespace names.

The server can still observe:

- the account and drive used by OAuth/API traffic;
- vault existence, random physical containers, object counts, padded
  ciphertext sizes, server timestamps, quota use, and deletion;
- request timing, IP/network metadata, access patterns, and which opaque object
  is fetched;
- denial of service, omission, and rollback attempts.

AES-GCM authenticates corruption, modification, substitution, object-role
swaps, vault swaps, and epoch swaps. A returning device stores its last trusted
frontier in the Keychain and rejects a state that omits that frontier. A new
device cannot detect history hidden before its first trusted checkpoint without
an independent external witness.

Because journal compaction is disabled in v1, a returning device also requires
every remote journal object in its local trusted cache to remain present in a
complete server listing. It never fills an omitted server listing from cache
and silently calls the result current.

Plaintext necessarily exists on an unlocked trusted endpoint. File Provider may
materialize content and metadata locally, and Spotlight may index the visible
working set. That is required for transparent Finder/Files behavior and is
outside the server-side threat model.

## Key hierarchy and custody

Each vault has an independent random 256-bit vault root key. HKDF-SHA-256 uses:

```text
salt = vault UUID bytes || object-specific salt
info = UTF-8("net.weavee.potassiumProvider.vault." || label)
```

Labels are domain separated by object role and key epoch. Content-key wrapping
uses `content-wrap.epoch.<epoch>`. Encrypted object envelopes use
`object.<role-number>.epoch.<epoch>`. Local SQLite and migration records use the
local-state role and are independently authenticated.

Every content revision has a fresh random 256-bit data-encryption key, random
object token, random content revision, and random 64-bit frame nonce prefix.
Plaintext hashes are never used for naming or deduplication.

The unwrapped root key is stored per device as a generic-password item with:

- the shared application access group;
- `kSecUseDataProtectionKeychain = true`;
- synchronization disabled;
- `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`.

This permits background File Provider work after the device's first unlock and
prevents key migration through backups. A locked-before-first-unlock or missing
key maps to `NSFileProviderError.notAuthenticated`. Invalid authentication
tags, malformed formats, and rollback map to `.cannotSynchronize`. An unlock
failure never initializes, overwrites, or deletes remote state.

Normal domain removal, logout, uninstall, full logout, and hard purge retain
vault keys and trusted frontiers. “Forget Key on This Device” is separate,
requires the matching recovery kit, deletes only the root key, and retains the
trusted rollback frontier.

## Recovery kit and bootstrap

A separate random 256-bit recovery secret derives the bootstrap wrapping key.
Only an AES-256-GCM-wrapped root key and encrypted remote layout are uploaded.
The recovery secret never leaves the setup/recovery UI.

The recovery kit is grouped, checksummed Base32 beginning with `KPV1`. Its
payload contains:

```text
magic "KPR1"
format version (u16, big endian)
vault UUID (16 bytes)
drive ID (signed value encoded in u64, big endian)
physical vault-root file ID (u64)
bootstrap file ID (u64)
recovery secret (32 bytes)
SHA-256 checksum prefix (5 bytes)
```

The app displays text and a locally generated QR code once. The user must paste
the complete kit back before the root key is committed and the File Provider
domain is registered. Opening an existing vault downloads and authenticates the
bootstrap and initial checkpoint before saving the key.

Recovery rotation uploads a new bootstrap wrapped by a new recovery secret and
requires confirmation of the new kit. It does **not** revoke old server
versions, backups, or an old bootstrap that still wraps the same root key.
Revoking a lost device requires a fresh root-key epoch and re-encryption of all
reachable content. The supported safe rekey model is a replacement vault plus
the verified migration state machine; destruction of the old vault is a
separate purge decision.

Loss of every device key and the recovery kit is intentionally unrecoverable.

## Physical layout

A vault root is a random 20-byte Base64URL token. Beneath it are random content,
journal, and checkpoint containers. Files are named
`<random-20-byte-Base64URL-token>.bin` and transferred as
`application/octet-stream`. Directory names are also random tokens.

The object-store adapter accepts no logical name, path, type, date, hash, or
device name. Uploads use URLSession file-backed upload tasks and downloads use
file tasks. An opaque token is also the kDrive client token and uploads request
conflict-as-error behavior, making retry lookup idempotent.

## General authenticated envelope

All integers are big endian:

```text
"KPE1" (4)
format version u16
object role u8
key epoch u32
vault UUID (16)
object token (20)
AES-GCM combined value:
  random nonce (12)
  ciphertext (variable)
  authentication tag (16)
```

The entire 47-byte header is associated data. The key is derived for the role,
epoch, vault, and object token. Metadata payloads use sorted-key JSON with
milliseconds-since-1970 dates. Decoders reject unsupported versions, incorrect
roles, vaults, tokens, epochs, lengths, and malformed decrypted values.

## Content format

Content is independently authenticated in 1 MiB frames:

```text
"KPC1" (4)
format version u16
frame size u32 (= 1,048,576)
random nonce prefix u64
repeat:
  ciphertext-plus-tag length u32
  ciphertext
  AES-GCM tag (16)
```

The 96-bit frame nonce is `prefix-u64 || frame-index-u32`. Associated data binds
the magic/version, epoch, vault UUID, logical item UUID, random content revision,
object token, frame index, padded length, and final-frame flag. Files exceeding
the 32-bit frame-index space are rejected before transfer.

The final frame is padded with random bytes to the smallest power-of-two bucket
from 4 KiB through 1 MiB. Empty files have one 4 KiB encrypted frame. The exact
plaintext length and SHA-256 digest exist only inside authenticated encrypted
item metadata. Decryption writes only to a protected temporary file, verifies
every tag, total length, frame count, padding bucket, absence of trailing data,
and final digest, and removes partial plaintext on any failure or cancellation.

## Logical model and synchronization

Logical identifiers are random UUIDs unrelated to kDrive IDs. File Provider
identifiers are `ev1:<base64url-uuid-bytes>`. A `VaultItem` contains encrypted
parent UUID, filename, type, dates, exact size, favorite/trash flags, content
and metadata revision digests, wrapped content key, opaque blob reference, and
logical versions.

Each mutation is an immutable 64 KiB encrypted transaction. It contains a
random transaction UUID, causal parent frontier, random per-vault device UUID,
base item/revisions, and exactly one upsert/trash/restore/purge operation.
Content ciphertext uploads first; publishing the transaction is the visibility
point. Uncommitted ciphertext is never enumerated.

Clients topologically sort the DAG and use transaction UUID ordering for a
deterministic replay:

- concurrent content edits keep the deterministic winner at the original UUID
  and synthesize a stable conflict-copy UUID/name for each loser;
- independent content and metadata changes merge;
- concurrent metadata conflicts use canonical transaction order and emit an
  opaque conflict record;
- stale delete loses to edit;
- folder deletion loses to a concurrent visible child;
- sibling name collisions keep both using deterministic conflict suffixes.

The local generation-based SQLite index stores UUID keys and frontiers. Item
records and generation state are encrypted even on the trusted endpoint. Four
complete encrypted generations are retained so File Provider change
enumeration is computed from the caller's requested frontier, not from whatever
snapshot another enumerator most recently loaded. An older unknown frontier
returns `syncAnchorExpired`; moves and trash transitions are emitted as item
updates, while only logical purge is emitted as deletion.
Provider activity/conflict rows for encrypted domains contain only opaque item
identifiers and fixed summaries; display names are resolved from the unlocked
vault.

Thumbnails are generated locally only after authenticated decryption. Encrypted
domains never call kDrive thumbnail, preview, latest, favorites, shared,
activity, or native-version endpoints. Favorite, duplicate (copy-on-write),
trash, restore, purge, and logical version restore are vault transactions.
Native kDrive share links are disabled with an explicit recipient-key-sharing
message.

## Checkpoints, rollback, and collection

Encrypted checkpoints contain the reconstructed logical index, causal frontier,
and a Merkle root over compacted transactions. The current implementation
retains immutable transaction objects and therefore always validates returning
frontiers directly. Merkle proof construction/verification is implemented and
tested; each leaf binds both the authenticated transaction digest and its UUID
so an inclusion path cannot be relabeled for another frontier entry. Remote
journal deletion remains deliberately disabled until immutable Merkle-node
retrieval and independent review are complete.

Maintenance first synchronizes the complete journal, uploads a new random
immutable checkpoint, and downloads and authenticates it. An unreferenced
content object then becomes an encrypted local garbage-collection candidate;
the server timestamp is not trusted as its age. Deletion is possible only after
the candidate remains unreferenced through a later synchronized, authenticated
checkpoint beyond the configured retention window. Candidate receipts are
encrypted in the local vault SQLite store. Defaults retain at least 10 versions
and 30 days.

This conservative boundary means the first reviewed release may use more quota,
but cannot destroy journal ancestry merely because a server cursor or timestamp
is misleading.

## Product limitations

kDrive web preview, server search, server malware inspection, native sharing,
and kDrive logical version history cannot operate on ciphertext. Encrypted
Desktop and Documents are logical folders; their plaintext names and Mac
namespace occur only in encrypted transactions.

The feature flag defaults off:

```sh
defaults write net.weavee.potassiumProvider EncryptedVaultsEnabled -bool YES
```

Enabling it is for development and security review, not a confidentiality
claim. The rollout gate is: format/crypto tests, read-only prototype,
single-device mutation testing, multi-device conflict testing, migration pilot,
independent security audit, then explicit default enablement.
