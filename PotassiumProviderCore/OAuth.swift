import CryptoKit
import Foundation
import PotassiumOAuth

public struct KDriveOAuthConfiguration: Equatable, Sendable {
    public let clientID: String
    public let clientSecret: String?
    public let redirectURI: URL
    public let hidesCreateAccountButton: Bool

    public init(
        clientID: String = ProviderConstants.oauthClientID,
        clientSecret: String? = nil,
        redirectURI: URL = ProviderConstants.oauthRedirectURI,
        hidesCreateAccountButton: Bool = true
    ) {
        self.clientID = clientID
        self.clientSecret = clientSecret
        self.redirectURI = redirectURI
        self.hidesCreateAccountButton = hidesCreateAccountButton
    }
}

public struct KDriveOAuthAuthorizationRequest: Equatable, Sendable {
    public let url: URL
    public let state: String
    public let codeVerifier: String
    public let callbackScheme: String
}

public struct KDriveOAuthToken: Codable, Equatable, Sendable {
    public let accessToken: String
    public let tokenType: String
    public let refreshToken: String?
    public let scope: String?
    public let idToken: String?
    public let expiresAt: Date?

    public init(
        accessToken: String,
        tokenType: String,
        refreshToken: String?,
        scope: String?,
        idToken: String?,
        expiresAt: Date?
    ) {
        self.accessToken = accessToken
        self.tokenType = tokenType
        self.refreshToken = refreshToken
        self.scope = scope
        self.idToken = idToken
        self.expiresAt = expiresAt
    }

    public func shouldRefresh(now: Date = Date(), leeway: TimeInterval = 300) -> Bool {
        guard let expiresAt else { return false }
        return expiresAt.timeIntervalSince(now) <= leeway
    }

    public static func from(response: InfomaniakOAuthTokenResponse, receivedAt: Date = Date()) -> KDriveOAuthToken {
        KDriveOAuthToken(
            accessToken: response.accessToken,
            tokenType: response.tokenType,
            refreshToken: response.refreshToken,
            scope: response.scope,
            idToken: response.idToken,
            expiresAt: response.expiresIn.map { receivedAt.addingTimeInterval(TimeInterval($0)) }
        )
    }
}

public enum KDriveOAuthClient {
    public static func makeAuthorizationRequest(
        configuration: KDriveOAuthConfiguration = KDriveOAuthConfiguration(),
        state: String = UUID().uuidString,
        codeVerifier: String = makeCodeVerifier()
    ) throws -> KDriveOAuthAuthorizationRequest {
        guard let callbackScheme = configuration.redirectURI.scheme else {
            throw KDriveOAuthError.invalidRedirectURI
        }

        let url = try InfomaniakOAuthRequests.authorizationURL(
            clientId: configuration.clientID,
            redirectURI: configuration.redirectURI,
            state: state,
            codeChallenge: codeChallenge(for: codeVerifier),
            additionalQueryItems: configuration.hidesCreateAccountButton ? [URLQueryItem(name: "hide_create_account", value: "")] : []
        )

        return KDriveOAuthAuthorizationRequest(
            url: url,
            state: state,
            codeVerifier: codeVerifier,
            callbackScheme: callbackScheme
        )
    }

    public static func authorizationCode(from callbackURL: URL, expectedState: String) throws -> String {
        guard let components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false) else {
            throw KDriveOAuthError.invalidCallbackURL
        }

        let queryItems = components.queryItems ?? []
        if let error = queryItems.first(where: { $0.name == "error" })?.value, error.isEmpty == false {
            throw KDriveOAuthError.authorizationFailed(
                error: error,
                description: queryItems.first(where: { $0.name == "error_description" })?.value
            )
        }

        guard queryItems.first(where: { $0.name == "state" })?.value == expectedState else {
            throw KDriveOAuthError.stateMismatch
        }

        guard let code = queryItems.first(where: { $0.name == "code" })?.value, code.isEmpty == false else {
            throw KDriveOAuthError.missingAuthorizationCode
        }

        return code
    }

    public static func exchangeAuthorizationCode(
        _ code: String,
        codeVerifier: String,
        configuration: KDriveOAuthConfiguration = KDriveOAuthConfiguration(),
        session: URLSession = .shared
    ) async throws -> KDriveOAuthToken {
        let request = try InfomaniakOAuthRequests.authorizationCodeTokenRequest(
            clientId: configuration.clientID,
            clientSecret: configuration.clientSecret,
            code: code,
            redirectURI: configuration.redirectURI,
            codeVerifier: codeVerifier
        )
        return try await sendTokenRequest(request, session: session)
    }

    public static func refresh(
        refreshToken: String,
        configuration: KDriveOAuthConfiguration = KDriveOAuthConfiguration(),
        session: URLSession = .shared
    ) async throws -> KDriveOAuthToken {
        let request = try InfomaniakOAuthRequests.refreshTokenRequest(
            clientId: configuration.clientID,
            clientSecret: configuration.clientSecret,
            refreshToken: refreshToken
        )
        return try await sendTokenRequest(request, session: session)
    }

    public static func makeCodeVerifier(byteCount: Int = 32) -> String {
        let bytes = (0..<byteCount).map { _ in UInt8.random(in: UInt8.min...UInt8.max) }
        return Data(bytes).base64URLEncodedString()
    }

    public static func codeChallenge(for verifier: String) -> String {
        Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncodedString()
    }

    private static func sendTokenRequest(_ request: URLRequest, session: URLSession) async throws -> KDriveOAuthToken {
        let receivedAt = Date()
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw KDriveOAuthError.tokenRequestFailed(statusCode: -1, message: nil)
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            let oauthError = try? JSONDecoder().decode(InfomaniakOAuthErrorResponse.self, from: data)
            throw KDriveOAuthError.tokenRequestFailed(
                statusCode: httpResponse.statusCode,
                message: oauthError?.errorDescription ?? oauthError?.error
            )
        }

        let tokenResponse = try JSONDecoder().decode(InfomaniakOAuthTokenResponse.self, from: data)
        return KDriveOAuthToken.from(response: tokenResponse, receivedAt: receivedAt)
    }
}

public enum KDriveOAuthError: Error, Equatable, LocalizedError, Sendable {
    case invalidRedirectURI
    case invalidCallbackURL
    case stateMismatch
    case missingAuthorizationCode
    case authorizationFailed(error: String, description: String?)
    case tokenRequestFailed(statusCode: Int, message: String?)

    public var errorDescription: String? {
        switch self {
        case .invalidRedirectURI:
            return "The Infomaniak OAuth redirect URI is invalid."
        case .invalidCallbackURL:
            return "Infomaniak returned an invalid OAuth callback URL."
        case .stateMismatch:
            return "The OAuth callback did not match the login request."
        case .missingAuthorizationCode:
            return "Infomaniak did not return an OAuth authorization code."
        case .authorizationFailed(let error, let description):
            return description?.isEmpty == false ? "Infomaniak authorization failed: \(description!)" : "Infomaniak authorization failed: \(error)"
        case .tokenRequestFailed(let statusCode, let message):
            return message?.isEmpty == false ? "Infomaniak token request failed with status \(statusCode): \(message!)" : "Infomaniak token request failed with status \(statusCode)."
        }
    }
}

private extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
