# Contextual Actions

Version 0.3 adds actionable kDrive commands to Finder and Files while remaining
on potassiumChannel 0.2.0. Every action is single-selection.

## Direct Provider Actions

`potassiumProviderFileProvider` adopts `NSFileProviderCustomAction`. Its
extension plist declares:

- Add to kDrive Favorites
- Remove from kDrive Favorites
- Duplicate on kDrive
- Restore from kDrive Trash

`FileProviderItem.userInfo` exposes `isDirectory`, `isFavorite`, `isTrashed`,
and `isRoot` for activation predicates. Favorite actions are mutually exclusive,
duplicate is unavailable in trash, restore is available only in trash, and no
contextual action is offered for the provider root.

`KDriveContextActionCoordinator` performs the remote sequence and returns the
affected parent IDs. Favorite mutations refetch authoritative metadata.
Duplicate uses kDrive's server-side operation and refetches the created item,
without downloading content. Restore checks whether the original parent still
exists and falls back to the drive root when it does not. The extension then
invalidates affected snapshots and signals each parent plus the working set.

Every direct action uses `FileProviderOperationLifecycle` for cancellable,
exactly-once completion. Cancellation is checked immediately before a remote
mutation. Activity uses only sanitized favorite, duplicate, and restore
summaries.

## Native Offline Behavior

Completed remote items report `isUploaded`. Normal items support system
eviction; macOS additionally uses lazy content policy. Finder/Files therefore
owns Download Now and Remove Download presentation. Trash items have the trash
container as their parent, expose trash state, and allow reading and permanent
deletion without rename, move, write, or retrash capabilities.

The provider does not set `favoriteRank`: potassiumChannel 0.2.0 exposes
favorite state but no portable favorite ordering.

## UI Actions

The embedded `potassiumProviderActions` target uses
`FPUIActionExtensionViewController` and hosts SwiftUI on macOS, iOS, and
visionOS. It shares the app group and keychain access group with the app and
provider extension.

`ProviderActionRuntime` resolves the selected domain from
`extensionContext.domainIdentifier`, loads its account-scoped token, refreshes
OAuth when required, creates the typed service, and opens the shared event
store. Missing configuration or credentials returns a sanitized message that
directs the user to the containing app.

### Share kDrive Link

The panel supports one nontrashed file or folder. A 404 from
`getFileShareLink` means no link; other authentication, permission, and network
failures propagate.

New links default to public read-only access, downloads enabled, file
information visible, and comments, editing, access requests, statistics, and
expiry disabled. The user can choose password access, expiry, downloads, and
comments. Existing links can be copied, sent through the system share sheet,
updated, or disabled after destructive confirmation.

Passwords and returned URLs remain in view-model memory only. They are never
logged, persisted, placed in activity summaries, or exported in diagnostics.
Success and failure activity uses fixed summaries and numeric/domain error
diagnostics, following the provider callback redaction boundary.

### Version History

The panel supports one nontrashed document. It pages the nondeprecated v3
version list, sorts results newest-first, and displays timestamp, editor, and
size.

Restore as Copy refetches the current item, uses its current parent, and asks
kDrive to restore under a timestamped name such as
`Report (restored 2026-07-23 22.45 A1B2C3).pdf`. The short random suffix keeps
repeated restores collision-resistant. It never overwrites the current file.
After success, it signals the destination parent and working set.

## Shared API Boundary

`KDriveContextActionProviding` contains only action-specific methods:
favorite, duplicate, trash restore, share-link CRUD, version pagination, and
version restore. `PotassiumKDriveService` implements it exclusively with typed
PotassiumKDrive 0.2.0 service calls. Existing `KDriveFileProviding` mutation
semantics remain unchanged.
