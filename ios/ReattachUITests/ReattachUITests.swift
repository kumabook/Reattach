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
    func testWindowLayoutSelectionAndRotation() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-demo_mode", "YES", "-permission-ui-fixture",
                               "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        let waiting = app.buttons.matching(identifier: "permissionWaitingMenu").firstMatch
        XCTAssertTrue(waiting.waitForExistence(timeout: 15))
        waiting.tap()
        app.buttons["myproject:0.0"].tap()
        let left = app.descendants(matching: .any).matching(identifier: "layoutPane-myproject:0.0").firstMatch
        let upperRight = app.descendants(matching: .any).matching(identifier: "layoutPane-myproject:0.1").firstMatch
        let lowerRight = app.descendants(matching: .any).matching(identifier: "layoutPane-myproject:0.2").firstMatch
        if !lowerRight.waitForExistence(timeout: 3) {
            let toggle = app.buttons["windowLayoutToggle"]
            if toggle.exists && toggle.isHittable { toggle.tap() }
            else {
                app.buttons["BottomOverflowBarButtonItem"].firstMatch.tap()
                app.buttons["Window Layout"].tap()
            }
        }
        XCTAssertTrue(lowerRight.waitForExistence(timeout: 10))
        XCTAssertLessThan(left.frame.minX, upperRight.frame.minX)
        XCTAssertLessThan(upperRight.frame.minY, lowerRight.frame.minY)
        // Dragging an unselected pane must scroll without changing the input target.
        upperRight.swipeLeft()
        upperRight.swipeUp()
        XCTAssertEqual(left.value as? String, "Selected")
        XCTAssertNotEqual(upperRight.value as? String, "Selected")
        lowerRight.tap()
        let selected = NSPredicate(format: "value == %@", "Selected")
        expectation(for: selected, evaluatedWith: lowerRight)
        waitForExpectations(timeout: 10)
        for orientation in [UIDeviceOrientation.landscapeLeft, .portrait] {
            XCUIDevice.shared.orientation = orientation
            XCTAssertTrue(left.waitForExistence(timeout: 5))
            XCTAssertTrue(lowerRight.exists)
            XCTAssertLessThan(left.frame.minX, upperRight.frame.minX)
            XCTAssertLessThan(upperRight.frame.minY, lowerRight.frame.minY)
            let screenshot = XCTAttachment(screenshot: app.screenshot())
            screenshot.name = "tmux mixed layout — \(orientation.rawValue)"
            screenshot.lifetime = .keepAlways
            add(screenshot)
        }
        let toggle = app.buttons["windowLayoutToggle"]
        if toggle.exists && toggle.isHittable {
            toggle.tap()
        } else {
            app.buttons["BottomOverflowBarButtonItem"].firstMatch.tap()
            app.buttons["Single Pane"].tap()
        }
        XCTAssertTrue(lowerRight.waitForNonExistence(timeout: 5))
    }

    @MainActor
    func testPermissionMenuNavigatesBetweenWaitingPanes() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-demo_mode", "YES", "-permission-ui-fixture", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
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
        app.launchArguments = ["-demo_mode", "YES", "-permission-ui-fixture", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        let waiting = app.buttons.matching(identifier: "permissionWaitingMenu").firstMatch
        XCTAssertTrue(waiting.waitForExistence(timeout: 15))
        waiting.tap()
        app.buttons["claude-demo:0.0"].tap()
        XCTAssertTrue(app.navigationBars["claude"].waitForExistence(timeout: 5))
        let size = app.buttons["textSizeButton"]
        if size.exists && size.isHittable {
            size.tap()
        } else {
            app.buttons["BottomOverflowBarButtonItem"].firstMatch.tap()
            let overflowSize = app.buttons["Text Size"]
            XCTAssertTrue(overflowSize.waitForExistence(timeout: 5))
            overflowSize.tap()
        }
        let slider = app.sliders.firstMatch
        XCTAssertTrue(slider.waitForExistence(timeout: 5))
        slider.adjust(toNormalizedSliderPosition: 0.5)
        // XCUI slider dragging is approximate; verify the displayed zoom changed.
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label MATCHES %@", "2[0-9]{2}%"))
            .firstMatch.waitForExistence(timeout: 5))
        app.buttons["Reset to Default"].tap()
        XCTAssertTrue(app.staticTexts["100%"].waitForExistence(timeout: 5))
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Text size popover"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    @MainActor
    func testLocalizedTerminalControls() throws {
        for (language, locale, waitingLabel, textSize, copyMenu) in [
            ("en", "en_US", "2 pending requests", "Text Size", "Copy and Paste"),
            ("ja", "ja_JP", "許可待ち 2件", "文字サイズ", "コピーと貼り付け")
        ] {
            let app = XCUIApplication()
            app.launchArguments = ["-demo_mode", "YES", "-permission-ui-fixture",
                                   "-AppleLanguages", "(\(language))", "-AppleLocale", locale]
            app.launch()
            let waiting = app.buttons.matching(identifier: "permissionWaitingMenu").firstMatch
            XCTAssertTrue(waiting.waitForExistence(timeout: 15))
            XCTAssertEqual(waiting.label, waitingLabel)
            waiting.tap()
            app.buttons["claude-demo:0.0"].tap()
            XCTAssertTrue(app.navigationBars["claude"].waitForExistence(timeout: 5))
            let size = app.buttons["textSizeButton"]
            if size.exists {
                XCTAssertEqual(size.label, textSize)
                XCTAssertEqual(app.buttons["clipboardMenu"].label, copyMenu)
            } else {
                app.buttons["BottomOverflowBarButtonItem"].firstMatch.tap()
                XCTAssertTrue(app.buttons[textSize].exists)
                XCTAssertTrue(app.buttons[copyMenu].exists)
                XCTAssertTrue(app.buttons[language == "ja" ? "文章入力" : "Compose"].exists)
                XCTAssertTrue(app.buttons[language == "ja" ? "表示するペイン" : "Pane Selection"].exists)
            }
            let screenshot = XCTAttachment(screenshot: app.screenshot())
            screenshot.name = "Terminal controls — \(language)"
            screenshot.lifetime = .keepAlways
            add(screenshot)
            app.terminate()
        }
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
