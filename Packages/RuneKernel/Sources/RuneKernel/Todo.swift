import Foundation

// MARK: - 可见任务清单（`todo_write`）
//
// ⚠️ 为什么这个工具值得单独做一文件：
//    `Context` 里**早就有** `.openTodos` 这个角色、以及 `openTodosPresent` 这条自检
//    （含一句"⚠️ 有未完成 todo 却没进上下文"的警告）—— 但 `TurnState` 里**从来没有
//    todos 字段，素材池里也永远不会出现 `openTodos`**。也就是说那条自检**永远不可能触发**，
//    它是"声明了但没接上"的又一例（T48/T49/T54 同源）。
//
//    对多步任务来说这不是装饰：todo 是"我打算做什么"的唯一外部记录。
//    没有它，模型跑到第 5 步时会忘记第 2 步做过什么，用户也看不见进度。

/// 清单里的一条。
public struct TodoItem: Sendable, Codable, Hashable {
    public enum Status: String, Sendable, Codable, Hashable {
        case pending
        case inProgress = "in_progress"
        case done

        public var isOpen: Bool { self != .done }

        /// 面向模型的标记（比英文单词更省 token，且一眼能看出状态）
        public var marker: String {
            switch self {
            case .pending:    return "[ ]"
            case .inProgress: return "[~]"
            case .done:       return "[x]"
            }
        }

        public var displayName: String {
            switch self {
            case .pending:    return "待办"
            case .inProgress: return "进行中"
            case .done:       return "已完成"
            }
        }
    }

    public let text: String
    public let status: Status

    public init(text: String, status: Status) {
        self.text = text
        self.status = status
    }
}

public enum TodoError: Error, Equatable, CustomStringConvertible {
    case emptyList
    case tooManyItems(Int)
    case emptyText(index: Int)
    case textTooLong(index: Int)
    case multipleInProgress(Int)

    public var description: String {
        switch self {
        case .emptyList:
            return "清单不能为空。"
        case .tooManyItems(let count):
            return "清单最多 20 条，收到了 \(count) 条。"
        case .emptyText(let index):
            return "第 \(index + 1) 条的 text 是空的。"
        case .textTooLong(let index):
            return "第 \(index + 1) 条的 text 超过 200 字。"
        case .multipleInProgress(let count):
            return "同时有 \(count) 条状态是 in_progress。"
        }
    }
}

public enum TodoList {

    /// 一条清单最多几条。
    ///
    /// ⚠️ 这个上限不是为了省 token，而是为了**逼模型真的拆解任务**：
    ///    20 条以上的清单基本等于"把整个需求抄了一遍"，它对"我现在该干什么"
    ///    没有任何帮助，反而会让上下文里的 todo 块越来越长、越来越没用。
    public static let maxItems = 20
    public static let maxTextLength = 200

    /// 校验一份清单。
    ///
    /// ⚠️ `multipleInProgress` 这条是刻意的**硬约束**而不是风格建议：
    ///    "同时进行中"超过一条时，模型实际上没有在做任何一个 ——
    ///    它会倾向于轮流推进，每一条都停在半路。`todo_write` 的文档也写着
    ///    "让自己不跑偏"，而"两件事同时进行中"正是跑偏的开始。
    ///    与其给出警告（模型大概率忽略），不如直接拒绝并说明理由 ——
    ///    拒绝是它能理解并立刻纠正的信号。
    public static func validate(_ items: [TodoItem]) throws {
        guard !items.isEmpty else { throw TodoError.emptyList }
        guard items.count <= maxItems else { throw TodoError.tooManyItems(items.count) }
        for (index, item) in items.enumerated() {
            guard !item.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw TodoError.emptyText(index: index)
            }
            guard item.text.count <= maxTextLength else { throw TodoError.textTooLong(index: index) }
        }
        let inProgress = items.filter { $0.status == .inProgress }.count
        guard inProgress <= 1 else { throw TodoError.multipleInProgress(inProgress) }
    }

    /// 渲染给模型看的清单。
    ///
    /// ⚠️ 渲染必须**逐字节确定**（同样的清单永远产生同样的文本）：
    ///    这段文本会进上下文，而上下文一变，请求指纹就变、Prompt Cache 就失效 ——
    ///    而用户会为此多付钱，且**不会有任何报错**（项目在 C33 记过这条）。
    ///    所以顺序就是数组顺序，不排序、不加时间戳。
    public static func render(_ items: [TodoItem]) -> String {
        items.map { "\($0.status.marker) \($0.text)" }.joined(separator: "\n")
    }

    /// 给模型的摘要（含进度计数，让它一眼知道还剩几步）。
    public static func summary(_ items: [TodoItem]) -> String {
        let done = items.filter { $0.status == .done }.count
        let inProgress = items.first { $0.status == .inProgress }
        var lines = ["任务清单（\(done)/\(items.count) 已完成）"]
        if let inProgress { lines.append("当前进行中：\(inProgress.text)") }
        lines.append("")
        lines.append(render(items))
        return lines.joined(separator: "\n")
    }
}

/// `todo_write` 的实现。
///
/// ⚠️ 它是**整体替换**语义（与工具文档一致）：每次调用传完整清单。
///    增量语义（"把第 2 条标成完成"）会需要引用旧清单、处理并发修改，
///    而模型在多轮之间并不能可靠地引用"第 2 条" —— 整体替换把状态收敛到一处，
///    也天然避免了"模型以为改了、实际没改"。
public struct TodoWriteToolExecutor: ToolExecuting {
    public static let names: Set<String> = [ToolName.todoWrite]

    public init() {}

    public func execute(_ call: ToolCall) throws -> ToolResult {
        guard call.name == ToolName.todoWrite else {
            return .failure(callID: call.id, error: ToolError(
                kind: .unknownTool,
                modelFacingMessage: "TodoWriteToolExecutor 不认识工具 `\(call.name)`。"))
        }
        let args: JSONValue
        do { args = try call.arguments() }
        catch {
            return .failure(callID: call.id, error: ToolError(
                kind: .invalidArguments, modelFacingMessage: "参数不是合法 JSON。"))
        }
        guard let raw = args.value(at: ["items"])?.arrayValue else {
            return .failure(callID: call.id, error: ToolError(
                kind: .invalidArguments,
                modelFacingMessage: "缺少 `items`（完整清单；本工具是**整体替换**语义）。",
                suggestion: #"例如 todo_write(items: [{"text": "改 money.py", "status": "in_progress"}])"#))
        }

        var items: [TodoItem] = []
        for (index, element) in raw.enumerated() {
            guard let text = element.value(at: ["text"])?.stringValue else {
                return .failure(callID: call.id, error: ToolError(
                    kind: .invalidArguments,
                    modelFacingMessage: "第 \(index + 1) 条缺少 `text`。",
                    suggestion: #"每条都要有 text 与 status，例如 {"text": "跑测试", "status": "pending"}"#))
            }
            let statusText = element.value(at: ["status"])?.stringValue ?? TodoItem.Status.pending.rawValue
            guard let status = TodoItem.Status(rawValue: statusText) else {
                return .failure(callID: call.id, error: ToolError(
                    kind: .invalidArguments,
                    modelFacingMessage: "第 \(index + 1) 条的 `status` 是 `\(statusText)`，不是允许的值。",
                    suggestion: "只能是 pending / in_progress / done 三者之一。",
                    candidates: ["pending", "in_progress", "done"]))
            }
            items.append(TodoItem(text: text, status: status))
        }

        do {
            try TodoList.validate(items)
        } catch let error as TodoError {
            // ⚠️ 校验失败必须给出**具体改法**，而不是只说"不合法"。
            //    `multipleInProgress` 尤其重要：模型很容易一次标两条 in_progress，
            //    而它不会自己意识到那是问题 —— 必须告诉它"先做完一条"。
            let suggestion: String
            switch error {
            case .multipleInProgress:
                suggestion = "把其中一条改回 pending，只保留一条 in_progress —— 一次只推进一件事。"
            case .emptyList:
                suggestion = "如果要清空清单，就直接给出你想要的新清单（至少一条）。"
            case .tooManyItems:
                suggestion = "合并或删掉一些，只保留当前任务真正需要的步骤（最多 \(TodoList.maxItems) 条）。"
            case .emptyText, .textTooLong:
                suggestion = "每条 text 写清「做什么」，1–200 字。"
            }
            return .failure(callID: call.id, error: ToolError(
                kind: .invalidArguments,
                modelFacingMessage: "清单不合法：\(error.description)",
                suggestion: suggestion))
        }

        // ⚠️ 工具本身**不改 TurnState** —— 状态由运行时在这一步之后写回。
        //    理由与 ApproveBroker 一致：能改状态的地方越少，"状态从哪来"就越可审计。
        //    返回值里带上清单本身，运行时据此更新状态并落事件。
        return ToolResult(
            callID: call.id,
            status: .ok,
            summary: TodoList.summary(items),
            metrics: .init()
        )
    }
}

// MARK: - 从工具参数取清单（供运行时更新状态）

public extension TodoList {
    /// 解析 `todo_write` 的参数。失败返回 nil（校验错误已由执行器报给模型）。
    static func items(from arguments: JSONValue) -> [TodoItem]? {
        guard let raw = arguments.value(at: ["items"])?.arrayValue else { return nil }
        var items: [TodoItem] = []
        for element in raw {
            guard let text = element.value(at: ["text"])?.stringValue,
                  let status = TodoItem.Status(rawValue: element.value(at: ["status"])?.stringValue
                                               ?? TodoItem.Status.pending.rawValue) else { return nil }
            items.append(TodoItem(text: text, status: status))
        }
        guard (try? validate(items)) != nil else { return nil }
        return items
    }
}
