# Authentication

Authentication is shared between the SwiftUI app and the File Provider extension
through the keychain access group configured in `ProviderConstants`.

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

## Keychain Storage

`KeychainOAuthTokenStore` stores the encoded `KDriveOAuthToken` as a generic
password item using:

- keychain service: `ProviderConstants.keychainService`
- keychain account: `ProviderConstants.keychainAccount`
- access group: `ProviderConstants.keychainAccessGroup`

The app saves tokens. The extension loads them in `FileProviderRuntime.load`.
If a token is refreshable and near expiration, the extension refreshes it and
saves the replacement token before continuing.

## Manual Access Token Path

The app also supports a manual access token. This creates a token value with:

- token type `Bearer`
- no refresh token
- no expiration date

This path is useful for development but is less robust than OAuth because the
extension cannot refresh the token when it stops working.

## Error Behavior

If the extension cannot load a token, or if it needs to refresh but no refresh
token exists, it throws `NSFileProviderError.notAuthenticated`. That tells the
system the provider cannot currently service the request.

Network and API errors are mapped later by `providerError(...)` in the extension
runtime.

## Secret Handling

Never log, commit, store in docs, or include in fixtures:

- bearer tokens
- refresh tokens
- ID tokens
- private user/account identifiers
- private file URLs
- customer or user data

Tests should use redacted strings and mocked URL sessions.
