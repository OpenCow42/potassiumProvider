import Foundation
import Testing
import PotassiumProviderCore

@Suite(.serialized)
struct KDriveMutationCoordinatorTests {
    @Test func fileCreateUploadsWithVersionConflictStrategy() async throws {
        let createdItem = makeItem(id: 101, name: "New.txt")
        let remote = RecordingKDriveFileProvider(uploadResult: createdItem)
        let coordinator = makeCoordinator(remote: remote)
        let contents = Data("new file".utf8)
        let lastModifiedAt = Date(timeIntervalSince1970: 500)

        let result = try await coordinator.createFile(
            parentID: Self.parentID,
            fileName: "New.txt",
            contents: contents,
            lastModifiedAt: lastModifiedAt
        )

        #expect(result == createdItem)
        #expect(await remote.calls() == [
            .uploadFile(
                driveID: Self.driveID,
                parentID: Self.parentID,
                fileName: "New.txt",
                contents: contents,
                lastModifiedAt: lastModifiedAt,
                conflictStrategy: .version
            )
        ])
    }

    @Test func directoryCreateCallsCreateDirectory() async throws {
        let createdFolder = makeItem(id: 102, name: "Folder", type: "dir", mimeType: nil)
        let remote = RecordingKDriveFileProvider(directoryResult: createdFolder)
        let coordinator = makeCoordinator(remote: remote)

        let result = try await coordinator.createDirectory(parentID: Self.parentID, name: "Folder")

        #expect(result == createdFolder)
        #expect(await remote.calls() == [
            .createDirectory(driveID: Self.driveID, parentID: Self.parentID, name: "Folder")
        ])
    }

    @Test func matchingContentVersionReplacesFileWithoutConflictCopy() async throws {
        let latestItem = makeItem(id: Self.fileID, name: "Report.txt")
        let replacedItem = makeItem(
            id: Self.fileID,
            name: "Report.txt",
            modifiedAt: Date(timeIntervalSince1970: 250),
            updatedAt: Date(timeIntervalSince1970: 350)
        )
        let remote = RecordingKDriveFileProvider(
            itemResults: [Self.fileID: [latestItem]],
            replaceResult: replacedItem
        )
        let stager = RecordingConflictStager(directoryURL: temporaryDirectory())
        let coordinator = makeCoordinator(remote: remote, stager: stager)
        let contents = Data("changed".utf8)
        let lastModifiedAt = Date(timeIntervalSince1970: 600)

        let result = try await coordinator.replaceContents(
            itemIdentifier: "\(Self.fileID)",
            fileID: Self.fileID,
            localFilename: "Report.txt",
            baseContentVersion: latestItem.contentVersion,
            contents: contents,
            lastModifiedAt: lastModifiedAt
        )

        #expect(result == .replaced(replacedItem))
        #expect(await stager.stagedURLs().isEmpty)
        #expect(await remote.calls() == [
            .item(driveID: Self.driveID, fileID: Self.fileID),
            .replaceFile(
                driveID: Self.driveID,
                fileID: Self.fileID,
                contents: contents,
                lastModifiedAt: lastModifiedAt
            )
        ])
    }

    @Test func staleContentVersionUploadsRenamedConflictCopyAndRemovesStagedBytes() async throws {
        let localBaseItem = makeItem(id: Self.fileID, name: "Report.pdf")
        let latestItem = makeItem(
            id: Self.fileID,
            name: "Report.pdf",
            parentID: 900,
            modifiedAt: Date(timeIntervalSince1970: 260),
            updatedAt: Date(timeIntervalSince1970: 360),
            mimeType: "application/pdf"
        )
        let conflictItem = makeItem(
            id: 303,
            name: "Report (conflict - Mac-One.Two - 1970-01-01 00.00.00).pdf",
            parentID: latestItem.parentID,
            modifiedAt: Date(timeIntervalSince1970: 610),
            updatedAt: Date(timeIntervalSince1970: 611),
            mimeType: "application/pdf"
        )
        let remote = RecordingKDriveFileProvider(
            itemResults: [Self.fileID: [latestItem]],
            uploadResult: conflictItem
        )
        let stager = RecordingConflictStager(directoryURL: temporaryDirectory())
        let observer = RecordingContentConflictObserver()
        let coordinator = makeCoordinator(remote: remote, stager: stager, observer: observer)
        let contents = Data("local stale edit".utf8)
        let lastModifiedAt = Date(timeIntervalSince1970: 600)

        let result = try await coordinator.replaceContents(
            itemIdentifier: "\(Self.fileID)",
            fileID: Self.fileID,
            localFilename: "Report.pdf",
            baseContentVersion: localBaseItem.contentVersion,
            contents: contents,
            lastModifiedAt: lastModifiedAt
        )

        #expect(result == .conflictCopy(conflictItem))
        #expect(await remote.calls() == [
            .item(driveID: Self.driveID, fileID: Self.fileID),
            .uploadFile(
                driveID: Self.driveID,
                parentID: latestItem.parentID,
                fileName: "Report (conflict - Mac-One.Two - 1970-01-01 00.00.00).pdf",
                contents: contents,
                lastModifiedAt: lastModifiedAt,
                conflictStrategy: .rename
            )
        ])

        let stagedURLs = await stager.stagedURLs()
        let stagedURL = try #require(stagedURLs.first)
        #expect(await stager.removedURLs() == [stagedURL])
        #expect(!FileManager.default.fileExists(atPath: stagedURL.path))

        let events = await observer.events()
        #expect(events.count == 2)
        guard let firstEvent = events.first,
              case .started(let startedContext) = firstEvent else {
            Issue.record("Expected a started conflict event")
            return
        }
        #expect(startedContext.localItemIdentifier == "\(Self.fileID)")
        #expect(startedContext.localFilename == "Report.pdf")
        #expect(startedContext.latestItem == latestItem)
        guard let lastEvent = events.last,
              case .resolved(let resolvedContext, let resolvedConflictItem, _) = lastEvent else {
            Issue.record("Expected a resolved conflict event")
            return
        }
        #expect(resolvedContext.id == startedContext.id)
        #expect(resolvedConflictItem == conflictItem)
    }

    @Test func failedConflictUploadLeavesStagedBytesAndPropagatesError() async throws {
        let localBaseItem = makeItem(id: Self.fileID, name: "Report.txt")
        let latestItem = makeItem(
            id: Self.fileID,
            name: "Report.txt",
            modifiedAt: Date(timeIntervalSince1970: 260),
            updatedAt: Date(timeIntervalSince1970: 360)
        )
        let remote = RecordingKDriveFileProvider(
            itemResults: [Self.fileID: [latestItem]],
            uploadError: .uploadFailed
        )
        let stager = RecordingConflictStager(directoryURL: temporaryDirectory())
        let observer = RecordingContentConflictObserver()
        let coordinator = makeCoordinator(remote: remote, stager: stager, observer: observer)
        let contents = Data("local stale edit".utf8)

        do {
            _ = try await coordinator.replaceContents(
                itemIdentifier: "\(Self.fileID)",
                fileID: Self.fileID,
                localFilename: "Report.txt",
                baseContentVersion: localBaseItem.contentVersion,
                contents: contents,
                lastModifiedAt: nil
            )
            Issue.record("Expected conflict upload failure")
        } catch RecordingKDriveError.uploadFailed {
            #expect(true)
        }

        let stagedURL = try #require(await stager.stagedURLs().first)
        #expect(FileManager.default.fileExists(atPath: stagedURL.path))
        #expect(await stager.removedURLs().isEmpty)

        let events = await observer.events()
        #expect(events.count == 2)
        guard let lastEvent = events.last,
              case .failed(let failedContext, _) = lastEvent else {
            Issue.record("Expected a failed conflict event")
            return
        }
        #expect(failedContext.stagedURL == stagedURL)
    }

    @Test func matchingRenameCallsRenameAndRefetchesItem() async throws {
        let latestItem = makeItem(id: Self.fileID, name: "Old.txt")
        let renamedItem = makeItem(
            id: Self.fileID,
            name: "New.txt",
            updatedAt: Date(timeIntervalSince1970: 350)
        )
        let remote = RecordingKDriveFileProvider(itemResults: [Self.fileID: [latestItem, renamedItem]])
        let coordinator = makeCoordinator(remote: remote)

        let result = try await coordinator.renameItem(
            fileID: Self.fileID,
            baseMetadataVersion: latestItem.metadataVersion,
            name: "New.txt"
        )

        #expect(result == renamedItem)
        #expect(await remote.calls() == [
            .item(driveID: Self.driveID, fileID: Self.fileID),
            .renameItem(driveID: Self.driveID, fileID: Self.fileID, name: "New.txt"),
            .item(driveID: Self.driveID, fileID: Self.fileID)
        ])
    }

    @Test func updatedAtOnlyRenameDriftStillRenames() async throws {
        let baseItem = makeItem(id: Self.fileID, name: "Old.txt")
        let driftedItem = makeItem(
            id: Self.fileID,
            name: "Old.txt",
            updatedAt: Date(timeIntervalSince1970: 350)
        )
        let renamedItem = makeItem(
            id: Self.fileID,
            name: "New.txt",
            updatedAt: Date(timeIntervalSince1970: 360)
        )
        let remote = RecordingKDriveFileProvider(itemResults: [Self.fileID: [driftedItem, renamedItem]])
        let coordinator = makeCoordinator(remote: remote)

        let result = try await coordinator.renameItem(
            fileID: Self.fileID,
            baseMetadataVersion: baseItem.metadataVersion,
            name: "New.txt"
        )

        #expect(result == renamedItem)
        #expect(await remote.calls() == [
            .item(driveID: Self.driveID, fileID: Self.fileID),
            .renameItem(driveID: Self.driveID, fileID: Self.fileID, name: "New.txt"),
            .item(driveID: Self.driveID, fileID: Self.fileID)
        ])
    }

    @Test func alreadyRenamedItemReturnsLatestWithoutDuplicateRename() async throws {
        let baseItem = makeItem(id: Self.fileID, name: "Old.txt")
        let alreadyRenamedItem = makeItem(
            id: Self.fileID,
            name: "New.txt",
            updatedAt: Date(timeIntervalSince1970: 350)
        )
        let remote = RecordingKDriveFileProvider(itemResults: [Self.fileID: [alreadyRenamedItem]])
        let coordinator = makeCoordinator(remote: remote)

        let result = try await coordinator.renameItem(
            fileID: Self.fileID,
            baseMetadataVersion: baseItem.metadataVersion,
            name: "New.txt"
        )

        #expect(result == alreadyRenamedItem)
        #expect(await remote.calls() == [
            .item(driveID: Self.driveID, fileID: Self.fileID)
        ])
    }

    @Test func staleRenameThrowsStaleVersionAndDoesNotRename() async throws {
        let baseItem = makeItem(id: Self.fileID, name: "Old.txt")
        let latestItem = makeItem(
            id: Self.fileID,
            name: "Remote.txt",
            updatedAt: Date(timeIntervalSince1970: 350)
        )
        let remote = RecordingKDriveFileProvider(itemResults: [Self.fileID: [latestItem]])
        let coordinator = makeCoordinator(remote: remote)

        let staleItem = try await expectStaleVersion {
            _ = try await coordinator.renameItem(
                fileID: Self.fileID,
                baseMetadataVersion: baseItem.metadataVersion,
                name: "New.txt"
            )
        }

        #expect(staleItem == latestItem)
        #expect(await remote.calls() == [
            .item(driveID: Self.driveID, fileID: Self.fileID)
        ])
    }

    @Test func matchingMovePassesOptionalNameAndRefetchesItem() async throws {
        let latestItem = makeItem(id: Self.fileID, name: "Old.txt")
        let movedItem = makeItem(
            id: Self.fileID,
            name: "Moved.txt",
            parentID: 901,
            updatedAt: Date(timeIntervalSince1970: 350)
        )
        let remote = RecordingKDriveFileProvider(itemResults: [Self.fileID: [latestItem, movedItem]])
        let coordinator = makeCoordinator(remote: remote)

        let result = try await coordinator.moveItem(
            fileID: Self.fileID,
            baseMetadataVersion: latestItem.metadataVersion,
            destinationParentID: 901,
            name: "Moved.txt"
        )

        #expect(result == movedItem)
        #expect(await remote.calls() == [
            .item(driveID: Self.driveID, fileID: Self.fileID),
            .moveItem(
                driveID: Self.driveID,
                fileID: Self.fileID,
                destinationParentID: 901,
                name: "Moved.txt"
            ),
            .item(driveID: Self.driveID, fileID: Self.fileID)
        ])
    }

    @Test func updatedAtOnlyMoveDriftStillMoves() async throws {
        let baseItem = makeItem(id: Self.fileID, name: "Old.txt")
        let driftedItem = makeItem(
            id: Self.fileID,
            name: "Old.txt",
            updatedAt: Date(timeIntervalSince1970: 350)
        )
        let movedItem = makeItem(
            id: Self.fileID,
            name: "Old.txt",
            parentID: 901,
            updatedAt: Date(timeIntervalSince1970: 360)
        )
        let remote = RecordingKDriveFileProvider(itemResults: [Self.fileID: [driftedItem, movedItem]])
        let coordinator = makeCoordinator(remote: remote)

        let result = try await coordinator.moveItem(
            fileID: Self.fileID,
            baseMetadataVersion: baseItem.metadataVersion,
            destinationParentID: 901,
            name: nil
        )

        #expect(result == movedItem)
        #expect(await remote.calls() == [
            .item(driveID: Self.driveID, fileID: Self.fileID),
            .moveItem(
                driveID: Self.driveID,
                fileID: Self.fileID,
                destinationParentID: 901,
                name: nil
            ),
            .item(driveID: Self.driveID, fileID: Self.fileID)
        ])
    }

    @Test func alreadyMovedItemReturnsLatestWithoutDuplicateMove() async throws {
        let baseItem = makeItem(id: Self.fileID, name: "Old.txt")
        let alreadyMovedItem = makeItem(
            id: Self.fileID,
            name: "Old.txt",
            parentID: 901,
            updatedAt: Date(timeIntervalSince1970: 350)
        )
        let remote = RecordingKDriveFileProvider(itemResults: [Self.fileID: [alreadyMovedItem]])
        let coordinator = makeCoordinator(remote: remote)

        let result = try await coordinator.moveItem(
            fileID: Self.fileID,
            baseMetadataVersion: baseItem.metadataVersion,
            destinationParentID: 901,
            name: nil
        )

        #expect(result == alreadyMovedItem)
        #expect(await remote.calls() == [
            .item(driveID: Self.driveID, fileID: Self.fileID)
        ])
    }

    @Test func alreadyMovedAndRenamedItemReturnsLatestWithoutDuplicateMove() async throws {
        let baseItem = makeItem(id: Self.fileID, name: "Old.txt")
        let alreadyMovedItem = makeItem(
            id: Self.fileID,
            name: "Moved.txt",
            parentID: 901,
            updatedAt: Date(timeIntervalSince1970: 350)
        )
        let remote = RecordingKDriveFileProvider(itemResults: [Self.fileID: [alreadyMovedItem]])
        let coordinator = makeCoordinator(remote: remote)

        let result = try await coordinator.moveItem(
            fileID: Self.fileID,
            baseMetadataVersion: baseItem.metadataVersion,
            destinationParentID: 901,
            name: "Moved.txt"
        )

        #expect(result == alreadyMovedItem)
        #expect(await remote.calls() == [
            .item(driveID: Self.driveID, fileID: Self.fileID)
        ])
    }

    @Test func movedToDestinationWithUnexpectedNameStillBlocksCombinedMoveRename() async throws {
        let baseItem = makeItem(id: Self.fileID, name: "Old.txt")
        let latestItem = makeItem(
            id: Self.fileID,
            name: "Remote.txt",
            parentID: 901,
            updatedAt: Date(timeIntervalSince1970: 350)
        )
        let remote = RecordingKDriveFileProvider(itemResults: [Self.fileID: [latestItem]])
        let coordinator = makeCoordinator(remote: remote)

        let staleItem = try await expectStaleVersion {
            _ = try await coordinator.moveItem(
                fileID: Self.fileID,
                baseMetadataVersion: baseItem.metadataVersion,
                destinationParentID: 901,
                name: "Moved.txt"
            )
        }

        #expect(staleItem == latestItem)
        #expect(await remote.calls() == [
            .item(driveID: Self.driveID, fileID: Self.fileID)
        ])
    }

    @Test func albumBatchMoveAllowsFolderTimestampDriftFromChildUploads() async throws {
        let oldParentID = 5
        let musicFolderID = 55
        let baseA = makeItem(id: 17, name: "A", parentID: oldParentID, updatedAt: Date(timeIntervalSince1970: 100), type: "dir", mimeType: nil)
        let baseB = makeItem(id: 24, name: "B", parentID: oldParentID, updatedAt: Date(timeIntervalSince1970: 100), type: "dir", mimeType: nil)
        let baseC = makeItem(id: 39, name: "C", parentID: oldParentID, updatedAt: Date(timeIntervalSince1970: 100), type: "dir", mimeType: nil)
        let movedA = makeItem(id: 17, name: "A", parentID: musicFolderID, updatedAt: Date(timeIntervalSince1970: 300), type: "dir", mimeType: nil)
        let movedB = makeItem(id: 24, name: "B", parentID: musicFolderID, updatedAt: Date(timeIntervalSince1970: 300), type: "dir", mimeType: nil)
        let movedC = makeItem(id: 39, name: "C", parentID: musicFolderID, updatedAt: Date(timeIntervalSince1970: 300), type: "dir", mimeType: nil)
        let remote = RecordingKDriveFileProvider(itemResults: [
            17: [
                makeItem(id: 17, name: "A", parentID: oldParentID, updatedAt: Date(timeIntervalSince1970: 200), type: "dir", mimeType: nil),
                movedA
            ],
            24: [
                makeItem(id: 24, name: "B", parentID: oldParentID, updatedAt: Date(timeIntervalSince1970: 200), type: "dir", mimeType: nil),
                movedB
            ],
            39: [
                makeItem(id: 39, name: "C", parentID: oldParentID, updatedAt: Date(timeIntervalSince1970: 200), type: "dir", mimeType: nil),
                movedC
            ]
        ])
        let coordinator = makeCoordinator(remote: remote)

        let resultA = try await coordinator.moveItem(
            fileID: 17,
            baseMetadataVersion: baseA.metadataVersion,
            destinationParentID: musicFolderID,
            name: nil
        )
        let resultB = try await coordinator.moveItem(
            fileID: 24,
            baseMetadataVersion: baseB.metadataVersion,
            destinationParentID: musicFolderID,
            name: nil
        )
        let resultC = try await coordinator.moveItem(
            fileID: 39,
            baseMetadataVersion: baseC.metadataVersion,
            destinationParentID: musicFolderID,
            name: nil
        )

        #expect([resultA, resultB, resultC] == [movedA, movedB, movedC])
        #expect(await remote.calls() == [
            .item(driveID: Self.driveID, fileID: 17),
            .moveItem(driveID: Self.driveID, fileID: 17, destinationParentID: musicFolderID, name: nil),
            .item(driveID: Self.driveID, fileID: 17),
            .item(driveID: Self.driveID, fileID: 24),
            .moveItem(driveID: Self.driveID, fileID: 24, destinationParentID: musicFolderID, name: nil),
            .item(driveID: Self.driveID, fileID: 24),
            .item(driveID: Self.driveID, fileID: 39),
            .moveItem(driveID: Self.driveID, fileID: 39, destinationParentID: musicFolderID, name: nil),
            .item(driveID: Self.driveID, fileID: 39)
        ])
    }

    @Test func staleMoveThrowsStaleVersionAndDoesNotMove() async throws {
        let baseItem = makeItem(id: Self.fileID, name: "Old.txt")
        let latestItem = makeItem(
            id: Self.fileID,
            name: "Remote.txt",
            parentID: 902,
            updatedAt: Date(timeIntervalSince1970: 350)
        )
        let remote = RecordingKDriveFileProvider(itemResults: [Self.fileID: [latestItem]])
        let coordinator = makeCoordinator(remote: remote)

        let staleItem = try await expectStaleVersion {
            _ = try await coordinator.moveItem(
                fileID: Self.fileID,
                baseMetadataVersion: baseItem.metadataVersion,
                destinationParentID: 901,
                name: nil
            )
        }

        #expect(staleItem == latestItem)
        #expect(await remote.calls() == [
            .item(driveID: Self.driveID, fileID: Self.fileID)
        ])
    }

    @Test func matchingTrashCallsTrashItem() async throws {
        let latestItem = makeItem(id: Self.fileID, name: "Report.txt")
        let remote = RecordingKDriveFileProvider(itemResults: [Self.fileID: [latestItem]])
        let coordinator = makeCoordinator(remote: remote)

        let result = try await coordinator.trashItem(
            fileID: Self.fileID,
            baseVersion: baseVersion(for: latestItem)
        )

        #expect(result == latestItem)
        #expect(await remote.calls() == [
            .item(driveID: Self.driveID, fileID: Self.fileID),
            .trashItem(driveID: Self.driveID, fileID: Self.fileID)
        ])
    }

    @Test func updatedAtOnlyTrashDriftStillTrashes() async throws {
        let baseItem = makeItem(id: Self.fileID, name: "Report.txt")
        let driftedItem = makeItem(
            id: Self.fileID,
            name: "Report.txt",
            updatedAt: Date(timeIntervalSince1970: 350)
        )
        let remote = RecordingKDriveFileProvider(itemResults: [Self.fileID: [driftedItem]])
        let coordinator = makeCoordinator(remote: remote)

        let result = try await coordinator.trashItem(fileID: Self.fileID, baseVersion: baseVersion(for: baseItem))

        #expect(result == driftedItem)
        #expect(await remote.calls() == [
            .item(driveID: Self.driveID, fileID: Self.fileID),
            .trashItem(driveID: Self.driveID, fileID: Self.fileID)
        ])
    }

    @Test func staleTrashThrowsStaleVersionAndDoesNotTrash() async throws {
        let baseItem = makeItem(id: Self.fileID, name: "Report.txt")
        let latestItem = makeItem(
            id: Self.fileID,
            name: "Remote.txt",
            modifiedAt: Date(timeIntervalSince1970: 260),
            updatedAt: Date(timeIntervalSince1970: 360)
        )
        let remote = RecordingKDriveFileProvider(itemResults: [Self.fileID: [latestItem]])
        let coordinator = makeCoordinator(remote: remote)

        let staleItem = try await expectStaleVersion {
            _ = try await coordinator.trashItem(fileID: Self.fileID, baseVersion: baseVersion(for: baseItem))
        }

        #expect(staleItem == latestItem)
        #expect(await remote.calls() == [
            .item(driveID: Self.driveID, fileID: Self.fileID)
        ])
    }

    @Test func matchingPermanentDeleteCallsDeleteTrashedItem() async throws {
        let latestItem = makeItem(id: Self.fileID, name: "Report.txt")
        let remote = RecordingKDriveFileProvider(itemResults: [Self.fileID: [latestItem]])
        let coordinator = makeCoordinator(remote: remote)

        let result = try await coordinator.deleteTrashedItem(
            fileID: Self.fileID,
            baseVersion: baseVersion(for: latestItem)
        )

        #expect(result == latestItem)
        #expect(await remote.calls() == [
            .item(driveID: Self.driveID, fileID: Self.fileID),
            .deleteTrashedItem(driveID: Self.driveID, fileID: Self.fileID)
        ])
    }

    @Test func updatedAtOnlyPermanentDeleteDriftStillDeletes() async throws {
        let baseItem = makeItem(id: Self.fileID, name: "Report.txt")
        let driftedItem = makeItem(
            id: Self.fileID,
            name: "Report.txt",
            updatedAt: Date(timeIntervalSince1970: 350)
        )
        let remote = RecordingKDriveFileProvider(itemResults: [Self.fileID: [driftedItem]])
        let coordinator = makeCoordinator(remote: remote)

        let result = try await coordinator.deleteTrashedItem(fileID: Self.fileID, baseVersion: baseVersion(for: baseItem))

        #expect(result == driftedItem)
        #expect(await remote.calls() == [
            .item(driveID: Self.driveID, fileID: Self.fileID),
            .deleteTrashedItem(driveID: Self.driveID, fileID: Self.fileID)
        ])
    }

    @Test func stalePermanentDeleteThrowsStaleVersionAndDoesNotDelete() async throws {
        let baseItem = makeItem(id: Self.fileID, name: "Report.txt")
        let latestItem = makeItem(
            id: Self.fileID,
            name: "Remote.txt",
            modifiedAt: Date(timeIntervalSince1970: 260),
            updatedAt: Date(timeIntervalSince1970: 360)
        )
        let remote = RecordingKDriveFileProvider(itemResults: [Self.fileID: [latestItem]])
        let coordinator = makeCoordinator(remote: remote)

        let staleItem = try await expectStaleVersion {
            _ = try await coordinator.deleteTrashedItem(fileID: Self.fileID, baseVersion: baseVersion(for: baseItem))
        }

        #expect(staleItem == latestItem)
        #expect(await remote.calls() == [
            .item(driveID: Self.driveID, fileID: Self.fileID)
        ])
    }

    private static let driveID = 42
    private static let parentID = 100
    private static let fileID = 200

    private static var configuration: ProviderDomainConfiguration {
        ProviderDomainConfiguration(
            domainIdentifier: "domain-1",
            displayName: "Work Drive",
            driveID: driveID,
            driveName: "kDrive",
            rootFileID: parentID,
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 1)
        )
    }

    private func makeCoordinator(
        remote: RecordingKDriveFileProvider,
        stager: any KDriveConflictContentStaging = UnexpectedConflictStager(),
        observer: RecordingContentConflictObserver? = nil
    ) -> KDriveMutationCoordinator {
        let observerHandler: KDriveMutationCoordinator.ContentConflictObserver? = observer.map { observer in
            { event in await observer.record(event) }
        }

        return KDriveMutationCoordinator(
            configuration: Self.configuration,
            remote: remote,
            conflictStager: stager,
            conflictDeviceName: { "Mac/One:Two" },
            conflictDate: { Date(timeIntervalSince1970: 0) },
            conflictTimeZone: { TimeZone(secondsFromGMT: 0)! },
            contentConflictObserver: observerHandler
        )
    }

    private func makeItem(
        id: Int,
        name: String,
        parentID: Int = parentID,
        modifiedAt: Date = Date(timeIntervalSince1970: 200),
        updatedAt: Date = Date(timeIntervalSince1970: 300),
        type: String? = "file",
        mimeType: String? = "text/plain"
    ) -> KDriveRemoteItem {
        KDriveRemoteItem(
            id: id,
            name: name,
            type: type,
            status: "ok",
            driveID: Self.driveID,
            parentID: parentID,
            path: "/\(name)",
            size: type == "dir" ? nil : 12,
            mimeType: mimeType,
            createdAt: Date(timeIntervalSince1970: 100),
            modifiedAt: modifiedAt,
            updatedAt: updatedAt
        )
    }

    private func baseVersion(for item: KDriveRemoteItem) -> KDriveItemBaseVersion {
        KDriveItemBaseVersion(contentVersion: item.contentVersion, metadataVersion: item.metadataVersion)
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("kdrive-mutation-coordinator-tests-\(UUID().uuidString)", isDirectory: true)
    }

    private func expectStaleVersion<T>(_ operation: () async throws -> T) async throws -> KDriveRemoteItem {
        do {
            _ = try await operation()
        } catch let error as KDriveMutationConflictError {
            switch error {
            case .staleVersion(let latestItem):
                return latestItem
            }
        }

        Issue.record("Expected KDriveMutationConflictError.staleVersion")
        throw RecordingKDriveError.expectedStaleVersion
    }
}

private enum RecordingKDriveCall: Equatable, Sendable {
    case item(driveID: Int, fileID: Int)
    case uploadFile(
        driveID: Int,
        parentID: Int,
        fileName: String,
        contents: Data,
        lastModifiedAt: Date?,
        conflictStrategy: KDriveUploadConflictStrategy
    )
    case replaceFile(driveID: Int, fileID: Int, contents: Data, lastModifiedAt: Date?)
    case createDirectory(driveID: Int, parentID: Int, name: String)
    case renameItem(driveID: Int, fileID: Int, name: String)
    case moveItem(driveID: Int, fileID: Int, destinationParentID: Int, name: String?)
    case trashItem(driveID: Int, fileID: Int)
    case deleteTrashedItem(driveID: Int, fileID: Int)
}

private enum RecordingKDriveError: Error, Equatable, Sendable {
    case expectedStaleVersion
    case missingItemResult(Int)
    case missingUploadResult
    case missingReplaceResult
    case missingDirectoryResult
    case uploadFailed
    case unexpectedStaging
    case unimplemented
}

private actor RecordingKDriveFileProvider: KDriveFileProviding {
    private var itemResults: [Int: [KDriveRemoteItem]]
    private let uploadResult: KDriveRemoteItem?
    private let uploadError: RecordingKDriveError?
    private let replaceResult: KDriveRemoteItem?
    private let directoryResult: KDriveRemoteItem?
    private var recordedCalls: [RecordingKDriveCall] = []

    init(
        itemResults: [Int: [KDriveRemoteItem]] = [:],
        uploadResult: KDriveRemoteItem? = nil,
        uploadError: RecordingKDriveError? = nil,
        replaceResult: KDriveRemoteItem? = nil,
        directoryResult: KDriveRemoteItem? = nil
    ) {
        self.itemResults = itemResults
        self.uploadResult = uploadResult
        self.uploadError = uploadError
        self.replaceResult = replaceResult
        self.directoryResult = directoryResult
    }

    func calls() -> [RecordingKDriveCall] {
        recordedCalls
    }

    func listDrives() async throws -> [KDriveDriveSummary] {
        throw RecordingKDriveError.unimplemented
    }

    func item(driveID: Int, fileID: Int) async throws -> KDriveRemoteItem {
        recordedCalls.append(.item(driveID: driveID, fileID: fileID))
        guard var results = itemResults[fileID], results.isEmpty == false else {
            throw RecordingKDriveError.missingItemResult(fileID)
        }
        let result = results.removeFirst()
        itemResults[fileID] = results
        return result
    }

    func listDirectory(driveID: Int, folderID: Int, cursor: String?, limit: Int) async throws -> KDriveItemPage {
        throw RecordingKDriveError.unimplemented
    }

    func listAdvancedDirectory(driveID: Int, folderID: Int, cursor: String?, limit: Int) async throws -> KDriveAdvancedItemPage {
        throw RecordingKDriveError.unimplemented
    }

    func listTrash(driveID: Int, cursor: String?, limit: Int) async throws -> KDriveItemPage {
        throw RecordingKDriveError.unimplemented
    }

    func downloadFile(driveID: Int, fileID: Int) async throws -> Data {
        throw RecordingKDriveError.unimplemented
    }

    func thumbnail(driveID: Int, fileID: Int, width: Int?, height: Int?) async throws -> Data {
        throw RecordingKDriveError.unimplemented
    }

    func uploadFile(
        driveID: Int,
        parentID: Int,
        fileName: String,
        contents: Data,
        lastModifiedAt: Date?,
        conflictStrategy: KDriveUploadConflictStrategy
    ) async throws -> KDriveRemoteItem {
        recordedCalls.append(.uploadFile(
            driveID: driveID,
            parentID: parentID,
            fileName: fileName,
            contents: contents,
            lastModifiedAt: lastModifiedAt,
            conflictStrategy: conflictStrategy
        ))
        if let uploadError {
            throw uploadError
        }
        guard let uploadResult else {
            throw RecordingKDriveError.missingUploadResult
        }
        return uploadResult
    }

    func replaceFile(driveID: Int, fileID: Int, contents: Data, lastModifiedAt: Date?) async throws -> KDriveRemoteItem {
        recordedCalls.append(.replaceFile(
            driveID: driveID,
            fileID: fileID,
            contents: contents,
            lastModifiedAt: lastModifiedAt
        ))
        guard let replaceResult else {
            throw RecordingKDriveError.missingReplaceResult
        }
        return replaceResult
    }

    func createDirectory(driveID: Int, parentID: Int, name: String) async throws -> KDriveRemoteItem {
        recordedCalls.append(.createDirectory(driveID: driveID, parentID: parentID, name: name))
        guard let directoryResult else {
            throw RecordingKDriveError.missingDirectoryResult
        }
        return directoryResult
    }

    func renameItem(driveID: Int, fileID: Int, name: String) async throws {
        recordedCalls.append(.renameItem(driveID: driveID, fileID: fileID, name: name))
    }

    func moveItem(driveID: Int, fileID: Int, destinationParentID: Int, name: String?) async throws {
        recordedCalls.append(.moveItem(
            driveID: driveID,
            fileID: fileID,
            destinationParentID: destinationParentID,
            name: name
        ))
    }

    func trashItem(driveID: Int, fileID: Int) async throws {
        recordedCalls.append(.trashItem(driveID: driveID, fileID: fileID))
    }

    func deleteTrashedItem(driveID: Int, fileID: Int) async throws {
        recordedCalls.append(.deleteTrashedItem(driveID: driveID, fileID: fileID))
    }
}

private actor RecordingConflictStager: KDriveConflictContentStaging {
    private let directoryURL: URL
    private var staged: [URL] = []
    private var removed: [URL] = []

    init(directoryURL: URL) {
        self.directoryURL = directoryURL
    }

    func stageConflictContents(_ contents: Data, itemIdentifier: String) async throws -> URL {
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let url = directoryURL.appendingPathComponent("\(itemIdentifier)-staged.upload")
        try contents.write(to: url, options: [.atomic])
        staged.append(url)
        return url
    }

    func removeStagedConflictContents(at url: URL) async {
        removed.append(url)
        try? FileManager.default.removeItem(at: url)
    }

    func stagedURLs() -> [URL] {
        staged
    }

    func removedURLs() -> [URL] {
        removed
    }
}

private struct UnexpectedConflictStager: KDriveConflictContentStaging {
    func stageConflictContents(_ contents: Data, itemIdentifier: String) async throws -> URL {
        throw RecordingKDriveError.unexpectedStaging
    }

    func removeStagedConflictContents(at url: URL) async {}
}

private actor RecordingContentConflictObserver {
    private var recordedEvents: [KDriveStaleContentConflictEvent] = []

    func record(_ event: KDriveStaleContentConflictEvent) {
        recordedEvents.append(event)
    }

    func events() -> [KDriveStaleContentConflictEvent] {
        recordedEvents
    }
}
