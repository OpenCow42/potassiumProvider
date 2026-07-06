# File Provider Cleanup

`scripts/uninstall-file-provider.sh` is the supported local development cleanup
path for this app's macOS File Provider install. Use it instead of manually
deleting `~/Library/CloudStorage` contents, app group files, or private File
Provider databases.

The script runs the signed macOS containing app with its hidden
`--file-provider-uninstall` command. That keeps domain management inside the
app's bundle, entitlements, app group, and keychain access group.

## Quick Start

Inspect first:

```sh
scripts/uninstall-file-provider.sh --dry-run
```

Perform the normal safe development reset:

```sh
scripts/uninstall-file-provider.sh --yes
```

Also delete the saved OAuth token:

```sh
scripts/uninstall-file-provider.sh --yes --full-logout
```

Use the system remove-all path only for a broken local development install:

```sh
scripts/uninstall-file-provider.sh --yes --hard-purge
```

## Script Wrapper Behavior

Before invoking the app, the wrapper checks whether `fileproviderd` still sees
this provider with `document group name: none`. That state means macOS has stale
provider metadata, usually from an older Xcode archive built before
`NSExtensionFileProviderDocumentGroup` was present.

When that stale state is detected, the wrapper scans
`~/Library/Developer/Xcode/Archives` for archived
`potassiumProviderFileProvider.appex` bundles with the expected provider bundle
identifier but the wrong or missing document group. It unregisters the containing
archived app from LaunchServices and restarts `fileproviderd`, then continues
with the normal app command.

If no app path is provided, the wrapper builds the macOS app with:

```sh
xcodebuild build \
  -project potassiumProvider.xcodeproj \
  -scheme potassiumProvider \
  -destination 'platform=macOS'
```

Pass `--app /path/to/potassiumProvider.app` to reuse an existing app bundle.
Point `--app` at a normal built app bundle, not an `xcodebuild test` product
that contains XCTest injection libraries.

## App Command Behavior

`--dry-run` prints the plan and does not remove domains, SQLite rows, domain
configuration JSON, ConflictStaging contents, or OAuth tokens.

Without `--yes`, a non-dry run prints the plan and exits without mutating local
state.

`--yes` is the normal dev reset:

- removes this app's registered File Provider domains through
  `NSFileProviderManager` using the preserve-dirty-user-data mode;
- removes matching `DomainConfigurations` JSON files;
- removes matching SQLite snapshot, conflict, and activity rows;
- keeps ConflictStaging contents;
- keeps the saved OAuth token.

If File Provider domain listing fails, the app can still build a cleanup plan
from saved domain configurations. For plain `--yes`, targeted domain removal
must still succeed; otherwise the command stops with a detailed File Provider
error instead of silently escalating to a destructive mode.

`--full-logout` includes the normal dev reset and also deletes the saved OAuth
token.

`--hard-purge` is the destructive local reset:

- uses File Provider remove-all mode;
- deletes ConflictStaging contents;
- deletes the saved OAuth token;
- may use the File Provider remove-all fallback if domain listing failed and
  targeted removal by saved configuration also fails.

## Safety Boundary

The cleanup script does not delete remote kDrive files.

The cleanup script also does not directly delete Finder storage,
`~/Library/CloudStorage`, or private File Provider system databases. If File
Provider system state is corrupt beyond the supported APIs and the stale archive
repair, diagnose with `fileproviderctl dump` or `fileproviderctl check` first and
document any new cleanup path before automating it.
