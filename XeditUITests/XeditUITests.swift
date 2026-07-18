//
//  XeditUITests.swift
//  WillDeepUITests
//
//  Created by rocky on 2026/5/27.
//

import XCTest

final class WillDeepUITests: XCTestCase {

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
    func testFirstLaunchShowsOnboardingFromDefaultAgentWindow() throws {
        let app = XCUIApplication()
        app.launchArguments += [
            "-ApplePersistenceIgnoreState", "YES",
            "-willdeep.onboarding.hasCompleted.v1", "NO",
        ]
        app.launch()

        XCTAssertTrue(
            app.staticTexts["onboarding.welcome.title"].waitForExistence(timeout: 5),
            "A clean launch should present onboarding from the default Agent window."
        )
    }

    @MainActor
    func testAgentHeaderDiffShortcutOpensSidePanel() throws {
        let app = XCUIApplication()
        app.launch()

        let diffShortcut = app.buttons["Diff"]
        XCTAssertTrue(diffShortcut.waitForExistence(timeout: 5))
        diffShortcut.click()

        XCTAssertTrue(
            app.staticTexts["Diff"].waitForExistence(timeout: 3),
            "Clicking the Agent header Diff shortcut should reveal the side panel."
        )
    }

    @MainActor
    func testLaunchPerformance() throws {
        // This measures how long it takes to launch your application.
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            XCUIApplication().launch()
        }
    }
}
