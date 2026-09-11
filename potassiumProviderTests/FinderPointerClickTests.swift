#if os(macOS) && STABILITY
import CoreGraphics
import PotassiumProviderCore
import Testing
@testable import potassiumProvider

@MainActor
struct FinderPointerClickTests {
    @Test(arguments: [CGMouseButton.left, .right])
    func movesBeforeRevalidationAndUsesOneUnmodifiedClick(_ button: CGMouseButton) async throws {
        var events: [CGEvent] = [], observations: [Int] = []
        let point = CGPoint(x: 20, y: 30)
        let clicked = try await FinderPointerClick.perform(at: point, button: button,
            mayClick: { observations.append(events.count); return true },
            canPostEvents: { true }, post: { events.append($0) }, settle: {})
        #expect(clicked)
        #expect(observations == [0, 1])
        #expect(events.map(\.type) == [.mouseMoved, button == .right ? .rightMouseDown : .leftMouseDown,
                                     button == .right ? .rightMouseUp : .leftMouseUp])
        #expect(events.allSatisfy { $0.flags.isEmpty && $0.location == point })
        #expect(events.dropFirst().allSatisfy { $0.getIntegerValueField(.mouseEventClickState) == 1 })
    }

    @Test func deniedInputPermissionCannotPostEventsOrAskForConsent() async {
        await #expect(throws: FinderUIError.permissionRequired) {
            _ = try await FinderPointerClick.perform(at: .zero, button: .right,
                mayClick: { Issue.record("Target lookup is unnecessary when posting is denied"); return true },
                canPostEvents: { false }, post: { _ in Issue.record("Denied event was posted") },
                settle: { Issue.record("Denied event must fail immediately") })
        }
    }

    @Test func completedTransferOrChangedTargetAfterHoverPreventsButtonDown() async throws {
        var events: [CGEventType] = []
        let clicked = try await FinderPointerClick.perform(at: .zero, button: .left,
            mayClick: { events.isEmpty }, canPostEvents: { true }, post: { events.append($0.type) }, settle: {})
        #expect(!clicked)
        #expect(events == [.mouseMoved])
    }

    @Test(arguments: [(600, 90), (20, 20), (0, 0), (-1, 0)])
    func transferBudgetDoesNotExtendOrdinaryUIWait(seconds: Int, expected: Int) {
        let now = ContinuousClock.now
        let deadline = FinderUIObservationDeadline.make(remaining: .seconds(seconds), now: now)
        #expect(deadline.remaining(now: now) == .seconds(expected))
        #expect(deadline.remaining(now: now.advanced(by: .seconds(91))) == .zero)
    }

    @Test func cancellationAlwaysReleasesAnAlreadyPressedButton() async {
        var events: [CGEventType] = []
        await #expect(throws: CancellationError.self) {
            _ = try await FinderPointerClick.perform(at: .zero, button: .right,
                mayClick: { true }, canPostEvents: { true }, post: { events.append($0.type) },
                settle: { if events.contains(.rightMouseDown) { throw CancellationError() } })
        }
        #expect(events == [.mouseMoved, .rightMouseDown, .rightMouseUp])
    }
}
#endif
