#if os(macOS) && STABILITY
import Foundation

@MainActor
enum FinderHydrationSequence {
    /// Finish inspecting the generated document before releasing its presenter.
    /// The following Finder eviction must not inherit an open TextEdit document.
    static func execute(using ui: any FinderDocumentUIDriving, url: URL,
                        verifyDownloadedBytes: () async throws -> Void) async throws {
        try await ui.edit(url, contents: nil)
        try await verifyDownloadedBytes()
        try await ui.closeOwnedEditorDocuments()
    }
}
#endif
