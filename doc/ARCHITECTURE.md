# Architecture

`potassiumProvider` is split into a SwiftUI setup app, a replicated File
Provider extension, and a shared framework that contains kDrive models,
networking adapters, account-scoped authentication helpers, and persistence.

```mermaid
flowchart LR
    User["User / Files app"] --> FP["potassiumProviderFileProvider"]
    App["SwiftUI app"] --> Domain["NSFileProviderManager domains"]
    App --> Core["PotassiumProviderCore"]
    FP --> Core
    Core --> KC["potassiumChannel"]
    KC --> KDrive["Infomaniak kDrive APIs"]
    Core --> Keychain["Keychain tokens"]
    Core --> AppGroup["App group storage"]
    AppGroup --> Accounts["Accounts/*.json"]
    AppGroup --> DomainJSON["DomainConfigurations/*.json"]
    AppGroup --> Snapshots["Snapshots.sqlite3"]
```

## Targets

- `potassiumProvider`: SwiftUI app used to connect multiple local accounts,
  load kDrives per account, register File Provider domains, remove configured
  domains, and log out accounts independently.
- `potassiumProviderFileProvider`: `NSFileProviderReplicatedExtension`
  implementation used by the system to enumerate, fetch, create, modify, trash,
  and delete items.
- `PotassiumProviderCore`: shared framework with domain configuration storage,
  OAuth/keychain storage, kDrive models, kDrive service adapter, snapshot diffing,
  SQLite snapshot storage, unified-log categories, durable activity retention,
  and redacted support-log export.
- `potassiumProviderTests`: Swift Testing unit tests for shared behavior and app
  model flows.
- `potassiumProviderUITests`: XCTest UI automation tests.

## Ownership Boundaries

- The app owns account setup, domain registration, domain removal, and
  independent account logout.
- The File Provider extension owns Apple's runtime callbacks and maps those
  callbacks to `KDriveFileProviding` operations.
- `PotassiumProviderCore` owns typed provider models, persistence protocols,
  OAuth utilities, and the `PotassiumKDriveService` adapter.
- `potassiumChannel` owns the typed request builders and service calls for
  Infomaniak APIs.
- The app group is the shared storage boundary between app and extension.
- The keychain access group is the shared credential boundary. Tokens are keyed
  by local account identifier.

## Runtime Flow

At runtime, the extension constructs a `FileProviderRuntime` for each callback.
That runtime loads the domain configuration from the app group, uses the
configuration's `accountIdentifier` to load and refresh the correct OAuth token
from keychain when needed, creates a `PotassiumKDriveService`, and opens the
SQLite snapshot store.

The extension does not keep a long-lived process-level sync engine. Each File
Provider callback performs the work it was asked to do, then returns via Apple's
completion handler.

## Local Reference Tree

`SynchronizingFilesUsingFileProviderExtensions/` is Apple's local sample tree.
It is useful for comparing concepts such as enumeration, domain state, and
conflict handling, but it is not integrated into `potassiumProvider.xcodeproj`
and should not be treated as part of this product's build graph.
