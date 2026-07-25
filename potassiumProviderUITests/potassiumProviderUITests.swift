//
//  potassiumProviderUITests.swift
//  potassiumProviderUITests
//
//  Created by OpenCow on 03/07/2026.
//

import XCTest

final class potassiumProviderUITests: XCTestCase {

    override func setUpWithError() throws {
        // Put setup code here. This method is called before the invocation of each test method in the class.

        // In UI tests it is usually best to stop immediately when a failure occurs.
        continueAfterFailure = false

        // In UI tests it’s important to set the initial state - such as interface orientation - required for your tests before they run. The setUp method is a good place to do this.
    }

    override func tearDownWithError() throws {
        // Put teardown code here. This method is called after the invocation of each test method in the class.
    }

    @MainActor
    func testExample() throws {
        // UI tests must launch the application that they test.
        let app = XCUIApplication()
        app.launch()

        // Use XCTAssert and related functions to verify your tests produce the correct results.
        // XCUIAutomation Documentation
        // https://developer.apple.com/documentation/xcuiautomation
    }

    @MainActor
    func testSetupNavigatesFromAccountToAvailableDriveManagement() throws {
        let app = launchSetupFixture()
        openSetup(in: app)

        let account = app.buttons["setup.account.ui-account"]
        XCTAssertTrue(account.waitForExistence(timeout: 5))
        account.tap()

        let availableDrive = app.buttons["account.drive.20"]
        XCTAssertTrue(availableDrive.waitForExistence(timeout: 5))
        availableDrive.tap()

        XCTAssertTrue(app.buttons["drive.addToFiles"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["This drive is currently in maintenance."].exists)
    }

    @MainActor
    func testConfiguredDrivePresentsRemovalConfirmation() throws {
        let app = launchSetupFixture()
        openSetup(in: app)
        app.buttons["setup.account.ui-account"].tap()
        app.buttons["account.drive.10"].tap()

        let remove = app.buttons["drive.removeFromFiles"]
        XCTAssertTrue(remove.waitForExistence(timeout: 5))
        remove.tap()

        XCTAssertTrue(app.buttons["Remove from Files"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "Remote kDrive files are not deleted")
        ).firstMatch.exists)
    }

    @MainActor
    func testAddAccountUsesDedicatedScreenWithAdvancedTokenEntry() throws {
        let app = launchSetupFixture()
        openSetup(in: app)

        let addAccount = app.buttons["setup.addAccount"]
        XCTAssertTrue(addAccount.waitForExistence(timeout: 5))
        addAccount.tap()

        XCTAssertTrue(app.buttons["addAccount.oauth"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.secureTextFields["addAccount.manualToken"].exists)
        XCTAssertTrue(app.staticTexts["Advanced"].exists)
    }

    @MainActor
    func testLaunchPerformance() throws {
        // This measures how long it takes to launch your application.
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            XCUIApplication().launch()
        }
    }

    @MainActor
    private func launchSetupFixture() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["POTASSIUM_UI_TEST_FIXTURE"] = "setup-navigation"
        app.launch()
        return app
    }

    @MainActor
    private func openSetup(in app: XCUIApplication) {
        let tabBarButton = app.tabBars.buttons["Setup"]
        if tabBarButton.waitForExistence(timeout: 2) {
            tabBarButton.tap()
        } else {
            let setupButton = app.buttons["Setup"]
            XCTAssertTrue(setupButton.waitForExistence(timeout: 5))
            setupButton.tap()
        }
    }
}
