#if os(macOS)
import FileProvider
import Foundation
import PotassiumProviderCore
import Testing
@testable import potassiumProvider

@Suite(.serialized)
@MainActor
struct ProviderDomainRegistrarExternalVolumeTests {
    @Test func preparesExternalDomainWithOpaqueBindingAndRegistersExactObject() async throws {
        let system = RecordingFileProviderDomainSystem()
        let registrar = FileProviderDomainRegistrar(system: system.client)
        let prepared = try registrar.prepareDomain(
            configurationIdentifier: "configuration-1",
            domainIdentifier: "ignored-for-external-domain",
            displayName: "External kDrive",
            target: .externalVolume(FileManager.default.temporaryDirectory)
        )

        let binding = try ProviderExternalDomainUserInfoCodec.decode(
            prepared.fileProviderDomain.userInfo
        )
        #expect(binding.configurationIdentifier == "configuration-1")
        #expect(prepared.configurationIdentifier == "configuration-1")
        #expect(prepared.domainIdentifier == prepared.fileProviderDomain.identifier.rawValue)
        #expect(prepared.fileProviderDomain.supportedKnownFolders == [.desktop, .documents])

        try await registrar.addPreparedDomain(prepared)

        let addedDomain = try #require(system.addedDomains.first)
        #expect(addedDomain === prepared.fileProviderDomain)
    }

    @Test func preparesInternalDomainWithRequestedIdentifier() throws {
        let registrar = FileProviderDomainRegistrar(system: RecordingFileProviderDomainSystem().client)

        let prepared = try registrar.prepareDomain(
            configurationIdentifier: "configuration-1",
            domainIdentifier: "internal-domain-1",
            displayName: "Local kDrive",
            target: .onThisMac
        )

        #expect(prepared.configurationIdentifier == "configuration-1")
        #expect(prepared.domainIdentifier == "internal-domain-1")
        #expect(prepared.volumeUUID == nil)
        #expect(ProviderExternalDomainUserInfoCodec.containsBinding(
            in: prepared.fileProviderDomain.userInfo
        ) == false)
        #expect(prepared.fileProviderDomain.supportedKnownFolders == [.desktop, .documents])
    }

    @Test func reportsRegisteredExternalBindingAndLocalDomainState() async throws {
        let externalDomain = NSFileProviderDomain(
            displayName: "External kDrive",
            userInfo: ProviderExternalDomainUserInfoCodec.userInfo(
                configurationIdentifier: "configuration-1"
            ),
            volumeURL: FileManager.default.temporaryDirectory
        )
        let localDomain = NSFileProviderDomain(
            identifier: NSFileProviderDomainIdentifier(rawValue: "local-domain"),
            displayName: "Local kDrive"
        )
        let system = RecordingFileProviderDomainSystem(registeredDomains: [externalDomain, localDomain])
        let registrar = FileProviderDomainRegistrar(system: system.client)

        let states = try await registrar.registeredDomainStates()

        let externalState = try #require(states.first {
            $0.domainIdentifier == externalDomain.identifier.rawValue
        })
        #expect(externalState.configurationIdentifier == "configuration-1")
        #expect(externalState.displayName == "External kDrive")
        #expect(externalState.isDisconnected == false)
        #expect(externalState.knownFolderSyncState == .inactive)

        let localState = try #require(states.first { $0.domainIdentifier == "local-domain" })
        #expect(localState.configurationIdentifier == nil)
    }

    @Test func existingExternalOperationsUseRegisteredObjectAndPreserveDirtyData() async throws {
        let externalDomain = NSFileProviderDomain(
            displayName: "External kDrive",
            userInfo: ProviderExternalDomainUserInfoCodec.userInfo(
                configurationIdentifier: "configuration-1"
            ),
            volumeURL: FileManager.default.temporaryDirectory
        )
        let preservedURL = URL(fileURLWithPath: "/private/tmp/preserved-user-data")
        let system = RecordingFileProviderDomainSystem(
            registeredDomains: [externalDomain],
            preservedURL: preservedURL
        )
        let registrar = FileProviderDomainRegistrar(system: system.client)
        let configuration = ProviderDomainConfiguration(
            configurationIdentifier: "configuration-1",
            domainIdentifier: externalDomain.identifier.rawValue,
            displayName: "External kDrive",
            driveID: 42,
            driveName: "External kDrive",
            storageLocation: .externalVolume(
                uuid: externalDomain.volumeUUID ?? UUID(),
                displayName: "External Drive"
            )
        )

        try await registrar.addDomain(for: configuration)
        try await registrar.waitForStabilization(for: configuration)
        try await registrar.reconnectDomain(for: configuration)
        let returnedPreservedURL = try await registrar.removeDomainPreservingDirtyUserData(
            for: configuration
        )
        try await registrar.removeDomain(for: configuration)

        #expect(system.addedDomains.first === externalDomain)
        #expect(system.stabilizedDomains.first === externalDomain)
        #expect(system.reconnectedDomains.first === externalDomain)
        #expect(system.preserveRemovedDomains.first === externalDomain)
        #expect(system.removedDomains.first === externalDomain)
        #expect(returnedPreservedURL == preservedURL)
    }

    @Test func externalExistingOperationFailsRatherThanReconstructingMissingDomain() async throws {
        let registrar = FileProviderDomainRegistrar(system: RecordingFileProviderDomainSystem().client)
        let configuration = ProviderDomainConfiguration(
            configurationIdentifier: "configuration-1",
            domainIdentifier: "missing-domain",
            displayName: "External kDrive",
            driveID: 42,
            driveName: "External kDrive",
            storageLocation: .externalVolume(uuid: UUID(), displayName: "External Drive")
        )

        await #expect(throws: ProviderDomainRegistrationError.domainNotRegistered("missing-domain")) {
            try await registrar.addDomain(for: configuration)
        }
        await #expect(throws: ProviderDomainRegistrationError.domainNotRegistered("missing-domain")) {
            try await registrar.removeDomain(for: configuration)
        }
    }

    @Test func mapsEveryExternalVolumeUnsupportedReasonIncludingCombinations() {
        let reasons: NSFileProviderVolumeUnsupportedReason = [
            .unknown,
            .nonAPFS,
            .nonEncrypted,
            .readOnly,
            .network,
            .quarantined,
        ]

        #expect(ProviderExternalVolumeSelectionService.unsupportedReasons(from: reasons) == Set(
            ProviderExternalVolumeUnsupportedReason.allCases
        ))
        #expect(ProviderExternalVolumeSelectionService.unsupportedReasons(from: []) == [])
        #expect(ProviderExternalVolumeUnsupportedReason.nonAPFS.userFacingDescription.contains("APFS"))
        #expect(ProviderExternalVolumeUnsupportedReason.nonEncrypted.userFacingDescription.contains("encrypted"))
    }

    @Test func selectionNormalizesToVolumeRootAndBalancesSecurityScope() async throws {
        let selectedURL = URL(fileURLWithPath: "/Volumes/Test Drive/Folder")
        let volumeURL = URL(fileURLWithPath: "/Volumes/Test Drive")
        let uuid = UUID()
        var startedURLs: [URL] = []
        var stoppedURLs: [URL] = []
        var inspectedURLs: [URL] = []
        let service = ProviderExternalVolumeSelectionService(
            chooseURL: { selectedURL },
            startAccessing: {
                startedURLs.append($0)
                return true
            },
            stopAccessing: { stoppedURLs.append($0) },
            volumeRoot: { _ in volumeURL },
            volumeMetadata: {
                inspectedURLs.append($0)
                return ProviderExternalVolumeMetadata(
                    uuid: uuid,
                    displayName: "Test Drive",
                    totalCapacity: 2_000,
                    availableCapacity: 1_000
                )
            },
            checkEligibility: {
                inspectedURLs.append($0)
                return .eligible
            }
        )

        let volume = try #require(try await service.selectExternalVolume())

        #expect(volume.url == volumeURL)
        #expect(volume.uuid == uuid)
        #expect(volume.displayName == "Test Drive")
        #expect(volume.totalCapacity == 2_000)
        #expect(volume.availableCapacity == 1_000)
        #expect(volume.eligibility == .eligible)
        #expect(startedURLs == [selectedURL])
        #expect(stoppedURLs == [selectedURL])
        #expect(inspectedURLs == [volumeURL, volumeURL])
    }

    @Test func selectionCancellationAndUnscopedAccessDoNotStopSecurityScope() async throws {
        var starts = 0
        var stops = 0
        let cancelledService = ProviderExternalVolumeSelectionService(
            chooseURL: { nil },
            startAccessing: { _ in starts += 1; return true },
            stopAccessing: { _ in stops += 1 },
            volumeRoot: { $0 },
            volumeMetadata: { _ in
                ProviderExternalVolumeMetadata(
                    uuid: UUID(),
                    displayName: "Unused",
                    totalCapacity: nil,
                    availableCapacity: nil
                )
            },
            checkEligibility: { _ in .eligible }
        )
        #expect(try await cancelledService.selectExternalVolume() == nil)
        #expect(starts == 0)
        #expect(stops == 0)

        let selectedURL = URL(fileURLWithPath: "/Volumes/Already Accessible")
        let unscopedService = ProviderExternalVolumeSelectionService(
            chooseURL: { selectedURL },
            startAccessing: { _ in starts += 1; return false },
            stopAccessing: { _ in stops += 1 },
            volumeRoot: { $0 },
            volumeMetadata: { _ in
                ProviderExternalVolumeMetadata(
                    uuid: UUID(),
                    displayName: "Already Accessible",
                    totalCapacity: nil,
                    availableCapacity: nil
                )
            },
            checkEligibility: { _ in .eligible }
        )
        _ = try await unscopedService.selectExternalVolume()
        #expect(starts == 1)
        #expect(stops == 0)
    }

    @Test func explicitSecurityScopeSpansAsyncOperationAndBalancesOnSuccessAndThrow() async throws {
        let selectedURL = URL(fileURLWithPath: "/Volumes/Test Drive/Selected Folder")
        let volumeURL = URL(fileURLWithPath: "/Volumes/Test Drive")
        var starts = 0
        var stops = 0
        let service = ProviderExternalVolumeSelectionService(
            chooseURL: { selectedURL },
            startAccessing: { url in
                #expect(url == selectedURL)
                starts += 1
                return true
            },
            stopAccessing: { url in
                #expect(url == selectedURL)
                stops += 1
            },
            volumeRoot: { _ in volumeURL },
            volumeMetadata: { _ in
                ProviderExternalVolumeMetadata(
                    uuid: UUID(),
                    displayName: "Test Drive",
                    totalCapacity: nil,
                    availableCapacity: nil
                )
            },
            checkEligibility: { _ in .eligible }
        )
        let volume = try #require(try await service.selectExternalVolume())
        #expect(starts == 1)
        #expect(stops == 1)

        let result = try await service.withSecurityScopedAccess(to: volume) { accessibleVolumeURL in
            #expect(accessibleVolumeURL == volumeURL)
            await Task.yield()
            #expect(stops == 1)
            return "registered"
        }
        #expect(result == "registered")
        #expect(starts == 2)
        #expect(stops == 2)

        await #expect(throws: ProviderExternalVolumeFoundationTestError.registrationFailed) {
            try await service.withSecurityScopedAccess(to: volume) { accessibleVolumeURL in
                #expect(accessibleVolumeURL == volumeURL)
                await Task.yield()
                throw ProviderExternalVolumeFoundationTestError.registrationFailed
            }
        }
        #expect(starts == 3)
        #expect(stops == 3)
    }

    @Test func systemNormalizationUsesContainingVolumeNotSelectedFolder() throws {
        let selectedURL = FileManager.default.temporaryDirectory
        let expectedVolume = try FileManager.default.temporaryDirectory
            .resourceValues(forKeys: [.volumeURLKey])
            .volume?
            .standardizedFileURL

        let normalizedVolume = try ProviderExternalVolumeSelectionService.systemVolumeRoot(
            for: selectedURL
        )

        #expect(normalizedVolume == expectedVolume)
        #expect(normalizedVolume != selectedURL)
    }
}

private enum ProviderExternalVolumeFoundationTestError: Error {
    case registrationFailed
}

@MainActor
private final class RecordingFileProviderDomainSystem {
    var addedDomains: [NSFileProviderDomain] = []
    var removedDomains: [NSFileProviderDomain] = []
    var stabilizedDomains: [NSFileProviderDomain] = []
    var preserveRemovedDomains: [NSFileProviderDomain] = []
    var reconnectedDomains: [NSFileProviderDomain] = []

    private let domains: [NSFileProviderDomain]
    private let preservedURL: URL?

    init(
        registeredDomains: [NSFileProviderDomain] = [],
        preservedURL: URL? = nil
    ) {
        domains = registeredDomains
        self.preservedURL = preservedURL
    }

    var client: FileProviderDomainSystemClient {
        FileProviderDomainSystemClient(
            addDomain: { [self] in addedDomains.append($0) },
            removeDomain: { [self] in removedDomains.append($0) },
            registeredDomains: { [self] in domains },
            waitForStabilization: { [self] in stabilizedDomains.append($0) },
            removeDomainPreservingDirtyUserData: { [self] in
                preserveRemovedDomains.append($0)
                return preservedURL
            },
            reconnectDomain: { [self] in reconnectedDomains.append($0) }
        )
    }
}
#endif
