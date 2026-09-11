#if STABILITY
import Foundation
import Testing
@testable import PotassiumProviderCore

@MainActor
struct StabilityActionPanelIdentityTests {
    @Test func mainActorCallerDoesNotRunDiskLookupOnTheUIThread() async throws {
        let alias = UUID()
        let result = try await StabilityActionPanelIdentity.resolve(for: "42") { identifier in
            #expect(!Thread.isMainThread)
            #expect(identifier == "42")
            return alias
        }
        #expect(result == alias)
    }

    @Test func missingActiveRunDoesNotInventAnAlias() async throws {
        #expect(try await StabilityActionPanelIdentity.resolve(for: "42", lookup: { _ in nil }) == nil)
    }

    @Test func blockedLookupExpiresWithoutWaitingForTheDiskReply() async {
        // Hold the synchronous lookup until the waiter has actually expired.
        // Relative sleeps raced under the full parallel CI test load.
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        await #expect(throws: StabilityDeadlineError.expired) {
            try await StabilityActionPanelIdentity.resolve(for: "42", timeout: .milliseconds(10)) { _ in
                release.wait()
                return UUID()
            }
        }
    }

    @Test func cancelledRequestDoesNotStartDiskLookup() async {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await StabilityActionPanelIdentity.resolve(for: "42") { _ in
                Issue.record("Cancelled lookup must not access the shared store")
                return UUID()
            }
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }
}
#endif
