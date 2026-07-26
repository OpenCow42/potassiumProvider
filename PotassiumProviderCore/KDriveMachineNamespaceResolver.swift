import Foundation
#if os(macOS)
import SystemConfiguration
#endif

public enum KDriveMachineNamespaceNameError: Error, Equatable, LocalizedError, Sendable {
    case computerNameUnavailable
    case unusableComputerName

    public var errorDescription: String? {
        switch self {
        case .computerNameUnavailable:
            return "The current Mac name is unavailable."
        case .unusableComputerName:
            return "The current Mac name cannot be used as a kDrive folder name."
        }
    }
}

/// Produces the kDrive directory name used to isolate known folders for one Mac name.
public enum KDriveMachineNamespaceName {
    public static let maximumUTF8ByteCount = 255
    private static let hashCharacterCount = 8

    public static func current() throws -> String {
        #if os(macOS)
        guard let computerName = SCDynamicStoreCopyComputerName(nil, nil) as String? else {
            throw KDriveMachineNamespaceNameError.computerNameUnavailable
        }
        return try sanitized(computerName)
        #else
        throw KDriveMachineNamespaceNameError.computerNameUnavailable
        #endif
    }

    public static func sanitized(_ computerName: String) throws -> String {
        let normalizedName = computerName.precomposedStringWithCanonicalMapping
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let containsUsableScalar = normalizedName.unicodeScalars.contains { scalar in
            scalar != "/"
                && scalar != ":"
                && CharacterSet.controlCharacters.contains(scalar) == false
                && CharacterSet.whitespacesAndNewlines.contains(scalar) == false
        }
        guard containsUsableScalar else {
            throw KDriveMachineNamespaceNameError.unusableComputerName
        }
        let replacedName = String(normalizedName.unicodeScalars.map { scalar in
            if scalar == "/" || scalar == ":" || CharacterSet.controlCharacters.contains(scalar) {
                return "-"
            }
            return Character(scalar)
        }).trimmingCharacters(in: .whitespacesAndNewlines)

        guard replacedName.isEmpty == false, replacedName != ".", replacedName != ".." else {
            throw KDriveMachineNamespaceNameError.unusableComputerName
        }
        guard replacedName.utf8.count > maximumUTF8ByteCount else {
            return replacedName
        }

        let suffix = "-\(shortHash(of: replacedName))"
        let prefixByteLimit = maximumUTF8ByteCount - suffix.utf8.count
        var prefix = ""
        for character in replacedName {
            let candidate = prefix + String(character)
            guard candidate.utf8.count <= prefixByteLimit else {
                break
            }
            prefix = candidate
        }
        guard prefix.isEmpty == false else {
            throw KDriveMachineNamespaceNameError.unusableComputerName
        }
        return prefix + suffix
    }

    private static func shortHash(of value: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(String(hash, radix: 16).suffix(hashCharacterCount))
            .leftPadding(toLength: hashCharacterCount, withPad: "0")
    }
}

public struct KDriveMachineNamespace: Equatable, Sendable {
    public let name: String
    public let fileID: Int

    public init(name: String, fileID: Int) {
        self.name = name
        self.fileID = fileID
    }
}

public enum KDriveMachineNamespaceResolutionError: Error, Equatable, LocalizedError, Sendable {
    case notDirectory(driveID: Int, parentFileID: Int, itemID: Int, name: String)
    case ambiguous(driveID: Int, parentFileID: Int, itemIDs: [Int], name: String)
    case invalidCreatedDirectory(driveID: Int, parentFileID: Int, itemID: Int, name: String)

    public var errorDescription: String? {
        switch self {
        case .notDirectory(_, let parentFileID, let itemID, let name):
            return "The '\(name)' item '\(itemID)' under Private '\(parentFileID)' is not a directory."
        case .ambiguous(_, let parentFileID, let itemIDs, let name):
            let identifiers = itemIDs.map(String.init).joined(separator: ", ")
            return "Private '\(parentFileID)' contains multiple '\(name)' items (\(identifiers))."
        case .invalidCreatedDirectory(_, let parentFileID, let itemID, let name):
            return "kDrive returned invalid metadata for the new '\(name)' directory '\(itemID)' under Private '\(parentFileID)'."
        }
    }
}

/// Reuses or creates the current Mac's namespace immediately below kDrive `Private`.
public enum KDriveMachineNamespaceResolver {
    public static let pageSize = 200

    public static func resolveOrCreate(
        driveID: Int,
        privateDirectoryFileID: Int,
        computerName: String,
        remote: any KDriveFileProviding
    ) async throws -> KDriveMachineNamespace {
        let namespaceName = try KDriveMachineNamespaceName.sanitized(computerName)
        let existingItems = try await matchingItems(
            driveID: driveID,
            parentFileID: privateDirectoryFileID,
            name: namespaceName,
            remote: remote
        )
        if let namespace = try resolvedNamespace(
            from: existingItems,
            driveID: driveID,
            parentFileID: privateDirectoryFileID,
            name: namespaceName
        ) {
            return namespace
        }

        do {
            let createdItem = try await remote.createDirectory(
                driveID: driveID,
                parentID: privateDirectoryFileID,
                name: namespaceName
            )
            guard createdItem.driveID == driveID,
                  createdItem.parentID == privateDirectoryFileID,
                  createdItem.name == namespaceName,
                  createdItem.isDirectory else {
                throw KDriveMachineNamespaceResolutionError.invalidCreatedDirectory(
                    driveID: driveID,
                    parentFileID: privateDirectoryFileID,
                    itemID: createdItem.id,
                    name: namespaceName
                )
            }
            return KDriveMachineNamespace(name: namespaceName, fileID: createdItem.id)
        } catch let creationError {
            let racedItems = try await matchingItems(
                driveID: driveID,
                parentFileID: privateDirectoryFileID,
                name: namespaceName,
                remote: remote
            )
            if let namespace = try resolvedNamespace(
                from: racedItems,
                driveID: driveID,
                parentFileID: privateDirectoryFileID,
                name: namespaceName
            ) {
                return namespace
            }
            throw creationError
        }
    }

    private static func matchingItems(
        driveID: Int,
        parentFileID: Int,
        name: String,
        remote: any KDriveFileProviding
    ) async throws -> [KDriveRemoteItem] {
        var cursor: String?
        var seenCursors: Set<String> = []
        var itemsByID: [Int: KDriveRemoteItem] = [:]

        while true {
            let page = try await remote.listDirectory(
                driveID: driveID,
                folderID: parentFileID,
                cursor: cursor,
                limit: pageSize
            )
            for item in page.items where item.name == name && item.parentID == parentFileID {
                itemsByID[item.id] = item
            }
            let nextCursor = try KDriveListingValidator.validatedNextCursor(
                currentCursor: cursor,
                nextCursor: page.nextCursor,
                hasMore: page.hasMore,
                seenCursors: &seenCursors
            )
            guard page.hasMore else {
                break
            }
            cursor = nextCursor
        }
        return itemsByID.values.sorted { $0.id < $1.id }
    }

    private static func resolvedNamespace(
        from items: [KDriveRemoteItem],
        driveID: Int,
        parentFileID: Int,
        name: String
    ) throws -> KDriveMachineNamespace? {
        switch items.count {
        case 0:
            return nil
        case 1:
            let item = items[0]
            guard item.isDirectory else {
                throw KDriveMachineNamespaceResolutionError.notDirectory(
                    driveID: driveID,
                    parentFileID: parentFileID,
                    itemID: item.id,
                    name: name
                )
            }
            return KDriveMachineNamespace(name: name, fileID: item.id)
        default:
            throw KDriveMachineNamespaceResolutionError.ambiguous(
                driveID: driveID,
                parentFileID: parentFileID,
                itemIDs: items.map(\.id),
                name: name
            )
        }
    }
}

private extension String {
    func leftPadding(toLength: Int, withPad character: Character) -> String {
        guard count < toLength else { return self }
        return String(repeating: String(character), count: toLength - count) + self
    }
}
