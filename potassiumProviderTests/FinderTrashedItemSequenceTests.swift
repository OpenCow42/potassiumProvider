#if os(macOS) && STABILITY
import Testing
@testable import potassiumProvider

@MainActor
struct FinderTrashedItemSequenceTests {
    @Test func targetIsReboundAfterNavigationBeforeAction() async throws {
        var state = "bound-before-navigation"
        try await FinderTrashedItemSequence.execute(reveal: {
            state = "navigation-complete"
        }, revalidate: {
            #expect(state == "navigation-complete")
            state = "fresh-binding"
        }, action: {
            #expect(state == "fresh-binding")
            state = "action-invoked"
        })
        #expect(state == "action-invoked")
    }

    @Test func identityReplacementDuringNavigationPreventsAction() async {
        var currentIdentity = 42
        var invoked = false
        await #expect(throws: FinderLiveError.unsafeTarget) {
            try await FinderTrashedItemSequence.execute(reveal: { currentIdentity = 43 },
                revalidate: {
                    guard currentIdentity == 42 else { throw FinderLiveError.unsafeTarget }
                }, action: { invoked = true })
        }
        #expect(!invoked)
    }

    @Test func unavailableParentCannotProceedToBindingOrAction() async {
        var rebound = false, invoked = false
        await #expect(throws: FinderUIError.windowMismatch) {
            try await FinderTrashedItemSequence.execute(reveal: { throw FinderUIError.windowMismatch },
                revalidate: { rebound = true }, action: { invoked = true })
        }
        #expect(!rebound && !invoked)
    }
}
#endif
