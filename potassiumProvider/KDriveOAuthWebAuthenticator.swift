import AuthenticationServices
import Foundation
import OSLog
import PotassiumProviderCore

#if os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

@MainActor
protocol KDriveOAuthAuthenticating: AnyObject {
    func authenticate() async throws -> KDriveOAuthToken
}

@MainActor
final class KDriveOAuthWebAuthenticator: NSObject, KDriveOAuthAuthenticating, ASWebAuthenticationPresentationContextProviding {
    private var session: ASWebAuthenticationSession?
    private let configuration: KDriveOAuthConfiguration

    init(configuration: KDriveOAuthConfiguration = KDriveOAuthConfiguration()) {
        self.configuration = configuration
    }

    func authenticate() async throws -> KDriveOAuthToken {
        let configuration = self.configuration
        let request = try KDriveOAuthClient.makeAuthorizationRequest(configuration: configuration)
        ProviderLog.authentication.info(
            "oauth authorization request callbackScheme(\(request.callbackScheme, privacy: .public))"
        )

        return try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(
                url: request.url,
                callbackURLScheme: request.callbackScheme
            ) { callbackURL, error in
                if let error {
                    let nsError = error as NSError
                    ProviderLog.authentication.error(
                        "oauth browser session failure errorDomain(\(nsError.domain, privacy: .public)) errorCode(\(nsError.code, privacy: .public))"
                    )
                    continuation.resume(throwing: error)
                    return
                }

                guard let callbackURL else {
                    continuation.resume(throwing: KDriveOAuthError.invalidCallbackURL)
                    return
                }

                Task {
                    do {
                        let code = try KDriveOAuthClient.authorizationCode(
                            from: callbackURL,
                            expectedState: request.state
                        )
                        let token = try await KDriveOAuthClient.exchangeAuthorizationCode(
                            code,
                            codeVerifier: request.codeVerifier,
                            configuration: configuration
                        )
                        ProviderLog.authentication.info(
                            "oauth token received tokenType(\(token.tokenType, privacy: .public)) hasRefreshToken(\(token.refreshToken != nil, privacy: .public)) hasGrantedScope(\(token.scope?.isEmpty == false, privacy: .public)) hasExpiration(\(token.expiresAt != nil, privacy: .public))"
                        )
                        continuation.resume(returning: token)
                    } catch {
                        let nsError = error as NSError
                        ProviderLog.authentication.error(
                            "oauth token exchange failure errorDomain(\(nsError.domain, privacy: .public)) errorCode(\(nsError.code, privacy: .public))"
                        )
                        continuation.resume(throwing: error)
                    }
                }
            }

            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = true
            self.session = session

            guard session.start() else {
                self.session = nil
                continuation.resume(throwing: KDriveOAuthError.invalidCallbackURL)
                return
            }
        }
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        #if os(macOS)
        NSApplication.shared.windows.first { $0.isKeyWindow } ?? NSApplication.shared.windows.first ?? ASPresentationAnchor()
        #elseif canImport(UIKit)
        let windowScenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        if let window = windowScenes.flatMap(\.windows).first(where: { $0.isKeyWindow }) {
            return window
        }
        if let scene = windowScenes.first {
            return ASPresentationAnchor(windowScene: scene)
        }
        preconditionFailure("A UIWindowScene is required to present kDrive OAuth.")
        #else
        ASPresentationAnchor()
        #endif
    }
}
