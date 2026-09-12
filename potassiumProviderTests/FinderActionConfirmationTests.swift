#if os(macOS) && STABILITY
import Testing
@testable import potassiumProvider

struct FinderActionConfirmationTests {
    @Test(arguments: FinderActionConfirmation.allCases)
    func exactPromptAndRecoveryMessageBindOneDialog(_ action: FinderActionConfirmation) {
        let dialog = FinderActionConfirmationObservation(texts: [action.prompt + " " + action.message],
            enabledButtonTitles: ["Cancel", action.buttonTitle])
        #expect(action.uniqueMatchIndex(in: [dialog]) == 0)
        #expect(action.uniqueMatchIndex(in: [dialog, dialog]) == nil)
    }

    @Test(arguments: FinderActionConfirmation.allCases)
    func underlyingFormOrIncompleteConfirmationCannotAuthorize(_ action: FinderActionConfirmation) {
        for texts in [[], [action.prompt], [action.message], ["Confirm another operation"]] {
            let dialog = FinderActionConfirmationObservation(texts: texts,
                enabledButtonTitles: ["Cancel", action.buttonTitle])
            #expect(action.uniqueMatchIndex(in: [dialog]) == nil)
        }
        for buttons in [["Cancel"], [action.buttonTitle], ["Cancel", action.buttonTitle, action.buttonTitle]] {
            let dialog = FinderActionConfirmationObservation(texts: [action.prompt, action.message],
                enabledButtonTitles: buttons)
            #expect(action.uniqueMatchIndex(in: [dialog]) == nil)
        }
    }

    @Test func aDifferentActionCannotMatch() {
        let restore = FinderActionConfirmation.restoreVersion
        let dialog = FinderActionConfirmationObservation(texts: [restore.prompt, restore.message],
            enabledButtonTitles: ["Cancel", restore.buttonTitle])
        #expect(FinderActionConfirmation.disableShareLink.uniqueMatchIndex(in: [dialog]) == nil)
    }

    @Test func onlyTheCompletedActionResultCanConfirmAnUncertainPress() {
        #expect(FinderActionConfirmation.disableShareLink.hasSuccessfulResult(in: ["Disabled share link."]))
        #expect(!FinderActionConfirmation.disableShareLink.hasSuccessfulResult(in: ["Disable Link", "Could not disable share link."]))
        let restore = FinderActionConfirmation.restoreVersion
        #expect(restore.hasSuccessfulResult(in: ["Restored synthetic copy.txt as a new copy."]))
        for text in ["Restore as Copy", "The current file will not be overwritten.",
                     "Restored  as a new copy.", "Could not restore synthetic copy.txt.", "Disabled share link."] {
            #expect(!restore.hasSuccessfulResult(in: [text]))
        }
    }
}
#endif
