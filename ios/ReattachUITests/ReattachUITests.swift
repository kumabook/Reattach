//
//  ReattachUITests.swift
//  ReattachUITests
//

import XCTest

final class ReattachUITests: XCTestCase {

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
    func testPermissionMenuNavigatesBetweenWaitingPanes() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-demo_mode", "YES", "-permission-ui-fixture"]
        app.launch()
        let menu = app.buttons.matching(identifier: "permissionWaitingMenu").firstMatch
        let menuExists = menu.waitForExistence(timeout: 15)
        if !menuExists { print(app.debugDescription) }
        XCTAssertTrue(menuExists)
        XCTAssertTrue(menu.label.contains("2"))
        menu.tap()
        let first = app.buttons["claude-demo:0.0"]
        XCTAssertTrue(first.waitForExistence(timeout: 5))
        first.tap()
        XCTAssertTrue(app.navigationBars["claude"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.otherElements["permissionWaitingBanner"].exists)
        XCTAssertTrue(app.buttons["permissionEnterButton"].waitForExistence(timeout: 5))
        let keyboardIntroduction = app.buttons["Continue"]
        if keyboardIntroduction.exists && keyboardIntroduction.isHittable { keyboardIntroduction.tap() }
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Permission waiting on another pane"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        menu.tap()
        let second = app.buttons["myproject:0.0"]
        XCTAssertTrue(second.waitForExistence(timeout: 5))
        second.tap()
        XCTAssertTrue(app.navigationBars["main"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testTextSizePopover() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-demo_mode", "YES", "-permission-ui-fixture"]
        app.launch()
        let waiting = app.buttons.matching(identifier: "permissionWaitingMenu").firstMatch
        XCTAssertTrue(waiting.waitForExistence(timeout: 15))
        waiting.tap()
        app.buttons["claude-demo:0.0"].tap()
        XCTAssertTrue(app.navigationBars["claude"].waitForExistence(timeout: 5))
        let size = app.buttons["textSizeButton"]
        if size.isHittable {
            size.tap()
        } else {
            app.buttons["More"].firstMatch.tap()
            let overflowSize = app.buttons["文字サイズ"]
            XCTAssertTrue(overflowSize.waitForExistence(timeout: 5))
            overflowSize.tap()
        }
        let slider = app.sliders.firstMatch
        XCTAssertTrue(slider.waitForExistence(timeout: 5))
        slider.adjust(toNormalizedSliderPosition: 0.5)
        // XCUI slider dragging is approximate; verify the displayed zoom changed.
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label MATCHES %@", "2[0-9]{2}%"))
            .firstMatch.waitForExistence(timeout: 5))
        app.buttons["標準に戻す"].tap()
        XCTAssertTrue(app.staticTexts["100%"].waitForExistence(timeout: 5))
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Text size popover"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    @MainActor
    func testExample() throws {
        // UI tests must launch the application that they test.
        let app = XCUIApplication()
        app.launch()

        // Use XCTAssert and related functions to verify your tests produce the correct results.
    }

    @MainActor
    func testLaunchPerformance() throws {
        // This measures how long it takes to launch your application.
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            XCUIApplication().launch()
        }
    }
}
