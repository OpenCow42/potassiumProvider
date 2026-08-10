# Changelog

## 0.4.0

Released 2026-08-10.

### Added

- Experimental end-to-end encrypted kDrive vault format v2, with opaque
  File Provider identifiers and ciphertext, deterministic journal replay,
  authenticated checkpoint padding, offline recovery kits, and optional
  iCloud Keychain access.
- Guided encrypted-vault creation and recovery flows with an explicit
  complete-data-loss warning and a mandatory five-second delay before any
  activation side effect.
- A normative conflict-resolution truth table and safety register covering
  plaintext and encrypted domains, including recovery paths and open gates.

### Changed

- Existing-file uploads now use authoritative kDrive ETags and conditional
  replacement by stable file ID. Local bytes are staged before network work,
  and stale or raced edits are preserved as visible conflict copies.
- Combined File Provider changes now apply move/rename, content/date, and
  trash operations in deterministic order while returning unsupported fields
  as still pending.
- Drive discovery exposes only verified-owned kDrives and fails closed when
  ownership cannot be determined. Existing configured domains are preserved.
- Release version is `0.4.0` with build number `5`.

### Fixed

- Persist kDrive ETags and revisions across snapshot migrations and process
  restarts so conflict checks retain their authoritative content base.
- Reject stale permanent deletion, surface retained staged copies in
  Activities, and signal recovery after transient File Provider failures.
- Prevent encrypted-vault parent cycles, unsafe recursive trash restoration,
  generated conflict-name collisions, and ABA stale writes during version
  restoration.

### Dependency state

- potassiumChannel is pinned to immutable revision
  `81014d32428b2f367c74c7f1616793c7a5b2ba01` for conditional uploads and
  conflict-aware mutation support.

### Security and release scope

- Encrypted vaults remain disabled by default and are not approved for
  production use. Independent cryptographic and adversarial synchronization
  review is still a critical release gate.
- External history witnessing, safe journal compaction, complete key
  revocation/rekeying, and safe plaintext-to-vault migration remain open.
- Live kDrive collision testing was not performed for the conflict-resolution
  changes; the release relies on unit, integration, and CI coverage described
  in the safety register.

## 0.3.0

### Added

- Finder/Files actions to add or remove kDrive favorites, duplicate items
  server-side, and restore items from trash with root fallback when the
  original parent is gone.
- A cross-platform File Provider UI extension for share-link management and
  paged document version history with non-destructive “Restore as Copy.”
- Favorite and trash metadata used by native File Provider presentation and
  action predicates.
- Native lazy/offline metadata so the system can present Download Now and
  Remove Download.
- Per-drive Show in Finder/Files and Sync Now controls in the app.
- Sanitized favorite, duplicate, restore, share-link, and version-restore
  activity in the existing timeline.

### Changed

- Snapshot generation and legacy snapshot tables now retain nullable favorite
  state with an in-place SQLite migration. Older snapshot and working-set JSON
  remains decodable.
- Successful local mutations invalidate and signal each affected folder plus
  the working set.
- Release version is `0.3.0` with build number `4`.

### Dependency state

- potassiumChannel remains pinned to `0.2.0`.
- Contextual operations use only existing typed `PotassiumKDrive` 0.2.0
  service methods; no local ad hoc HTTP requests were added.

### Security

- Share URLs and passwords remain view-model memory only. They are not written
  to domain JSON, SQLite, activity rows, support logs, or unified logs.

## 0.2.1

### Fixed

- Treat the File Provider working-set identifier as a virtual enumeration
  container. Metadata requests now return `.noSuchItem` locally instead of
  starting a runtime, retrying kDrive metadata, and recording expected failures.
- Reject working-set identifiers where a concrete kDrive parent is required.

### Distribution

- Repackaged the macOS universal download without AppleDouble metadata sidecars.
  Standard ZIP extraction no longer adds unsealed files to embedded frameworks
  and triggers a Gatekeeper override prompt.

## 0.2.0

Released 2026-07-23.

### Added

- Observable, cancellable whole-file transfer operations backed by
  potassiumChannel's live `URLSessionTask.progress`.
- Immediate File Provider progress with byte-aware Finder upload/download
  presentation and exactly-once completion handling.
- Materialized-plus-relevant working-set polling with durable state.
- Immutable, keyset-paged SQLite snapshot generations.

### Fixed

- Advanced listing actions now reduce newest-first.
- Content fetches validate requested versions and detect changes during a
  download.
- Document identifiers are no longer treated as enumerable containers.
- Cached listings and change enumeration avoid loading full snapshots into
  duplicate in-memory collections.
- Working-set polls commit materialized-container cursors and published changes
  atomically, preventing failed polls from skipping remote actions.
- One shared transfer permit bounds concurrent whole-file buffers.

### Dependency state

- potassiumChannel release: `0.2.0`
- release revision: `8a6d236d69c381c17f334b66dd4075ef2e0b7d89`
- the Xcode project accepts compatible potassiumChannel `0.2.x` releases and
  `Package.resolved` locks builds to the verified `0.2.0` release.

### Deferred

Streaming and file-backed downloads, file-URL uploads, chunked transfers, and
upload sessions are intentionally deferred until after 0.2.0. Whole-file
`Data` remains the transfer representation, so one large file can still define
the extension's peak memory.

### Release gates

- Complete the macOS Finder progress/cancellation and RSS checks in
  [Testing And Development](doc/TESTING_AND_DEVELOPMENT.md).
- Build and test macOS, iOS Simulator, and visionOS.
- Verify the published potassiumChannel 0.2.0 dependency resolves cleanly, and
  only then tag potassiumProvider 0.2.0.
