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
- enabling or releasing macOS Desktop & Documents known-folder sync
- logging out one account without touching other accounts
- showing a Status dashboard for configured accounts, drives, cached snapshots,
  and sanitized provider activity
- revealing each configured drive through its File Provider user-visible URL
- requesting an immediate working-set refresh for one configured drive
- showing Setup for account and drive configuration through dedicated account
  and drive-management destinations

On macOS, the app runs as an accessory menu bar app: it hides its Dock icon and
keeps an atom status item visible while the process is running. Clicking the
status item reveals the setup window, and right-clicking it opens a menu with a
close option. Closing the setup window does not quit the app.

The main window has three tabs: Status, Setup, and Activities. Status is the
default tab and is a read-only dashboard. Account and drive actions live under
Setup rather than on the dashboard. Switching tabs uses the same short
slide-and-fade motion as Setup navigation; Reduce Motion removes the horizontal
movement and keeps a brief fade.

Setup uses a three-level navigation hierarchy:

1. Setup lists connected accounts and summarizes discovered and configured
   drive counts.
2. An account screen owns rename, drive refresh, logout, and the account's drive
   list.
3. Each drive opens a dedicated management screen for its File Provider and,
   on macOS, known-folder actions.

Account creation has its own destination. Infomaniak OAuth is the primary path;
manual access-token entry remains available in an Advanced section for
development. While stored state is being restored, Setup shows an explicit
loading row instead of briefly presenting the empty-account state. Setup errors
appear in a nonmodal, dismissible banner so background refreshes do not interrupt
navigation with a transient alert.

The Status dashboard only uses local/provider-safe state: local account records,
configured domain records, currently loaded kDrive summaries, SQLite listing
snapshot aggregates, and sanitized activity/conflict counts. It does not fetch
remote account profile data, quotas, OAuth token details, private links, or file
contents.

Each configured drive's management screen has a Show in Finder button on macOS
or Show in Files on iOS and visionOS. The app asks that domain's
`NSFileProviderManager` for the root container's user-visible URL and opens it
through the system. Sync Now signals the domain's working-set enumerator. These
controls do not enumerate files or bypass the extension.

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

Discovery uses the account's bearer token to call the kDrive
`GET /2/drive/init?with=drives` endpoint. A discovered drive is usable when its
role is neither `none` nor `external`, matching the official iOS kDrive client.
Admin and ordinary internal-user drives are shown; unavailable and external
shared drives are excluded from new File Provider domains. The app does not
call the general `/1/account` API or claim that eligibility proves product
ownership.

An account's drive list is the union of usable remote discovery and stored
domain configurations. A configured drive therefore remains manageable when
discovery is unavailable or no longer returns that drive. Its detail screen
uses the saved drive name and explicitly marks remote details as unavailable.

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

Known-folder activation is not stored in domain JSON. On macOS,
`NSFileProviderDomain.replicatedKnownFolders` is the source of truth.

Finder/Files names use the drive name when unique. If multiple configured
domains would have the same name, the app appends the account display name; if
that is still ambiguous, it appends the drive ID and then a short domain ID.

## Adding A Domain

The add flow is:

1. The user adds an account through OAuth or by saving a manual access token.
2. The app creates a local account record and saves the token under that account.
3. The app loads kDrives for that account through
   `PotassiumKDriveService.listDrives()` and keeps drives whose role is neither
   `none` nor `external`.
4. The user opens a usable internal drive and chooses **Add to Files** on its
   management screen.
5. `PotassiumProviderAppModel.addDomain()` creates a
   `ProviderDomainConfiguration` whose display name is derived from the drive
   name and, when needed, the account display name.
6. The app saves the configuration to the app group.
7. `FileProviderDomainRegistrar.addDomain(for:)` registers an
   `NSFileProviderDomain` with Apple's File Provider manager. On macOS 15 or
   later, the domain advertises support for Desktop and Documents together.
8. If registration fails, the app rolls back the saved configuration and removes
   any snapshots for that domain.

The configuration is saved before registration so the extension can find it when
the system starts calling into the new domain.

On reload, the app also normalizes stored configurations to the current
Finder-visible display-name policy and re-adds each stored
`NSFileProviderDomain`. Re-adding a domain with the same identifier updates the
system's registered display name.

## Desktop & Documents On macOS

On macOS 15 or later, a configured drive's management screen can opt in to
Apple's known-folder feature. This is not arbitrary-folder sync: Apple currently
permits Desktop and Documents to be claimed only together.

The app resolves the existing root-level kDrive directory named `Private`,
sanitizes the current macOS computer name, and reuses or creates the exact
directory `Private/<current Mac name>`. That machine namespace is the common
parent for `Desktop` and `Documents`. The `Private` directory must already
exist and be a directory. A file collision or multiple exact namespace matches
fail the claim instead of selecting an arbitrary item.

The namespace follows the Mac's current name; its remote identifier is not
pinned locally. Macs with the same sanitized name deliberately share the same
namespace. Names are Unicode-normalized, path separators and control characters
are replaced, and long names receive a deterministic suffix while remaining
within kDrive's 255-byte limit.

Claiming begins only from the app's explicit control and presents Apple's user
consent UI. Cancellation leaves the previous state unchanged. The extension's
`getKnownFolderLocations` callback returns the same two locations when macOS
initiates a switch outside that claim call. The app reads live state from the
registered domain, refreshes it when domain state changes, and provides a
matching control to stop syncing both folders through `releaseKnownFolders`.

Stored domain configurations include a known-folder layout marker. Legacy JSON
without the marker decodes to the old direct-`Private` layout. An already active
legacy claim remains there without moving or deleting remote data. Stopping and
re-enabling it, or a new system-initiated claim while inactive, upgrades it to
the current machine namespace.

Encrypted onboarding includes an explicit Desktop & Documents step after vault
registration. The same preflight is available later from drive management. It
reports key availability, kDrive reachability, current ownership, and quota
when exposed by the API. The UI distinguishes preparing, awaiting consent,
connected/uploading, up to date, quota blocked, and attention required.

A legacy plaintext Potassium owner blocks direct claiming because safe
encrypted migration is not implemented. Another provider can be handed off
through macOS consent, with a warning that its previous remote copies are not
purged.

## Removing A Domain

Removal is initiated from the drive-management screen and requires explicit
confirmation. The confirmation identifies the provider-local state being
cleared and states that remote kDrive files are not deleted. After successful
removal, a remotely discovered drive stays on screen in its unconfigured state
and can be added again.

The remove flow is:

1. On macOS, the app refreshes live known-folder state and releases Desktop and
   Documents when this domain owns them. A release failure aborts removal.
2. `NSFileProviderManager.remove(_:)` removes the domain from the system.
3. `KDriveSnapshotStoring.removeSnapshots(domainIdentifier:)` deletes all SQLite
   snapshots for that domain.
4. `DomainConfigurationFileStore.remove(domainIdentifier:)` deletes the domain
   JSON file.
5. The app refreshes its visible domain list.

Removing a domain only removes provider state from this app. It does not delete
remote kDrive files.

## Configured Drive Actions

A configured drive's management screen owns all direct File Provider actions:

- show the domain root in Finder on macOS or Files on other platforms
- request a fresh working-set sync
- remove the drive from Files
- enable, repair, or stop Desktop & Documents sync on supported macOS versions

Only one mutating or provider-management action can run for a drive at a time.
The screen disables conflicting controls and shows operation progress. Drive
discovery refresh remains account-scoped even when requested from a drive
screen.

## Logging Out One Account

Independent logout is confirmed from the account screen. It first removes every
File Provider domain tied to that account, including domain JSON, snapshots,
activity/conflict rows, and thumbnail cache entries. On macOS this includes
releasing any known folders owned by those domains; a release failure stops
logout. Only after domain cleanup succeeds does the app delete that account's
keychain token and account JSON. Domains and tokens for other accounts are left
untouched, and remote kDrive files are never deleted by logout.

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

## Encrypted vault domains

When the security-review feature flag is enabled, drive management offers
Create Encrypted Vault and Open Existing Vault. Before creation, recovery-kit
open, or iCloud Keychain open performs any activation side effect, it displays
a mandatory warning that the unsupported experimental feature may cause
complete, unrecoverable data loss and that the user proceeds entirely on their
own. The acknowledgement button remains disabled for five seconds measured with
system uptime. Creation then shows a one-time text and QR recovery kit and
requires exact confirmation before saving the device key or registering the
domain. Existing plaintext domains remain separately registered; no cross-vault
migration or source-purge workflow is implemented. Normal removal/logout
retains vault keys; the separate Forget Key workflow requires the matching
recovery kit.

Creation is a guided flow: threat-boundary overview, device-only versus optional
iCloud Keychain custody, recovery confirmation, durable registration,
Desktop/Documents consent on macOS, and a final summary. Cloud publication and
known-folder failures happen after the durable boundary and remain retryable
without deleting or unregistering the vault.
If setup closes or the app restarts after registration, Security & Recovery
shows **Finish Vault Setup** until the platform-appropriate final step is
completed. Only the onboarding schema version and Desktop/Documents deferral
choice are persisted; key and known-folder status are re-read live.

Security & Recovery verifies a pasted kit by using it locally to authenticate
the remote encrypted bootstrap and checkpoint. The recovery material is never
sent to kDrive, saved by the app, or copied into iCloud Keychain.

After kDrive sign-in, matching synchronizable records appear as encrypted
vaults found in iCloud Keychain. The app authenticates a selected record against
remote ciphertext before registration. Recovery-kit opening and “Check Again”
remain available.
