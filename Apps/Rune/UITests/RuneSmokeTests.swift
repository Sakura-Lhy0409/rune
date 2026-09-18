import XCTest

// MARK: - UI 冒烟测试
//
// ⚠️ 为什么只做"冒烟"：
// 在没有 Mac 的环境里（docs/16），UI 测试是**唯一**能自动回答
// "App 在真的 iOS 运行时里起来了、而且真的跑通了内核"这件事的东西。
// 真机上装不上、启动就崩、或者内核在 iOS 上行为不同 —— 这三种失败
// 都只有"在 iOS 上真的跑一次"才能发现。
//
// 所以它不测界面长什么样（那会随设计变），只测**它能不能起来并跑完一次内核运行**。

final class RuneSmokeTests: XCTestCase {

    override func setUp() {
        continueAfterFailure = false
    }

    /// 把界面上此刻的文字打出来。
    ///
    /// ⚠️ 为什么这件事必须做：CI 跑在 GitHub 的 macOS 上，而我们手边**没有 Mac** ——
    ///    失败细节都在 `.xcresult` 里，而那个 bundle 在 Windows 上读不了。
    ///    **而 CI 日志是能读的。** 所以"屏幕上到底有什么"必须主动打到 stdout 去，
    ///    否则每修一次都要靠猜（这和修 VFS 那个 macOS bug 时是同一个教训：
    ///    断言失败信息里必须有**实际值**）。
    private func dumpVisibleText(_ app: XCUIApplication, _ stage: String) {
        let texts = app.staticTexts.allElementsBoundByIndex.prefix(60).map(\.label).filter { !$0.isEmpty }
        print("=== [\(stage)] 界面文字（\(texts.count) 条）===")
        for text in texts { print("  · \(text)") }
        let buttons = app.buttons.allElementsBoundByIndex.prefix(20).map(\.label).filter { !$0.isEmpty }
        print("=== [\(stage)] 按钮：\(buttons.joined(separator: " ｜ "))")
        print("=== [\(stage)] 导航栏：\(app.navigationBars.allElementsBoundByIndex.map(\.identifier).joined(separator: " ｜ "))")
    }

    @MainActor
    func testAppLaunchesAndRunsTheKernel() throws {
        let app = XCUIApplication()
        app.launch()

        // ① App 起来了，标题在
        let bar = app.navigationBars["Rune"].waitForExistence(timeout: 30)
        if !bar { dumpVisibleText(app, "启动后（没等到导航栏）") }
        XCTAssertTrue(bar, "App 没起来（或者启动就崩了）")
        dumpVisibleText(app, "启动后")

        // ② 能触发一次运行
        let runButton = app.buttons["在设备上跑一遍内核"]
        if !runButton.waitForExistence(timeout: 10) { dumpVisibleText(app, "找不到运行按钮") }
        XCTAssertTrue(runButton.exists, "找不到运行按钮")
        runButton.tap()

        // ③ 跑完之后能看到时间轴 —— 这一条同时证明了：
        //    TurnRunner 跑完了、工具执行器被调用了、事件日志写进去了。
        let timeline = app.staticTexts["时间轴（来自事件日志）"].waitForExistence(timeout: 60)
        if !timeline { dumpVisibleText(app, "点完之后（没等到时间轴）") }
        XCTAssertTrue(timeline, "内核没有跑完 —— 可能卡住了，或者在 iOS 上崩了")
        dumpVisibleText(app, "跑完之后")

        // ④ 哈希链校验通过（"事件日志是唯一真相源"这句话的运行时证据）
        XCTAssertTrue(app.staticTexts["链校验通过"].waitForExistence(timeout: 10),
                      "事件哈希链校验未通过")

        // ⑤ ⭐ 磁盘上的文件**真的被改了** —— 这是"Agent 能改设备上的文件"的运行时证据
        //    （上面那条只证明它跑完了；这条证明它真的动了文件。）
        XCTAssertTrue(app.staticTexts["工作区（磁盘上的真实内容）"].waitForExistence(timeout: 10),
                      "没有看到工作区面板")
        XCTAssertTrue(app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS %@", "这一行是 Agent 自己勾上的")
        ).firstMatch.waitForExistence(timeout: 10),
                      "notes.md 里被改的那一行没有出现在界面上 —— 文件可能没真的被改")

        // ⑥ 截一张图作为产物 —— 没有 Mac 的话，这是唯一能"看到"界面的方式
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "rune-after-run"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}

