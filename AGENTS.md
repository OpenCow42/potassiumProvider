# AGENTS.md

## Project Summary

`potassiumProvider` is an Xcode Swift app for building a Potassium-backed
File Provider experience.

- Language: Swift
- UI: SwiftUI app shell
- Build system: Xcode project, not Tuist and not a root Swift Package
- Scheme: `potassiumProvider`
- Targets: `potassiumProvider`, `potassiumProviderTests`,
  `potassiumProviderUITests`
- Dependencies: `SQLite.swift` and `potassiumChannel` package products
  `PotassiumChannelCore`, `PotassiumKDrive`, and `PotassiumOAuth`
- Tests: Swift Testing for unit tests, XCTest for UI tests

## Context Map

```text
potassiumProvider/
|-- potassiumProvider/           # App target; SwiftUI entry point and views
|-- potassiumProviderTests/      # Swift Testing unit tests
|-- potassiumProviderUITests/    # XCTest UI automation tests
|-- potassiumProvider.xcodeproj/ # Source of truth for targets, scheme, settings,
|                                # and SwiftPM package pins
`-- SynchronizingFilesUsingFileProviderExtensions/
                                 # Apple File Provider sample/reference tree.
                                 # At the time this file was written, it is
                                 # present locally but not tracked by git.
```

## Local Command Patterns

Use the root Xcode project as the source of truth:

```sh
xcodebuild -list -project potassiumProvider.xcodeproj
xcodebuild -showdestinations -project potassiumProvider.xcodeproj -scheme potassiumProvider
```

Build and test through the Xcode scheme:

```sh
xcodebuild build \
  -project potassiumProvider.xcodeproj \
  -scheme potassiumProvider \
  -destination 'platform=iOS Simulator,OS=26.5,name=iPhone 17'

xcodebuild test \
  -project potassiumProvider.xcodeproj \
  -scheme potassiumProvider \
  -destination 'platform=iOS Simulator,OS=26.5,name=iPhone 17'
```

Do not import command habits from sibling Tuist or SwiftPM repos unless this
project is explicitly migrated. In particular, do not use `tuist generate`,
`tuist test`, or root-level `swift build` / `swift test` as validation for this
app.

## Swift Engineering Rules

- Follow the Swift API Design Guidelines: optimize for clarity at the call site,
  prefer role-based names, and use precise argument labels.
- Prefer clarity over brevity, especially around File Provider and networking
  behavior.
- Use structured concurrency where practical. Use InfomaniakConcurrency where
  it fits the problem instead of reaching for semaphores or locks. Prefer
  explicit async/await, actors, and isolated state over `@unchecked Sendable`
  whenever possible. Keep cancellation and actor/thread expectations explicit
  when crossing system or network boundaries.
- Keep public APIs and documentation intentional. Document semantic choices when
  API ergonomics hide non-obvious system behavior.
- Keep changes small, focused, and easy to review. Do not mix unrelated
  refactors, formatting churn, and dependency changes with feature work.
- Prefer small source files split along app, service, File Provider, and
  persistence boundaries before files become difficult to review.
- Preserve user work already present in the tree. Never revert changes you did
  not make unless explicitly asked.

## Potassium And API Rules

- Import the split Potassium modules directly, such as `PotassiumChannelCore`,
  `PotassiumKDrive`, and `PotassiumOAuth`. Do not use the old
  `potassiumChannel` module name.
- Keep the `potassiumChannel` package docs as the source of truth for module
  names, request builders, service helpers, and secret-handling expectations.
- Never print, commit, or store Infomaniak bearer tokens, refresh tokens,
  account identifiers, private URLs, live fixtures, or customer/user data.
- Keep networking behavior testable with mocks, fixtures, or injectable
  clients. Live checks must be explicit, locally guarded, and kept out of the
  default test path.
- Prefer typed request/response flows from Potassium products over app-local
  ad hoc HTTP construction.

## File Provider Rules

- Treat `NSFileProvider` enumeration, sync anchors, item identifiers, progress,
  cancellation, and completion handlers as correctness-critical.
- Map File Provider errors deliberately. Resolvable errors such as
  `.notAuthenticated`, `.serverUnreachable`, `.insufficientQuota`, and
  `.cannotSynchronize` should be surfaced in ways the system can recover from.
- Do not assume `SynchronizingFilesUsingFileProviderExtensions/` is integrated
  into `potassiumProvider.xcodeproj`. Check project membership and targets
  before editing or relying on sample code.
- When integrating File Provider code, update app group identifiers,
  entitlements, bundle identifiers, and provisioning settings deliberately and
  consistently across app and extension targets.
- Keep app UI, Potassium API access, File Provider extension logic, and local
  persistence boundaries explicit. Avoid hiding sync semantics behind generic
  helpers that make conflict, durability, or retry behavior unclear.

## Testing And PR Hygiene

- Add or update tests for every meaningful behavior change.
- Use Swift Testing (`import Testing`) for new unit tests unless the work is in
  existing XCTest UI test targets.
- Use XCTest only for UI automation or when extending existing XCTest files.
- Run the relevant `xcodebuild build` or `xcodebuild test` command before
  describing implementation work as complete. If validation cannot be run, say
  exactly why.
- Use Conventional Commits when committing, for example `feat: add file provider
  domain setup` or `test: cover kdrive request mapping`.
- Do not commit generated build artifacts, DerivedData, local caches, editor
  state, `.DS_Store`, credentials, or unrelated file churn.

## Self-correction

Future agents should keep this file useful and current:

1. If targets, schemes, dependencies, or major folders change, update the
   project summary and context map.
2. If the user corrects a local preference, add it to the relevant rules section.
3. If the File Provider sample becomes tracked or integrated into the root
   project, replace the "sample/reference tree" note with the actual ownership
   and validation rules.
4. If this file becomes too verbose, prune it back to high-signal rules.
