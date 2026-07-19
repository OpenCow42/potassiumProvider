# Architecture

`potassiumProvider` is split into a SwiftUI setup app, a replicated File
Provider extension, a File Provider UI action extension, and a shared framework
that contains kDrive models, networking adapters, account-scoped authentication
helpers, action coordination, and persistence.

```mermaid
flowchart LR
    User["User / Files app"] --> FP["potassiumProviderFileProvider"]
    User --> Actions["potassiumProviderActions"]
    App["SwiftUI app"] --> Domain["NSFileProviderManager domains"]
    Domain --> LocalStorage["System-managed local storage"]
    Domain --> ExternalVolume["Eligible encrypted APFS volume (macOS 15+)"]
    App --> Core["PotassiumProviderCore"]
    FP --> Core
    Actions --> Core
    Core --> KC["potassiumChannel"]
    KC --> KDrive["Infomaniak kDrive APIs"]
    Core --> Keychain["Keychain tokens"]
    Core --> AppGroup["App group storage"]
    AppGroup --> Accounts["Accounts/*.json"]
    AppGroup --> DomainJSON["DomainConfigurations/*.json"]
    AppGroup --> Relocations["DomainRelocations/*.json"]
    AppGroup --> Snapshots["Snapshots.sqlite3"]
```

## Targets

- `potassiumProvider`: SwiftUI app used to connect multiple local accounts,
  load kDrives per account, register File Provider domains, remove configured
  domains, choose and change macOS storage placement, repair interrupted moves,
  control Desktop & Documents sync, and log out accounts independently.
- `potassiumProviderFileProvider`: `NSFileProviderReplicatedExtension`
  implementation used by the system to enumerate, fetch, create, modify, trash,
  and delete items, provide macOS known-folder locations, and execute
  background favorite, duplicate, and restore actions.
- `potassiumProviderActions`: `FPUIActionExtensionViewController` hosted
  SwiftUI for share-link management and document version history on macOS,
  iOS, and visionOS.
- `PotassiumProviderCore`: shared framework with domain configuration storage,
  OAuth/keychain storage, kDrive models, kDrive service and contextual-action
  adapters, action runtime/coordinator, snapshot diffing, SQLite snapshot
  storage, unified-log categories, durable activity retention, and redacted
  support-log export.
- `potassiumProviderTests`: Swift Testing unit tests for shared behavior and app
  model flows.
- `potassiumProviderUITests`: XCTest UI automation tests.

## Ownership Boundaries

- The app owns account setup, domain registration, external-volume selection and
  eligibility checks, durable relocation/recovery, live placement and
  known-folder state, user-triggered claim/release, domain removal, and
  independent account logout.
- The File Provider extension owns Apple's runtime callbacks and maps those
  callbacks to `KDriveFileProviding` operations. On macOS it also maps Desktop
  and Documents to `Private/<current Mac name>` on the selected drive, while
  preserving active legacy domains that still point directly at `Private`. For
  an external domain it approves connection only after validating the opaque
  local binding, current volume UUID, and usable same-Mac keychain credentials.
- `PotassiumProviderCore` owns typed provider models, persistence protocols,
  OAuth utilities, and the `PotassiumKDriveService` adapter.
- `potassiumChannel` owns the typed request builders and service calls for
  Infomaniak APIs. The Xcode project requires the published 0.2 release line,
  while `Package.resolved` locks validated builds to potassiumChannel 0.2.0.
- The app group is the shared storage boundary between app and extension.
- The keychain access group is the shared credential boundary. Tokens are keyed
  by local account identifier.

## Domain And Placement Identity

`configurationIdentifier` is the stable app identity for one configured kDrive.
It keys app-group JSON, relocation journals, SwiftUI/status identity, and the
opaque external-domain binding. `domainIdentifier` identifies the current system
domain and can change when storage is recreated; Apple generates it for domains
created with the external-volume initializer. SQLite snapshots and activity are
keyed by this current domain identifier, so a successful move removes the old
domain's rows.

External `NSFileProviderDomain.userInfo` contains only a schema version and the
stable configuration identifier. Account selection and all credentials remain
in the app group/keychain on the Mac. A selected folder is normalized to its
containing volume before the app asks Apple to create the system-managed domain;
no arbitrary user folder becomes part of the provider architecture.

## Runtime Flow

At runtime, the extension constructs a `FileProviderRuntime` for each callback.
A local domain resolves configuration by its current domain identifier. An
external domain decodes its stable configuration binding, then verifies that the
stored current domain identifier and volume UUID match the system domain. The
runtime uses the resulting configuration's `accountIdentifier` to load and
refresh the correct OAuth token from keychain when needed, creates a
`PotassiumKDriveService`, and opens the SQLite snapshot store.

Changing placement is explicitly transactional at the application level rather
than an in-place mutation: stabilize, release known folders when active, prepare
the target, remove the source while preserving dirty data, save/register the
target, clean old domain-keyed rows, and reclaim known folders. The durable
`DomainRelocations` journal is the recovery boundary across crashes and relaunch.

Neither extension keeps a long-lived process-level sync engine. Each File
Provider callback or contextual panel loads account-scoped runtime state,
performs the requested work, signals affected enumerators, and completes
through Apple's extension context.

## Local Reference Tree

`SynchronizingFilesUsingFileProviderExtensions/` is Apple's local sample tree.
It is useful for comparing concepts such as enumeration, domain state, and
conflict handling, but it is not integrated into `potassiumProvider.xcodeproj`
and should not be treated as part of this product's build graph.

## Encrypted vault boundary

For `opaqueVaultV2`, runtime loading adds the root key and trusted frontier from
Keychain, an encrypted UUID-keyed SQLite generation, and
`KDriveObjectStoreProviding` plus `EncryptedVaultProviding`. Provider-facing
code receives only `VaultItem`; `KDriveRemoteItem` remains physical-object
metadata and cannot construct Finder metadata. See
[Encrypted Vault Format v2](ENCRYPTED_VAULT.md).
