#if os(macOS) && STABILITY
struct FinderActionConfirmationObservation {
    let texts: [String]
    let enabledButtonTitles: [String]
}

/// Matches only a leaf confirmation sheet inside the already bound action panel.
enum FinderActionConfirmation: CaseIterable {
    case disableShareLink, restoreVersion

    var buttonTitle: String {
        switch self {
        case .disableShareLink: "Disable Link"
        case .restoreVersion: "Restore as Copy"
        }
    }

    var prompt: String {
        switch self {
        case .disableShareLink: "Disable this share link?"
        case .restoreVersion: "Restore this version as a new copy?"
        }
    }

    var message: String {
        switch self {
        case .disableShareLink: "Anyone using the current URL will lose access."
        case .restoreVersion: "The current file will not be overwritten."
        }
    }

    func uniqueMatchIndex(in dialogs: [FinderActionConfirmationObservation]) -> Int? {
        let matches = dialogs.indices.filter { index in
            let dialog = dialogs[index]
            let text = dialog.texts.joined(separator: " ")
            return dialog.enabledButtonTitles.sorted() == ["Cancel", buttonTitle].sorted() &&
                text.contains(prompt) && text.contains(message)
        }
        return matches.count == 1 ? matches.first : nil
    }

    func hasSuccessfulResult(in texts: [String]) -> Bool {
        switch self {
        case .disableShareLink:
            texts.contains("Disabled share link.")
        case .restoreVersion:
            texts.contains {
                $0.hasPrefix("Restored ") && $0.hasSuffix(" as a new copy.") &&
                    $0.count > "Restored  as a new copy.".count
            }
        }
    }
}
#endif
