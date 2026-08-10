import Foundation
import LocalAuthentication

@MainActor
protocol VaultUserPresenceAuthorizing {
    func authorize(reason: String) async throws
}

@MainActor
struct LocalAuthenticationVaultUserPresenceAuthorizer:
    VaultUserPresenceAuthorizing
{
    func authorize(reason: String) async throws {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(
            .deviceOwnerAuthentication,
            error: &error
        ) else {
            throw error ?? VaultUserPresenceAuthorizationError.unavailable
        }
        try await context.evaluatePolicy(
            .deviceOwnerAuthentication,
            localizedReason: reason
        )
    }
}

enum VaultUserPresenceAuthorizationError: Error, LocalizedError {
    case unavailable

    var errorDescription: String? {
        "Device authentication is not available."
    }
}
