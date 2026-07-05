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

- [Architecture](doc/ARCHITECTURE.md): targets, modules, persistence, runtime
  boundaries, and high-level data flow.
- [App And Domains](doc/APP_AND_DOMAINS.md): SwiftUI setup app, kDrive loading,
  File Provider domain registration, and domain storage.
- [Authentication](doc/AUTHENTICATION.md): OAuth PKCE, manual token entry,
  keychain storage, refresh behavior, and secret-handling rules.
- [File Provider Lifecycle](doc/FILE_PROVIDER_LIFECYCLE.md): Apple callbacks,
  downloads, mutations, enumeration entrypoints, and SQLite touch points.
- [Listing And Versioning](doc/LISTING_AND_VERSIONING.md): how Apple
  enumeration, sync anchors, kDrive listing APIs, SQLite caching, and item
  versions fit together.
- [Persistence](doc/PERSISTENCE.md): app group files, domain JSON, SQLite
  snapshot tables, and what is not cached.
- [kDrive API Mapping](doc/KDRIVE_API_MAPPING.md): provider operations mapped
  to potassiumChannel service calls and visible kDrive endpoints.
- [Mutations](doc/MUTATIONS.md): create, upload, replace, rename, move, trash,
  delete, server-authoritative returns, and later reconciliation.
- [Conflicts](doc/CONFLICTS.md): conflict cases, current resolution behavior,
  risks, and safer future direction.
- [Testing And Development](doc/TESTING_AND_DEVELOPMENT.md): schemes,
  dependencies, commands, and local-state caveats.

## Project Shape

The root Xcode project is the source of truth:

- App target: `potassiumProvider`
- File Provider extension target: `potassiumProviderFileProvider`
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

Run tests:

```sh
xcodebuild test \
  -project potassiumProvider.xcodeproj \
  -scheme potassiumProvider \
  -destination 'platform=iOS Simulator,OS=26.5,name=iPhone 17'
```

Run tests on Mac as well:

```sh
xcodebuild test \
  -project potassiumProvider.xcodeproj \
  -scheme potassiumProvider \
  -destination 'platform=macOS'
```

Run tests on visionOS as well:

```sh
xcodebuild test \
  -project potassiumProvider.xcodeproj \
  -scheme potassiumProvider \
  -destination 'platform=visionOS Simulator,OS=26.5,name=Apple Vision Pro'
```

If the full scheme stalls during simulator/UI-test cleanup, this has previously
worked more reliably:

```sh
xcodebuild test \
  -project potassiumProvider.xcodeproj \
  -scheme potassiumProvider \
  -destination 'platform=iOS Simulator,OS=26.5,name=iPhone 17' \
  -parallel-testing-enabled NO
```

Use `xcodebuild -showdestinations` to copy exact Mac or visionOS destinations if
local Xcode requires a more specific variant.

## Safety Notes

- Do not commit bearer tokens, refresh tokens, account identifiers, private
  links, or user data.
- The current conflict handling delegates many decisions to kDrive. Read
  [Conflicts](doc/CONFLICTS.md) before relying on it for important files.
- SQLite snapshots cache metadata only. File contents are not stored there.

## License

This project is licensed under the GNU General Public License v3.0, matching
[Infomaniak/ios-kDrive](https://github.com/Infomaniak/ios-kDrive). See
[LICENSE](LICENSE) for the full text.
