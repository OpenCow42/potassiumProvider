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
    func testSetupPresentsErrorsAsDismissibleBannerInsteadOfAlert() throws {
        let app = launchSetupFixture(named: "setup-error-banner")
        openSetup(in: app)

        let banner = app.descendants(matching: .any)["setup.errorBanner"]
        XCTAssertTrue(banner.waitForExistence(timeout: 5))
        XCTAssertEqual(app.alerts.count, 0)

        app.buttons["Dismiss kDrive message"].tap()
        XCTAssertTrue(banner.waitForNonExistence(timeout: 5))
    }

    @MainActor
    func testActivitiesPrefetchesOlderRowsAndReturnsToLatest() throws {
        let app = launchSetupFixture(named: "activities-pagination")
        openActivities(in: app)

        XCTAssertTrue(app.staticTexts["Item 0000"].waitForExistence(timeout: 5))
        let timeline = app.scrollViews["activity.timeline"]
        XCTAssertTrue(timeline.waitForExistence(timeout: 5))

        for _ in 0..<14 where app.staticTexts["Item 0075"].exists == false {
            timeline.swipeUp()
        }

        XCTAssertTrue(app.staticTexts["Item 0075"].waitForExistence(timeout: 5))
        let backToLatest = app.buttons["activity.backToLatest"]
        XCTAssertTrue(backToLatest.waitForExistence(timeout: 5))
        backToLatest.tap()
        XCTAssertTrue(app.staticTexts["Item 0000"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testActivitiesScrollPerformance() throws {
        let app = launchSetupFixture(named: "activities-pagination")
        openActivities(in: app)
        let timeline = app.scrollViews["activity.timeline"]
        XCTAssertTrue(timeline.waitForExistence(timeout: 5))

        measure(metrics: [XCTOSSignpostMetric.scrollingAndDecelerationMetric]) {
            timeline.swipeUp(velocity: .fast)
        }
    }

    #if os(macOS)
    @MainActor
    func testActivitiesExportPresentsSavePanel() throws {
        let app = launchSetupFixture(named: "activities-pagination")
        openActivities(in: app)

        let export = app.buttons["Export"]
        XCTAssertTrue(export.waitForExistence(timeout: 5))
        XCTAssertTrue(export.isEnabled)
        export.tap()

        let savePanel = app.sheets.firstMatch
        XCTAssertTrue(savePanel.waitForExistence(timeout: 5))
        let cancel = savePanel.buttons["Cancel"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 2))
        cancel.tap()
    }
    #endif

    @MainActor
    func testLaunchPerformance() throws {
        // This measures how long it takes to launch your application.
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            XCUIApplication().launch()
        }
    }

    @MainActor
    private func launchSetupFixture(named fixtureName: String = "setup-navigation") -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["POTASSIUM_UI_TEST_FIXTURE"] = fixtureName
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

    @MainActor
    private func openActivities(in app: XCUIApplication) {
        let tabBarButton = app.tabBars.buttons["Activities"]
        if tabBarButton.waitForExistence(timeout: 2) {
            tabBarButton.tap()
        } else {
            let activitiesButton = app.buttons["Activities"]
            XCTAssertTrue(activitiesButton.waitForExistence(timeout: 5))
            activitiesButton.tap()
        }
    }
}
