# Encrypted Vault Format v2

Status: implemented behind `EncryptedVaultsEnabled`; **not approved for
production use**. Independent cryptographic review and resolution of all
high-severity findings are release gates. This document is the versioned format
specification for format version 2. Experimental v1 vaults are intentionally
incompatible: clients recognize their saved configuration only to fail closed
and will not activate, enumerate, or mutate them.

The app does not re-register a saved v1 configuration. A v1 domain that the
operating system already registered remains inert until the user explicitly
removes it: every extension entry point rejects the configuration before token,
key, local-state, or network access. Automatic removal is intentionally avoided
because it could discard pending materialized changes.

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

Because journal compaction is disabled in v2, a returning device also requires
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
`object.<role-number>.epoch.<epoch>`. Local SQLite records use the local-state
role and are independently authenticated.

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

The recovery kit is grouped, checksummed Base32 beginning with `KPV2`. Its
payload contains:

```text
magic "KPR2"
format version (u16, big endian)
vault UUID (16 bytes)
drive ID (signed value encoded in u64, big endian)
physical vault-root file ID (u64)
bootstrap file ID (u64)
recovery secret (32 bytes)
SHA-256 checksum prefix (5 bytes)
```

The remotely stored bootstrap begins with `KPB2`, carries format version 2 in
its authenticated header, and wraps the root key plus opaque remote layout.

The app displays text and a locally generated QR code once. The user must paste
the complete kit back before the root key is committed and the File Provider
domain is registered. Opening an existing vault downloads and authenticates the
bootstrap and initial checkpoint before saving the key.
The existing-vault verification and Forget Key actions also authenticate the
remote encrypted header and checkpoint; they do not accept locator matching as
proof and never transmit or persist the recovery material.

Recovery rewrapping uploads a new bootstrap wrapped by a new recovery secret and
requires confirmation of the new kit. It does **not** revoke old server
versions, backups, or an old bootstrap that still wraps the same root key.
Revoking a lost device requires a fresh root-key epoch and re-encryption of all
reachable content. Neither full rekey nor safe cross-vault migration is
implemented. Destructive source purge is therefore not exposed.

Loss of every device key and the recovery kit is intentionally unrecoverable.

### iCloud Keychain convenience

Device-only custody remains the default. With the separate iCloud Keychain gate
enabled, setup and Security & Recovery can publish a synchronizable
`VaultCloudAccessRecord`. iCloud Keychain protects that record end to end, but
Apple Account recovery and trusted Apple devices then become part of the
custody boundary.

The record holds the root key, vault/drive identity, opaque physical locators,
format/epoch, and remote layout. It excludes the recovery secret, trusted
frontier, device identity, and logical metadata. Import is explicit and
foreground-only. It authenticates the bootstrap identity plus the encrypted
checkpoint and complete journal before saving a device-local key. A returning
device's trusted frontier is validated and retained.

Forgetting a device key never silently imports the cloud record. Removing the
cloud record does not erase keys already imported elsewhere; full rekeying
remains the lost-device revocation mechanism.

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
"KPE2" (4)
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
"KPC2" (4)
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
identifiers are `ev2:<base64url-uuid-bytes>`. A `VaultItem` contains encrypted
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

## Checkpoints, rollback, and conservative maintenance

Encrypted checkpoints contain the reconstructed logical index, causal frontier,
and a Merkle root over the complete current transaction set. Before encryption, each
checkpoint is length-prefixed and padded with random bytes to a power-of-two
bucket from 64 KiB through 256 MiB. Exact aggregate metadata size is therefore
not exposed by ciphertext length. Unpadded or out-of-range checkpoints fail
closed. The current implementation
retains immutable transaction objects and therefore always validates returning
frontiers directly. Merkle proof construction/verification is implemented and
tested; each leaf binds both the authenticated transaction digest and its UUID
so an inclusion path cannot be relabeled for another frontier entry. Remote
journal deletion remains deliberately disabled until immutable Merkle-node
retrieval and independent review are complete.

Maintenance first synchronizes the complete journal, uploads a new random
immutable padded checkpoint, and downloads and authenticates it. It may record
and report apparently unreferenced content objects in encrypted local state,
but it never deletes remote content or journal objects. Retention time and a
single device's checkpoints cannot prove that an offline device will not later
publish a valid transaction referencing that ciphertext.

This conservative boundary means the first reviewed release may use more quota,
but cannot destroy content or journal ancestry merely because a server cursor,
timestamp, or incomplete device history is misleading.

## Product limitations

kDrive web preview, server search, server malware inspection, native sharing,
and kDrive logical version history cannot operate on ciphertext. Encrypted
Desktop and Documents are logical folders; their plaintext names and Mac
namespace occur only in encrypted transactions.

Onboarding offers Desktop & Documents as a separate macOS consent step after
durable registration. Preflight checks the local key, remote reachability, and
current owner. A legacy plaintext Potassium owner blocks direct claiming because
safe migration is not implemented; an external owner triggers a warning that
prior remote copies remain outside this vault and are not deleted. Transfer UI
uses phases and Finder per-item progress rather than a fabricated percentage.

### Activation warning and feature gates

Every activation route—new-vault creation, recovery-kit open, and iCloud
Keychain open—first displays the same warning that the unsupported feature can
cause complete, unrecoverable data loss, has no support, and leaves the user on
their own. The continuation control remains disabled for at least five seconds
measured with system uptime. Before that delay expires, activation performs no
remote preparation, device authentication, key import, or domain registration.

The main feature flag defaults off:

```sh
defaults write net.weavee.potassiumProvider EncryptedVaultsEnabled -bool YES
```

This gate controls activation UI only. It is not a runtime kill switch for an
already registered v2 domain and it is not a production-readiness assertion.

Optional iCloud Keychain custody has a second additive gate:

```sh
defaults write net.weavee.potassiumProvider EncryptedVaultICloudKeychainEnabled -bool YES
```

The iCloud route also requires the main vault gate; enabling only the
convenience gate cannot bypass the vault gate or the warning. Both flags are for
development and security review, not a confidentiality claim. The rollout gate
is: format/crypto tests, read-only prototype, single-device mutation testing,
multi-device conflict testing, a designed and reviewed migration/rekey story,
independent security audit, then explicit default enablement.

## Apple platform references

- [Synchronizable Keychain items](https://developer.apple.com/documentation/security/ksecattrsynchronizable)
- [iCloud Keychain security overview](https://support.apple.com/guide/security/icloud-keychain-security-overview-sec1c89c6f3b/web)
- [File Provider framework updates and known folders](https://developer.apple.com/documentation/updates/fileprovider)
