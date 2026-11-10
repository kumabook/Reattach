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
    func testNewWindowWithoutSelectedPane() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-demo_mode", "YES", "-window-create-ui-fixture",
                               "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        let create = app.buttons["newWindow"].firstMatch
        XCTAssertTrue(create.waitForExistence(timeout: 15))
        XCTAssertTrue(create.isEnabled)
        create.tap()
        let destination = app.buttons["myproject"].firstMatch
        XCTAssertTrue(destination.waitForExistence(timeout: 5))
        destination.tap()
        XCTAssertTrue(app.navigationBars["created-window"].waitForExistence(timeout: 10))
    }

    @MainActor
    func testPermissionInboxCanCloseAfterAllReplies() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-demo_mode", "YES", "-permission-ui-fixture",
                               "-permission-choice-fixture", "-permission-complete-fixture",
                               "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        let inbox = app.buttons.matching(identifier: "permissionWaitingMenu").firstMatch
        XCTAssertTrue(inbox.waitForExistence(timeout: 15))
        inbox.tap()
        for target in ["myproject:0.0", "claude-demo:0.0"] {
            let allow = app.buttons["permissionChoice-\(target)-1"]
            XCTAssertTrue(allow.waitForExistence(timeout: 10))
            allow.tap()
        }
        let close = app.buttons["closeEmptyPermissionInbox"]
        XCTAssertTrue(close.waitForExistence(timeout: 10))
        XCTAssertTrue(close.isHittable)
        close.tap()
        XCTAssertTrue(inbox.waitForExistence(timeout: 5))
        inbox.tap()
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        close.tap()
        XCTAssertTrue(inbox.waitForExistence(timeout: 5))
    }

    @MainActor
    func testPermissionStoreScreenshots() throws {
        for language in ["en", "ja"] {
            let app = XCUIApplication()
            app.launchArguments = ["-demo_mode", "YES", "-permission-ui-fixture", "-permission-store-fixture",
                                   "-AppleLanguages", "(\(language))", "-AppleLocale", language == "ja" ? "ja_JP" : "en_US"]
            app.launch()
            let inbox = app.buttons.matching(identifier: "permissionWaitingMenu").firstMatch
            XCTAssertTrue(inbox.waitForExistence(timeout: 15))
            inbox.tap()
            let pager = app.descendants(matching: .any).matching(identifier: "permissionPager").firstMatch
            XCTAssertTrue(pager.waitForExistence(timeout: 5))
            pager.swipeLeft()
            let choice = app.buttons["permissionChoice-claude-demo:0.0-3"]
            XCTAssertTrue(choice.waitForExistence(timeout: 5))
            XCTAssertTrue(choice.isHittable)
            let screenshot = XCTAttachment(screenshot: app.screenshot())
            screenshot.name = "Permission Store — \(language)"
            screenshot.lifetime = .keepAlways
            add(screenshot)
            app.terminate()
        }
    }

    @MainActor
    func testPermissionInboxRepliesWithoutOpeningPane() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-demo_mode", "YES", "-permission-ui-fixture",
                               "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        let inbox = app.buttons.matching(identifier: "permissionWaitingMenu").firstMatch
        XCTAssertTrue(inbox.waitForExistence(timeout: 15))
        inbox.tap()
        XCTAssertTrue(app.navigationBars["Pending Requests"].waitForExistence(timeout: 5))
        let enter = app.buttons["permissionInboxEnter-myproject:0.0"]
        XCTAssertTrue(enter.waitForExistence(timeout: 10))
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: enter)
        waitForExpectations(timeout: 10)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Permission inbox"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        enter.tap()
        XCTAssertTrue(app.staticTexts["Sent. Waiting for the agent…"].waitForExistence(timeout: 5))
        XCTAssertFalse(enter.isEnabled)
        XCTAssertTrue(app.navigationBars["Pending Requests"].exists)
    }

    @MainActor
    func testPermissionInboxShowsAndSendsChoices() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-demo_mode", "YES", "-permission-ui-fixture", "-permission-choice-fixture",
                               "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        let inbox = app.buttons.matching(identifier: "permissionWaitingMenu").firstMatch
        XCTAssertTrue(inbox.waitForExistence(timeout: 15))
        inbox.tap()
        let allow = app.buttons["permissionChoice-myproject:0.0-1"]
        let deny = app.buttons["permissionChoice-myproject:0.0-3"]
        XCTAssertTrue(deny.waitForExistence(timeout: 10))
        XCTAssertTrue(allow.label.contains("Yes, proceed (y)"))
        XCTAssertTrue(deny.label.contains("No, and tell Codex"))
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Permission choices"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        deny.tap()
        XCTAssertTrue(app.staticTexts["Sent. Waiting for the agent…"].waitForExistence(timeout: 5))
        XCTAssertFalse(allow.isEnabled)
        XCTAssertTrue(app.navigationBars["Pending Requests"].exists)
    }

    @MainActor
    func testPermissionFeedPagesAndExpandsContextInPlace() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-demo_mode", "YES", "-permission-ui-fixture", "-permission-choice-fixture",
                               "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        let inbox = app.buttons.matching(identifier: "permissionWaitingMenu").firstMatch
        XCTAssertTrue(inbox.waitForExistence(timeout: 15))
        inbox.tap()
        let counter = app.descendants(matching: .any).matching(identifier: "permissionPager").firstMatch
        XCTAssertTrue(counter.waitForExistence(timeout: 5))
        XCTAssertEqual(counter.value as? String, "1 / 2")
        let preview = app.descendants(matching: .any).matching(identifier: "permissionPreview-myproject:0.0").firstMatch
        XCTAssertTrue(preview.waitForExistence(timeout: 5))
        preview.press(forDuration: 1)
        let close = app.buttons["closePermissionContext"]
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        let expanded = XCTAttachment(screenshot: app.screenshot())
        expanded.name = "Expanded permission context"
        expanded.lifetime = .keepAlways
        add(expanded)
        close.tap()
        XCTAssertTrue(close.waitForNonExistence(timeout: 5))
        XCTAssertEqual(counter.value as? String, "1 / 2")
        app.buttons["permissionChoice-myproject:0.0-1"].swipeUp()
        XCTAssertEqual(counter.value as? String, "1 / 2")
        app.buttons["permissionChoice-myproject:0.0-1"].swipeLeft()
        expectation(for: NSPredicate(format: "value == %@", "2 / 2"), evaluatedWith: counter)
        waitForExpectations(timeout: 5)
        XCTAssertTrue(app.buttons["claude-demo:0.0"].isHittable)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Full-screen permission feed"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        app.descendants(matching: .any).matching(identifier: "permissionPager").firstMatch.swipeRight()
        expectation(for: NSPredicate(format: "value == %@", "1 / 2"), evaluatedWith: counter)
        waitForExpectations(timeout: 5)
        XCTAssertFalse(app.staticTexts["Sent. Waiting for the agent…"].exists)
        app.buttons["permissionChoice-myproject:0.0-3"].tap()
        XCTAssertTrue(app.staticTexts["Sent. Waiting for the agent…"].waitForExistence(timeout: 5))
        app.descendants(matching: .any).matching(identifier: "permissionPager").firstMatch.swipeLeft()
        app.descendants(matching: .any).matching(identifier: "permissionPager").firstMatch.swipeRight()
        XCTAssertFalse(app.buttons["permissionChoice-myproject:0.0-1"].isEnabled)
    }

    @MainActor
    func testPermissionPreviewScrollsWholeCard() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-demo_mode", "YES", "-permission-ui-fixture", "-permission-scroll-fixture",
                               "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
                               "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryXXXL"]
        app.launch()
        let inbox = app.buttons.matching(identifier: "permissionWaitingMenu").firstMatch
        XCTAssertTrue(inbox.waitForExistence(timeout: 15))
        inbox.tap()
        let preview = app.descendants(matching: .any).matching(identifier: "permissionPreview-myproject:0.0").firstMatch
        XCTAssertTrue(preview.waitForExistence(timeout: 5))
        let initialY = preview.frame.minY
        preview.swipeUp()
        XCTAssertLessThan(preview.frame.minY, initialY - 40)
        XCTAssertFalse(app.buttons["closePermissionContext"].exists)
        let pager = app.descendants(matching: .any).matching(identifier: "permissionPager").firstMatch
        XCTAssertEqual(pager.value as? String, "1 / 2")
        XCTAssertFalse(app.staticTexts["Sent. Waiting for the agent…"].exists)
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
        func openDisplayMenu() {
            let menu = app.buttons["windowLayoutMenu"]
            if menu.waitForExistence(timeout: 5) && menu.isHittable { menu.tap() }
            else {
                app.buttons.matching(NSPredicate(format: "label == %@", "More")).firstMatch.tap()
                app.buttons["Display Mode"].tap()
            }
        }
        openDisplayMenu()
        XCTAssertTrue(app.buttons["Selected Pane Only"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Match tmux Layout"].exists)
        XCTAssertFalse(app.buttons["splitPaneLeftRight"].exists)
        XCTAssertFalse(app.buttons["splitPaneTopBottom"].exists)
        app.buttons["Match tmux Layout"].tap()
        XCTAssertTrue(lowerRight.waitForExistence(timeout: 10))
        openDisplayMenu()
        XCTAssertTrue(app.buttons["splitPaneLeftRight"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["splitPaneTopBottom"].exists)
        app.buttons["Match tmux Layout"].tap()
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
        openDisplayMenu()
        app.buttons["Selected Pane Only"].tap()
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
        app.descendants(matching: .any).matching(identifier: "permissionPager").firstMatch.swipeLeft()
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
                app.buttons.matching(NSPredicate(format: "label == %@", "More")).firstMatch.tap()
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
