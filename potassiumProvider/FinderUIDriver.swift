#if os(macOS) && STABILITY
import AppKit
import ApplicationServices
import ScreenCaptureKit
import Darwin
import PotassiumProviderCore

@MainActor
protocol FinderUINavigating: AnyObject {
    func navigate(to url: URL) async throws
    func navigateHistory(back: Bool, expectedURL: URL) async throws
    func navigateParent(expectedURL: URL) async throws
}

@MainActor
protocol FinderUIDriving: FinderUINavigating {
    var actionCount: Int { get }
    func useDeadline(_ remaining: @escaping @MainActor () -> Duration)
    func expectActionPanel(for alias: UUID)
    func closeOwnedWindows() async throws
    func select(_ url: URL) async throws
    func contains(_ url: URL) async throws -> Bool
    func createFolder(named name: String, in parent: URL) async throws
    func copy(_ source: URL, to parent: URL) async throws
    func rename(_ source: URL, to name: String) async throws
    func move(_ source: URL, to parent: URL) async throws
    func contextAction(_ title: String, on url: URL) async throws
    func hasContextAction(_ title: String, on url: URL) async throws -> Bool
    func trash(_ url: URL) async throws
    func edit(_ url: URL, contents: String?) async throws
    func cancelDownload(_ url: URL) async throws
    func confirmPermanentDeletion(_ url: URL, fixtureAlias: UUID) async throws
    func panelAction(_ action: FinderPanelAction) async throws
    func capture(in directory: URL, sequence: Int) async throws
}

enum FinderPanelAction {
    case inheritAccess, createLink, toggleComments, saveLink, disableLink, confirmDisableLink, done
    case restoreVersion(Int), confirmRestore, confirmSystemDeletion
}

enum FinderUIError: String, Error, Equatable {
    case finderUnavailable, permissionRequired, windowMismatch, selectionMismatch
    case controlUnavailable, timedOut, operatorCancelled, screenshotUnavailable
    case editorUnavailable, automationFailed, finderBusy, evictionResourceBusy
}

private enum FinderAppleEventOperation: String {
    case observe, navigate, createWindow, changeView, activate, select
}

/// Owns a dedicated Finder window. Apple Events address its stable window ID;
/// Accessibility actions resolve fresh elements and never reuse row indices.
@MainActor
final class SystemFinderUIDriver: FinderUIDriving {
    private(set) var actionCount = 0
    private var windowID: Int32?
    private var currentURL: URL?
    private var selectionURL: URL?
    private var windowOwner: FinderWindowOwnership?
    private var menuIsOpen = false
    private var windowsBeforeAction: [AXUIElement] = []
    private var windowBeforeAction: AXUIElement?
    private var awaitingEvictionResult = false
    private var remainingTime: @MainActor () -> Duration = { .seconds(90) }
    private var actionPanelIdentifier: String?
    private var selectedDeletionRequested = false
    private var lastRowObservation: String?
    private var ownedEditorDocuments: [URL: FinderProcessIdentity] = [:]

    func useDeadline(_ remaining: @escaping @MainActor () -> Duration) { remainingTime = remaining }
    func expectActionPanel(for alias: UUID) { actionPanelIdentifier = "provider.stability.action." + alias.uuidString }

    func closeOwnedWindows() async throws {
        let deadline = StabilityDeadline(budget: .seconds(90))
        remainingTime = { deadline.remaining() }
        var failure: Error?
        do { try await closeOwnedEditorDocuments() } catch { failure = error }
        do { try await closeOwnedFinderWindows() } catch { failure = failure ?? error }
        if let failure { throw failure }
    }

    private func closeOwnedEditorDocuments() async throws {
        for (url, owner) in ownedEditorDocuments {
            guard processIdentity(pid: owner.pid) == owner,
                  let editor = NSRunningApplication(processIdentifier: owner.pid),
                  editor.bundleIdentifier == "com.apple.TextEdit" else {
                ownedEditorDocuments[url] = nil; continue
            }
            guard let document = editorDocument(url, editor: editor) else {
                ownedEditorDocuments[url] = nil; continue
            }
            _ = AXUIElementPerformAction(document, kAXRaiseAction as CFString)
            editor.activate()
            try await wait { NSWorkspace.shared.frontmostApplication?.processIdentifier == editor.processIdentifier }
            if let close = attribute(document, kAXCloseButtonAttribute), CFGetTypeID(close) == AXUIElementGetTypeID(),
               (attribute(close as! AXUIElement, kAXEditedAttribute) as? Bool) == true {
                // Preserve the generated document's current bytes on failure;
                // never dismiss a save prompt by discarding or quitting TextEdit.
                try await editorMenu("File", item: "Save", documentURL: url, editor: editor)
                try await wait {
                    guard let fresh = self.editorDocument(url, editor: editor),
                          let button = self.attribute(fresh, kAXCloseButtonAttribute), CFGetTypeID(button) == AXUIElementGetTypeID() else { return false }
                    return (self.attribute(button as! AXUIElement, kAXEditedAttribute) as? Bool) == false
                }
            }
            guard let fresh = editorDocument(url, editor: editor),
                  let button = attribute(fresh, kAXCloseButtonAttribute), CFGetTypeID(button) == AXUIElementGetTypeID(),
                  AXUIElementPerformAction(button as! AXUIElement, kAXPressAction as CFString) == .success else { throw FinderUIError.editorUnavailable }
            try await wait { self.editorDocument(url, editor: editor) == nil }
            ownedEditorDocuments[url] = nil
        }
    }

    private func closeOwnedFinderWindows() async throws {
        let cleanupDeadline = StabilityDeadline(budget: .seconds(90))
        remainingTime = { cleanupDeadline.remaining() }
        guard let ownership = windowOwner else { return }
        guard ownership.process == finderProcessIdentity() else {
            windowID = nil; windowOwner = nil; currentURL = nil; selectionURL = nil; menuIsOpen = false
            return
        }
        if menuIsOpen { try await dismissContextMenu(allowMissingWindow: true) }
        try ownership.close(currentProcess: finderProcessIdentity()) { identifier in
            // A manually closed window is already clean. Never close by title,
            // front-window position, or a window from a relaunched Finder.
            _ = try script("if exists Finder window id \(identifier) then close Finder window id \(identifier)")
        }
        windowID = nil
        windowOwner = nil
        currentURL = nil
        selectionURL = nil
    }

    private func finderProcessIdentity() -> FinderProcessIdentity? {
        guard let finder = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first else { return nil }
        return processIdentity(pid: finder.processIdentifier)
    }

    private func processIdentity(pid: Int32) -> FinderProcessIdentity? {
        // The kernel start time distinguishes PID reuse, even when
        // LaunchServices omits the application's launch date.
        var info = proc_bsdinfo()
        let size = MemoryLayout<proc_bsdinfo>.stride
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(size)) == size else { return nil }
        let launchedAt = Date(timeIntervalSince1970: Double(info.pbi_start_tvsec) + Double(info.pbi_start_tvusec) / 1_000_000)
        return FinderProcessIdentity(pid: pid, launchedAt: launchedAt)
    }

    func navigate(to url: URL) async throws {
        if windowID != nil {
            try await navigateWithGoToFolder(url)
        } else {
            guard let owner = finderProcessIdentity() else { throw FinderUIError.finderUnavailable }
            windowID = try script("set w to make new Finder window to (POSIX file \(quote(url.path)) as alias)\nreturn id of w", operation: .createWindow).int32Value
            if let windowID { windowOwner = FinderWindowOwnership(windowID: windowID, process: owner) }
        }
        if let windowID { _ = try script("set current view of Finder window id \(windowID) to list view", operation: .changeView) }
        currentURL = url
        selectionURL = nil
        try await wait { try self.verifyWindow(url) }
        actionCount += 1
    }

    private func navigateWithGoToFolder(_ url: URL) async throws {
        // Finder can acknowledge an Apple Event target change while its list
        // remains busy indefinitely. Exercise Finder's normal navigation sheet
        // and verify the original window identity after the UI accepts the path.
        try await activateFinder()
        guard let window = finderWindowAX() else { throw FinderUIError.windowMismatch }
        try key(5, flags: [.maskCommand, .maskShift]) // Go to Folder
        var field: AXUIElement?
        try await wait {
            let sheets = self.elements(window).filter { self.string($0, kAXRoleAttribute) == kAXSheetRole }
            guard sheets.count == 1, let sheet = sheets.first else { return false }
            let fields = self.elements(sheet).filter { self.string($0, kAXRoleAttribute) == kAXTextFieldRole }
            guard fields.count == 1, let candidate = fields.first else { return false }
            field = candidate
            return true
        }
        guard let field, AXUIElementSetAttributeValue(field, kAXValueAttribute as CFString, url.path as CFString) == .success else {
            throw FinderUIError.controlUnavailable
        }
        try await wait { self.string(field, kAXValueAttribute) == url.path }
        try key(36)
        try await wait { try self.verifyWindow(url) }
        print("finder stability UI: Go to Folder navigation verified")
    }

    func navigateHistory(back: Bool, expectedURL: URL) async throws {
        try await activateFinder()
        try key(back ? 33 : 30, flags: .maskCommand) // [ / ]
        try await wait { try self.verifyWindow(expectedURL) }
        currentURL = expectedURL
        selectionURL = nil
        actionCount += 1
    }

    func navigateParent(expectedURL: URL) async throws {
        try await activateFinder()
        try key(126, flags: .maskCommand)
        try await wait { try self.verifyWindow(expectedURL) }
        currentURL = expectedURL
        selectionURL = nil
        actionCount += 1
    }

    func select(_ url: URL) async throws {
        let parent = url.deletingLastPathComponent()
        if !FinderUIURLIdentity.matches(currentURL, parent) { try await navigate(to: parent) }
        selectionURL = nil
        lastRowObservation = nil
        try await activateFinder()
        try await FinderSelectionSequence.execute(waitUntilVisible: {
            print("finder stability UI: waiting for generated selection row")
            do { try await self.wait { try await self.contains(url) } }
            catch {
                // Use the last live observation; querying after the deadline
                // would fail its guard and fabricate an apparent binding loss.
                print("finder stability UI: last row observation \(self.lastRowObservation ?? "unavailable")")
                throw error
            }
        }, assignSelection: {
            guard let windowID = self.windowID, try self.verifyWindow(parent),
                  try self.script("get id of front Finder window").int32Value == windowID else {
                throw FinderUIError.windowMismatch
            }
            // `select file` can reveal it in another Finder window. Assign the
            // selection of the already verified front window without revealing.
            print("finder stability UI: generated row visible; assigning selection")
            _ = try self.script("set selection to {POSIX file \(self.quote(url.path)) as alias}", operation: .select)
            self.selectionURL = url
        }, waitUntilSelected: {
            try await self.wait { try self.verifySelection(url) }
        })
        actionCount += 1
    }

    func contains(_ url: URL) async throws -> Bool {
        guard let windowID else { throw FinderUIError.windowMismatch }
        guard try verifyWindow(url.deletingLastPathComponent()) else { return false }
        guard let window = finderWindowAX() else { throw FinderUIError.windowMismatch }
        guard let displayedName = try displayedName(of: url) else { return false }
        let nodes = elements(window)
        let names = nodes.filter { string($0, kAXRoleAttribute) == kAXTextFieldRole }
            .compactMap { string($0, kAXValueAttribute) }
        let listView = try script("get current view of Finder window id \(windowID) is list view").booleanValue
        let matches = names.filter { $0 == displayedName }.count
        let namedElements = nodes.filter {
            [string($0, kAXValueAttribute), string($0, kAXTitleAttribute), string($0, kAXDescriptionAttribute)].contains(displayedName)
        }.count
        let observation = "windowBound=true parentMatches=true listView=\(listView) matchingTextRows=\(matches) matchingNamedElements=\(namedElements)"
        if lastRowObservation != observation {
            print("finder stability UI: row observation " + observation)
            lastRowObservation = observation
        }
        return FinderUINameObservation.hasUniqueMatch(displayedName: displayedName, rowNames: names)
    }

    func createFolder(named name: String, in parent: URL) async throws {
        try await navigate(to: parent)
        try await activateFinder()
        guard let windowID else { throw FinderUIError.windowMismatch }
        let before = try script("get URL of every item of target of Finder window id \(windowID)")
        let priorURLs = (1...max(1, before.numberOfItems)).compactMap { before.atIndex($0)?.stringValue.flatMap(URL.init(string:)) }
        try key(45, flags: [.maskCommand, .maskShift]) // N
        try await wait {
            let result = try self.script("set selectedItems to get selection\nif (count selectedItems) is not 1 then return {}\nreturn {URL of item 1 of selectedItems}")
            guard result.numberOfItems == 1, let text = result.atIndex(1)?.stringValue, let created = URL(string: text),
                  FinderUIURLIdentity.matches(created.deletingLastPathComponent(), parent),
                  !priorURLs.contains(where: { FinderUIURLIdentity.matches($0, created) }) else { return false }
            self.selectionURL = created
            return true
        }
        try await enterFinderName(name)
        try key(36)
        try await wait { try await self.contains(parent.appendingPathComponent(name)) }
        actionCount += 1
    }

    func copy(_ source: URL, to parent: URL) async throws {
        try await select(source)
        try await activateFinder()
        try key(8, flags: .maskCommand)
        try await navigate(to: parent)
        try await activateFinder()
        try key(9, flags: .maskCommand)
        try await wait { try await self.contains(parent.appendingPathComponent(source.lastPathComponent)) }
        actionCount += 1
    }

    func rename(_ source: URL, to name: String) async throws {
        try await select(source)
        try await activateFinder()
        try key(36)
        try await enterFinderName(name)
        try key(36)
        try await wait { try await self.contains(source.deletingLastPathComponent().appendingPathComponent(name)) }
        actionCount += 1
    }

    func move(_ source: URL, to parent: URL) async throws {
        try await select(source)
        try await activateFinder()
        try key(8, flags: .maskCommand)
        try await navigate(to: parent)
        try await activateFinder()
        try key(9, flags: [.maskCommand, .maskAlternate])
        try await wait { try await self.contains(parent.appendingPathComponent(source.lastPathComponent)) }
        actionCount += 1
    }

    func trash(_ url: URL) async throws {
        try await select(url)
        try await activateFinder()
        try key(51, flags: .maskCommand)
        try await wait { try await self.contains(url) == false }
        actionCount += 1
    }

    func contextAction(_ title: String, on url: URL) async throws {
        try await select(url)
        try await activateFinder()
        windowsBeforeAction = attribute(finderAX(), kAXWindowsAttribute) as? [AXUIElement] ?? []
        windowBeforeAction = finderWindowAX()
        awaitingEvictionResult = title == "Remove Download"
        selectedDeletionRequested = title == "Delete Immediately…"
        try await showSelectedContextMenu()
        do {
            try await wait {
                guard let menu = self.contextMenu(), let item = self.elements(menu).first(where: {
                    self.string($0, kAXRoleAttribute) == kAXMenuItemRole && self.string($0, kAXTitleAttribute) == title
                }) else { return false }
                guard (self.attribute(item, kAXEnabledAttribute) as? Bool) != false else { return false }
                let result = AXUIElementPerformAction(item, kAXPressAction as CFString)
                guard result == .success else {
                    print("finder stability UI: contextual press failed; AX code \(result.rawValue)")
                    throw FinderUIError.controlUnavailable
                }
                return true
            }
            print("finder stability UI: contextual command invoked")
            try await wait { self.contextMenu() == nil }
            if ["Share kDrive Link…", "Version History…"].contains(title) {
                try await wait { self.actionPanelScope() != nil }
            } else if selectedDeletionRequested {
                try await wait { self.selectedDeletionDialog() != nil }
            } else { try await waitForFinderIdle() }
            menuIsOpen = false
            actionCount += 1
        } catch {
            try? await dismissContextMenu()
            throw error
        }
    }

    func hasContextAction(_ title: String, on url: URL) async throws -> Bool {
        try await select(url)
        try await activateFinder()
        try await showSelectedContextMenu()
        do {
            try await wait { self.contextMenu() != nil }
            guard let menu = contextMenu() else { throw FinderUIError.controlUnavailable }
            let found = elements(menu).filter { string($0, kAXRoleAttribute) == kAXMenuItemRole && string($0, kAXTitleAttribute) == title }
            try await dismissContextMenu()
            actionCount += 1
            return found.count == 1
        } catch {
            try? await dismissContextMenu()
            throw error
        }
    }

    func edit(_ url: URL, contents: String?) async throws {
        try await select(url)
        _ = try script("open selection using application file id \"com.apple.TextEdit\"")
        print("finder stability UI: TextEdit open requested")
        try await wait {
            guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.TextEdit").first else { return false }
            let ax = AXUIElementCreateApplication(app.processIdentifier)
            return self.elements(ax).contains { FinderUIURLIdentity.matches(self.string($0, kAXDocumentAttribute).flatMap(URL.init(string:)), url) }
        }
        guard let editor = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.TextEdit").first else { throw FinderUIError.editorUnavailable }
        print("finder stability UI: TextEdit document located")
        let editorAX = AXUIElementCreateApplication(editor.processIdentifier)
        let documents = (attribute(editorAX, kAXWindowsAttribute) as? [AXUIElement] ?? []).filter {
            FinderUIURLIdentity.matches(string($0, kAXDocumentAttribute).flatMap(URL.init(string:)), url)
        }
        guard documents.count == 1, let document = documents.first,
              AXUIElementPerformAction(document, kAXRaiseAction as CFString) == .success else { throw FinderUIError.editorUnavailable }
        guard let owner = processIdentity(pid: editor.processIdentifier) else { throw FinderUIError.editorUnavailable }
        ownedEditorDocuments[url] = owner
        editor.activate()
        try await wait { NSWorkspace.shared.frontmostApplication?.processIdentifier == editor.processIdentifier }
        guard let focused = attribute(editorAX, kAXFocusedWindowAttribute), CFEqual(focused, document) else { throw FinderUIError.editorUnavailable }
        print("finder stability UI: TextEdit document focused")
        if let contents {
            let areas = elements(document).filter { string($0, kAXRoleAttribute) == kAXTextAreaRole }
            guard areas.count == 1, let textArea = areas.first,
                  AXUIElementSetAttributeValue(textArea, kAXFocusedAttribute as CFString, kCFBooleanTrue) == .success else {
                throw FinderUIError.editorUnavailable
            }
            // Native paste goes through TextEdit's editing/undo pipeline.
            // AppKit may ignore a synthetic event's overridden Unicode string.
            NSPasteboard.general.clearContents()
            guard NSPasteboard.general.setString(contents, forType: .string) else { throw FinderUIError.controlUnavailable }
            try await FinderTextEditSequence.execute { action in
                try await self.editorMenu(action.menuTitle, item: action.itemTitle, documentURL: url, editor: editor)
            } verifyText: {
                try await self.wait {
                    guard let fresh = self.editorDocument(url, editor: editor) else { return false }
                    return self.elements(fresh).contains { self.string($0, kAXRoleAttribute) == kAXTextAreaRole && self.string($0, kAXValueAttribute) == contents }
                }
                print("finder stability UI: TextEdit fixture text verified")
            } verifySave: {
                try await self.wait {
                    guard let fresh = self.editorDocument(url, editor: editor) else { return false }
                    guard let close = self.attribute(fresh, kAXCloseButtonAttribute), CFGetTypeID(close) == AXUIElementGetTypeID() else { return false }
                    // AppKit exposes the document's edited state on its close
                    // button; TextEdit does not expose AXEdited on the window.
                    return (self.attribute(close as! AXUIElement, kAXEditedAttribute) as? Bool) == false
                }
                print("finder stability UI: TextEdit save acknowledged")
            }
        }
        // Close only the verified document, releasing it before Remove Download.
        guard let freshDocument = editorDocument(url, editor: editor),
              let close = attribute(freshDocument, kAXCloseButtonAttribute), CFGetTypeID(close) == AXUIElementGetTypeID(),
              AXUIElementPerformAction(close as! AXUIElement, kAXPressAction as CFString) == .success else {
            throw FinderUIError.editorUnavailable
        }
        try await wait {
            !(self.attribute(editorAX, kAXWindowsAttribute) as? [AXUIElement] ?? []).contains {
                FinderUIURLIdentity.matches(self.string($0, kAXDocumentAttribute).flatMap(URL.init(string:)), url)
            }
        }
        ownedEditorDocuments[url] = nil
        actionCount += 1
    }

    private func editorDocument(_ url: URL, editor: NSRunningApplication) -> AXUIElement? {
        guard !editor.isTerminated else { return nil }
        let app = AXUIElementCreateApplication(editor.processIdentifier)
        let matches = (attribute(app, kAXWindowsAttribute) as? [AXUIElement] ?? []).filter {
            FinderUIURLIdentity.matches(string($0, kAXDocumentAttribute).flatMap(URL.init(string:)), url)
        }
        return matches.count == 1 ? matches.first : nil
    }

    private func editorMenu(_ menuTitle: String, item title: String, documentURL: URL, editor: NSRunningApplication) async throws {
        let app = AXUIElementCreateApplication(editor.processIdentifier)
        guard let document = editorDocument(documentURL, editor: editor),
              NSWorkspace.shared.frontmostApplication?.processIdentifier == editor.processIdentifier,
              attribute(app, kAXFocusedWindowAttribute).map({ CFEqual($0, document) }) == true,
              let bar = attribute(app, kAXMenuBarAttribute), CFGetTypeID(bar) == AXUIElementGetTypeID() else {
            throw FinderUIError.editorUnavailable
        }
        // Physical US key codes are layout-dependent: Command-A can become
        // Quit on AZERTY. Resolve the native menu action in the bound editor.
        let menus = (attribute(bar as! AXUIElement, kAXChildrenAttribute) as? [AXUIElement] ?? []).filter {
            string($0, kAXRoleAttribute) == kAXMenuBarItemRole && string($0, kAXTitleAttribute) == menuTitle
        }
        guard menus.count == 1, let menu = menus.first else { throw FinderUIError.controlUnavailable }
        try await wait {
            // Native AXMenuItem press performs the command directly. Opening
            // the menu bar first can leave TextEdit in its modal tracking loop.
            guard !editor.isTerminated, NSWorkspace.shared.frontmostApplication?.processIdentifier == editor.processIdentifier else {
                throw FinderUIError.editorUnavailable
            }
            let lists = self.attribute(menu, kAXChildrenAttribute) as? [AXUIElement] ?? []
            let items = lists.flatMap { self.attribute($0, kAXChildrenAttribute) as? [AXUIElement] ?? [] }.filter {
                self.string($0, kAXRoleAttribute) == kAXMenuItemRole && self.string($0, kAXTitleAttribute) == title &&
                (self.attribute($0, kAXEnabledAttribute) as? Bool) == true }
            guard items.count == 1, let item = items.first else { return false }
            guard AXUIElementPerformAction(item, kAXPressAction as CFString) == .success else { throw FinderUIError.controlUnavailable }
            return true
        }
        print("finder stability UI: TextEdit \(title) invoked")
        try await wait {
            guard let fresh = self.editorDocument(documentURL, editor: editor) else { return false }
            return self.attribute(app, kAXFocusedWindowAttribute).map { CFEqual($0, fresh) } == true
        }
    }

    func cancelDownload(_ url: URL) async throws {
        try await select(url)
        try await activateFinder()
        try await wait {
            guard let selected = self.selectedElement(), let cancel = self.elements(selected).first(where: {
                let label = self.string($0, kAXDescriptionAttribute) ?? self.string($0, kAXTitleAttribute) ?? ""
                return label.localizedCaseInsensitiveContains("cancel")
            }) else { return false }
            guard AXUIElementPerformAction(cancel, kAXPressAction as CFString) == .success else { throw FinderUIError.controlUnavailable }
            return true
        }
        actionCount += 1
    }

    func confirmPermanentDeletion(_ url: URL, fixtureAlias: UUID) async throws {
        try await select(url)
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 480, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        panel.title = "Stability run awaiting confirmation"
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "Permanently delete this generated test fixture?"
        alert.informativeText = url.lastPathComponent + "\nRun item alias: " + fixtureAlias.uuidString + "\nThis cannot be undone. No other Trash item will be selected."
        alert.addButton(withTitle: "Delete generated fixture")
        alert.addButton(withTitle: "Stop run")
        let result = await withCheckedContinuation { continuation in
            alert.beginSheetModal(for: panel) { continuation.resume(returning: $0) }
        }
        panel.close()
        guard result == .alertFirstButtonReturn else { throw FinderUIError.operatorCancelled }
        // Caller revalidates identity after the prompt before executing deletion.
    }

    func panelAction(_ action: FinderPanelAction) async throws {
        switch action {
        case .inheritAccess:
            try await pressControl(title: "Access", role: kAXPopUpButtonRole)
            try await pressControl(title: "Inherit Access", role: kAXMenuItemRole)
        case .createLink: try await pressControl(title: "Create Link")
        case .toggleComments: try await pressControl(title: "Allow comments", role: kAXCheckBoxRole)
        case .saveLink: try await pressControl(title: "Save Changes")
        case .disableLink, .confirmDisableLink: try await pressControl(title: "Disable Link")
        case .done: try await pressControl(title: "Done")
        case .restoreVersion(let versionID):
            try await pressControl(identifier: "provider.version.restore." + KDriveMutationIdentity.clientToken([String(versionID)]))
        case .confirmRestore: try await pressControl(title: "Restore as Copy")
        case .confirmSystemDeletion:
            guard selectedDeletionRequested, let dialog = selectedDeletionDialog() else { throw FinderUIError.selectionMismatch }
            let buttons = elements(dialog).filter { string($0, kAXRoleAttribute) == kAXButtonRole && string($0, kAXTitleAttribute) == "Delete" }
            guard buttons.count == 1, let button = buttons.first,
                  AXUIElementPerformAction(button, kAXPressAction as CFString) == .success else { throw FinderUIError.controlUnavailable }
            selectedDeletionRequested = false
        }
        actionCount += 1
    }

    private func pressControl(title: String? = nil, role: String = kAXButtonRole, identifier: String? = nil) async throws {
        try await wait {
            guard let scope = self.actionPanelScope() else { return false }
            let matches = self.elements(scope).filter {
                if let identifier { return self.string($0, kAXIdentifierAttribute) == identifier }
                return self.string($0, kAXRoleAttribute) == role &&
                    [self.string($0, kAXTitleAttribute), self.string($0, kAXDescriptionAttribute)].contains(title)
            }
            let enabled = matches.filter { (self.attribute($0, kAXEnabledAttribute) as? Bool) != false }
            guard enabled.count == 1, let element = enabled.first else { return false }
            guard AXUIElementPerformAction(element, kAXPressAction as CFString) == .success else { throw FinderUIError.controlUnavailable }
            return true
        }
    }

    private func actionPanelScope() -> AXUIElement? {
        guard let actionPanelIdentifier else { return nil }
        let windows = attribute(finderAX(), kAXWindowsAttribute) as? [AXUIElement] ?? []
        let matches = windows.filter { window in
            elements(window).contains { string($0, kAXIdentifierAttribute) == actionPanelIdentifier }
        }
        return matches.count == 1 ? matches.first : nil
    }

    private func selectedDeletionDialog() -> AXUIElement? {
        guard selectedDeletionRequested, let selectionURL else { return nil }
        let windows = attribute(finderAX(), kAXWindowsAttribute) as? [AXUIElement] ?? []
        var candidates = windows.filter { candidate in !windowsBeforeAction.contains { CFEqual($0, candidate) } }
        if let windowBeforeAction { candidates += elements(windowBeforeAction).filter { string($0, kAXRoleAttribute) == kAXSheetRole } }
        let matches = candidates.filter { candidate in
            let values = elements(candidate).flatMap { [string($0, kAXTitleAttribute), string($0, kAXValueAttribute)] }.compactMap { $0 }
            let buttons = elements(candidate).filter { string($0, kAXRoleAttribute) == kAXButtonRole }.compactMap { string($0, kAXTitleAttribute) }
            return values.contains { $0.contains(selectionURL.lastPathComponent) } && buttons.contains("Delete") && buttons.contains("Cancel")
        }
        return matches.count == 1 ? matches.first : nil
    }

    func capture(in directory: URL, sequence: Int) async throws {
        guard CGPreflightScreenCaptureAccess(), let windowID, let selected = selectedElement(),
              let bounds = rect(selected) else { throw FinderUIError.screenshotUnavailable }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let window = content.windows.first(where: { $0.windowID == UInt32(windowID) && $0.owningApplication?.bundleIdentifier == "com.apple.finder" }) else {
            throw FinderUIError.screenshotUnavailable
        }
        // Capture only the selected generated row, excluding sidebar/path and other rows.
        let region = bounds.intersection(window.frame)
        guard !region.isEmpty, region.width > 1, region.height > 1 else { throw FinderUIError.screenshotUnavailable }
        let config = SCStreamConfiguration()
        config.sourceRect = region.offsetBy(dx: -window.frame.minX, dy: -window.frame.minY)
        config.width = Int(region.width * 2)
        config.height = Int(region.height * 2)
        config.showsCursor = false
        let image = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: window), configuration: config)
        let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
        guard let data else { throw FinderUIError.screenshotUnavailable }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try data.write(to: directory.appendingPathComponent(String(format: "%03d.png", sequence)), options: .withoutOverwriting)
    }

    private func script(_ body: String, operation: FinderAppleEventOperation = .observe) throws -> NSAppleEventDescriptor {
        guard remainingTime() > .zero else { throw FinderUIError.timedOut }
        let source = "with timeout of 10 seconds\ntell application id \"com.apple.finder\"\n" + body + "\nend tell\nend timeout"
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else { throw FinderUIError.automationFailed }
        let value = script.executeAndReturnError(&error)
        guard error == nil else {
            if (error?[NSAppleScript.errorNumber] as? Int) == -15260 { throw FinderUIError.finderBusy }
            print("finder stability UI: Apple Event failed; operation \(operation.rawValue); code \((error?[NSAppleScript.errorNumber] as? Int) ?? 0)")
            throw FinderUIError.automationFailed
        }
        return value
    }

    private func quote(_ value: String) -> String { "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"" }

    private func verifyWindow(_ url: URL) throws -> Bool {
        guard let windowID, let value = try script("get URL of target of Finder window id \(windowID)").stringValue,
              let actual = URL(string: value) else { throw FinderUIError.windowMismatch }
        return FinderUIURLIdentity.matches(actual, url)
    }

    private func verifySelection(_ url: URL) throws -> Bool {
        // Finder's optimized `count selection` event returns zero on this OS
        // even when its selection list contains one item. Fetch the list once
        // and count that snapshot before reading the one selected URL.
        let selected = try script("set selectedItems to get selection\nif (count selectedItems) is not 1 then return {}\nreturn {URL of item 1 of selectedItems}")
        guard selected.numberOfItems == 1,
              let value = selected.atIndex(1)?.stringValue,
              let actual = URL(string: value) else { return false }
        return FinderUIURLIdentity.matches(actual, url)
    }

    private func displayedName(of url: URL) throws -> String? {
        // Finder may hide a filename extension. Ask for the display label of
        // the exact bound URL; never infer identity by stripping extensions.
        let file = "POSIX file " + quote(url.path)
        let value = try script("if not (exists \(file)) then return \"\"\nget displayed name of (\(file) as alias)")
        guard let name = value.stringValue else { throw FinderUIError.selectionMismatch }
        return name.isEmpty ? nil : name
    }

    private func activateFinder() async throws {
        guard let windowID, let currentURL, try verifyWindow(currentURL) else { throw FinderUIError.windowMismatch }
        _ = try script("set index of Finder window id \(windowID) to 1\nactivate", operation: .activate)
        try await wait { NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.finder" }
        if let selectionURL, try verifySelection(selectionURL) == false { throw FinderUIError.selectionMismatch }
    }

    private func finderAX() -> AXUIElement {
        AXUIElementCreateApplication(NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first?.processIdentifier ?? 0)
    }

    private func finderWindowAX() -> AXUIElement? {
        guard let windowID, let currentURL, (try? verifyWindow(currentURL)) == true,
              let bounds = try? script("get bounds of Finder window id \(windowID)"), bounds.numberOfItems == 4 else { return nil }
        let x = CGFloat(bounds.atIndex(1)?.int32Value ?? 0), y = CGFloat(bounds.atIndex(2)?.int32Value ?? 0)
        let expected = CGRect(x: x, y: y, width: CGFloat(bounds.atIndex(3)?.int32Value ?? 0) - x,
                              height: CGFloat(bounds.atIndex(4)?.int32Value ?? 0) - y)
        let matches = (attribute(finderAX(), kAXWindowsAttribute) as? [AXUIElement] ?? []).filter {
            guard let frame = rect($0) else { return false }
            return abs(frame.minX - expected.minX) < 3 && abs(frame.minY - expected.minY) < 3 &&
                abs(frame.width - expected.width) < 3 && abs(frame.height - expected.height) < 3
        }
        if matches.count == 1 { return matches.first }
        // Two retained run windows can have identical frames and titles. The
        // front window is usable only after its Apple Events ID is verified;
        // AX focus then disambiguates those otherwise identical windows.
        guard (try? script("get id of front Finder window").int32Value) == windowID,
              let focused = attribute(finderAX(), kAXFocusedWindowAttribute) else { return nil }
        return matches.first { CFEqual($0, focused) }
    }

    private func selectedElement() -> AXUIElement? {
        guard let selectionURL, (try? verifySelection(selectionURL)) == true, let window = finderWindowAX(),
              let displayedName = try? displayedName(of: selectionURL) else { return nil }
        let candidates = elements(window).filter { element in
            (attribute(element, kAXSelectedAttribute) as? Bool) == true && elements(element).contains {
                [string($0, kAXTitleAttribute), string($0, kAXValueAttribute), string($0, kAXDescriptionAttribute)].contains(displayedName)
            }
        }
        // The complete row includes progress controls; its contents belong only
        // to the verified single selection. Never search another Finder window.
        return candidates.first { string($0, kAXRoleAttribute) == kAXRowRole } ?? candidates.first
    }

    private func selectedMenuAnchor() -> AXUIElement? {
        guard let selected = selectedElement(), let selectionURL,
              let name = try? displayedName(of: selectionURL) else { return nil }
        let candidates = elements(selected).filter {
            string($0, kAXRoleAttribute) == kAXTextFieldRole && string($0, kAXValueAttribute) == name
        }
        let supported = candidates.filter { element in
            var actions: CFArray?
            return AXUIElementCopyActionNames(element, &actions) == .success &&
                (actions as? [String] ?? []).contains(kAXShowMenuAction)
        }
        return supported.count == 1 ? supported.first : nil
    }

    private func showSelectedContextMenu() async throws {
        try await wait { self.selectedMenuAnchor() != nil }
        guard let field = selectedMenuAnchor(), let frame = rect(field),
              let window = finderWindowAX(), let windowFrame = rect(window),
              windowFrame.contains(frame), frame.width > 1, frame.height > 1,
              let finder = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first else {
            throw FinderUIError.controlUnavailable
        }
        // Finder advertises AXShowMenu on the name field but can reject its
        // invocation. Use a real secondary click at the freshly verified field,
        // whose geometry is confined to our bound window. No fixed coordinates.
        let point = CGPoint(x: frame.midX, y: frame.midY)
        menuIsOpen = true
        for type in [CGEventType.rightMouseDown, .rightMouseUp] {
            guard let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .right) else {
                throw FinderUIError.controlUnavailable
            }
            // Mouse routing needs WindowServer hit testing. postToPid does not
            // reliably open Finder's contextual menu on current macOS.
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == finder.processIdentifier else {
                throw FinderUIError.windowMismatch
            }
            event.post(tap: .cghidEventTap)
        }
    }

    private func contextMenu() -> AXUIElement? {
        // The application menu bar contains similarly named commands. Only
        // the transient popup opened on our verified selection is actionable.
        let menus = elements(finderAX()).filter {
            guard string($0, kAXRoleAttribute) == kAXMenuRole, let frame = rect($0) else { return false }
            return frame.width > 1 && frame.height > 1
        }
        return menus.count == 1 ? menus.first : nil
    }

    private func waitForFinderIdle(allowMissingWindow: Bool = false) async throws {
        guard let windowID else { throw FinderUIError.windowMismatch }
        try await wait {
            try self.detectEvictionFailure()
            _ = try self.script(allowMissingWindow ? "exists Finder window id \(windowID)" : "get id of Finder window id \(windowID)")
            return true
        }
    }

    private func detectEvictionFailure() throws {
        guard awaitingEvictionResult else { return }
        let windows = attribute(finderAX(), kAXWindowsAttribute) as? [AXUIElement] ?? []
        var candidates = windows.filter { candidate in !windowsBeforeAction.contains { CFEqual($0, candidate) } }
        if let windowBeforeAction {
            candidates += elements(windowBeforeAction).filter { string($0, kAXRoleAttribute) == kAXSheetRole }
        }
        let alerts = candidates.filter { candidate in
            let labels = elements(candidate).flatMap { [string($0, kAXTitleAttribute), string($0, kAXValueAttribute)] }.compactMap { $0 }
            return FinderAlertObservation.isResourceBusyEviction(labels: labels)
        }
        guard alerts.count == 1, let alert = alerts.first else { return }
        let buttons = elements(alert).filter { string($0, kAXRoleAttribute) == kAXButtonRole && string($0, kAXTitleAttribute) == "OK" }
        guard buttons.count == 1, let button = buttons.first,
              AXUIElementPerformAction(button, kAXPressAction as CFString) == .success else { throw FinderUIError.controlUnavailable }
        print("finder stability UI: generated eviction rejected; resource busy; alert dismissed")
        awaitingEvictionResult = false
        throw FinderUIError.evictionResourceBusy
    }

    private func dismissContextMenu(allowMissingWindow: Bool = false) async throws {
        try key(53)
        try await waitForFinderIdle(allowMissingWindow: allowMissingWindow)
        menuIsOpen = false
    }

    private func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }
    private func string(_ element: AXUIElement, _ name: String) -> String? { attribute(element, name) as? String }
    private func elements(_ root: AXUIElement) -> [AXUIElement] {
        var result: [AXUIElement] = [], queue = [root]
        while !queue.isEmpty && result.count < 5_000 {
            let value = queue.removeLast()
            result.append(value)
            queue.append(contentsOf: attribute(value, kAXChildrenAttribute) as? [AXUIElement] ?? [])
        }
        return result
    }
    private func rect(_ element: AXUIElement) -> CGRect? {
        guard let position = attribute(element, kAXPositionAttribute), let size = attribute(element, kAXSizeAttribute),
              CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero, extent = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &point), AXValueGetValue(size as! AXValue, .cgSize, &extent) else { return nil }
        return CGRect(origin: point, size: extent)
    }
    private func key(_ code: CGKeyCode, flags: CGEventFlags = []) throws {
        guard remainingTime() > .zero else { throw FinderUIError.timedOut }
        guard AXIsProcessTrusted(), let target = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first?.processIdentifier,
              let down = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: false) else { throw FinderUIError.permissionRequired }
        down.flags = flags; up.flags = flags
        down.postToPid(target); up.postToPid(target)
    }
    private func enterFinderName(_ name: String) async throws {
        var editor: AXUIElement?
        do { try await wait {
            guard let focused = self.attribute(self.finderAX(), kAXFocusedUIElementAttribute),
                  CFGetTypeID(focused) == AXUIElementGetTypeID() else { return false }
            let field = focused as! AXUIElement
            guard self.string(field, kAXRoleAttribute) == kAXTextFieldRole,
                  let window = self.finderWindowAX(),
                  self.belongsToWindow(field, window: window) || self.belongsToSelectedRowOverlay(field, window: window) ||
                    self.isConfinedNameEditor(field, window: window) else { return false }
            var settable = DarwinBoolean(false)
            guard AXUIElementIsAttributeSettable(field, kAXValueAttribute as CFString, &settable) == .success,
                  settable.boolValue else { return false }
            editor = field
            return true
        } } catch {
            if let value = attribute(finderAX(), kAXFocusedUIElementAttribute), CFGetTypeID(value) == AXUIElementGetTypeID() {
                let field = value as! AXUIElement
                let role = string(field, kAXRoleAttribute) ?? ""
                let knownRoles = [kAXTextFieldRole, kAXTextAreaRole, kAXOutlineRole, kAXRowRole, kAXGroupRole, kAXWindowRole, kAXComboBoxRole]
                var settable = DarwinBoolean(false)
                let result = AXUIElementIsAttributeSettable(field, kAXValueAttribute as CFString, &settable)
                let window = finderWindowAX()
                print("finder stability UI name field: role \(knownRoles.contains(role) ? role : "other"); settable \(settable.boolValue); status \(result.rawValue); window \(window != nil); ownership \(window.map { belongsToWindow(field, window: $0) } ?? false)")
                let row = selectedElement()
                let focusedWindow = attribute(finderAX(), kAXFocusedWindowAttribute)
                print("finder stability UI name geometry: row \(row != nil); focused window \(window.map { w in focusedWindow.map { CFEqual($0, w) } ?? false } ?? false); editor bounds \(rect(field) != nil); contained \(window.flatMap(rect).map { w in rect(field).map(w.contains) ?? false } ?? false); overlaps row \(row.flatMap(rect).map { r in rect(field).map(r.intersects) ?? false } ?? false)")
            } else { print("finder stability UI name field: no focused element") }
            throw error
        }
        guard let editor,
              AXUIElementSetAttributeValue(editor, kAXValueAttribute as CFString, name as CFString) == .success else {
            throw FinderUIError.controlUnavailable
        }
    }

    private func belongsToWindow(_ element: AXUIElement, window: AXUIElement) -> Bool {
        // Finder's inline name editor is an overlay omitted from AXChildren.
        // Its AXWindow/parent links still provide an explicit ownership edge.
        if let owner = attribute(element, kAXWindowAttribute), CFEqual(owner, window) { return true }
        var current = element
        for _ in 0..<16 {
            guard let parent = attribute(current, kAXParentAttribute), CFGetTypeID(parent) == AXUIElementGetTypeID() else { return false }
            if CFEqual(parent, window) { return true }
            current = parent as! AXUIElement
        }
        return false
    }

    private func belongsToSelectedRowOverlay(_ field: AXUIElement, window: AXUIElement) -> Bool {
        // Finder omits both child and parent links for its inline editor on
        // some OS versions. Bind the focused editor to the independently
        // verified single selection and focused window, using fresh geometry.
        guard let focusedWindow = attribute(finderAX(), kAXFocusedWindowAttribute), CFEqual(focusedWindow, window),
              let selected = selectedElement(), let row = rect(selected), let editor = rect(field),
              let bounds = rect(window), bounds.contains(editor), row.intersects(editor) else { return false }
        var editorPID: pid_t = 0, windowPID: pid_t = 0
        return AXUIElementGetPid(field, &editorPID) == .success && AXUIElementGetPid(window, &windowPID) == .success && editorPID == windowPID
    }

    private func isConfinedNameEditor(_ field: AXUIElement, window: AXUIElement) -> Bool {
        guard let selectionURL, (try? verifySelection(selectionURL)) == true,
              let expected = try? displayedName(of: selectionURL), let editorBounds = rect(field), let windowBounds = rect(window),
              let windowID else { return false }
        var editorPID: pid_t = 0, windowPID: pid_t = 0
        let sameProcess = AXUIElementGetPid(field, &editorPID) == .success && AXUIElementGetPid(window, &windowPID) == .success && editorPID == windowPID
        return FinderNameEditorObservation.isConfined(value: string(field, kAXValueAttribute), expected: expected,
            editorBounds: editorBounds, windowBounds: windowBounds, sameProcess: sameProcess,
            ownedWindowIsFront: (try? script("get id of front Finder window").int32Value) == windowID)
    }
    private func wait(_ predicate: () async throws -> Bool) async throws {
        guard remainingTime() > .zero else { throw FinderUIError.timedOut }
        let deadline = ContinuousClock.now.advanced(by: remainingTime())
        repeat {
            try Task.checkCancellation()
            do { if try await predicate() { return } }
            catch FinderUIError.finderBusy { /* Menu tracking is transient; retry only the bounded observation. */ }
            try await Task.sleep(for: .milliseconds(100))
        } while ContinuousClock.now < deadline
        throw FinderUIError.timedOut
    }
}
#endif
