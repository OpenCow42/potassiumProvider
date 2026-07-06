#if os(macOS)
import AppKit
import SwiftUI

enum MacAppPresenceConfiguration {
    static let mainWindowSceneID = "potassiumProvider.main"
    static let mainWindowIdentifier = "net.weavee.potassiumProvider.main-window"
    static let statusItemTitle = "⚛️"
    static let statusItemAccessibilityLabel = "Show potassiumProvider"
    static let closeMenuItemTitle = "Close potassiumProvider"
    static let activationPolicy = NSApplication.ActivationPolicy.accessory
}

@MainActor
final class MacAppPresenceController: NSObject {
    static let shared = MacAppPresenceController()

    private let revealAction: @MainActor () -> Void
    private let closeAction: @MainActor () -> Void
    private let menuPresenter: @MainActor (NSMenu) -> Void
    private let installsStatusItem: Bool
    private var statusItem: NSStatusItem?

    init(
        revealAction: @escaping @MainActor () -> Void = { MacMainWindowRevealer.shared.revealMainWindow() },
        closeAction: @escaping @MainActor () -> Void = { NSApplication.shared.terminate(nil) },
        menuPresenter: @escaping @MainActor (NSMenu) -> Void = { menu in
            guard let button = MacAppPresenceController.shared.statusItem?.button else { return }
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.minY), in: button)
        },
        installsStatusItem: Bool = true
    ) {
        self.revealAction = revealAction
        self.closeAction = closeAction
        self.menuPresenter = menuPresenter
        self.installsStatusItem = installsStatusItem
        super.init()
    }

    func start() {
        NSApplication.shared.setActivationPolicy(MacAppPresenceConfiguration.activationPolicy)
        guard installsStatusItem else { return }
        installStatusItemIfNeeded()
    }

    @objc
    func statusItemButtonClicked(_ sender: Any?) {
        handleStatusItemClick(eventType: NSApplication.shared.currentEvent?.type)
    }

    func handleStatusItemClick(eventType: NSEvent.EventType?) {
        if eventType == .rightMouseUp {
            menuPresenter(makeStatusMenu())
        } else {
            revealAction()
        }
    }

    @objc
    func closeMenuItemClicked(_ sender: Any?) {
        closeAction()
    }

    func makeStatusMenu() -> NSMenu {
        let menu = NSMenu()
        let closeItem = NSMenuItem(
            title: MacAppPresenceConfiguration.closeMenuItemTitle,
            action: #selector(closeMenuItemClicked(_:)),
            keyEquivalent: "q"
        )
        closeItem.target = self
        menu.addItem(closeItem)
        return menu
    }

    private func installStatusItemIfNeeded() {
        guard statusItem == nil else { return }

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.title = MacAppPresenceConfiguration.statusItemTitle
            button.toolTip = MacAppPresenceConfiguration.statusItemAccessibilityLabel
            button.setAccessibilityLabel(MacAppPresenceConfiguration.statusItemAccessibilityLabel)
            button.target = self
            button.action = #selector(statusItemButtonClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        statusItem = item
    }
}

@MainActor
final class MacMainWindowRevealer {
    static let shared = MacMainWindowRevealer()

    private var openWindowAction: (() -> Void)?

    func registerOpenWindowAction(_ action: @escaping () -> Void) {
        openWindowAction = action
    }

    func revealMainWindow() {
        NSApplication.shared.unhide(nil)

        if let window = mainWindow {
            bringForward(window)
        } else {
            openWindowAction?()
            Task { @MainActor in
                if let window = self.mainWindow {
                    self.bringForward(window)
                }
            }
        }

        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    private var mainWindow: NSWindow? {
        NSApplication.shared.windows.first {
            $0.identifier?.rawValue == MacAppPresenceConfiguration.mainWindowIdentifier
        }
    }

    private func bringForward(_ window: NSWindow) {
        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }
}

final class MacAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        MacAppPresenceController.shared.start()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

struct MacMainWindowIdentifierInstaller: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        assignIdentifier(from: view)
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        assignIdentifier(from: view)
    }

    private func assignIdentifier(from view: NSView) {
        DispatchQueue.main.async {
            view.window?.identifier = NSUserInterfaceItemIdentifier(
                MacAppPresenceConfiguration.mainWindowIdentifier
            )
        }
    }
}

struct MacOpenWindowActionRegistrar: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onAppear {
                MacMainWindowRevealer.shared.registerOpenWindowAction {
                    openWindow(id: MacAppPresenceConfiguration.mainWindowSceneID)
                }
            }
    }
}
#endif
