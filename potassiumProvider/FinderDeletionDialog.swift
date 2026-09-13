#if os(macOS) && STABILITY
import Foundation
import PotassiumProviderCore

struct FinderDeletionDialogObservation {
    let texts: [String]
    let buttonTitles: [String]
}

/// Display text identifies a dialog only after the caller has bound the exact
/// provider item and selected URL. Never derive display names by stripping an
/// extension: Finder can hide it or give a trashed item a different local name.
struct FinderDeletionDialogExpectation {
    let selectedURL: URL
    let displayName: String

    func uniqueMatchIndex(selection: URL, dialogs: [FinderDeletionDialogObservation]) -> Int? {
        guard !displayName.isEmpty, FinderUIURLIdentity.matches(selection, selectedURL) else { return nil }
        let prompt = "Are you sure you want to delete “\(displayName)”?"
        let matches = dialogs.indices.filter { index in
            let dialog = dialogs[index]
            guard dialog.buttonTitles.sorted() == ["Cancel", "Delete"] else { return false }
            // Require the entire quoted name, not a substring of another item.
            return dialog.texts.contains {
                $0 == prompt || $0.hasPrefix(prompt + "\n") || $0.hasPrefix(prompt + " ")
            }
        }
        return matches.count == 1 ? matches.first : nil
    }
}
#endif
