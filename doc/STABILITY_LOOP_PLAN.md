# File Provider Stability Loop

Implementation progress and the required evidence/decision ledger live in
[`STABILITY_LOOP_AUDIT.md`](STABILITY_LOOP_AUDIT.md). That ledger is part of
this plan: a milestone is not complete until its implementation, validation,
privacy scan, reviewer result, and affected truth-table cells are recorded
there.

## Summary

Build an opt-in macOS Stability configuration for the legacy plaintext File
Provider. It will use a real development bearer token stored through the
existing manual-token Keychain flow, replace activity/conflict SQLite
persistence with per-run JSONL audit files, drive Finder through Accessibility
automation, and verify resulting server state against a lab-owned disposable
kDrive root.

The API audit will use version-pinned evidence from the official
[iOS](https://github.com/Infomaniak/ios-kDrive),
[Android](https://github.com/Infomaniak/android-kDrive), and
[desktop](https://github.com/Infomaniak/desktop-kDrive) clients, with live
server observations taking precedence.

## Stability Runtime And Diagnostics

- Add a `Stability` Xcode build configuration and app/File Provider extension
  schemes, using a `STABILITY` compilation condition across all runtime-owning
  targets.
- Reuse the current app identity. Before a run, preflight must reject normal
  registered domains and instruct the operator to use
  `scripts/uninstall-file-provider.sh --dry-run` then the explicit safe `--yes`
  reset; never invoke hard purge automatically.
- Introduce a shared diagnostic interface (`ProviderDiagnosticRecording` plus
  versioned `ProviderDiagnosticEvent`) for File Provider callbacks and typed
  kDrive operations.
- In Stability builds, construct a JSONL-backed event store everywhere the
  current SQLite event store is created: app, File Provider extension, and
  contextual-action runtime. Snapshot, anchor, and working-set SQLite storage
  remains unchanged.
- Write one app-group run bundle per run: immutable `run.json`, append-only
  `events.jsonl`, API observations, assertion results, and a final summary.
  Support Activity UI paging/export by replaying the JSONL events through the
  existing event-store protocols.
- Record sanitized callback starts/completions, changed-field shapes,
  pagination/anchor state, request route templates and option shapes,
  status/error classes, durations, progress/cancellation, and correlation IDs.
  Never log tokens, authorization headers, URLs with identifiers, bodies, file
  bytes, names, paths, or share links.
- Serialize cross-process JSONL appends with an advisory file lock; tolerate
  only a partial trailing line after interruption, and surface other corruption
  in the Stability Lab. Retain the newest 20 completed runs up to 250 MB,
  pruning only whole completed bundles.

## Live Finder Lab

- Add a Stability Lab to provision a unique top-level test root under a
  dedicated non-customer account, store its stable ID in the domain
  configuration, and register the File Provider against that root rather than
  the drive root.
- Reuse the existing manual access-token UI and shared Keychain; do not accept
  credentials from launch arguments, environment variables, files, or scripts.
- Require an explicit destructive confirmation to reset the lab root. Verify
  that the configured root is non-root, directly owned by the lab, and matches
  its stored ownership marker before deleting only its contents.
- Add an app command mode and `scripts/run-finder-stability.sh` to start/finish
  runs, capture API baselines and assertions, open Finder, and assemble the
  evidence bundle without printing credentials or private URLs.
- Add an Accessibility/Apple Events Finder runner with preflight checks for
  Accessibility, Finder Automation, File Provider registration, and consent
  state. It automates stable actions and reports a checkpoint—not a false
  failure—for OS-owned consent or variable contextual UI.
- Cover enumeration and change anchors; hydrate/evict/download; file and
  directory creation; edits/uploads; rename; move; trash/restore/permanent
  deletion; concurrent remote changes and preserve-both behavior;
  cancellation/progress; working-set refresh; and supported contextual actions.
  Each step asserts both Finder-visible state and server-authoritative state,
  then attaches correlated diagnostics.

## kDrive API Evidence Audit

- Create a version-pinned API evidence matrix covering every operation in
  `KDriveFileProviding` and `KDriveContextActionProviding`: route/options,
  pagination/action semantics, ETags and conflict policies,
  transfer/cancellation behavior, mutations, trash, sharing, versions, and
  error mapping.
- For each entry, capture the potassiumChannel 0.3.0 pin, official API
  documentation, live observation, and exact source permalink/commit from the
  three reference clients. Record discrepancies, the selected behavior, and its
  rationale using: live server, then official docs, then client implementation.
- Turn each accepted decision into typed request/response fixture tests. Treat
  client code as behavioral evidence only; do not copy GPL implementation.
- Correct stale documentation that still claims potassiumChannel 0.2.0, and
  update `doc/KDRIVE_API_MAPPING.md`, `doc/LOGGING.md`, and
  `doc/TESTING_AND_DEVELOPMENT.md`.
- Update `doc/CONFLICT_RESOLUTION_TRUTH_TABLE.md` and its regression evidence
  for every mutation, ETag, conflict, retry, or error-mapping decision affected
  by the audit.

## Validation

- Unit-test JSONL encoding/replay, locking, interrupted writes, retention,
  redaction, event-store compatibility, Stability-only factory selection, root
  ownership guards, and no-token/no-private-value assertions.
- Add adapter tests for every audited request shape and server rule, using
  fixtures generated from sanitized live observations; keep all live checks out
  of CI.
- Test Stability Lab provisioning/reset and command preflight with injected
  remote, Keychain, and domain fakes.
- Validate the Accessibility runner's permission and checkpoint behavior
  locally; run full live Finder scenarios only with the development account.
- Run the relevant Xcode build/test matrix on macOS, iOS Simulator, and
  visionOS after shared runtime changes.

## Assumptions

- Initial live coverage is macOS Finder and the legacy plaintext engine only;
  opaque vault validation becomes a separate stability loop.
- The operator provisions and manually enters a real development access token,
  and uses an account/root that contains no customer data.
- Finder automation may require one-time macOS permissions and explicit
  checkpoints for non-deterministic system UI.
- The Stability build shares today's identity, so its domain-isolation preflight
  is mandatory.
