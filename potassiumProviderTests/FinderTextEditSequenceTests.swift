#if os(macOS) && STABILITY
import Testing
@testable import potassiumProvider

@MainActor
@Suite("Native TextEdit command sequencing")
struct FinderTextEditSequenceTests {
    @Test func lostPasteCannotReachSave() async {
        var commands: [FinderTextEditAction] = []
        var checkedSave = false
        await #expect(throws: FinderUIError.selectionMismatch) {
            try await FinderTextEditSequence.execute(menu: { commands.append($0) }, verifyText: {
                throw FinderUIError.selectionMismatch
            }, verifySave: { checkedSave = true })
        }
        #expect(commands == [.selectAll, .paste])
        #expect(!checkedSave)
    }

    @Test func rejectedSelectionCannotPasteIntoAnotherDocument() async {
        var commands: [FinderTextEditAction] = []
        await #expect(throws: FinderUIError.windowMismatch) {
            try await FinderTextEditSequence.execute(menu: {
                commands.append($0)
                throw FinderUIError.windowMismatch
            }, verifyText: { Issue.record("Text verification must not follow rejected selection") },
               verifySave: { Issue.record("Save must not follow rejected selection") })
        }
        #expect(commands == [.selectAll])
    }

    @Test(arguments: [false, true])
    func completionRequiresSaveAcknowledgement(saveFails: Bool) async throws {
        var commands: [FinderTextEditAction] = []
        var textVerified = false, completed = false
        do {
            try await FinderTextEditSequence.execute(menu: {
                if $0 == .save { #expect(textVerified) }
                commands.append($0)
            }, verifyText: { textVerified = true }, verifySave: {
                if saveFails { throw FinderUIError.timedOut }
            })
            completed = true
        } catch FinderUIError.timedOut { #expect(saveFails) }
        #expect(completed == !saveFails)
        #expect(commands == [.selectAll, .paste, .save])
    }
}
#endif
