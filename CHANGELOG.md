# Changelog

## 0.2.0

Release status: prepared on a dedicated dependency branch; not yet tagged.

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
- One shared transfer permit bounds concurrent whole-file buffers.

### Dependency state

- potassiumChannel branch: `codex/0.2.0-transfer-operations`
- locked revision: `f8540c2a953b70d64a23fa95e241edf838e80c5a`
- replace the branch requirement with the tagged potassiumChannel 0.2.0 release
  before publishing potassiumProvider 0.2.0.

### Deferred

Streaming and file-backed downloads, file-URL uploads, chunked transfers, and
upload sessions are intentionally deferred until after 0.2.0. Whole-file
`Data` remains the transfer representation, so one large file can still define
the extension's peak memory.

### Release gates

- Complete the macOS Finder progress/cancellation and RSS checks in
  [Testing And Development](doc/TESTING_AND_DEVELOPMENT.md).
- Build and test macOS, iOS Simulator, and visionOS.
- Tag potassiumChannel 0.2.0, update the package requirement to that release,
  resolve dependencies, and only then tag potassiumProvider 0.2.0.
