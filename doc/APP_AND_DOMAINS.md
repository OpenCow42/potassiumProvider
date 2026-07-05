# App And Domains

The main app is a small SwiftUI shell around `PotassiumProviderAppModel`. Its job
is to get credentials, discover or accept a kDrive, create a
`ProviderDomainConfiguration`, and register that configuration as a File Provider
domain.

## App Responsibilities

The app handles:

- connecting through Infomaniak OAuth or accepting a manual access token
- loading available kDrives from the authenticated account
- building a domain configuration for the selected drive
- registering and removing `NSFileProviderDomain` entries
- showing configured domains and simple status/error state

The app does not enumerate files itself. File listing is handled by the File
Provider extension after the system asks for an enumerator.

## Domain Configuration

`ProviderDomainConfiguration` is the local record that connects an Apple File
Provider domain to a kDrive:

- `domainIdentifier`: stable identifier used as `NSFileProviderDomainIdentifier`
- `displayName`: Finder/Files-visible name derived from `driveName`, for
  example `Work Drive`
- `driveID`: kDrive identifier used in API calls
- `driveName`: display name returned by kDrive or entered manually
- `rootFileID`: kDrive root folder ID; currently defaults to `1`
- `createdAt` and `updatedAt`: local metadata for the configuration

Domain configurations are stored as JSON files in the app group under
`DomainConfigurations/`.

## Adding A Domain

The add flow is:

1. The user connects or saves an access token.
2. The app loads kDrives through `PotassiumKDriveService.listDrives()`.
3. The user selects a drive or enters a manual drive ID/name.
4. `PotassiumProviderAppModel.addDomain()` creates a
   `ProviderDomainConfiguration` whose display name is derived from the drive
   name.
5. The app saves the configuration to the app group.
6. `FileProviderDomainRegistrar.addDomain(for:)` registers an
   `NSFileProviderDomain` with Apple's File Provider manager.
7. If registration fails, the app rolls back the saved configuration and removes
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

## Manual Tokens

Manual access tokens are accepted for development and testing. They are saved in
the same token store as OAuth tokens. A manually entered token may not have a
refresh token or expiration, so reconnecting may be required when it stops
working.
