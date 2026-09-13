#if os(macOS) && STABILITY
import Testing
@testable import potassiumProvider

struct FinderCopyCancellationTargetTests {
    @Test func copyPreparationBindsBothExactQuotedNames() {
        #expect(FinderCopyCancellationTarget.matches(sourceName: "transfer.dat", destinationName: "probe-unique",
            labels: ["Preparing to copy “transfer.dat”", "Preparing to copy to “probe-unique”"]))
    }

    @Test(arguments: [
        ["Preparing to copy “other.dat”", "Preparing to copy to “probe-unique”"],
        ["Preparing to copy “transfer.dat”", "Preparing to copy to “other-probe”"],
        ["Preparing to copy “transfer.dat.backup”", "Preparing to copy to “probe-unique”"],
        ["Preparing to copy “transfer.dat”", "Preparing to copy to “probe-unique-other”"],
        ["Copying files"], []
    ])
    func unrelatedOrIncompleteProgressIsNeverATarget(_ labels: [String]) {
        #expect(!FinderCopyCancellationTarget.matches(sourceName: "transfer.dat", destinationName: "probe-unique", labels: labels))
    }
}
#endif
