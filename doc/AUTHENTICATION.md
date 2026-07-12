# Authentication

Authentication is shared between the SwiftUI app and the File Provider extension
through the keychain access group configured in `ProviderConstants`. The app can
store multiple local accounts at the same time, and each File Provider domain
loads the token for the account recorded in its domain configuration.

## OAuth PKCE Flow

`KDriveOAuthClient` builds an Infomaniak OAuth authorization request with:

- client ID from `ProviderConstants.oauthClientID`
- redirect URI from `ProviderConstants.oauthRedirectURI`
- random state
- random PKCE code verifier
- SHA-256 code challenge
- `hide_create_account` query item when configured

The app-side `KDriveOAuthWebAuthenticator` opens the authorization URL and
returns a callback URL. `KDriveOAuthClient.authorizationCode(from:expectedState:)`
validates the state and extracts the authorization code. The client then
exchanges the code for a `KDriveOAuthToken`.

## Token Model

`KDriveOAuthToken` stores:

- access token
- token type
- optional refresh token
- optional scope
- optional ID token
- optional expiration date

`shouldRefresh(now:leeway:)` asks for refresh when the token expires within the
configured leeway, currently five minutes by default.

## Account-Scoped Keychain Storage

`KeychainOAuthTokenStore` stores one encoded `KDriveOAuthToken` per local
account as a generic password item using:

- keychain service: `ProviderConstants.keychainService`
- keychain account: `oauthToken:<local account identifier>`
- access group: `ProviderConstants.keychainAccessGroup`

The app saves tokens when a local account is created. The extension loads the
domain configuration in `FileProviderRuntime.load`, reads that configuration's
`accountIdentifier`, and then loads only that account's token. If a token is
refreshable and near expiration, the extension refreshes it and saves the
replacement token back to the same account-scoped keychain item.

Legacy installs used a single `oauthToken` keychain account. On app reload, if
that old token or old domain configuration shape is present, the app creates a
fixed local legacy account, copies the old token into `oauthToken:legacy-account`,
deletes the old single-token key, and rewrites legacy domain configuration JSON
with the account identifier.

## Manual Access Token Path

The app also supports a manual access token. This creates a token value with:

- token type `Bearer`
- no refresh token
- no expiration date

This path is useful for development but is less robust than OAuth because the
extension cannot refresh the token when it stops working. Each manual token
creates its own local account and can be logged out independently.

## Error Behavior

If the extension cannot load the token for a domain's account, or if it needs to
refresh but no refresh token exists, it throws `NSFileProviderError.notAuthenticated`.
That tells the system only the affected provider domain cannot currently service
the request. Other domains backed by other accounts continue to use their own
tokens.

Network and API errors are mapped later by `providerError(...)` in the extension
runtime. The same mapping path records sanitized authentication/runtime failure
activity when the shared activity database is available.

The app also records sanitized app-scoped authentication failures for OAuth,
manual-token saving, token deletion, and drive loading. These activity rows can
include categories and numeric error codes, but must not include bearer tokens,
refresh tokens, ID tokens, raw API response bodies, or bearer-bearing request
data.

The shared logging mechanism follows the same boundary for unified logging and
support exports. See [Logging](LOGGING.md).

## Secret Handling

Never log, commit, store in docs, or include in fixtures:

- bearer tokens
- refresh tokens
- ID tokens
- private user/account identifiers
- private file URLs
- customer or user data

Tests should use redacted strings and mocked URL sessions.
