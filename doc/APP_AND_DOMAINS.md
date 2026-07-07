# App And Domains

The main app is a SwiftUI shell around `PotassiumProviderAppModel`. Its job is
to manage local kDrive accounts, discover or accept kDrives for each account,
create `ProviderDomainConfiguration` records, and register those configurations
as File Provider domains.

## App Responsibilities

The app handles:

- connecting through Infomaniak OAuth or accepting a manual access token
- storing multiple local account records and account-scoped keychain tokens
- loading available kDrives for each authenticated account
- automatically loading kDrives for saved accounts when the setup view appears
  and usable account credentials are available
- building a domain configuration for the selected account and drive
- registering and removing `NSFileProviderDomain` entries
- logging out one account without touching other accounts
- showing configured domains and simple status/error state

On macOS, the app runs as an accessory menu bar app: it hides its Dock icon and
keeps an atom status item visible while the process is running. Clicking the
status item reveals the setup window, and right-clicking it opens a menu with a
close option. Closing the setup window does not quit the app.

The app does not enumerate files itself. File listing is handled by the File
Provider extension after the system asks for an enumerator. Each extension
callback loads the domain configuration, uses that configuration's
`accountIdentifier` to load the correct token, and then talks to kDrive with
that account's bearer token.

## Accounts

`ProviderAccount` is the local record for one connected account. It stores a
generated local identifier, an editable display name, the authentication kind,
and local dates. It intentionally does not store remote Infomaniak account IDs or
profile data.

OAuth and manual-token accounts use the same account model. A manual-token
account may stop working when the access token expires because it cannot be
refreshed.

When the setup view is shown, the app attempts one automatic kDrive discovery
per saved account that has a usable local token and no drives loaded yet. Missing
tokens and expired non-refreshable tokens are skipped silently so the account can
be refreshed manually or reconnected without creating repeated setup-page
errors.

## Domain Configuration

`ProviderDomainConfiguration` is the local record that connects an Apple File
Provider domain to a kDrive:

- `domainIdentifier`: stable identifier used as `NSFileProviderDomainIdentifier`
- `accountIdentifier`: local account whose keychain token should be used
- `displayName`: Finder/Files-visible name derived from `driveName`, for
  example `Work Drive`
- `driveID`: kDrive identifier used in API calls
- `driveName`: display name returned by kDrive or entered manually
- `rootFileID`: kDrive root folder ID; currently defaults to `1`
- `createdAt` and `updatedAt`: local metadata for the configuration

Domain configurations are stored as JSON files in the app group under
`DomainConfigurations/`. Legacy JSON without `accountIdentifier` is migrated to
the fixed `legacy-account` local account.

Finder/Files names use the drive name when unique. If multiple configured
domains would have the same name, the app appends the account display name; if
that is still ambiguous, it appends the drive ID and then a short domain ID.

## Adding A Domain

The add flow is:

1. The user adds an account through OAuth or by saving a manual access token.
2. The app creates a local account record and saves the token under that account.
3. The app loads kDrives for that account through `PotassiumKDriveService.listDrives()`.
4. The user chooses a discovered drive row for that account.
5. `PotassiumProviderAppModel.addDomain()` creates a
   `ProviderDomainConfiguration` whose display name is derived from the drive
   name and, when needed, the account display name.
6. The app saves the configuration to the app group.
7. `FileProviderDomainRegistrar.addDomain(for:)` registers an
   `NSFileProviderDomain` with Apple's File Provider manager.
8. If registration fails, the app rolls back the saved configuration and removes
   any snapshots for that domain.

The configuration is saved before registration so the extension can find it when
the system starts calling into the new domain.

On reload, the app also normalizes stored configurations to the current
Finder-visible display-name policy and re-adds each stored
`NSFileProviderDomain`. Re-adding a domain with the same identifier updates the
system's registered display name.

## Removing A Domain

The remove flow is:

1. `NSFileProviderManager.remove(_:)` removes the domain from the system.
2. `KDriveSnapshotStoring.removeSnapshots(domainIdentifier:)` deletes all SQLite
   snapshots for that domain.
3. `DomainConfigurationFileStore.remove(domainIdentifier:)` deletes the domain
   JSON file.
4. The app refreshes its visible domain list.

Removing a domain only removes provider state from this app. It does not delete
remote kDrive files.

## Logging Out One Account

Independent logout first removes every File Provider domain tied to that
account, including domain JSON, snapshots, activity/conflict rows, and thumbnail
cache entries. Only after domain cleanup succeeds does the app delete that
account's keychain token and account JSON. Domains and tokens for other accounts
are left untouched.

For development, `scripts/uninstall-file-provider.sh` can perform the same
domain-detach path outside the UI. It runs the signed macOS app with a hidden
`--file-provider-uninstall` command so domain removal still goes through
`NSFileProviderManager` with the app's entitlements. The default dev reset
preserves dirty local user data and keeps account records and tokens. See
[File Provider Cleanup](FILE_PROVIDER_CLEANUP.md) for the full cleanup script
behavior and hard-purge boundary.

## Manual Tokens

Manual access tokens are accepted for development and testing. Each manual token
creates an independent local account and is saved in the same account-scoped
token store as OAuth tokens. A manually entered token may not have a refresh
token or expiration, so reconnecting may be required when it stops working.
