#if os(macOS) && STABILITY
import Foundation
import Testing
@testable import potassiumProvider

@MainActor
struct StabilityActionRegistrationTests {
    let identifier = "test.provider.Actions"
    let expected = URL(fileURLWithPath: "/tmp/Chosen App.app/Contents/PlugIns/Actions.appex")
    func line(path: String) -> String { "    test.provider.Actions(1.0)\t00000000-0000-0000-0000-000000000001\t2026-09-11 10:00:00 +0000\t" + path }

    @Test func exactUniqueRegistrationPasses() throws {
        try StabilityActionRegistration.validate(listing: line(path: expected.path) + "\n (1 plug-in)\n", identifier: identifier, expectedURL: expected)
    }

    @Test func duplicatesWrongPathsAndMalformedDiscoveryFailClosed() {
        let correct = line(path: expected.path)
        for listing in ["", " (0 plug-ins)", line(path: "/Applications/Older.app/Contents/PlugIns/Actions.appex"),
                        correct + "\n" + line(path: "/Applications/Older.app/Contents/PlugIns/Actions.appex"),
                        correct + "\n" + correct, "test.provider.Actions(1.0) " + expected.path,
                        correct.replacingOccurrences(of: identifier, with: "different.provider.Actions")] {
            #expect(throws: StabilityActionRegistrationError.self) {
                try StabilityActionRegistration.validate(listing: listing, identifier: identifier, expectedURL: expected)
            }
        }
    }
}
#endif
