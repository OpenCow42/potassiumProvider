import CryptoKit
import Foundation
#if os(macOS)
import Security
#endif

/// Process identity and run-local aliases contain no raw item or account identifiers.
public enum StabilityDiagnosticIdentity {
    public static let processInstanceID = UUID()
    public static let processCodeHash: String? = {
        #if os(macOS)
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        return codeHash(staticCode)
        #else
        return nil
        #endif
    }()

    #if os(macOS)
    public static func codeHash(at url: URL) -> String? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else { return nil }
        return codeHash(code)
    }

    private static func codeHash(_ code: SecStaticCode) -> String? {
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(code, [], &information) == errSecSuccess,
              let dictionary = information as? [String: Any],
              let hash = dictionary[kSecCodeInfoUnique as String] as? Data else { return nil }
        return hash.map { String(format: "%02x", $0) }.joined()
    }
    #endif

    public static func alias(for identifier: String, runID: UUID) -> UUID {
        let bytes = Array(SHA256.hash(data: Data((runID.uuidString + ":item:" + identifier).utf8)).prefix(16))
        return UUID(uuid: (bytes[0],bytes[1],bytes[2],bytes[3],bytes[4],bytes[5],bytes[6],bytes[7],
                           bytes[8],bytes[9],bytes[10],bytes[11],bytes[12],bytes[13],bytes[14],bytes[15]))
    }

    public static func activeAlias(for identifier: String?) -> UUID? {
        #if STABILITY
        guard let identifier, let run = try? activeRun() else { return nil }
        return alias(for: identifier, runID: run.runID)
        #else
        return nil
        #endif
    }

    /// Commits to an item's identity, name, parent, and size without exporting
    /// their values. The run salt prevents comparison across evidence bundles.
    public static func metadataAlias(for item: KDriveRemoteItem, runID: UUID) -> UUID {
        let fields = [String(item.id), String(item.parentID), item.name, item.size.map(String.init) ?? "nil"]
        let encoded = fields.map { "\($0.utf8.count):\($0)" }.joined()
        return alias(for: "metadata:" + encoded, runID: runID)
    }

    public static func activeRun() throws -> StabilityRunHandle? {
        guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: ProviderConstants.appGroupIdentifier) else {
            throw ProviderDiagnosticStoreError.missingAppGroupContainer(ProviderConstants.appGroupIdentifier)
        }
        return try StabilityRunLocator.activeRun(rootDirectoryURL: container.appendingPathComponent("StabilityRuns"))
    }
}
