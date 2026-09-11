#if os(macOS) && STABILITY
import Testing
@testable import potassiumProvider

struct FinderPointerTargetTests {
    @Test(arguments: [1, 2])
    func exactScopeAndItsDescendantReceiveInput(hit: Int) throws {
        try FinderPointerTarget.verify(processIdentifier: 42, scope: 2, hitTest: { hit },
            owner: { _ in 42 }, parent: { $0 == 1 ? 2 : nil }, equal: ==)
    }

    @Test func anotherAppIsRejectedWithoutInspectingItsUI() {
        #expect(throws: FinderUIError.pointerTargetObstructed) {
            try FinderPointerTarget.verify(processIdentifier: 42, scope: 2, hitTest: { 1 },
                owner: { _ in 43 }, parent: { _ in Issue.record("Other apps must not be traversed"); return nil }, equal: ==)
        }
        #expect(FinderUIError.pointerTargetObstructed.isEnvironmental)
        #expect(!FinderUIError.controlUnavailable.isEnvironmental)
    }

    @Test func anotherFinderWindowAndMissingHitCannotAuthorizeAClick() {
        for hit in [nil, 3] as [Int?] {
            #expect(throws: FinderUIError.pointerTargetObstructed) {
                try FinderPointerTarget.verify(processIdentifier: 42, scope: 2, hitTest: { hit },
                    owner: { _ in 42 }, parent: { _ in nil }, equal: ==)
            }
        }
    }

    @Test func cyclicOrCrossProcessAncestryFailsClosed() {
        var visits = 0
        #expect(throws: FinderUIError.pointerTargetObstructed) {
            try FinderPointerTarget.verify(processIdentifier: 42, scope: 2, hitTest: { 1 },
                owner: { _ in 42 }, parent: { value in visits += 1; return value }, equal: ==)
        }
        #expect(visits == 32)
        #expect(throws: FinderUIError.pointerTargetObstructed) {
            try FinderPointerTarget.verify(processIdentifier: 42, scope: 2, hitTest: { 1 },
                owner: { $0 == 1 ? 42 : 43 }, parent: { _ in 2 }, equal: ==)
        }
    }
}
#endif
