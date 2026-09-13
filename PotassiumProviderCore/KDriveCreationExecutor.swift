import FileProvider

/// The plaintext create callback's production routing boundary. A reconciliation
/// hint does not authorize overwriting a same-name server item. File replay uses
/// the coordinator's deterministic upload identity; directory reconciliation is
/// still an explicit CR-009 limitation.
public enum KDriveCreationExecutor {
    public static func execute(isDirectory: Bool, options: NSFileProviderCreateItemOptions,
                               createDirectory: @Sendable () async throws -> KDriveRemoteItem,
                               createFile: @Sendable () async throws -> KDriveRemoteItem) async throws -> KDriveRemoteItem {
        try Task.checkCancellation()
        // Preserve the existing policy for both ordinary and mayAlreadyExist
        // callbacks. Matching a name alone cannot establish remote identity.
        if isDirectory { return try await createDirectory() }
        return try await createFile()
    }
}
