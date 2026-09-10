import FileProvider
import Foundation

/// Keeps combined fields and their acknowledgement in the same path used by the
/// replicated extension. A trash transition must never discard pending contents.
public enum VaultModificationExecutor {
    public struct Result: Sendable {
        public let item: VaultItem?
        public let remainingFields: NSFileProviderItemFields
        public let trashed: Bool
    }

    public static func execute(current: VaultItem, fields: NSFileProviderItemFields,
                               requestsTrash: Bool, hasContents: Bool,
                               baseContentRevision: VaultRevision, baseMetadataRevision: VaultRevision,
                               modify: @Sendable () async throws -> VaultItem,
                               trash: @Sendable (VaultRevision, VaultRevision) async throws -> Void) async throws -> Result {
        try Task.checkCancellation()
        if fields.contains(.contents), !hasContents { throw NSFileProviderError(.cannotSynchronize) }
        var remaining = fields
        let modifiedFields = fields.intersection([.contents, .filename, .parentItemIdentifier])
            .subtracting(requestsTrash ? [.parentItemIdentifier] : [])
        var updated = current
        if !modifiedFields.isEmpty {
            updated = try await modify()
            remaining.subtract(modifiedFields)
            if fields.contains(.contents) { remaining.remove(.contentModificationDate) }
        }
        if requestsTrash {
            try Task.checkCancellation()
            try await trash(modifiedFields.isEmpty ? baseContentRevision : updated.contentRevision,
                            modifiedFields.isEmpty ? baseMetadataRevision : updated.metadataRevision)
            remaining.remove(.parentItemIdentifier)
            return Result(item: nil, remainingFields: remaining, trashed: true)
        }
        return Result(item: updated, remainingFields: remaining, trashed: false)
    }
}
