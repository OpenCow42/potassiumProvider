import FileProvider
import Foundation
import PotassiumProviderCore
import Testing

/// Stable test IDs are also reproduction selectors. Expected outcomes are
/// specified independently of the coordinator's implementation.
enum ConflictCase: String, CaseIterable, Sendable {
    case staleEdit = "plaintext.content.stale"
    case missingVersion = "plaintext.content.missing-version"
    case conditionalRace = "plaintext.content.after-preflight"
    case failOnConflict = "plaintext.content.fail-on-conflict"
    case renameRename = "plaintext.metadata.rename-rename"
    case moveMove = "plaintext.metadata.move-move"
    case editRename = "plaintext.metadata.edit-rename"
    case editMove = "plaintext.metadata.edit-move"
    case moveRemoteRename = "plaintext.metadata.move-preserves-rename"
    case nameCollision = "plaintext.identity.name-collision"
    case caseCollision = "plaintext.identity.case-collision"
    case unicodeCollision = "plaintext.identity.unicode-collision"
    case trashEdit = "plaintext.trash.concurrent-edit"
    case staleDeletion = "plaintext.delete.stale"
    case lostCreateResponse = "plaintext.retry.create-response-lost"
    case lostConflictResponse = "plaintext.retry.conflict-response-lost"
    case lostReplacementResponse = "plaintext.retry.replacement-response-lost"
    case lostDirectoryResponse = "plaintext.retry.directory-response-lost"
    case sameNameReplacement = "plaintext.identity.same-name-replacement"
    case repeatedMetadata = "plaintext.retry.metadata-delivery"
    case mayAlreadyExistFile = "plaintext.callback.may-already-exist-file"
    case mayAlreadyExistDirectory = "plaintext.callback.may-already-exist-directory"
    case movedParent = "plaintext.folder.parent-moved"
    case removedParent = "plaintext.folder.parent-removed"

    case vaultContent = "vault.content.concurrent"
    case vaultMetadata = "vault.metadata.concurrent"
    case vaultCycle = "vault.folder.reciprocal-moves"
    case vaultDeleteChild = "vault.folder.delete-child-create"
    case vaultTrashProvenance = "vault.trash.independent-descendant"
    case vaultNameAllocation = "vault.identity.name-collision"
    case vaultStalePurge = "vault.delete.stale-purge"
    case vaultHistoricalRestore = "vault.version.restore-aba"
    case vaultOmittedHistory = "vault.history.omission"
    case vaultOfflineReference = "vault.history.offline-reference"

    enum Engine: String { case plaintext, vault }
    var engine: Engine { rawValue.hasPrefix("vault.") ? .vault : .plaintext }
    static var callbackCases: [Self] { [.mayAlreadyExistFile, .mayAlreadyExistDirectory] }
    static var plaintextCases: [Self] { allCases.filter { $0.engine == .plaintext && !callbackCases.contains($0) } }
    static var vaultCases: [Self] { allCases.filter { $0.engine == .vault } }
    var ordering: String {
        switch self {
        case .conditionalRace: "competing client commits after local preflight"
        case .mayAlreadyExistFile, .mayAlreadyExistDirectory: "existing server identity, then duplicate create delivery through production callback routing"
        case .lostCreateResponse, .lostConflictResponse, .lostReplacementResponse, .lostDirectoryResponse: "server commits, response is lost, client restarts and retries"
        default: engine == .vault ? "causal transactions delivered in different orders" : "both clients cache base; remote intent precedes local intent"
        }
    }
    var competingOperations: [String] {
        switch self {
        case .staleEdit, .missingVersion, .conditionalRace, .failOnConflict, .vaultContent: ["edit base on client A", "edit same base on client B"]
        case .renameRename: ["rename A", "rename B"]
        case .moveMove: ["move to A", "move to B"]
        case .editRename: ["edit contents", "rename same identity"]
        case .editMove, .moveRemoteRename: ["edit independent field", "move same identity"]
        case .nameCollision, .caseCollision, .unicodeCollision, .vaultNameAllocation: ["create sibling", "claim equivalent name"]
        case .trashEdit, .staleDeletion, .vaultStalePurge: ["edit contents", "trash or delete stale identity"]
        case .lostCreateResponse, .lostConflictResponse, .lostReplacementResponse, .lostDirectoryResponse: ["commit mutation", "restart and replay unacknowledged mutation"]
        case .mayAlreadyExistFile, .mayAlreadyExistDirectory: ["server item already exists", "create callback with reconciliation hint", "repeat callback"]
        case .sameNameReplacement: ["remove original identity", "create another identity at the same path", "edit original cached identity"]
        case .repeatedMetadata: ["move and rename", "repeat same callback intent"]
        case .movedParent, .removedParent: ["move or remove parent", "create child by parent identity"]
        case .vaultMetadata: ["rename A", "rename B"]
        case .vaultCycle: ["move A under B", "move B under A"]
        case .vaultDeleteChild: ["delete parent", "create child"]
        case .vaultTrashProvenance: ["trash descendant independently", "trash and restore ancestor"]
        case .vaultHistoricalRestore: ["restore historical content", "edit with old revision"]
        case .vaultOmittedHistory: ["persist causal history", "omit a remote journal object"]
        case .vaultOfflineReference: ["retain offline reference", "run maintenance"]
        }
    }
    var unresolvedFinding: String? {
        switch self {
        case .lostReplacementResponse, .lostDirectoryResponse, .mayAlreadyExistDirectory: "CR-009"
        case .staleDeletion: "CR-013"
        default: nil
        }
    }
    var recoveryAssertion: String { "Re-read preserved identities and contents after resolution; retain staged bytes when rejected." }
    var expectedResolution: String {
        switch self {
        case .staleEdit, .missingVersion, .conditionalRace: "preserve both byte streams"
        case .failOnConflict: "reject and retain staged local bytes"
        case .renameRename, .moveMove: "apply local metadata intent to the same identity"
        case .editRename, .editMove, .moveRemoteRename: "preserve independent remote metadata"
        case .nameCollision, .caseCollision, .unicodeCollision: "retain both identities with distinct names"
        case .trashEdit: "preserve remote bytes in reversible trash"
        case .staleDeletion: "reject deletion and preserve changed item"
        case .lostCreateResponse, .lostConflictResponse: "retry against retained state without a second upload effect"
        case .lostReplacementResponse: "preserve bytes in original and redundant copy; ambiguous success remains CR-009"
        case .lostDirectoryResponse: "preserve original and create second directory; reconciliation remains CR-009"
        case .sameNameReplacement: "reject missing original identity; preserve replacement and staged local bytes"
        case .repeatedMetadata: "return same identity without repeating remote effects"
        case .mayAlreadyExistFile: "preserve existing bytes; file replay returns the same created identity under the service token model"
        case .mayAlreadyExistDirectory: "preserve both directories; do not infer identity from a matching name; CR-009 remains"
        case .movedParent: "address the parent by stable identity"
        case .removedParent: "reject create and retain staged bytes"
        case .vaultContent: "canonical winner plus stable copies of competing contents"
        case .vaultMetadata: "canonical metadata winner with explicit conflict"
        case .vaultCycle: "preserve an acyclic parent graph in every replay order"
        case .vaultDeleteChild: "preserve the folder and concurrent child"
        case .vaultTrashProvenance: "leave independently trashed descendants in trash"
        case .vaultNameAllocation: "allocate distinct normalized sibling names"
        case .vaultStalePurge: "preserve the changed identity"
        case .vaultHistoricalRestore: "publish a fresh revision; reject stale ABA write"
        case .vaultOmittedHistory: "reject rollback without filling omitted history from cache"
        case .vaultOfflineReference: "never delete ciphertext that an offline device may reference"
        }
    }
}

struct ConflictMatrixTests {
    @Test(.timeLimit(.minutes(1)), arguments: ConflictCase.plaintextCases)
    func twoPersistentClientsResolve(_ scenario: ConflictCase) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let remote = try ConflictTestRemote(directory: directory.appendingPathComponent("server"))
        let first = ConflictTestClient(directory: directory.appendingPathComponent("first"), remote: remote)
        let second = ConflictTestClient(directory: directory.appendingPathComponent("second"), remote: remote)
        let base = try await remote.item(driveID: 7, fileID: 3)
        try first.cache(base); try second.cache(base)
        let local = Data("local changed contents".utf8), other = Data("remote changed contents".utf8)
        var resultID = 3
        switch scenario {
        case .staleEdit, .missingVersion, .failOnConflict:
            _ = try await second.edit(other)
            if scenario == .failOnConflict {
                await #expect(throws: KDriveMutationConflictError.self) { try await first.edit(local, failOnConflict: true) }
                let files = try FileManager.default.contentsOfDirectory(at: first.directory.appendingPathComponent("staging"), includingPropertiesForKeys: nil)
                #expect(try files.map { try Data(contentsOf: $0) } == [local])
                #expect(await remote.snapshot().items.count == 3)
            } else {
                let result = try await first.edit(local, version: scenario == .missingVersion ? Data() : nil)
                resultID = result.item.id
                #expect(resultID != base.id)
                #expect(try await remote.downloadFile(driveID: 7, fileID: resultID) == local)
            }
            #expect(try await remote.downloadFile(driveID: 7, fileID: 3) == other)
        case .conditionalRace:
            let gate = ConflictTestGate()
            await remote.gateReplacement(gate)
            let edit = Task { try await first.edit(local) }
            defer { edit.cancel() }
            try await gate.waitUntilReached()
            _ = try await second.edit(other)
            await gate.release()
            let result = try await edit.value
            resultID = result.item.id
            #expect(resultID != 3)
            #expect(await remote.operations() == ["replace", "replace", "upload"])
            #expect(try await remote.downloadFile(driveID: 7, fileID: resultID) == local)
            #expect(try await remote.downloadFile(driveID: 7, fileID: 3) == other)
        case .renameRename:
            _ = try await second.coordinator.renameItem(fileID: 3, baseMetadataVersion: base.metadataVersion, name: "Remote.txt")
            let result = try await first.coordinator.renameItem(fileID: 3, baseMetadataVersion: base.metadataVersion, name: "Local.txt")
            #expect(result.id == 3 && result.name == "Local.txt" && result.parentID == 1)
        case .moveMove:
            let folder = try await remote.createDirectory(driveID: 7, parentID: 1, name: "Third")
            _ = try await second.coordinator.moveItem(fileID: 3, baseMetadataVersion: base.metadataVersion, destinationParentID: folder.id, name: nil)
            let result = try await first.coordinator.moveItem(fileID: 3, baseMetadataVersion: base.metadataVersion, destinationParentID: 2, name: nil)
            #expect(result.id == 3 && result.parentID == 2 && result.name == base.name)
        case .editRename, .moveRemoteRename:
            _ = try await second.coordinator.renameItem(fileID: 3, baseMetadataVersion: base.metadataVersion, name: "Remote.txt")
            let result: KDriveRemoteItem
            if scenario == .editRename { result = try await first.edit(local).item }
            else { result = try await first.coordinator.moveItem(fileID: 3, baseMetadataVersion: base.metadataVersion, destinationParentID: 2, name: nil) }
            #expect(result.id == 3 && result.name == "Remote.txt")
            #expect(result.parentID == (scenario == .editRename ? 1 : 2))
            #expect(try await remote.downloadFile(driveID: 7, fileID: 3) == (scenario == .editRename ? local : Data("base".utf8)))
        case .editMove:
            _ = try await second.coordinator.moveItem(fileID: 3, baseMetadataVersion: base.metadataVersion, destinationParentID: 2, name: nil)
            let result = try await first.edit(local).item
            #expect(result.id == 3 && result.parentID == 2 && result.name == base.name)
            #expect(try await remote.downloadFile(driveID: 7, fileID: 3) == local)
        case .nameCollision, .caseCollision, .unicodeCollision:
            let existingName = scenario == .unicodeCollision ? "caf\u{00E9}.txt" : "Local.txt"
            let desired = scenario == .caseCollision ? "LOCAL.txt" : scenario == .unicodeCollision ? "cafe\u{0301}.txt" : existingName
            let sibling = try await second.coordinator.createFile(parentID: 1, fileName: existingName, contents: other, lastModifiedAt: nil)
            let result = try await first.coordinator.renameItem(fileID: 3, baseMetadataVersion: base.metadataVersion, name: desired)
            #expect(result.id == 3 && result.parentID == 1)
            #expect(result.name.precomposedStringWithCanonicalMapping.lowercased() != existingName.precomposedStringWithCanonicalMapping.lowercased())
            #expect(try await remote.downloadFile(driveID: 7, fileID: sibling.id) == other)
        case .trashEdit, .staleDeletion:
            _ = try await second.edit(other)
            let version = KDriveItemBaseVersion(contentVersion: base.contentVersion, metadataVersion: base.metadataVersion)
            if scenario == .trashEdit {
                _ = try await first.coordinator.trashItem(fileID: 3, baseVersion: version)
                #expect(await remote.snapshot().trash == [3])
            } else {
                await #expect(throws: KDriveMutationConflictError.self) { try await first.coordinator.deleteTrashedItem(fileID: 3, baseVersion: version) }
                #expect(!(await remote.operations()).contains("delete"))
            }
            #expect(try await remote.downloadFile(driveID: 7, fileID: 3) == other)
        case .lostCreateResponse, .lostConflictResponse:
            if scenario == .lostConflictResponse { _ = try await second.edit(other) }
            await remote.inject(.responseLost)
            await #expect(throws: URLError.self) {
                if scenario == .lostCreateResponse { _ = try await first.coordinator.createFile(parentID: 1, fileName: "New.txt", contents: local, lastModifiedAt: nil) }
                else { _ = try await first.edit(local) }
            }
            let committed = await remote.snapshot()
            let restartedRemote = try ConflictTestRemote(directory: directory.appendingPathComponent("server"))
            let restarted = ConflictTestClient(directory: first.directory, remote: restartedRemote)
            #expect(try restarted.base() == base)
            let result: KDriveRemoteItem
            if scenario == .lostCreateResponse { result = try await restarted.coordinator.createFile(parentID: 1, fileName: "New.txt", contents: local, lastModifiedAt: nil) }
            else { result = try await restarted.edit(local).item }
            #expect(await restartedRemote.snapshot().items == committed.items)
            #expect(try await restartedRemote.downloadFile(driveID: 7, fileID: result.id) == local)
            #expect(try FileManager.default.contentsOfDirectory(atPath: first.directory.appendingPathComponent("staging").path).isEmpty)
        case .lostReplacementResponse, .lostDirectoryResponse:
            await remote.inject(.responseLost)
            await #expect(throws: URLError.self) {
                if scenario == .lostReplacementResponse { _ = try await first.edit(local) }
                else { _ = try await first.coordinator.createDirectory(parentID: 1, name: "Unacknowledged") }
            }
            let committed = await remote.snapshot()
            let restartedRemote = try ConflictTestRemote(directory: directory.appendingPathComponent("server"))
            let restarted = ConflictTestClient(directory: first.directory, remote: restartedRemote)
            let retried: KDriveRemoteItem
            if scenario == .lostReplacementResponse {
                retried = try await restarted.edit(local).item
                #expect(retried.id != 3)
                #expect(try await restartedRemote.downloadFile(driveID: 7, fileID: 3) == local)
                #expect(try await restartedRemote.downloadFile(driveID: 7, fileID: retried.id) == local)
            } else {
                retried = try await restarted.coordinator.createDirectory(parentID: 1, name: "Unacknowledged")
                #expect(retried.isDirectory && retried.name != "Unacknowledged" && retried.parentID == 1)
                let child = try await restarted.coordinator.createFile(parentID: retried.id, fileName: "Usable.txt", contents: local, lastModifiedAt: nil)
                #expect(try await restartedRemote.downloadFile(driveID: 7, fileID: child.id) == local)
            }
            #expect(committed.items[retried.id] == nil)
            for (id, item) in committed.items { #expect(await restartedRemote.snapshot().items[id] == item) }
            #expect(scenario.unresolvedFinding == "CR-009")
        case .sameNameReplacement:
            try await remote.trashItem(driveID: 7, fileID: 3)
            try await remote.deleteTrashedItem(driveID: 7, fileID: 3)
            let replacement = try await second.coordinator.createFile(parentID: 1, fileName: base.name, contents: other, lastModifiedAt: nil)
            resultID = replacement.id
            #expect(replacement.id != base.id && replacement.name == base.name)
            await remote.clearOperations()
            await #expect(throws: (any Error).self) { try await first.edit(local) }
            #expect(await remote.operations().isEmpty)
            #expect(try await remote.downloadFile(driveID: 7, fileID: replacement.id) == other)
            let files = try FileManager.default.contentsOfDirectory(at: first.directory.appendingPathComponent("staging"), includingPropertiesForKeys: nil)
            #expect(try files.map { try Data(contentsOf: $0) } == [local])
        case .repeatedMetadata:
            let applied = try await first.coordinator.moveItem(fileID: 3, baseMetadataVersion: base.metadataVersion, destinationParentID: 2, name: "Applied.txt")
            await remote.clearOperations()
            let replayed = try await second.coordinator.moveItem(fileID: 3, baseMetadataVersion: base.metadataVersion, destinationParentID: 2, name: "Applied.txt")
            #expect(replayed == applied && applied.id == base.id)
            #expect(await remote.operations().isEmpty)
        case .movedParent:
            let folder = try await remote.createDirectory(driveID: 7, parentID: 1, name: "Moving Parent")
            _ = try await second.coordinator.moveItem(fileID: folder.id, baseMetadataVersion: folder.metadataVersion, destinationParentID: 2, name: nil)
            let result = try await first.coordinator.createFile(parentID: folder.id, fileName: "Child.txt", contents: local, lastModifiedAt: nil)
            resultID = result.id
            #expect(result.parentID == folder.id)
            #expect(try await remote.downloadFile(driveID: 7, fileID: result.id) == local)
        case .removedParent:
            try await remote.trashItem(driveID: 7, fileID: 2)
            await #expect(throws: (any Error).self) { try await first.coordinator.createFile(parentID: 2, fileName: "Child.txt", contents: local, lastModifiedAt: nil) }
            let staged = try FileManager.default.contentsOfDirectory(at: first.directory.appendingPathComponent("staging"), includingPropertiesForKeys: nil)
            #expect(try staged.map { try Data(contentsOf: $0) } == [local])
        default:
            Issue.record("A vault case was routed through the plaintext engine")
        }
        // Independent persisted base must never silently advance on the other client.
        #expect(try first.base() == base && second.base() == base)
        let final = try await remote.item(driveID: 7, fileID: resultID)
        #expect(final.driveID == 7 && final.etag != nil)
        _ = try await remote.downloadFile(driveID: 7, fileID: resultID)
    }

    @Test(arguments: ConflictCase.callbackCases)
    func creationCallbackPolicyMatrix(_ scenario: ConflictCase) async throws {
        switch scenario {
        case .mayAlreadyExistFile:
            try await CreationCallbackTests().reconciliationHintPreservesExistingBytesAndReplaysFileIdentity(mayAlreadyExist: true)
        case .mayAlreadyExistDirectory:
            try await CreationCallbackTests().repeatedDirectoryHintRetainsTheDocumentedReconciliationLimitation()
        default: Issue.record("Unexpected create callback catalog entry")
        }
    }

    @Test(arguments: ConflictCase.vaultCases)
    func vaultPolicyMatrix(_ scenario: ConflictCase) async throws {
        switch scenario {
        case .vaultContent: try VaultJournalTests().concurrentContentEditsConvergeForEveryReplayOrder()
        case .vaultMetadata: try VaultConflictReplayTests().competingMetadataUsesCanonicalWinnerInEveryPermutation()
        case .vaultCycle: try VaultJournalTests().concurrentDirectoryMovesCannotCreateAParentCycle()
        case .vaultDeleteChild: try VaultJournalTests().staleDeleteLosesToEditAndFolderDeleteLosesToChild()
        case .vaultTrashProvenance: try VaultJournalTests().restoringFolderPreservesIndependentlyTrashedDescendant()
        case .vaultNameAllocation: try VaultJournalTests().siblingConflictAllocatorSkipsExistingGeneratedName()
        case .vaultStalePurge: try VaultConflictReplayTests().stalePurgePreservesEditedIdentity()
        case .vaultHistoricalRestore: try await VaultProvisioningTests().restoringVersionPublishesFreshRevisionAndRejectsABAStaleWrite()
        case .vaultOmittedHistory: try await VaultProvisioningTests().returningDeviceRejectsOmittedRemoteJournalObject()
        case .vaultOfflineReference: try await VaultProvisioningTests().maintenanceNeverDeletesCiphertextThatAnOfflineDeviceMayReference()
        default: Issue.record("A plaintext case was routed through the vault engine")
        }
    }

    @Test(arguments: [ConflictTestRemote.Fault.offline, .status(401), .status(403), .status(429), .status(507), .cancelled])
    func interruptedEditCanBeRecoveredAfterRestart(_ fault: ConflictTestRemote.Fault) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let remote = try ConflictTestRemote(directory: directory.appendingPathComponent("server"))
        let client = ConflictTestClient(directory: directory.appendingPathComponent("client"), remote: remote)
        try client.cache(await remote.item(driveID: 7, fileID: 3))
        let local = Data("retained change".utf8)
        await remote.inject(fault)
        await #expect(throws: (any Error).self) { try await client.edit(local) }
        let files = try FileManager.default.contentsOfDirectory(at: client.directory.appendingPathComponent("staging"), includingPropertiesForKeys: nil)
        #expect(try files.map { try Data(contentsOf: $0) } == [local])
        #expect(await remote.operations().isEmpty)
        let restarted = ConflictTestClient(directory: client.directory, remote: remote)
        let result = try await restarted.edit(local).item
        #expect(result.id == 3)
        #expect(try await remote.downloadFile(driveID: 7, fileID: 3) == local)
    }
}
