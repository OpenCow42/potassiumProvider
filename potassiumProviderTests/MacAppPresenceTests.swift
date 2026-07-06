#if os(macOS)
import AppKit
import Foundation
import Testing
@testable import potassiumProvider

@MainActor
struct MacAppPresenceTests {
    @Test func statusItemConfigurationUsesAtomLabeling() {
        #expect(MacAppPresenceConfiguration.statusItemTitle == "⚛️")
        #expect(MacAppPresenceConfiguration.statusItemAccessibilityLabel == "Show potassiumProvider")
        #expect(MacAppPresenceConfiguration.closeMenuItemTitle == "Close potassiumProvider")
    }

    @Test func statusItemClickInvokesRevealAction() {
        var revealCount = 0
        let controller = MacAppPresenceController(
            revealAction: { revealCount += 1 },
            installsStatusItem: false
        )

        controller.statusItemButtonClicked(nil)

        #expect(revealCount == 1)
    }

    @Test func rightClickPresentsCloseMenuWithoutRevealingWindow() {
        var revealCount = 0
        var presentedMenu: NSMenu?
        let controller = MacAppPresenceController(
            revealAction: { revealCount += 1 },
            menuPresenter: { presentedMenu = $0 },
            installsStatusItem: false
        )

        controller.handleStatusItemClick(eventType: .rightMouseUp)

        #expect(revealCount == 0)
        let menu = try? #require(presentedMenu)
        #expect(menu?.items.first?.title == MacAppPresenceConfiguration.closeMenuItemTitle)
    }

    @Test func closeMenuItemInvokesCloseAction() {
        var closeCount = 0
        let controller = MacAppPresenceController(
            closeAction: { closeCount += 1 },
            installsStatusItem: false
        )

        controller.closeMenuItemClicked(nil)

        #expect(closeCount == 1)
    }

    @Test func appStaysRunningAfterLastWindowCloses() {
        let delegate = MacAppDelegate()

        #expect(delegate.applicationShouldTerminateAfterLastWindowClosed(NSApplication.shared) == false)
    }

    @Test func missingOpenWindowRegistrationDoesNotCrash() {
        let revealer = MacMainWindowRevealer()

        revealer.revealMainWindow()
    }

    @Test func macAppPresenceDeclaresAccessoryDockHiddenIntent() throws {
        #expect(MacAppPresenceConfiguration.activationPolicy == NSApplication.ActivationPolicy.accessory)

        let sourceFile = URL(fileURLWithPath: #filePath)
        let projectDirectory = sourceFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let plistURL = projectDirectory
            .appendingPathComponent("Config", isDirectory: true)
            .appendingPathComponent("potassiumProviderInfo.plist")
        let plistData = try Data(contentsOf: plistURL)
        let plist = try #require(
            PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any]
        )

        #expect(plist["LSUIElement"] as? Bool == true)
    }
}
#endif
