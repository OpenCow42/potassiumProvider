import XCTest

/// Select the product beside this test runner, even if another checkout has
/// registered an application with the same bundle identifier on this Mac.
@MainActor
enum UITestApplication {
    static func make(for testCase: XCTestCase) -> XCUIApplication {
        #if os(macOS)
        let productDirectory = Bundle(for: potassiumProviderUITests.self).bundleURL
            .deletingLastPathComponent() // PlugIns
            .deletingLastPathComponent() // Contents
            .deletingLastPathComponent() // test runner application
            .deletingLastPathComponent() // build products
        let appURL = productDirectory.appendingPathComponent("potassiumProvider.app")
        XCTAssertEqual(Bundle(url: appURL)?.bundleIdentifier, "net.weavee.potassiumProvider",
            "The UI runner must launch its sibling build product.")
        let app = XCUIApplication(url: appURL)
        #else
        let app = XCUIApplication()
        #endif
        // Launch/performance screenshots must also contain synthetic state.
        app.launchEnvironment["POTASSIUM_UI_TEST_FIXTURE"] = "setup-navigation"
        testCase.addTeardownBlock { @MainActor in
            if app.state != .notRunning { app.terminate() }
        }
        return app
    }
}
