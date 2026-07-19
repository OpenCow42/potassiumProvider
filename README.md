# potassiumProvider

<table>
  <tr>
    <td width="112">
      <img src="potassiumProvider/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png" alt="potassiumProvider app icon" width="96">
    </td>
    <td>
      <code>potassiumProvider</code> is a Swift/Xcode app that experiments with
      exposing an Infomaniak kDrive account through Apple's File Provider APIs.
    </td>
  </tr>
</table>

## ⚠️ No Support Or Guarantee ⚠️

This project is a community effort. **No support, uptime, compatibility,
maintenance, or data-safety guarantee is provided.** Treat it as experimental
software and review the implementation carefully before using it with important
data.

## Documentation Index

- [0.3.0 Release Notes](CHANGELOG.md): actionable kDrive behavior, dependency
  state, validation, and remaining manual release gates.
- [Architecture](doc/ARCHITECTURE.md): targets, modules, persistence, runtime
  boundaries, and high-level data flow.
- [Encrypted Vault Format v2](doc/ENCRYPTED_VAULT.md): threat model, leakage,
  device-local and optional iCloud Keychain custody, guided recovery, binary
  formats, opaque synchronization, rollback behavior, and security-review
  feature gates.
- [Conflict Resolution Truth Table](doc/CONFLICT_RESOLUTION_TRUTH_TABLE.md):
  normative encrypted-vault data-safety decisions, evidence, and open gates.
- [App And Domains](doc/APP_AND_DOMAINS.md): SwiftUI setup app, kDrive loading,
  File Provider domain registration, macOS storage placement, and Desktop &
  Documents controls.
- [Authentication](doc/AUTHENTICATION.md): OAuth PKCE, manual token entry,
  keychain storage, refresh behavior, and secret-handling rules.
- [File Provider Lifecycle](doc/FILE_PROVIDER_LIFECYCLE.md): Apple callbacks,
  local and external-volume domains, known-folder locations, mutations,
  enumeration, and SQLite touch points.
- [Contextual Actions](doc/CONTEXTUAL_ACTIONS.md): Finder/Files favorite,
  duplicate, restore, share-link, and version-history actions.
- [Listing And Versioning](doc/LISTING_AND_VERSIONING.md): how Apple
  enumeration, sync anchors, kDrive listing APIs, SQLite caching, and item
  versions fit together.
- [Persistence](doc/PERSISTENCE.md): app group files, domain JSON, SQLite
  snapshot tables, and what is not cached.
- [kDrive API Mapping](doc/KDRIVE_API_MAPPING.md): provider operations mapped
  to potassiumChannel service calls and visible kDrive endpoints.
- [Mutations](doc/MUTATIONS.md): create, upload, replace, rename, move, trash,
  delete, server-authoritative returns, and later reconciliation.
- [Conflict Resolution Truth Table And Safety Register](doc/CONFLICT_RESOLUTION_TRUTH_TABLE.md):
  mission-critical audited decisions, data-loss and soft-lock findings, user
  recovery limits, and the mandatory maintenance procedure.
- [Conflicts](doc/CONFLICTS.md): conflict cases, current resolution behavior,
  design context, risks, and safer future direction.
- [File Provider Cleanup](doc/FILE_PROVIDER_CLEANUP.md): local development
  uninstall script, reset modes, stale registration repair, and safety boundary.
- [Testing And Development](doc/TESTING_AND_DEVELOPMENT.md): schemes,
  dependencies, commands, and local-state caveats.

## Project Shape

The root Xcode project is the source of truth:

- App target: `potassiumProvider`
- File Provider extension target: `potassiumProviderFileProvider`
- File Provider UI extension target: `potassiumProviderActions`
- Shared framework target: `PotassiumProviderCore`
- Unit tests: `potassiumProviderTests`
- UI tests: `potassiumProviderUITests`

The local `SynchronizingFilesUsingFileProviderExtensions/` folder is Apple's
sample/reference project. It is useful for comparison, but it is not the source
of truth for this app and is not integrated into the root Xcode project.

Supported validation platforms are iOS Simulator, macOS, and visionOS.

## Useful Commands

List schemes and targets:

```sh
xcodebuild -list -project potassiumProvider.xcodeproj
```

Build the app and extension:

```sh
xcodebuild build \
  -project potassiumProvider.xcodeproj \
  -scheme potassiumProvider \
  -destination 'platform=iOS Simulator,OS=26.5,name=iPhone 17'
```

Build on Mac as well:

```sh
xcodebuild build \
  -project potassiumProvider.xcodeproj \
  -scheme potassiumProvider \
  -destination 'platform=macOS'
```

Build on visionOS as well:

```sh
xcodebuild build \
  -project potassiumProvider.xcodeproj \
  -scheme potassiumProvider \
  -destination 'generic/platform=visionOS'
```

Run unit tests:

```sh
xcodebuild test \
  -project potassiumProvider.xcodeproj \
  -scheme potassiumProvider \
  -destination 'platform=iOS Simulator,OS=26.5,name=iPhone 17'
```

Run unit tests on Mac as well:

```sh
xcodebuild test \
  -project potassiumProvider.xcodeproj \
  -scheme potassiumProvider \
  -destination 'platform=macOS'
```

Run unit tests on visionOS as well:

```sh
xcodebuild test \
  -project potassiumProvider.xcodeproj \
  -scheme potassiumProvider \
  -destination 'platform=visionOS Simulator,OS=26.5,name=Apple Vision Pro'
```

The shared scheme's Test action contains `potassiumProviderTests` only. UI
automation remains a separate Xcode test-target workflow and does not run in
the command-line matrix above.

Use `xcodebuild -showdestinations` to copy exact Mac or visionOS destinations if
local Xcode requires a more specific variant.

## External File Provider Storage On macOS

On macOS 15 or later, a kDrive File Provider domain can be placed on this Mac or
on an eligible external volume. The picker accepts a folder only so the user can
grant access; the app normalizes that choice to its containing volume, and macOS
chooses the provider-managed folder on that volume. It is not arbitrary-folder
sync and the selected folder is not used as a kDrive root.

Before registration, the app asks Apple's
[`checkDomainsCanBeStoredOnVolume(at:)`](https://developer.apple.com/documentation/fileprovider/nsfileprovidermanager/checkdomainscanbestoredonvolume(at:))
API whether the volume is eligible. The intended physical target is writable,
local, encrypted APFS. The UI reports Apple's unsupported reasons for an unknown,
non-APFS, unencrypted, read-only, network, or quarantined volume.

External domains are bound to a stable local configuration identifier, while
Apple generates the File Provider domain identifier. Changing storage therefore
removes and recreates the system domain without changing the drive's identity in
the app. The external domain's opaque `userInfo` contains only a binding schema
version and that local configuration identifier—never account identifiers,
tokens, URLs, or other credentials. Connection approval requires the matching
configuration and usable keychain credentials on the same Mac.

Setup provides add, Change Storage, and Repair flows. Status shows the configured
volume and live placement state. Keep the external drive connected while using
the domain; an absent volume is surfaced as an actionable warning and blocks
unsafe removal/logout until the drive is reconnected or the placement is
repaired. See [App And Domains](doc/APP_AND_DOMAINS.md) and
[Testing And Development](doc/TESTING_AND_DEVELOPMENT.md) for the lifecycle and
physical-drive validation matrix.

## Safety Notes

- Do not commit bearer tokens, refresh tokens, account identifiers, private
  links, or user data.
- Encrypted vaults are experimental and disabled by default pending independent
  cryptographic review. The feature flag is not a production-readiness claim.
- Every encrypted-vault activation route starts with a mandatory
  unsupported-feature and complete-data-loss warning whose continuation remains
  disabled for five seconds.
- Encrypted-vault onboarding always requires a verified offline recovery kit.
  Optional iCloud Keychain access is a separately gated convenience: it can
  open a vault on another trusted Apple device, but it does not replace offline
  recovery or revoke keys already imported by another device.
- Conflict handling is mission-critical. Read the
  [Conflict Resolution Truth Table And Safety Register](doc/CONFLICT_RESOLUTION_TRUTH_TABLE.md)
  before relying on the provider for important files. Any change to conflict
  detection, mutation ordering, server conflict policy, retry/error behavior,
  or user recovery must update that file in the same change; a stale table is a
  release-blocking data-safety defect.
- The current conflict handling still delegates some decisions to kDrive. Read
  [Conflicts](doc/CONFLICTS.md) for the broader design context.
- File creates stage bytes before their first network send. Existing-file
  content uploads use kDrive ETags with `If-Match`, stage local bytes before
  preflight, and preserve stale/raced edits as visible renamed copies unless
  File Provider explicitly requests fail-on-conflict. Combined
  move/rename/content/trash callbacks are applied in order; unapplied metadata
  is returned as still pending.
- SQLite snapshots cache metadata only. File contents and thumbnails are not
  stored there.
- On macOS 15 or later, Desktop & Documents protection is an explicit action.
  Encrypted domains preflight ownership and local key availability before
  presenting Apple's consent UI, then upload only opaque vault ciphertext.
  A legacy plaintext Potassium owner blocks the encrypted known-folder claim.
  Safe migration and destructive source purge are not implemented.
- External File Provider storage is experimental and must be validated with a
  disposable encrypted APFS volume and non-customer data before relying on it.

## License

This project is licensed under the GNU General Public License v3.0, matching
[Infomaniak/ios-kDrive](https://github.com/Infomaniak/ios-kDrive). See
[LICENSE](LICENSE) for the full text.
