import Foundation

#if os(macOS)
import AppKit
import FileProvider
#endif

enum ProviderExternalVolumeUnsupportedReason: String, CaseIterable, Equatable, Hashable, Sendable {
    case unknown
    case nonAPFS
    case nonEncrypted
    case readOnly
    case network
    case quarantined

    var userFacingDescription: String {
        switch self {
        case .unknown:
            return "macOS could not determine whether this drive supports File Provider storage."
        case .nonAPFS:
            return "The drive must use APFS."
        case .nonEncrypted:
            return "The drive must be encrypted."
        case .readOnly:
            return "The drive is read-only."
        case .network:
            return "Network volumes cannot store File Provider domains."
        case .quarantined:
            return "The drive is quarantined by macOS."
        }
    }
}

enum ProviderExternalVolumeEligibility: Equatable, Sendable {
    case eligible
    case ineligible(Set<ProviderExternalVolumeUnsupportedReason>)
}

struct ProviderExternalVolume: Equatable, Sendable {
    let url: URL
    let uuid: UUID
    let displayName: String
    let totalCapacity: Int64?
    let availableCapacity: Int64?
    let eligibility: ProviderExternalVolumeEligibility

    fileprivate let securityScopedURL: URL
}

@MainActor
protocol ProviderExternalVolumeSelecting {
    func selectExternalVolume() async throws -> ProviderExternalVolume?
    func inspectVolume(at selectedURL: URL) throws -> ProviderExternalVolume
    func mountedVolume(uuid: UUID) throws -> ProviderExternalVolume?
    func withSecurityScopedAccess<T>(
        to volume: ProviderExternalVolume,
        operation: @MainActor (URL) async throws -> T
    ) async throws -> T
}

enum ProviderExternalVolumeSelectionError: Error, Equatable, LocalizedError, Sendable {
    case unsupportedPlatform
    case missingVolumeRoot(URL)
    case missingVolumeUUID(URL)

    var errorDescription: String? {
        switch self {
        case .unsupportedPlatform:
            return "External File Provider storage is available only on macOS."
        case .missingVolumeRoot:
            return "The selected location is not on an accessible volume."
        case .missingVolumeUUID:
            return "macOS could not identify the selected volume."
        }
    }
}

@MainActor
struct ProviderExternalVolumeSelectionService: ProviderExternalVolumeSelecting {
    private let chooseURL: () async throws -> URL?
    private let startAccessing: (URL) -> Bool
    private let stopAccessing: (URL) -> Void
    private let volumeRoot: (URL) throws -> URL
    private let volumeMetadata: (URL) throws -> ProviderExternalVolumeMetadata
    private let checkEligibility: (URL) throws -> ProviderExternalVolumeEligibility
    private let mountedVolumeURLs: () -> [URL]

    init() {
        #if os(macOS)
        chooseURL = Self.presentOpenPanel
        startAccessing = { $0.startAccessingSecurityScopedResource() }
        stopAccessing = { $0.stopAccessingSecurityScopedResource() }
        volumeRoot = Self.systemVolumeRoot
        volumeMetadata = Self.systemVolumeMetadata
        checkEligibility = Self.systemEligibility
        mountedVolumeURLs = {
            FileManager.default.mountedVolumeURLs(
                includingResourceValuesForKeys: [.volumeUUIDStringKey],
                options: [.skipHiddenVolumes]
            ) ?? []
        }
        #else
        chooseURL = { throw ProviderExternalVolumeSelectionError.unsupportedPlatform }
        startAccessing = { _ in false }
        stopAccessing = { _ in }
        volumeRoot = { throw ProviderExternalVolumeSelectionError.missingVolumeRoot($0) }
        volumeMetadata = { throw ProviderExternalVolumeSelectionError.missingVolumeUUID($0) }
        checkEligibility = { _ in throw ProviderExternalVolumeSelectionError.unsupportedPlatform }
        mountedVolumeURLs = { [] }
        #endif
    }

    init(
        chooseURL: @escaping () async throws -> URL?,
        startAccessing: @escaping (URL) -> Bool,
        stopAccessing: @escaping (URL) -> Void,
        volumeRoot: @escaping (URL) throws -> URL,
        volumeMetadata: @escaping (URL) throws -> ProviderExternalVolumeMetadata,
        checkEligibility: @escaping (URL) throws -> ProviderExternalVolumeEligibility,
        mountedVolumeURLs: @escaping () -> [URL] = { [] }
    ) {
        self.chooseURL = chooseURL
        self.startAccessing = startAccessing
        self.stopAccessing = stopAccessing
        self.volumeRoot = volumeRoot
        self.volumeMetadata = volumeMetadata
        self.checkEligibility = checkEligibility
        self.mountedVolumeURLs = mountedVolumeURLs
    }

    func selectExternalVolume() async throws -> ProviderExternalVolume? {
        guard let selectedURL = try await chooseURL() else { return nil }
        return try inspectVolume(at: selectedURL)
    }

    func inspectVolume(at selectedURL: URL) throws -> ProviderExternalVolume {
        let didStartAccessing = startAccessing(selectedURL)
        defer {
            if didStartAccessing {
                stopAccessing(selectedURL)
            }
        }

        let normalizedURL = try volumeRoot(selectedURL)
        let metadata = try volumeMetadata(normalizedURL)
        return ProviderExternalVolume(
            url: normalizedURL,
            uuid: metadata.uuid,
            displayName: metadata.displayName,
            totalCapacity: metadata.totalCapacity,
            availableCapacity: metadata.availableCapacity,
            eligibility: try checkEligibility(normalizedURL),
            securityScopedURL: selectedURL
        )
    }

    func mountedVolume(uuid: UUID) throws -> ProviderExternalVolume? {
        for url in mountedVolumeURLs() {
            guard let volume = try? inspectVolume(at: url), volume.uuid == uuid else {
                continue
            }
            return volume
        }
        return nil
    }

    func withSecurityScopedAccess<T>(
        to volume: ProviderExternalVolume,
        operation: @MainActor (URL) async throws -> T
    ) async throws -> T {
        let didStartAccessing = startAccessing(volume.securityScopedURL)
        defer {
            if didStartAccessing {
                stopAccessing(volume.securityScopedURL)
            }
        }
        return try await operation(volume.url)
    }
}

struct ProviderExternalVolumeMetadata: Equatable, Sendable {
    let uuid: UUID
    let displayName: String
    let totalCapacity: Int64?
    let availableCapacity: Int64?
}

#if os(macOS)
extension ProviderExternalVolumeSelectionService {
    static func unsupportedReasons(
        from reasons: NSFileProviderVolumeUnsupportedReason
    ) -> Set<ProviderExternalVolumeUnsupportedReason> {
        var result: Set<ProviderExternalVolumeUnsupportedReason> = []
        if reasons.contains(.unknown) { result.insert(.unknown) }
        if reasons.contains(.nonAPFS) { result.insert(.nonAPFS) }
        if reasons.contains(.nonEncrypted) { result.insert(.nonEncrypted) }
        if reasons.contains(.readOnly) { result.insert(.readOnly) }
        if reasons.contains(.network) { result.insert(.network) }
        if reasons.contains(.quarantined) { result.insert(.quarantined) }
        return result
    }

    private static func presentOpenPanel() async -> URL? {
        await withCheckedContinuation { continuation in
            let panel = NSOpenPanel()
            panel.title = "Choose an External Drive"
            panel.message = "Choose any folder on the encrypted APFS drive where macOS should store this File Provider domain."
            panel.prompt = "Choose Drive"
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.allowsMultipleSelection = false
            panel.canCreateDirectories = false
            panel.resolvesAliases = true
            panel.begin { response in
                continuation.resume(returning: response == .OK ? panel.url : nil)
            }
        }
    }

    static func systemVolumeRoot(for url: URL) throws -> URL {
        let values = try url.resourceValues(forKeys: [.volumeURLKey])
        guard let volume = values.volume else {
            throw ProviderExternalVolumeSelectionError.missingVolumeRoot(url)
        }
        return volume.standardizedFileURL
    }

    private static func systemVolumeMetadata(for volumeURL: URL) throws -> ProviderExternalVolumeMetadata {
        let values = try volumeURL.resourceValues(forKeys: [
            .volumeUUIDStringKey,
            .volumeNameKey,
            .volumeLocalizedNameKey,
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
        ])
        guard let uuidString = values.volumeUUIDString,
              let uuid = UUID(uuidString: uuidString)
        else {
            throw ProviderExternalVolumeSelectionError.missingVolumeUUID(volumeURL)
        }
        let displayName = values.volumeLocalizedName
            ?? values.volumeName
            ?? volumeURL.lastPathComponent
        return ProviderExternalVolumeMetadata(
            uuid: uuid,
            displayName: displayName.isEmpty ? "External Drive" : displayName,
            totalCapacity: values.volumeTotalCapacity.map(Int64.init),
            availableCapacity: values.volumeAvailableCapacityForImportantUsage
        )
    }

    private static func systemEligibility(for volumeURL: URL) throws -> ProviderExternalVolumeEligibility {
        switch try NSFileProviderManager.checkDomainsCanBeStoredOnVolume(at: volumeURL) {
        case .eligible:
            return .eligible
        case .ineligible(let reasons):
            return .ineligible(unsupportedReasons(from: reasons))
        }
    }
}
#endif
