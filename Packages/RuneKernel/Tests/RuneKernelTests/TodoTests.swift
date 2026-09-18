import Foundation
import Testing
@testable import RuneKernel

// MARK: - 可见任务清单（todo_write）
//
// ⚠️ 这一组值得存在，是因为它修的是一个「声明了但没接上」的洞：
//    `Context` 里**早就有** `.openTodos` 角色与 `openTodosPresent` 自检
//    （含一句"⚠️ 有未完成 todo 却没进上下文"的警告），
//    但 `TurnState` 从来没有 todos 字段 —— 那条自检**永远不可能触发**。
//
// ⚠️ 另一条重点：**校验拒绝的理由必须可执行**。
//    模型最容易犯的是"一次标两条 in_progress"，而它不会自己意识到那是问题 ——
//    所以拒绝信息要直接告诉它"先做完一条"，而不是只说"不合法"。

private func writeTodo(_ items: JSONValue) throws -> ToolResult {
    let executor = TodoWriteToolExecutor()
    let call = ToolCall(id: "c1", name: ToolName.todoWrite,
                        argumentsJSON: Data(JSONValue.object(["items": items]).canonicalString().utf8))
    return try executor.execute(call)
}

private func item(_ text: String, _ status: String) -> JSONValue {
    .object(["text": .string(text), "status": .string(status)])
}

@Suite("todo_write —— 基本行为")
struct TodoWriteBasicsTests {

    @Test("⭐ 正常清单：摘要里要有进度计数与进行中的那一条")
    func normalList() throws {
        let result = try writeTodo(.array([
            item("读 money.py", "done"),
            item("改取整逻辑", "in_progress"),
            item("跑测试", "pending"),
        ]))
        #expect(result.status == .ok, "实际：\(result.summary)")
        #expect(result.summary.contains("1/3 已完成"), "要给出进度，实际：\(result.summary)")
        #expect(result.summary.contains("当前进行中：改取整逻辑"), "实际：\(result.summary)")
        #expect(result.summary.contains("[x] 读 money.py"))
        #expect(result.summary.contains("[~] 改取整逻辑"))
        #expect(result.summary.contains("[ ] 跑测试"))
    }

    @Test("⚠️ 标记必须能区分三种状态（模型靠它一眼看清进度）")
    func markersAreDistinct() {
        #expect(TodoItem.Status.pending.marker == "[ ]")
        #expect(TodoItem.Status.inProgress.marker == "[~]")
        #expect(TodoItem.Status.done.marker == "[x]")
        #expect(TodoItem.Status.done.isOpen == false)
        #expect(TodoItem.Status.inProgress.isOpen)
        #expect(TodoItem.Status.pending.isOpen)
    }

    @Test("⚠️ 渲染必须**逐字节确定**（否则请求指纹变、Prompt Cache 失效，用户白付钱）")
    func renderIsDeterministic() {
        // ⚠️ 这段文本会进上下文。顺序一变，整个请求的指纹就变，
        //    而缓存失效**不会有任何报错** —— 用户只会在账单上发现（C33 记过这条）。
        let items = [TodoItem(text: "a", status: .done), TodoItem(text: "b", status: .pending)]
        let first = TodoList.render(items)
        for _ in 0..<5 { #expect(TodoList.render(items) == first) }
        #expect(first == "[x] a\n[ ] b", "顺序必须是数组顺序，不排序：\(first)")
    }
}

@Suite("todo_write —— 校验拒绝必须可执行")
struct TodoWriteValidationTests {

    @Test("⭐⭐ 两条 in_progress 必须被拒，而且要说清「一次只推进一件事」")
    func multipleInProgressRejected() throws {
        // ⚠️ 这条是刻意的硬约束，不是风格建议：
        //    同时进行中超过一条时，模型实际上没有在做任何一个 ——
        //    它会轮流推进，每一条都停在半路。而工具文档写着"让自己不跑偏"，
        //    "两件事同时进行中"正是跑偏的开始。
        //    给警告（模型大概率忽略）不如直接拒绝 + 说明理由。
        let result = try writeTodo(.array([
            item("A", "in_progress"),
            item("B", "in_progress"),
        ]))
        #expect(result.status != .ok, "两条 in_progress 必须被拒")
        #expect(result.summary.contains("in_progress"), "要指出问题所在，实际：\(result.summary)")
        #expect(result.summary.contains("只保留一条") || result.summary.contains("一次只推进"),
                "必须给出可执行改法，实际：\(result.summary)")
    }

    @Test("⭐ 一条 in_progress 是允许的")
    func singleInProgressAllowed() throws {
        let result = try writeTodo(.array([item("A", "in_progress"), item("B", "pending")]))
        #expect(result.status == .ok, "实际：\(result.summary)")
    }

    @Test("⚠️ 空清单要被拒（含「怎么清空」的替代做法）")
    func emptyListRejected() throws {
        let result = try writeTodo(.array([]))
        #expect(result.status != .ok)
        #expect(result.summary.contains("不能为空"))
        #expect(result.summary.contains("新清单"), "要给出替代做法，实际：\(result.summary)")
    }

    @Test("⚠️ 超过 20 条要被拒（逼模型真的拆解任务，而不是把需求抄一遍）")
    func tooManyItemsRejected() throws {
        let many = (1...21).map { item("步骤 \($0)", "pending") }
        let result = try writeTodo(.array(many))
        #expect(result.status != .ok)
        #expect(result.summary.contains("20"), "实际：\(result.summary)")
        #expect(result.summary.contains("合并") || result.summary.contains("删掉"), "实际：\(result.summary)")
    }

    @Test("⚠️ 恰好 20 条是允许的（边界不能多算一条）")
    func exactlyMaxAllowed() throws {
        let exactly = (1...20).map { item("步骤 \($0)", "pending") }
        #expect(try writeTodo(.array(exactly)).status == .ok)
    }

    @Test("⚠️ 空白 text 要被拒（空条目会让清单失去意义）")
    func blankTextRejected() throws {
        let result = try writeTodo(.array([item("   ", "pending")]))
        #expect(result.status != .ok)
        #expect(result.summary.contains("空的") || result.summary.contains("text"))
    }

    @Test("⚠️ 非法 status 要给出允许的三个值（而不是只说「不合法」）")
    func invalidStatusListsAllowedValues() throws {
        let result = try writeTodo(.array([item("A", "doing")]))
        #expect(result.status != .ok)
        #expect(result.summary.contains("doing"))
        for allowed in ["pending", "in_progress", "done"] {
            #expect(result.summary.contains(allowed), "要列出允许值 \(allowed)，实际：\(result.summary)")
        }
    }

    @Test("⚠️ 缺少 items 要说明这是**整体替换**语义（否则模型会以为能增量改）")
    func missingItemsExplainsReplaceSemantics() throws {
        let executor = TodoWriteToolExecutor()
        let call = ToolCall(id: "c1", name: ToolName.todoWrite, argumentsJSON: Data("{}".utf8))
        let result = try executor.execute(call)
        #expect(result.status != .ok)
        #expect(result.summary.contains("整体替换"), "实际：\(result.summary)")
    }
}

@Suite("todo_write —— 状态字段与向前兼容")
struct TodoStateCompatibilityTests {

    @Test("⭐⭐ 旧检查点（JSON 里没有 todos 键）必须仍能解码")
    func oldCheckpointsStillDecode() throws {
        // ⚠️ 这条测试守的是一个很容易被"顺手改成非可选"破坏的性质：
        //    如果把 `todos` 写成非可选 `[TodoItem]`，`Codable` 合成会在解码
        //    **任何历史状态**时抛错 —— 那等于所有已落盘的会话都恢复不了。
        //    可选 + 默认 nil 让新旧两种状态都能解出来。
        let state = TurnState(objective: "测试", todos: [TodoItem(text: "a", status: .pending)])
        let encoded = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(TurnState.self, from: encoded)
        #expect(decoded.todos?.count == 1)

        // 模拟"旧版本落盘"：把 todos 键整段删掉
        var object = try #require(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "todos")
        let legacy = try JSONSerialization.data(withJSONObject: object)
        let fromLegacy = try JSONDecoder().decode(TurnState.self, from: legacy)
        #expect(fromLegacy.todos == nil, "旧状态解出来应当是 nil（调用方用 `?? []` 兜底）")
        #expect(fromLegacy.objective == "测试", "其余字段必须完好")
    }

    @Test("⭐ 从参数解析清单（供运行时更新状态）")
    func itemsFromArguments() {
        let args = JSONValue.object(["items": .array([item("A", "done"), item("B", "pending")])])
        let parsed = TodoList.items(from: args)
        #expect(parsed?.count == 2)
        #expect(parsed?[0].status == .done)
        // 不合法的参数不该被解析出来（否则运行时会写进一份坏状态）
        let bad = JSONValue.object(["items": .array([item("A", "in_progress"), item("B", "in_progress")])])
        #expect(TodoList.items(from: bad) == nil, "校验不过的参数不能被解析成状态")
    }

    @Test("⚠️ status 缺省是 pending（不逼模型每次都写全）")
    func statusDefaultsToPending() throws {
        let result = try writeTodo(.array([.object(["text": .string("只有文本")])]))
        #expect(result.status == .ok, "实际：\(result.summary)")
        #expect(result.summary.contains("[ ] 只有文本"))
    }
}
