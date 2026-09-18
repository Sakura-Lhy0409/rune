import XCTest

/// 真渠道验收：**像真人一样，一步一步手动走完**。
///
/// ⚠️ 与 `RuneSmokeTests` 的区别：那些用的是 `--runtime-fixture`（脚本化模型），
///    验的是"界面与链路对不对"；这一条**用真实渠道、真实模型、真实网络**，
///    验的是"装到手机上，一个真人能不能配好并让它干活"。
///
/// ⚠️ API Key **不写在代码里**：从环境变量 `RUNE_E2E_API_KEY` 读
///    （在 scheme 里声明继承，值由跑测试的人在自己的 shell 给）。
///    没有它就 `XCTSkip` —— **明确跳过，不假装通过**（"跳过"既不是通过也不是失败）。
final class RuneLiveProviderTests: XCTestCase {

    private var key: String { ProcessInfo.processInfo.environment["RUNE_E2E_API_KEY"] ?? "" }
    private var baseURL: String { ProcessInfo.processInfo.environment["RUNE_E2E_BASE_URL"] ?? "https://api.deepseek.com" }
    private var model: String { ProcessInfo.processInfo.environment["RUNE_E2E_MODEL"] ?? "deepseek-v4-pro" }

    @MainActor private func screenshot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        // ⚠️ T56：`.xcresult` 在别的机器上读不了，所以**同时把关键信息打到 stdout**，
        //    CI 日志里也能看见（这次是本机跑，但我保留这个习惯）。
        print("SCREENSHOT \(name)")
    }

    /// 把当前界面上的可点元素打出来 —— 失败时能一眼看出"我当时看到的是什么"。
    @MainActor private func dumpUI(_ app: XCUIApplication, _ label: String) {
        let buttons = app.buttons.allElementsBoundByIndex.prefix(25).map { "[\($0.identifier)|\($0.label)]" }
        let fields = app.textFields.allElementsBoundByIndex.prefix(10).map { "[\($0.identifier)]" }
        print("UI-DUMP \(label) buttons=\(buttons.joined()) fields=\(fields.joined())")
    }

    @MainActor func testConfigureRealProviderByHandAndRunATask() throws {
        try XCTSkipIf(key.isEmpty, "未提供 RUNE_E2E_API_KEY；跳过真渠道验收（不算通过）")
        continueAfterFailure = false

        let app = XCUIApplication()
        app.launchArguments = ["--uitesting", "--reset-ui", "--skip-onboarding"]
        app.launch()

        // ── 第 1 步：从主界面进设置 ────────────────────────────────
        XCTAssertTrue(app.buttons["open-settings"].waitForExistence(timeout: 15), "主界面没有设置入口")
        screenshot(app, "e2e-01-home")
        app.buttons["open-settings"].tap()

        // ── 第 2 步：进「渠道与模型」 ──────────────────────────────
        XCTAssertTrue(app.buttons["settings-providers"].waitForExistence(timeout: 10), "设置里没有渠道入口")
        app.buttons["settings-providers"].tap()
        screenshot(app, "e2e-02-providers-empty")

        // ── 第 3 步：添加渠道 ─────────────────────────────────────
        XCTAssertTrue(app.buttons["add-provider"].waitForExistence(timeout: 10), "找不到「添加渠道」")
        app.buttons["add-provider"].tap()
        screenshot(app, "e2e-03-form")

        // ── 第 4 步：逐个填字段（**像真人一样先点输入框再打字**）────────
        XCTAssertFalse(app.buttons["save-provider"].isEnabled, "空表单不该允许保存")

        // ⚠️⚠️ 这一节我第一版写错了，代价很大，记下来：
        //    4 次 `typeText` **一个都没落进去**（点字段前没确认它在可视区域，
        //    `tap()` 没聚焦，字打进了虚空）。而我没在填完后**立刻**断言字段里有值，
        //    于是错误以「测试连接 → HTTP 404」的面目出现在 5 步之后，极难归因 ——
        //    看起来像 App 的网络层坏了，实际是我的测试没把字打进去。
        //    修法：**每填一个字段就立刻回读并断言**（见 `fill`），让错误在原地暴露。
        // ⚠️ 第二版又错了一次，同样值得记：表单**预填了 OpenAI 的 URL**
        //    （`https://api.openai.com/v1`），而 `typeText` 是**追加**不是替换 ——
        //    结果拼成了 `https://api.openai.com/https://api.deepseek.comv1`。
        //    所以必须先**清空**再填。真人也是这么做的（长按全选删除，或用快速填写）。
        // ⚠️ 第三版：仍然被 URL 键盘的**自动补全**干扰（清空后打字，补全把建议插了进来，
        //    回读出 `https://api.deepseek.comv1`）。真人遇到这种情况会**粘贴**而不是继续敲。
        //    所以这里也粘贴 —— 顺带这更接近真人的实际做法（从别处复制 Base URL）。
        //
        //    ⚠️ 还要先点「自定义渠道」：表单默认预填 OpenAI 的 URL，
        //    而从"空 URL 起点"开始才符合真人配第三方渠道的路径。
        @MainActor func paste(_ element: XCUIElement, _ text: String, _ label: String) {
            XCTAssertTrue(element.waitForExistence(timeout: 10), "\(label)：字段不存在")
            while !element.isHittable { app.swipeUp() }
            UIPasteboard.general.string = text
            element.tap()
            element.press(forDuration: 1.2)
            let pasteItem = app.menuItems["粘贴"]
            let byLabel = app.menuItems["Paste"]
            if pasteItem.waitForExistence(timeout: 3) { pasteItem.tap() }
            else if byLabel.waitForExistence(timeout: 3) { byLabel.tap() }
            else { XCTFail("\(label)：长按后没有出现「粘贴」菜单") }
            if label != "API Key" {
                let actual = element.value as? String ?? ""
                XCTAssertEqual(actual, text, "\(label)：粘贴后回读不一致（实际「\(actual)」）")
                print("FILLED \(label) = \(actual)")
            } else {
                print("FILLED \(label) = (已输入，不回显)")
            }
        }

        @MainActor func fillName(_ text: String) {
            let element = app.textFields["provider-name"]
            XCTAssertTrue(element.waitForExistence(timeout: 10), "名称：字段不存在")
            while !element.isHittable { app.swipeUp() }
            element.tap()
            element.clearAndEnterText(text)
            let actual = element.value as? String ?? ""
            XCTAssertEqual(actual, text, "名称：回读不一致（实际「\(actual)」）")
            print("FILLED 名称 = \(actual)")
        }

        // 真人路径：先点「自定义渠道」拿一个干净起点。
        // ⚠️⚠️ 第四版才想明白前几版为什么反复失败：**我一直没确认"清空到底成没成功"就往下填**。
        //    表单预填 OpenAI 的 URL，而无论是 `typeText`、"全选后打字" 还是 "粘贴"，
        //    在**没有真正清空**的字段上都表现为"把新值拼在旧值后面" ——
        //    于是每次都得等回读断言报错才知道，而错误文本 `https://api.openai.com/<我填的>v1`
        //    看起来像 App 把 URL 拼错了。
        // ⚠️ 它在表单下方（屏幕外），必须先滚动到它可见 —— 之前用 `exists` 判断是错的：
        //    `exists` 对**已经渲染但在屏幕外**的元素也可能为 false/true 不稳定，
        //    而 `isHittable` 才回答"我现在能不能点它"。判据用错会得到误导性的"找不到按钮"。
        let preset = app.buttons["自定义渠道"]
        var scrolls = 0
        while !preset.isHittable && scrolls < 8 { app.swipeUp(); scrolls += 1 }
        XCTAssertTrue(preset.isHittable, "滚了 \(scrolls) 次仍点不到「自定义渠道」")
        preset.tap()
        screenshot(app, "e2e-03b-custom-preset")

        // ⚠️ 预设按钮在表单**底部**，点完之后必须**滚回顶部** ——
        //    否则 URL 输入框还在屏幕外，"找不到 URL 输入框"就是这么来的。
        for _ in 0..<8 { app.swipeDown() }

        // ⚠️ 硬断言：预设之后 URL **必须是空的** —— 这是后面粘贴能生效的前提。
        //    不确认这一点，后面的失败会以各种面目出现（拼串、404、校验不过）。
        let urlField = app.textFields["provider-url"]
        XCTAssertTrue(urlField.waitForExistence(timeout: 10), "没有 URL 输入框")
        let urlAfterPreset = (urlField.value as? String) ?? ""
        XCTAssertTrue(urlAfterPreset.isEmpty || urlAfterPreset == "HTTPS Base URL",
                      "点了「自定义渠道」之后 URL 仍非空：「\(urlAfterPreset)」—— 粘贴会拼在它后面")
        print("PRESET-OK URL 已清空（回读「\(urlAfterPreset)」）")

        fillName("DeepSeek 官方")
        paste(app.textFields["provider-model"], model, "模型 ID")
        paste(app.textFields["provider-url"], baseURL, "Base URL")
        paste(app.secureTextFields["provider-key"], key, "API Key")

        screenshot(app, "e2e-04-form-filled")
        dumpUI(app, "已填完表单")

        // ── 第 5 步：先测连接（真人一定会先点这个）──────────────────
        let testButton = app.buttons["测试连接"]
        if testButton.exists && testButton.isEnabled {
            testButton.tap()
            // 成功会插入一条带对勾的 Label；失败会显示错误文本
            let ok = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "可用")).firstMatch
            let failed = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "失败")).firstMatch
            let deadline = Date().addingTimeInterval(40)
            while Date() < deadline && !ok.exists && !failed.exists { usleep(400_000) }
            screenshot(app, "e2e-05-test-connection")
            XCTAssertFalse(failed.exists, "「测试连接」失败了：\(failed.label)")
        }

        // ── 第 6 步：保存 ────────────────────────────────────────
        XCTAssertTrue(app.buttons["save-provider"].isEnabled, "填完了保存仍不可用")
        app.buttons["save-provider"].tap()

        // ⚠️⚠️ 这里我第五版才搞对：`save-provider` 的 action 是
        //    `saveProvider(...)` **然后 `dismiss()`** —— 它会把整张表单关掉。
        //    而我原来的断言却在"同一张表单里找刚存的渠道"，自然找不到，
        //    报出来却是"保存失败"，方向完全错了。
        //    正确的验法是**重新进列表看它在不在** —— 这也正是真人确认保存成功的方式。
        XCTAssertTrue(app.buttons["add-provider"].waitForExistence(timeout: 15),
                      "保存后没有回到渠道列表（表单没关掉？）")
        screenshot(app, "e2e-06-saved")

        // ⚠️ 保存后停在**渠道列表**（表单关掉了），所以真人会先返回设置根、再回来确认。
        //    而且返回/进入都带动画 —— 必须等元素**可点**（isHittable），
        //    只等 `exists` 会在动画中途拿到一个"存在但点不到"的元素，
        //    报出来是 "No matches found"，看起来像元素不存在。这个坑我踩了两次。
        @MainActor func tapWhenReady(_ element: XCUIElement, _ label: String, timeout: TimeInterval = 15) {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                if element.exists && element.isHittable { element.tap(); return }
                usleep(300_000)
            }
            XCTFail("\(label)：等了 \(Int(timeout)) 秒仍不可点")
        }

        // ⚠️ 导航栏返回按钮要用**标签**找，不要用 `boundBy: 0` 猜索引 ——
        //    dump 出来的实际标签是「设置」（它是返回目标的名字）。
        //    猜索引的写法在"取消/返回/关闭"混在一起时会点到别的东西，
        //    而报出来只是"点不到"，非常难查。这个坑我也踩了两次。
        let navBack = app.navigationBars.buttons["设置"]
        if navBack.exists && navBack.isHittable {
            tapWhenReady(navBack, "返回设置根")
        }
        tapWhenReady(app.buttons["close-settings"], "关闭设置")
        tapWhenReady(app.buttons["open-settings"], "打开设置")
        tapWhenReady(app.buttons["settings-providers"], "进入渠道与模型")
        XCTAssertTrue(app.staticTexts["DeepSeek 官方"].waitForExistence(timeout: 15),
                      "重新进列表仍看不到刚配的渠道 —— 说明保存没生效")
        screenshot(app, "e2e-06b-provider-persisted")

        // ── 第 7 步：退回主界面 ───────────────────────────────────
        tapWhenReady(app.navigationBars.buttons.element(boundBy: 0), "返回设置根")
        tapWhenReady(app.buttons["close-settings"], "关闭设置")
        XCTAssertTrue(app.buttons["new-task"].waitForExistence(timeout: 15), "回不到主界面")
        screenshot(app, "e2e-07-back-home")

        // ── 第 8 步：新建任务，写一个**真实的小目标** ────────────────
        app.buttons["new-task"].tap()
        let prompt = app.textFields["task-prompt"]
        XCTAssertTrue(prompt.waitForExistence(timeout: 10), "合成器里没有输入框")
        prompt.tap()
        prompt.typeText("读取 notes.md，把它里面唯一的那行「# 随手记」改成「# 我的笔记」，改完再读一次确认。只动这一个文件，最后用一句中文告诉我结果。")
        screenshot(app, "e2e-08-task-typed")
        app.buttons["submit-task"].tap()

        // ── 第 9 步：开始执行（会真的打网络请求）────────────────────
        XCTAssertTrue(app.buttons["start-live-task"].waitForExistence(timeout: 15), "找不到「开始执行」")
        screenshot(app, "e2e-09-before-run")
        app.buttons["start-live-task"].tap()

        // ── 第 10 步：等审批卡（真模型应当先 read 再 edit，然后要审批）──
        let approve = app.buttons["approve-live-change"]
        XCTAssertTrue(approve.waitForExistence(timeout: 120),
                      "等不到审批卡 —— 可能是模型没调工具、或网络/鉴权失败")
        screenshot(app, "e2e-10-approval-card")
        dumpUI(app, "审批卡出现时")

        // ── 第 11 步：批准 ──────────────────────────────────────
        approve.tap()
        screenshot(app, "e2e-11-approved")

        // ── 第 12 步：等它跑完，并确认**真的改了盘** ─────────────────
        //    判据不是"界面上出现了某个词"，而是**工作区里的文件内容真的变了**。
        app.buttons["close-conversation"].waitForExistence(timeout: 120)
        screenshot(app, "e2e-12-after-approval")
        app.buttons["close-conversation"].tap()
        app.tabBars.buttons["工作台"].tap()
        app.buttons["open-files"].tap()
        XCTAssertTrue(app.buttons["file-notes.md"].waitForExistence(timeout: 15), "工作区里没有 notes.md")
        app.buttons["file-notes.md"].tap()
        let content = app.staticTexts["file-content"]
        XCTAssertTrue(content.waitForExistence(timeout: 10), "打不开文件内容")
        screenshot(app, "e2e-13-file-content")
        print("FILE-CONTENT-BEGIN\n\(content.label)\nFILE-CONTENT-END")
        XCTAssertTrue(content.label.contains("我的笔记"),
                      "文件内容没有被真的改掉；实际内容：\n\(content.label)")
    }
}

private extension XCUIElement {
    /// 清空后输入 —— `typeText` 是**追加**，而表单常有预填值（例如默认的 OpenAI URL）。
    ///
    /// ⚠️ 用 `⌘A` + `⌫`：这是模拟器/真机上都成立的做法，比"按 N 次退格"可靠
    ///    （退格次数要猜，而猜错就留下残字 —— 我第一版残字拼出了
    ///     `https://api.openai.com/https://api.deepseek.comv1` 这种畸形 URL）。
    func clearAndEnterText(_ text: String) {
        tap()
        if let existing = value as? String, !existing.isEmpty, existing != placeholderValue {
            press(forDuration: 1.0)
            let selectAll = XCUIApplication().menuItems["全选"]
            if selectAll.waitForExistence(timeout: 2) { selectAll.tap() }
            else { typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: existing.count)) }
        }
        typeText(text)
    }
}
