import XCTest

final class RuneSmokeTests: XCTestCase {
    @MainActor private func launch(onboarding: Bool = false) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting", "--reset-ui"] + (onboarding ? [] : ["--skip-onboarding"])
        app.launch()
        return app
    }
    @MainActor private func screenshot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
    @MainActor func testOnboardingAndHome() {
        let app = launch(onboarding: true)
        for _ in 0..<3 { XCTAssertTrue(app.buttons["onboarding-next"].waitForExistence(timeout: 10)); app.buttons["onboarding-next"].tap() }
        XCTAssertTrue(app.buttons["start-demo"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.tabBars.buttons["工作台"].exists)
        screenshot(app, "01-today")
    }
    @MainActor func testReviewApplyAndUndo() {
        let app = launch()
        app.buttons["start-demo"].tap()
        XCTAssertTrue(app.buttons["review-change"].waitForExistence(timeout: 15))
        screenshot(app, "02-conversation-approval")
        app.buttons["review-change"].tap()
        XCTAssertTrue(app.buttons["apply-change"].waitForExistence(timeout: 5))
        screenshot(app, "03-diff-review")
        app.buttons["apply-change"].tap()
        app.buttons["confirm-apply"].firstMatch.tap()
        XCTAssertTrue(app.buttons["undo-change"].waitForExistence(timeout: 10))
        app.buttons["undo-change"].tap()
        app.buttons["confirm-undo"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["已撤销"].waitForExistence(timeout: 5))
        app.buttons["open-timeline"].tap()
        XCTAssertTrue(app.navigationBars["时间轴"].waitForExistence(timeout: 5))
        screenshot(app, "04-timeline")
    }
    @MainActor func testRejectKeepsOriginalFile() {
        let app = launch()
        app.buttons["start-demo"].tap()
        XCTAssertTrue(app.buttons["reject-change"].waitForExistence(timeout: 15))
        app.buttons["reject-change"].tap()
        XCTAssertTrue(app.staticTexts["已保留原文件"].waitForExistence(timeout: 5))
        app.buttons["close-conversation"].tap()
        app.tabBars.buttons["工作台"].tap()
        app.buttons["open-files"].tap()
        app.buttons["file-notes.md"].tap()
        XCTAssertTrue(app.staticTexts["file-content"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["file-content"].label.contains("[ ] 完成第一次文件审阅"))
    }
    @MainActor func testTaskCreationAndPersistence() {
        let app = launch()
        app.buttons["new-task"].tap()
        let field = app.textFields["task-prompt"]
        XCTAssertTrue(field.waitForExistence(timeout: 5)); field.tap(); field.typeText("Test task")
        app.buttons["submit-task"].tap()
        XCTAssertTrue(app.buttons["close-conversation"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "任务已保存在本机")).firstMatch.exists)
        app.terminate(); app.launchArguments = ["--uitesting", "--skip-onboarding"]; app.launch()
        app.tabBars.buttons["会话"].tap()
        XCTAssertTrue(app.buttons.containing(NSPredicate(format: "label CONTAINS %@", "Test task")).firstMatch.waitForExistence(timeout: 5))
        screenshot(app, "05-conversations")
    }
    @MainActor func testFileEditing() {
        let app = launch()
        app.tabBars.buttons["工作台"].tap()
        screenshot(app, "06-workbench")
        app.buttons["open-files"].tap()
        app.buttons["file-notes.md"].tap()
        app.buttons["edit-file"].tap()
        let editor = app.textViews["file-editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5)); editor.tap(); editor.typeText("Saved locally.\n")
        app.buttons["save-file"].tap()
        XCTAssertTrue(app.staticTexts["file-content"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["file-content"].label.contains("Saved locally."))
    }
    @MainActor func testProviderFormAndLiveActivitySettings() {
        let app = launch()
        app.buttons["open-settings"].tap()
        app.buttons["settings-providers"].tap()
        app.buttons["add-provider"].tap()
        XCTAssertFalse(app.buttons["save-provider"].isEnabled)
        app.textFields["provider-name"].tap(); app.textFields["provider-name"].typeText("My endpoint")
        app.textFields["provider-model"].tap(); app.textFields["provider-model"].typeText("test-model")
        XCTAssertTrue(app.buttons["save-provider"].isEnabled)
        app.buttons["save-provider"].tap()
        XCTAssertTrue(app.staticTexts["My endpoint"].waitForExistence(timeout: 5))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.buttons["settings-live"].tap()
        XCTAssertTrue(app.staticTexts["布局预览"].waitForExistence(timeout: 5))
        screenshot(app, "07-live-activity")
    }
    @MainActor func testCreateReusableSkill() {
        let app = launch()
        app.tabBars.buttons["工作台"].tap()
        app.buttons["open-skills"].tap()
        app.buttons["new-note"].tap()
        app.textFields["note-title"].tap(); app.textFields["note-title"].typeText("My skill")
        app.textViews["note-body"].tap(); app.textViews["note-body"].typeText("Read before editing.")
        app.buttons["save-note"].tap()
        XCTAssertTrue(app.staticTexts["My skill"].waitForExistence(timeout: 5))
    }
    @MainActor func testGoalChecklistAndCommands() {
        let app = launch()
        app.buttons["command-palette"].tap()
        XCTAssertTrue(app.navigationBars["快捷操作"].waitForExistence(timeout: 5))
        app.buttons["完成"].tap()
        app.tabBars.buttons["工作台"].tap()
        app.buttons["open-goals"].tap()
        app.buttons["new-goal"].tap()
        app.alerts.textFields.firstMatch.typeText("Prepare release")
        app.alerts.buttons["创建"].tap()
        app.buttons.containing(NSPredicate(format: "label CONTAINS %@", "Prepare release")).firstMatch.tap()
        app.textFields["goal-step-input"].tap(); app.textFields["goal-step-input"].typeText("Review files")
        app.buttons["add-goal-step"].tap()
        XCTAssertTrue(app.buttons["goal-step-0"].waitForExistence(timeout: 5))
        app.buttons["goal-step-0"].tap()
        XCTAssertTrue(app.staticTexts["1/1"].exists)
        screenshot(app, "08-goal")
    }
    @MainActor func testLiveActivityOnSpringBoard() {
        let app = launch()
        app.buttons["start-demo"].tap()
        XCTAssertTrue(app.buttons["review-change"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["live-activity-active"].waitForExistence(timeout: 5), "ActivityKit 没有成功创建活动")
        XCUIDevice.shared.press(.home)
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        XCTAssertTrue(springboard.wait(for: .runningForeground, timeout: 5))
        let iconReady = expectation(for: NSPredicate(format: "hittable == true"), evaluatedWith: springboard.icons["Rune"].firstMatch)
        wait(for: [iconReady], timeout: 8)
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "09-live-island-system"; attachment.lifetime = .keepAlways; add(attachment)
        springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.04)).press(forDuration: 1.1)
        XCTAssertTrue(springboard.staticTexts["完成第一次文件审阅"].waitForExistence(timeout: 5))
        let expanded = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        expanded.name = "10-live-island-expanded"; expanded.lifetime = .keepAlways; add(expanded)
        let open = springboard.buttons["审阅变更"].firstMatch
        if open.exists { open.tap() } else { app.activate() }
        XCTAssertTrue(app.buttons["review-change"].waitForExistence(timeout: 5))
    }

    @MainActor func testRuntimeApprovalSurvivesRelaunchAndWritesFile() {
        let app = XCUIApplication()
        continueAfterFailure = false
        app.launchArguments = ["--uitesting", "--reset-ui", "--skip-onboarding", "--runtime-fixture"]
        app.launch()
        app.buttons["new-task"].tap()
        let input = app.textFields["task-prompt"]
        XCTAssertTrue(input.waitForExistence(timeout: 5)); input.tap(); input.typeText("Runtime verification")
        app.buttons["submit-task"].tap()
        XCTAssertTrue(app.buttons["start-live-task"].waitForExistence(timeout: 8))
        app.buttons["start-live-task"].tap()
        XCTAssertTrue(app.buttons["approve-live-change"].waitForExistence(timeout: 15))
        app.terminate()
        app.launchArguments = ["--uitesting", "--skip-onboarding", "--runtime-fixture"]
        app.launch()
        app.buttons["open-active-task"].tap()
        XCTAssertTrue(app.buttons["approve-live-change"].waitForExistence(timeout: 10))
        app.buttons["approve-live-change"].tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "真实工具执行与落盘")).firstMatch.waitForExistence(timeout: 15))
        app.buttons["close-conversation"].tap()
        app.tabBars.buttons["工作台"].tap()
        app.buttons["open-files"].tap()
        app.buttons["file-notes.md"].tap()
        XCTAssertTrue(app.staticTexts["file-content"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["file-content"].label.contains("Runtime verified"))
        screenshot(app, "11-runtime-file-proof")
    }

}
