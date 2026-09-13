#if os(macOS) && STABILITY
import Foundation

/// Logical menu actions deliberately have no physical keyboard key codes.
enum FinderTextEditAction: Equatable {
    case selectAll, paste, save
    var menuTitle: String { self == .save ? "File" : "Edit" }
    var itemTitle: String {
        switch self { case .selectAll: "Select All"; case .paste: "Paste"; case .save: "Save" }
    }
}

@MainActor
enum FinderTextEditSequence {
    static func execute(menu: (FinderTextEditAction) async throws -> Void,
                        verifyText: () async throws -> Void,
                        verifySave: () async throws -> Void) async throws {
        try await menu(.selectAll)
        try await menu(.paste)
        // A lost focus or ignored paste must never cause Save to succeed with
        // the original bytes and be treated as a completed edit.
        try await verifyText()
        try await menu(.save)
        try await verifySave()
    }
}
#endif
