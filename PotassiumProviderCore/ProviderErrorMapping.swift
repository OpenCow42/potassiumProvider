import FileProvider
import Foundation
import OSLog

/// The same mapping is used by production callbacks and deterministic conflict tests.
public struct ProviderErrorMapping {
    public let mappedError: Error
    public let diagnostic: KDriveProviderActivityErrorDiagnostic
}

public func providerErrorMapping(_ error: Error) -> ProviderErrorMapping {
    if let fileProviderError = error as? NSFileProviderError {
        let nsError = fileProviderError as NSError
        ProviderLog.runtime.debug("preserve FileProvider error code(\(nsError.code, privacy: .public)): \(nsError.localizedDescription, privacy: .public)")
        return ProviderErrorMapping(
            mappedError: fileProviderError,
            diagnostic: providerDiagnostic(
                category: providerActivityErrorCategory(originalError: nsError),
                originalError: error,
                mappedError: fileProviderError
            )
        )
    }

    if let apiRejection = KDriveRemoteErrorClassifier.apiRejection(from: error) {
        let mappedError = fileProviderError(for: apiRejection.recovery)
        let mappedNSError = mappedError as NSError
        ProviderLog.runtime.error("map API rejection HTTP \(apiRejection.statusCode, privacy: .public) to \(mappedNSError.domain, privacy: .public) code(\(mappedNSError.code, privacy: .public))")
        return ProviderErrorMapping(
            mappedError: mappedError,
            diagnostic: providerDiagnostic(
                category: .api,
                originalError: error,
                mappedError: mappedError,
                diagnosticSummary: apiRejection.diagnosticSummary
            )
        )
    }

    if let directUploadError = error as? KDriveDirectUploadError {
        let mappedError = fileProviderError(for: directUploadError.recovery)
        return ProviderErrorMapping(
            mappedError: mappedError,
            diagnostic: providerDiagnostic(
                category: directUploadError.diagnosticCategory,
                originalError: error,
                mappedError: mappedError,
                diagnosticSummary: directUploadError.diagnosticSummary
            )
        )
    }

    if let mutationConflictError = error as? KDriveMutationConflictError {
        switch mutationConflictError {
        case .staleVersion:
            ProviderLog.runtime.error("map stale mutation version to cannotSynchronize: \(error.localizedDescription, privacy: .public)")
            let mappedError = staleMutationVersionError()
            return ProviderErrorMapping(
                mappedError: mappedError,
                diagnostic: providerDiagnostic(
                    category: .mutationConflict,
                    originalError: error,
                    mappedError: mappedError
                )
            )
        case .localContentConflict:
            let mappedError = NSFileProviderError(.localVersionConflictingWithServer)
            ProviderLog.runtime.error("map fail-on-conflict upload to localVersionConflictingWithServer")
            return ProviderErrorMapping(
                mappedError: mappedError,
                diagnostic: providerDiagnostic(
                    category: .mutationConflict,
                    originalError: error,
                    mappedError: mappedError
                )
            )
        }
    }

    if error is KDriveListingValidationError {
        ProviderLog.runtime.error("map listing validation failure to cannotSynchronize: \(error.localizedDescription, privacy: .public)")
        let mappedError = NSFileProviderError(.cannotSynchronize)
        return ProviderErrorMapping(
            mappedError: mappedError,
            diagnostic: providerDiagnostic(
                category: .listing,
                originalError: error,
                mappedError: mappedError
            )
        )
    }

    if let snapshotStoreError = error as? KDriveSnapshotStoreError,
       case .staleSnapshot = snapshotStoreError {
        ProviderLog.runtime.error("map stale snapshot write to cannotSynchronize: \(error.localizedDescription, privacy: .public)")
        let mappedError = NSFileProviderError(.cannotSynchronize)
        return ProviderErrorMapping(
            mappedError: mappedError,
            diagnostic: providerDiagnostic(
                category: .snapshot,
                originalError: error,
                mappedError: mappedError
            )
        )
    }

    if error is VaultCryptoError ||
        error is VaultJournalError ||
        error is VaultLocalStoreError ||
        error is VaultProvisioningError {
        let mappedError = NSFileProviderError(.cannotSynchronize)
        return ProviderErrorMapping(
            mappedError: mappedError,
            diagnostic: providerDiagnostic(
                category: .storage,
                originalError: error,
                mappedError: mappedError
            )
        )
    }

    if let vaultError = error as? EncryptedVaultError {
        let mappedError: NSFileProviderError
        switch vaultError {
        case .missingKey:
            mappedError = NSFileProviderError(.notAuthenticated)
        case .itemNotFound:
            mappedError = NSFileProviderError(.noSuchItem)
        case .syncAnchorExpired:
            mappedError = NSFileProviderError(.syncAnchorExpired)
        default:
            mappedError = NSFileProviderError(.cannotSynchronize)
        }
        return ProviderErrorMapping(
            mappedError: mappedError,
            diagnostic: providerDiagnostic(
                category: .storage,
                originalError: error,
                mappedError: mappedError
            )
        )
    }

    let nsError = error as NSError
    if nsError.domain == NSURLErrorDomain {
        ProviderLog.runtime.error("map URL error \(nsError.code, privacy: .public) to serverUnreachable: \(nsError.localizedDescription, privacy: .public)")
        let mappedError = NSFileProviderError(.serverUnreachable)
        return ProviderErrorMapping(
            mappedError: mappedError,
            diagnostic: providerDiagnostic(
                category: .network,
                originalError: error,
                mappedError: mappedError
            )
        )
    }

    if nsError.domain == NSCocoaErrorDomain || nsError.domain == NSFileProviderErrorDomain {
        ProviderLog.runtime.error("preserve Cocoa/FileProvider error \(nsError.domain, privacy: .public) code(\(nsError.code, privacy: .public)): \(nsError.localizedDescription, privacy: .public)")
        return ProviderErrorMapping(
            mappedError: error,
            diagnostic: providerDiagnostic(
                category: providerActivityErrorCategory(originalError: nsError),
                originalError: error,
                mappedError: error
            )
        )
    }

    ProviderLog.runtime.error("wrap unexpected error as XPC reply invalid: \(error.localizedDescription, privacy: .public)")
    let mappedError = NSError(
        domain: NSCocoaErrorDomain,
        code: NSXPCConnectionReplyInvalid,
        userInfo: [NSUnderlyingErrorKey: error]
    )
    return ProviderErrorMapping(
        mappedError: mappedError,
        diagnostic: providerDiagnostic(
            category: providerActivityErrorCategory(originalError: nsError),
            originalError: error,
            mappedError: mappedError
        )
    )
}

public func providerError(_ error: Error) -> Error {
    providerErrorMapping(error).mappedError
}

public func shouldRecordGenericFailure(for error: Error) -> Bool {
    if error is CancellationError { return false }
    if error is KDriveMutationConflictError { return false }

    let nsError = error as NSError
    return nsError.domain != NSCocoaErrorDomain || nsError.code != NSUserCancelledError
}

public func providerActivityKindForRuntimeLoadFailure(_ error: Error) -> KDriveProviderActivityKind {
    let nsError = error as NSError
    if nsError.domain == NSFileProviderErrorDomain,
       nsError.code == NSFileProviderError.notAuthenticated.rawValue {
        return .authentication
    }
    if let apiRejection = KDriveRemoteErrorClassifier.apiRejection(from: error),
       apiRejection.recovery == .notAuthenticated {
        return .authentication
    }
    if error is KDriveOAuthError || error is KeychainTokenStoreError {
        return .authentication
    }
    return .runtimeLoading
}

private func providerDiagnostic(
    category: KDriveProviderActivityErrorCategory,
    originalError: Error,
    mappedError: Error,
    diagnosticSummary: String? = nil
) -> KDriveProviderActivityErrorDiagnostic {
    let originalNSError = originalError as NSError
    let mappedNSError = mappedError as NSError
    let providerCode = mappedNSError.domain == NSFileProviderErrorDomain ? mappedNSError.code : nil
    let recoverySuggestion = mappedNSError.localizedRecoverySuggestion
        ?? (originalError as? LocalizedError)?.recoverySuggestion

    return KDriveProviderActivityErrorDiagnostic(
        errorCategory: category,
        providerErrorCode: providerCode,
        underlyingErrorDomain: originalNSError.domain,
        underlyingErrorCode: originalNSError.code,
        recoverySuggestion: recoverySuggestion,
        diagnosticSummary: diagnosticSummary ?? providerDiagnosticSummary(category: category)
    )
}

private func fileProviderError(for recovery: KDriveRemoteAPIRejectionRecovery) -> Error {
    switch recovery {
    case .notAuthenticated:
        return NSFileProviderError(.notAuthenticated)
    case .serverUnreachable:
        return NSFileProviderError(.serverUnreachable)
    case .insufficientQuota:
        return NSFileProviderError(.insufficientQuota)
    case .cannotSynchronize:
        return NSFileProviderError(.cannotSynchronize)
    }
}

private func providerActivityErrorCategory(originalError nsError: NSError) -> KDriveProviderActivityErrorCategory {
    if nsError.domain == NSURLErrorDomain {
        return .network
    }
    if nsError.domain == NSFileProviderErrorDomain {
        if nsError.code == NSFileProviderError.notAuthenticated.rawValue {
            return .authentication
        }
        return .fileProvider
    }
    if nsError.domain == NSCocoaErrorDomain {
        return .storage
    }
    return .unknown
}

private func providerDiagnosticSummary(category: KDriveProviderActivityErrorCategory) -> String {
    switch category {
    case .authentication:
        return "Authentication is unavailable or needs to be refreshed."
    case .network:
        return "A network request failed before the operation could complete."
    case .api:
        return "The remote API rejected the operation."
    case .fileProvider:
        return "File Provider returned a recoverable provider error."
    case .listing:
        return "The remote listing response could not be safely applied."
    case .snapshot:
        return "Local sync snapshot state could not be updated safely."
    case .storage:
        return "Local storage returned an error."
    case .validation:
        return "Input or remote state failed validation."
    case .mutationConflict:
        return "The remote item changed before the local mutation could be applied."
    case .unknown:
        return "An unexpected provider error occurred."
    }
}

private func staleMutationVersionError() -> Error {
    NSError(
        domain: NSFileProviderErrorDomain,
        code: NSFileProviderError.cannotSynchronize.rawValue,
        userInfo: [
            NSLocalizedDescriptionKey: "The item changed on the server before the local mutation could be applied.",
            NSLocalizedRecoverySuggestionErrorKey: "Refresh the folder and retry the change."
        ]
    )
}
