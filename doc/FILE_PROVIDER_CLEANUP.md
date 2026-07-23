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

Also delete all saved account records and OAuth tokens:

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

`--dry-run` prints the plan and does not remove domains, SQLite rows, thumbnail
cache files, domain configuration/relocation JSON, account JSON, ConflictStaging
contents, or OAuth tokens.

Without `--yes`, a non-dry run prints the plan and exits without mutating local
state.

`--yes` is the normal dev reset:

- removes this app's registered File Provider domains through
  `NSFileProviderManager` using the preserve-dirty-user-data mode;
- removes matching `DomainConfigurations` JSON files;
- removes matching `DomainRelocations` JSON files;
- removes matching SQLite snapshot, conflict, and activity rows;
- keeps ConflictStaging contents;
- keeps all saved account records and OAuth tokens.

If File Provider domain listing fails, the app can still build a cleanup plan
from saved domain configurations. For plain `--yes`, targeted domain removal
must still succeed; otherwise the command stops with a detailed File Provider
error instead of silently escalating to a destructive mode.

`--full-logout` includes the normal dev reset and also deletes every stored
account record, every account-scoped OAuth token, and the legacy single-token
key if it still exists.

`--hard-purge` is the destructive local reset:

- uses File Provider remove-all mode;
- deletes ConflictStaging contents;
- deletes every stored account record, every account-scoped OAuth token, and the
  legacy single-token key if it still exists;
- may use the File Provider remove-all fallback if domain listing failed and
targeted removal by saved configuration also fails.

## Stable And Generated Identifiers

External-volume domains use an Apple-generated File Provider domain identifier,
and changing storage can replace it. The app's `configurationIdentifier` remains
stable. An interrupted relocation journal can also contain both a source domain
ID and a prepared/registered target domain ID.

The uninstall plan therefore keeps two explicit cleanup sets:

- configuration identifiers from stored configurations and relocation journals,
  used to remove `DomainConfigurations` and `DomainRelocations` files;
- domain identifiers from the actual registered-domain list, current stored
  configurations, and journal source/target fields, used to remove all matching
  SQLite and provider-local state.

Do not replace this plan with display-name matching or assume one stable domain
ID per kDrive. Dry-run output should be checked especially carefully after an
interrupted move. Targeted domain removal resolves the exact object from Apple's
current registered-domain list before removal; it does not reconstruct an
external domain.

Preserve-dirty-user-data removal may return one or more local preserved-data
locations. The command prints those paths for manual review and does not delete
them. A listing failure, missing/disconnected external domain, or stale saved ID
causes plain `--yes` to stop rather than silently escalating to remove-all.

## Safety Boundary

The cleanup script does not delete remote kDrive files.

If a development domain currently owns Desktop & Documents, stop that sync from
the app before running the uninstall wrapper. The wrapper's existing reset modes
remove domains and local provider state; they do not offer a separate
known-folder release workflow.

In the normal UI, an unavailable external volume disables Remove from Files and
blocks account logout until that placement is reconnected or repaired. Keep that
safety boundary when diagnosing a missing drive. The uninstall wrapper is a
development recovery tool, not a user-facing workaround; inspect `--dry-run`,
prefer plain `--yes`, and reconnect the volume when targeted removal requires the
registered external domain.

The cleanup script also does not directly delete Finder storage,
`~/Library/CloudStorage`, or private File Provider system databases. If File
Provider system state is corrupt beyond the supported APIs and the stale archive
repair, diagnose with `fileproviderctl dump` or `fileproviderctl check` first and
document any new cleanup path before automating it.
