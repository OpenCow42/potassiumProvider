#if os(macOS) && STABILITY
import Foundation
import Testing
@testable import potassiumProvider

@MainActor
struct FinderDeletionDialogTests {
    private let selected = URL(filePath: "/synthetic/.Trash/fixture 12.34.56.txt")

    @Test(arguments: ["fixture 12.34.56", "fixture 12.34.56.txt", "café ‘draft’"])
    func usesTheObservedDisplayNameWithoutGuessingAnExtension(_ displayName: String) {
        let expected = FinderDeletionDialogExpectation(selectedURL: selected, displayName: displayName)
        let dialog = observation(name: displayName)
        #expect(expected.uniqueMatchIndex(selection: selected, dialogs: [dialog]) == 0)
    }

    @Test func hiddenExtensionIsNotMatchedAgainstTheURLFilename() {
        let displayed = "fixture 12.34.56"
        let dialog = observation(name: displayed)
        let wrong = FinderDeletionDialogExpectation(selectedURL: selected, displayName: selected.lastPathComponent)
        #expect(wrong.uniqueMatchIndex(selection: selected, dialogs: [dialog]) == nil)
    }

    @Test func changedSelectionOrEmptyDisplayNameCannotAuthorizeDeletion() {
        let expected = FinderDeletionDialogExpectation(selectedURL: selected, displayName: "fixture")
        #expect(expected.uniqueMatchIndex(selection: selected.deletingLastPathComponent().appendingPathComponent("other.txt"),
            dialogs: [observation(name: "fixture")]) == nil)
        #expect(FinderDeletionDialogExpectation(selectedURL: selected, displayName: "")
            .uniqueMatchIndex(selection: selected, dialogs: [observation(name: "")]) == nil)
    }

    @Test(arguments: ["other fixture", "fixture copy", "fixture.txt", "fixture and another item"])
    func anotherQuotedNameCannotMatchBySubstring(_ name: String) {
        let expected = FinderDeletionDialogExpectation(selectedURL: selected, displayName: "fixture")
        #expect(expected.uniqueMatchIndex(selection: selected, dialogs: [observation(name: name)]) == nil)
    }

    @Test func onlyOneExactScopedDialogCanBeConfirmed() {
        let expected = FinderDeletionDialogExpectation(selectedURL: selected, displayName: "fixture")
        let matching = observation(name: "fixture"), unrelated = observation(name: "another")
        #expect(expected.uniqueMatchIndex(selection: selected, dialogs: [unrelated, matching]) == 1)
        #expect(expected.uniqueMatchIndex(selection: selected, dialogs: [matching, matching]) == nil)
        #expect(expected.uniqueMatchIndex(selection: selected, dialogs: []) == nil)
        for buttons in [["Delete"], ["Cancel", "Empty Trash"], ["Cancel", "Delete", "Delete"]] {
            let missingControl = FinderDeletionDialogObservation(texts: matching.texts, buttonTitles: buttons)
            #expect(expected.uniqueMatchIndex(selection: selected, dialogs: [missingControl]) == nil)
        }
    }

    private func observation(name: String) -> FinderDeletionDialogObservation {
        FinderDeletionDialogObservation(texts: ["Are you sure you want to delete “\(name)”? This item will be deleted immediately. You can’t undo this action."],
            buttonTitles: ["Delete", "Cancel"])
    }
}
#endif
