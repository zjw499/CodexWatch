import XCTest

final class ScribePilotUITests: XCTestCase {
    func testQueueRenameRemoveAndSettingsScreens() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-scribe-ui-preview"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Your recordings"].waitForExistence(timeout: 15))
        screenshot("phone-capture-queue")
        app.swipeUp()
        let actions = app.buttons["Actions for Team check-in"]
        XCTAssertTrue(actions.waitForExistence(timeout: 5))
        actions.tap()
        XCTAssertTrue(app.buttons["Rename"].waitForExistence(timeout: 15))
        app.buttons["Rename"].tap()
        let field = app.alerts.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 15))
        field.tap()
        if let old = field.value as? String { field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: old.count)) }
        field.typeText("Weekly review")
        app.alerts.buttons["Save"].tap()
        XCTAssertTrue(app.staticTexts["Weekly review"].waitForExistence(timeout: 5))
        app.buttons["Actions for Weekly review"].tap()
        app.buttons["Remove recording"].tap()
        let remove = app.buttons["Remove 1 recording"]
        XCTAssertTrue(remove.waitForExistence(timeout: 10))
        screenshot("phone-remove-confirmation")
        remove.tap()
        XCTAssertFalse(app.staticTexts["Weekly review"].exists)
        app.swipeDown()
        app.buttons["Open settings"].tap()
        XCTAssertTrue(app.staticTexts["Your AI workspace"].waitForExistence(timeout: 5))
        screenshot("phone-workspace-settings")
        app.swipeUp()
        screenshot("phone-privacy-workflow")
        app.buttons["Done"].tap()
        app.segmentedControls.buttons["Library · 1"].tap()
        if !app.buttons["Project kickoff"].isHittable { app.swipeUp() }
        XCTAssertTrue(app.buttons["Project kickoff"].waitForExistence(timeout: 15))
        app.buttons["Project kickoff"].tap()
        XCTAssertTrue(app.staticTexts["Full transcript"].waitForExistence(timeout: 5))
        screenshot("phone-transcript")
        app.buttons["Recording actions"].tap()
        app.buttons["Remove recording"].tap()
        XCTAssertTrue(app.buttons["Remove 1 recording"].waitForExistence(timeout: 10))
        app.buttons["Remove 1 recording"].tap()
        XCTAssertTrue(app.staticTexts["Your recordings"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["Project kickoff"].exists)
    }
    func testInvitationAndAssistantInterfaces() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-scribe-ui-preview", "-scribe-login-preview"]
        app.launch()
        app.buttons["Open settings"].tap()
        XCTAssertTrue(app.secureTextFields["Password"].waitForExistence(timeout: 20))
        app.segmentedControls.buttons["Accept invitation"].tap()
        XCTAssertTrue(app.textFields["Invitation code"].exists)
        XCTAssertTrue(app.secureTextFields["Repeat password"].exists)
        screenshot("phone-invitation-login")
        app.terminate()
        app.launchArguments = ["-scribe-ui-preview"]
        app.launch()
        app.buttons["Open settings"].tap()
        app.swipeUp()
        let create = app.buttons["Create assistant"]
        XCTAssertTrue(create.waitForExistence(timeout: 10))
        create.tap()
        XCTAssertTrue(app.textFields["Name"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.textViews.firstMatch.exists)
        screenshot("phone-assistant-editor")
        let voice = app.switches["Enable voice conversations"]
        if !voice.isHittable { app.swipeUp() }
        XCTAssertTrue(voice.waitForExistence(timeout: 15))
        let voiceControl = voice.descendants(matching: .switch).firstMatch
        XCTAssertTrue(voiceControl.waitForExistence(timeout: 15))
        voiceControl.tap()
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "1"), object: voiceControl)
        XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: 5), .completed)
        app.swipeUp()
        XCTAssertTrue(app.descendants(matching: .any)["assistant-voice-picker"].firstMatch.waitForExistence(timeout: 15))
        screenshot("phone-assistant-voice-editor")
    }
    func testFullRecordingReplayCoverageAndRetranscriptionControls() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-scribe-ui-preview", "-scribe-full-recording-preview"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Your recordings"].waitForExistence(timeout: 15))
        app.segmentedControls.buttons["Library · 1"].tap()
        if !app.buttons["Project kickoff"].isHittable { app.swipeUp() }
        XCTAssertTrue(app.buttons["Project kickoff"].waitForExistence(timeout: 15))
        app.buttons["Project kickoff"].tap()
        XCTAssertTrue(app.buttons["play-full-recording"].waitForExistence(timeout: 10))
        screenshot("phone-full-recording-replay")
        app.swipeUp()
        let transcribe = app.buttons["Transcribe again from saved audio"]
        XCTAssertTrue(transcribe.waitForExistence(timeout: 5))
        screenshot("phone-transcript-coverage")
        transcribe.tap()
        XCTAssertTrue(app.buttons["Transcribe again"].waitForExistence(timeout: 5))
        screenshot("phone-retranscription-confirmation")
    }
    private func screenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
    func testSavedAssistantHasKnowledgeFileUploadControls() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-scribe-ui-preview"]
        app.launch()
        app.buttons["Open settings"].tap()
        let assistant = app.buttons["assistant-editor-preview-assistant"]
        if !assistant.isHittable { app.swipeUp() }
        XCTAssertTrue(assistant.waitForExistence(timeout: 15))
        assistant.tap()
        let files = app.buttons["assistant-knowledge-files"]
        if !files.isHittable { app.swipeUp() }
        XCTAssertTrue(files.waitForExistence(timeout: 15))
        files.tap()
        XCTAssertTrue(app.buttons["knowledge-add-files"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["No knowledge files yet."].exists)
        screenshot("phone-assistant-knowledge-files")
    }
}
