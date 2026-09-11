#if os(macOS) && STABILITY
import Foundation
import PotassiumProviderCore

@MainActor
enum FinderRestoreObservation {
    static func matchesVisibleDestination(_ url: URL, parent: URL, name: String) -> Bool {
        FinderUIURLIdentity.matches(url.deletingLastPathComponent(), parent) &&
            url.lastPathComponent.precomposedStringWithCanonicalMapping == name.precomposedStringWithCanonicalMapping
    }

    static func observeVisibleDestination(parent: URL, name: String,
                                          readVisible: () async throws -> URL) async throws -> URL? {
        try await observeVisibleDestination(name: name, readVisible: readVisible) {
            FinderUIURLIdentity.matches($0, parent)
        }
    }

    static func observeVisibleDestination(name: String, readVisible: () async throws -> URL,
                                          matchesParent: (URL) async throws -> Bool) async throws -> URL? {
        let candidate: URL
        do { candidate = try await readVisible() }
        catch {
            recordLookupFailure(error, phase: "resolveItemURL")
            throw error
        }
        guard candidate.lastPathComponent.precomposedStringWithCanonicalMapping == name.precomposedStringWithCanonicalMapping else { return nil }
        let parentMatches: Bool
        do { parentMatches = try await matchesParent(candidate.deletingLastPathComponent()) }
        catch {
            recordLookupFailure(error, phase: "bindDestinationParent")
            throw error
        }
        guard parentMatches else { return nil }
        return candidate
    }

    private static func recordLookupFailure(_ error: any Error, phase: String) {
        // Closed call-site labels and numeric codes only: a lookup error can
        // carry the local URL in its description or user-info.
        print("finder stability: destination lookup failed; phase=\(phase) class=\(ProviderDiagnosticErrorClassifier.classify(error).rawValue) code=\((error as NSError).code)")
    }

    /// A completed UI-originated callback gates verification. Active-item 404
    /// while restoration becomes visible is pending, never positive evidence.
    static func observe(callbackCompleted: Bool, expected: KDriveRemoteItem,
                        readActive: () async throws -> KDriveRemoteItem) async throws -> KDriveRemoteItem? {
        guard callbackCompleted else { return nil }
        do {
            let current = try await readActive()
            guard current.id == expected.id, current.driveID == expected.driveID,
                  current.parentID == expected.parentID else { throw FinderLiveError.unsafeTarget }
            return current
        } catch where KDriveRemoteErrorClassifier.isNotFound(error) {
            return nil
        }
    }
}
#endif
