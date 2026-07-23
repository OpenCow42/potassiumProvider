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
- choosing local or eligible external-volume storage on macOS 15 or later
- changing storage through a journaled remove-and-recreate transition and
  repairing interrupted transitions
- enabling or releasing macOS Desktop & Documents known-folder sync
- logging out one account without touching other accounts
- showing a Status dashboard for configured accounts, drives, cached snapshots,
  and sanitized provider activity
- showing Setup for account and drive configuration

On macOS, the app runs as an accessory menu bar app: it hides its Dock icon and
keeps an atom status item visible while the process is running. Clicking the
status item reveals the setup window, and right-clicking it opens a menu with a
close option. Closing the setup window does not quit the app.

The main window has three tabs: Status, Setup, and Activities. Status is first
and is always the default, including when no drives are configured. Its empty
state links to Setup, where accounts, domains, storage, and repairs are managed.

The Status dashboard only uses local/provider-safe state: local account records,
configured domain records, live File Provider placement state, currently loaded
kDrive summaries, SQLite listing snapshot aggregates, and sanitized
activity/conflict counts. Each drive card names its storage location and reports
Connected, Registering, Moving, Authentication Required, External Drive
Disconnected, or Needs Repair. Authentication, disconnected-volume, and repair
states contribute to the Issues total; registering and moving are informational.
The dashboard does not fetch remote account profile data, quotas, OAuth token
details, private links, or file contents.

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

- `configurationIdentifier`: stable app identity used for the configuration
  JSON filename, SwiftUI row identity, repair journal, and external-domain binding
- `domainIdentifier`: current `NSFileProviderDomainIdentifier`; local placement
  can use the requested identifier, while Apple generates this identifier for an
  external domain and it can change when storage is recreated
- `accountIdentifier`: local account whose keychain token should be used
- `displayName`: Finder/Files-visible name derived from `driveName`, for
  example `Work Drive`
- `driveID`: kDrive identifier used in API calls
- `driveName`: display name returned by kDrive or entered manually
- `rootFileID`: kDrive root folder ID; currently defaults to `1`
- `storageLocation`: either `onThisMac` or an external volume's UUID and local
  display name
- `createdAt` and `updatedAt`: local metadata for the configuration

Domain configurations are stored as JSON files in the app group under
`DomainConfigurations/`, keyed by `configurationIdentifier`. Legacy JSON without
`configurationIdentifier` treats its existing domain identifier as the stable
configuration identity; legacy JSON without `accountIdentifier` is migrated to
the fixed `legacy-account` local account. Legacy JSON without `storageLocation`
defaults to `onThisMac`.

Known-folder activation is not stored in domain JSON. On macOS,
`NSFileProviderDomain.replicatedKnownFolders` is the source of truth.

Finder/Files names use the drive name when unique. If multiple configured
domains would have the same name, the app appends the account display name; if
that is still ambiguous, it appends the drive ID and then a short domain ID.

## Adding A Domain

The add flow is:

1. The user adds an account through OAuth or by saving a manual access token.
2. The app creates a local account record and saves the token under that account.
3. The app loads kDrives for that account through `PotassiumKDriveService.listDrives()`.
4. The user chooses a discovered drive row for that account. On macOS, a storage
   sheet offers On This Mac or External Drive; other platforms use local storage.
5. `PotassiumProviderAppModel.addDomain()` creates a stable
   `configurationIdentifier` and a
   `ProviderDomainConfiguration` whose display name is derived from the drive
   name and, when needed, the account display name.
6. For an external target, the app holds security-scoped access through
   preparation and registration, normalizes the selected folder to its volume
   root, verifies Apple's eligibility result and the prepared domain's volume
   UUID, and records Apple's generated domain identifier.
7. The app saves the configuration to the app group, then registers the exact
   prepared `NSFileProviderDomain`. On macOS 15 or later, the domain advertises
   support for Desktop and Documents together.
8. If registration fails, the app rolls back the saved configuration and removes
   any snapshots for that domain.

The configuration is saved before registration so the extension can find it when
the system starts calling into the new domain.

On reload, the app normalizes stored configurations to the current Finder-visible
display-name policy and compares them with registered system domains. An external
domain must be looked up as the exact registered object using its persisted,
Apple-generated identifier; the app never reconstructs an external domain from
display name and identifier. Missing or mismatched registrations and interrupted
relocation journals become repair states instead of silent replacement domains.

## External Volume Storage On macOS 15 Or Later

External placement is volume selection, not folder selection. The open panel
accepts any folder so macOS can grant security-scoped access, but the app resolves
the containing volume root before inspection and registration. Apple's File
Provider subsystem chooses and owns the actual domain storage folder.

The app calls
[`NSFileProviderManager.checkDomainsCanBeStoredOnVolume(at:)`](https://developer.apple.com/documentation/fileprovider/nsfileprovidermanager/checkdomainscanbestoredonvolume(at:))
and permits registration only when Apple returns eligible. The supported target
is writable, local, encrypted APFS. Ineligible UI explains all Apple reason bits:
unknown eligibility, non-APFS, unencrypted, read-only, network, and quarantined.
The sheet also shows the volume name and capacity information available from
macOS.

The external initializer stores an opaque, versioned binding in domain
`userInfo`: only the stable `configurationIdentifier` is present. It never
contains an account identifier, bearer or refresh token, path, private URL, or
customer data. The extension's external-volume connection callback resolves the
configuration from this Mac's app group, verifies the current generated domain
identifier and volume UUID, and requires usable credentials from this Mac's
keychain. Moving the physical drive to another Mac does not transfer an approved
kDrive session.

Disconnecting a configured volume leaves the configuration record intact. Setup
and Status surface the placement state; Setup supplies the Repair action. When
the state is External Drive Disconnected, mutation controls—including Remove
from Files—are disabled, and logout is blocked before credentials or local
records are deleted. Reconnect the same volume, then finish or repair the File
Provider operation.

## Changing Storage And Recovery

File Provider has no in-place domain move operation, so Change Storage is a
remove-and-recreate transition:

1. Record the source, target, and known-folder state in a relocation journal,
   then wait for the source domain to stabilize.
2. If Desktop & Documents are active, release both known folders, persist that
   phase, and wait again.
3. Prepare the exact target domain. External targets receive a new Apple-generated
   domain identifier; the stable configuration identifier does not change.
4. Remove the source with preserve-dirty-user-data mode. If macOS returns a
   preserved-data URL, the app offers to reveal it in Finder.
5. Save the replacement configuration and register the prepared target.
6. Remove SQLite rows keyed by the old domain identifier.
7. Reclaim Desktop & Documents when they were active, including renewed consent
   when macOS requires it.

Every material phase is recorded under `DomainRelocations/`. A failure before
source removal can restore known folders and keep the source. A failure after
source removal attempts to recreate the source placement. A registered target
whose cleanup is incomplete, a failed source recovery, or an incomplete
known-folder reclaim remains journaled and appears as Needs Repair after relaunch.
Repair completes the safest phase supported by the journal and mounted-volume
state rather than guessing from a display name.

## Desktop & Documents On macOS

On macOS 15 or later, a configured drive row can opt in to Apple's known-folder
feature. This is not arbitrary-folder sync: Apple currently permits Desktop and
Documents to be claimed only together.

The app resolves the existing root-level kDrive directory named `Private` and
uses its item identifier as the common parent for `Private/Desktop` and
`Private/Documents`. The `Private` directory must already exist and be a
directory. File Provider reuses directory children with the recommended names
or creates them when absent; invalid or colliding locations fail the claim.

Claiming begins only from the app's explicit control and presents Apple's user
consent UI. Cancellation leaves the previous state unchanged. The extension's
`getKnownFolderLocations` callback returns the same two locations when macOS
initiates a switch outside that claim call. The app reads live state from the
registered domain, refreshes it when domain state changes, and provides a
matching control to stop syncing both folders through `releaseKnownFolders`.

## Removing A Domain

The remove flow is:

1. On macOS, the app refreshes live known-folder state and releases Desktop and
   Documents when this domain owns them. A release failure aborts removal.
2. `NSFileProviderManager.remove(_:)` removes the exact registered domain from
   the system. External domains are not reconstructed for removal.
3. `KDriveSnapshotStoring.removeSnapshots(domainIdentifier:)` deletes all SQLite
   snapshots for that domain.
4. `DomainConfigurationFileStore.remove(configurationIdentifier:)` deletes the
   stable configuration JSON file.
5. The app refreshes its visible domain list.

Removing a domain only removes provider state from this app. It does not delete
remote kDrive files. A disconnected external placement is not removed by
discarding JSON: the UI blocks removal until the volume is reconnected or the
placement can be repaired safely.

## Logging Out One Account

Independent logout first removes every File Provider domain tied to that
account, including domain JSON, snapshots, activity/conflict rows, and thumbnail
cache entries. On macOS this includes releasing any known folders owned by those
domains; a release failure stops logout. Only after domain cleanup succeeds does
the app delete that account's keychain token and account JSON. Domains and tokens
for other accounts are left untouched. Logout is also blocked while one of the
account's external volumes is unavailable or a storage transition must be
finished/repaired, so credentials cannot disappear before File Provider cleanup.

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
