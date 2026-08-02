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

        XCTAssertTrue(
            app.buttons["drive.createEncryptedVault"].waitForExistence(timeout: 5)
        )
        XCTAssertTrue(app.staticTexts["This drive is currently in maintenance."].exists)
    }

    @MainActor
    func testEncryptedVaultWarningRequiresFiveSecondWait() throws {
        let app = launchSetupFixture()
        openSetup(in: app)
        app.buttons["setup.account.ui-account"].tap()
        app.buttons["account.drive.20"].tap()

        let createVault = app.buttons["drive.createEncryptedVault"]
        XCTAssertTrue(createVault.waitForExistence(timeout: 5))
        XCTAssertTrue(createVault.isEnabled)
        createVault.tap()

        XCTAssertTrue(
            text(containing: "complete and unrecoverable data loss", in: app)
                .waitForExistence(timeout: 5)
        )
        XCTAssertTrue(
            text(containing: "you are entirely on your own", in: app).exists
        )

        let continueButton = app.buttons["vault.unsupportedRiskContinue"]
        XCTAssertTrue(continueButton.waitForExistence(timeout: 5))
        XCTAssertFalse(continueButton.isEnabled)
        XCTAssertTrue(
            app.staticTexts["vault.unsupportedRiskCountdown"].exists
        )

        let enabledAfterDelay = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "isEnabled == true"),
            object: continueButton
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [enabledAfterDelay], timeout: 7),
            .completed
        )
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
        XCTAssertTrue(
            text(containing: "Remote kDrive files are not deleted", in: app).exists
        )
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

        let dismiss = app.buttons["setup.dismissError"]
        XCTAssertTrue(dismiss.waitForExistence(timeout: 5))
        #if os(macOS)
        app.typeKey(.escape, modifierFlags: [])
        #else
        dismiss.tap()
        #endif
        XCTAssertTrue(banner.waitForNonExistence(timeout: 5))
    }

    @MainActor
    func testActivitiesPrefetchesOlderRowsAndReturnsToLatest() throws {
        let app = launchSetupFixture(named: "activities-pagination")
        openActivities(in: app)

        let latestEntry = app.buttons[
            "activity.entry.activity-00000000-0000-0000-0000-000000000001"
        ]
        XCTAssertTrue(latestEntry.waitForExistence(timeout: 5))
        let timeline = app.scrollViews["activity.timeline"]
        XCTAssertTrue(timeline.waitForExistence(timeout: 5))

        let olderEntry = app.buttons[
            "activity.entry.activity-00000000-0000-0000-0000-000000000076"
        ]
        for _ in 0..<14 where olderEntry.exists == false {
            timeline.swipeUp()
        }

        XCTAssertTrue(olderEntry.waitForExistence(timeout: 5))
        let backToLatest = app.buttons["activity.backToLatest"]
        XCTAssertTrue(backToLatest.waitForExistence(timeout: 5))
        backToLatest.tap()
        XCTAssertTrue(latestEntry.waitForExistence(timeout: 5))
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

    @MainActor
    func testActivitiesShowsExportFailureWhileTimelineIsEmpty() throws {
        let app = launchSetupFixture(named: "activities-action-errors")
        openActivities(in: app)

        #if os(macOS)
        let export = app.buttons["Export"]
        #else
        app.buttons["More Activity Actions"].tap()
        let export = app.buttons["Export"]
        #endif
        XCTAssertTrue(export.waitForExistence(timeout: 5))
        export.tap()

        let error = app.descendants(matching: .any)["activity.error"]
        XCTAssertTrue(error.waitForExistence(timeout: 5))
        XCTAssertTrue(
            text(containing: "Could not create support log", in: app).exists
        )
    }

    @MainActor
    func testActivitiesDisablesRefreshWhenDatabaseIsUnavailable() throws {
        let app = launchSetupFixture(named: "activities-unavailable")
        openActivities(in: app)

        XCTAssertTrue(
            text(containing: "Activities Unavailable", in: app)
                .waitForExistence(timeout: 5)
        )
        XCTAssertTrue(app.descendants(matching: .any)["activity.error"].exists)
        let refresh = app.buttons["activity.refresh"]
        XCTAssertTrue(refresh.exists)
        XCTAssertFalse(refresh.isEnabled)
    }

    @MainActor
    func testActivitiesReportsRejectedItemOpenAndClipboardWrite() throws {
        let app = launchSetupFixture(named: "activities-row-action-errors")
        openActivities(in: app)

        let entry = app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", "Failed enumeration")
        ).firstMatch
        XCTAssertTrue(entry.waitForExistence(timeout: 5))
        entry.tap()

        let openItem = app.buttons["activity.openInFiles"]
        XCTAssertTrue(openItem.waitForExistence(timeout: 5))
        openItem.tap()
        #if os(macOS)
        let unavailableText = "This item could not be found in Finder"
        #else
        let unavailableText = "This item is not currently available in Files"
        #endif
        XCTAssertTrue(
            text(containing: unavailableText, in: app)
                .waitForExistence(timeout: 5)
        )

        let copy = app.buttons["activity.copyDetails"]
        XCTAssertTrue(copy.exists)
        copy.tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["activity.copyError"]
                .waitForExistence(timeout: 5)
        )
        XCTAssertFalse(app.buttons["Copied"].exists)
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
        openTab(named: "Setup", in: app)
    }

    @MainActor
    private func openActivities(in app: XCUIApplication) {
        openTab(named: "Activities", in: app)
    }

    @MainActor
    private func text(containing text: String, in app: XCUIApplication) -> XCUIElement {
        app.staticTexts.matching(
            NSPredicate(
                format: "label CONTAINS %@ OR value CONTAINS %@",
                text,
                text
            )
        ).firstMatch
    }

    @MainActor
    private func openTab(named name: String, in app: XCUIApplication) {
        #if os(macOS)
        let tab = app.radioButtons[name]
        XCTAssertTrue(
            tab.waitForExistence(timeout: 5),
            "The \(name) tab was not available."
        )
        tab.tap()
        #else
        let tabBarButton = app.tabBars.buttons[name]
        if tabBarButton.waitForExistence(timeout: 2) {
            tabBarButton.tap()
        } else {
            let tabButton = app.buttons[name]
            XCTAssertTrue(
                tabButton.waitForExistence(timeout: 5),
                "The \(name) tab was not available."
            )
            tabButton.tap()
        }
        #endif
    }
}
