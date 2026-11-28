import XCTest

/// Captures the App Store scenes. Run on iPhone and iPad with the status bar
/// overridden to 9:41 and the simulator's hardware keyboard disconnected.
final class StoreScreenshotTests: XCTestCase {
    private let languages = [("en", "en_US"), ("ja", "ja_JP")]

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testStoreScreenshots() throws {
        for (language, locale) in languages {
            capture("1-sessions", language) { app in
                launch(app, language, locale, ["-autoOpenPermissionInbox", "NO"])
                XCTAssertTrue(app.buttons.matching(identifier: "permissionWaitingMenu").firstMatch.waitForExistence(timeout: 15))
            }
            capture("0-pane", language) { app in
                launch(app, language, locale, ["-autoOpenPermissionInbox", "NO", "-show_tmux_window_layout", "NO",
                                               "-direct_input_compose_enabled", "NO"])
                openClaudePane(app)
            }
            capture("2-layout", language) { app in
                launch(app, language, locale, ["-autoOpenPermissionInbox", "NO", "-show_tmux_window_layout", "YES",
                                               "-direct_input_compose_enabled", "NO"])
                openPane(app, session: "myproject", window: "main")
            }
            capture("3-keys", language) { app in
                launch(app, language, locale, ["-autoOpenPermissionInbox", "NO", "-direct_input_compose_enabled", "NO", "-store-screenshot-input"])
                openClaudePane(app)
                let showKeyboard = app.buttons["showKeyboardButton"]
                if showKeyboard.waitForExistence(timeout: 3) { showKeyboard.tap() }
                let control = app.buttons["accessoryControl"]
                XCTAssertTrue(control.waitForExistence(timeout: 5))
                control.tap()
            }
            capture("4-permissions", language) { app in
                launch(app, language, locale, ["-permission-ui-fixture", "-permission-store-fixture"])
                let inbox = app.buttons.matching(identifier: "permissionWaitingMenu").firstMatch
                XCTAssertTrue(inbox.waitForExistence(timeout: 15))
                inbox.tap()
                XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "permissionPager").firstMatch
                    .waitForExistence(timeout: 5))
            }
            capture("6-setup", language) { app in
                app.launchArguments = ["-demo_mode", "NO", "-AppleLanguages", "(\(language))", "-AppleLocale", locale]
                app.launch()
                XCTAssertTrue(app.buttons["qrcode.viewfinder"].waitForExistence(timeout: 10)
                              || app.staticTexts["Reattach"].waitForExistence(timeout: 1))
            }
        }
    }

    private func launch(_ app: XCUIApplication, _ language: String, _ locale: String, _ extra: [String]) {
        app.launchArguments = ["-demo_mode", "YES", "-store-screenshot",
                               "-AppleLanguages", "(\(language))", "-AppleLocale", locale] + extra
        app.launch()
    }

    private func openClaudePane(_ app: XCUIApplication) {
        openPane(app, session: "webapp", window: "claude")
    }

    private func openPane(_ app: XCUIApplication, session: String, window: String) {
        let pane = app.buttons.matching(NSPredicate(format: "label CONTAINS %@ AND label CONTAINS %@", window, session)).firstMatch
        XCTAssertTrue(pane.waitForExistence(timeout: 15))
        pane.tap()
        // A window with several panes expands into a pane list first.
        let firstPane = app.buttons.matching(NSPredicate(
            format: "label CONTAINS %@ AND (label BEGINSWITH %@ OR label BEGINSWITH %@)", session, "Pane 0", "ペイン 0")).firstMatch
        if firstPane.waitForExistence(timeout: 2) { firstPane.tap() }
        XCTAssertTrue(app.navigationBars[window].waitForExistence(timeout: 5))
        // The terminal text is too small to read at the default size on iPad.
        sleep(2)
    }

    @MainActor
    private func capture(_ name: String, _ language: String, _ prepare: (XCUIApplication) -> Void) {
        let app = XCUIApplication()
        prepare(app)
        sleep(1)
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "\(name)-\(language)"
        attachment.lifetime = .keepAlways
        add(attachment)
        app.terminate()
    }
}
