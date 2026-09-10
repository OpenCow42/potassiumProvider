#if os(macOS) && STABILITY
import FileProvider
import Foundation
import Testing
@testable import potassiumProvider

@MainActor
struct FinderReplicatedRefreshTests {
    @Test func changedFoldersRequestOneWorkingSetEnumeration() async throws {
        let generated = NSFileProviderItemIdentifier("synthetic-folder")
        let batches: [[NSFileProviderItemIdentifier]] = [[.rootContainer], [generated], [.rootContainer, generated, generated], [.workingSet]]
        for batch in batches {
            var requested: [NSFileProviderItemIdentifier] = []
            try await FinderReplicatedRefresh.signal(changedContainers: batch) { requested.append($0) }
            #expect(requested == [.workingSet])
        }
    }

    @Test func emptyBatchDoesNotWakeTheProvider() async throws {
        var requests = 0
        try await FinderReplicatedRefresh.signal(changedContainers: []) { _ in requests += 1 }
        #expect(requests == 0)
    }

    @Test func failedSignalRemainsAFailure() async throws {
        await #expect(throws: URLError.self) {
            try await FinderReplicatedRefresh.signal(changedContainers: [.rootContainer]) { _ in
                throw URLError(.cannotConnectToHost)
            }
        }
    }
}
#endif
