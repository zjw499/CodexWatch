import XCTest

final class ScribePilotUITests: XCTestCase {
    func testQueueRenameRemoveAndSettingsScreens() {
        let app = XCUIApplication()
        app.launchArguments = ["-scribe-ui-preview"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Your recordings"].waitForExistence(timeout: 15))
        screenshot("phone-capture-queue")
        app.swipeUp()
        let actions = app.buttons["Actions for Team check-in"]
        XCTAssertTrue(actions.waitForExistence(timeout: 5))
        actions.tap()
        app.buttons["Rename"].tap()
        let field = app.alerts.textFields.firstMatch
        field.tap()
        if let old = field.value as? String { field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: old.count)) }
        field.typeText("Weekly review")
        app.alerts.buttons["Save"].tap()
        XCTAssertTrue(app.staticTexts["Weekly review"].waitForExistence(timeout: 5))
        app.buttons["Actions for Weekly review"].tap()
        app.buttons["Remove recording"].tap()
        app.buttons["Remove 1 recording"].tap()
        XCTAssertFalse(app.staticTexts["Weekly review"].exists)
        app.swipeDown()
        app.buttons["Open settings"].tap()
        XCTAssertTrue(app.secureTextFields.firstMatch.waitForExistence(timeout: 5))
        screenshot("phone-openai-settings")
        app.swipeUp()
        screenshot("phone-privacy-workflow")
        app.buttons["Cancel"].tap()
        app.segmentedControls.buttons["Library · 1"].tap()
        app.swipeUp()
        app.buttons["Project kickoff"].tap()
        XCTAssertTrue(app.staticTexts["Full transcript"].waitForExistence(timeout: 5))
        screenshot("phone-transcript")
    }
    private func screenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
