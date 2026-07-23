# Changelog

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
