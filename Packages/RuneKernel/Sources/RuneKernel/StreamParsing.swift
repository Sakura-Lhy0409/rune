import Foundation

// MARK: - SSE 事件
//
// ⚠️ 真实世界的 SSE **非常脏**（docs/06 §12 已列过）：
//   * 厂商会发心跳与注释行（uni-api 发 `: keepalive`）
//   * 事件可能跨 chunk 断开，甚至断在 UTF-8 多字节字符中间
//   * 有的发 `[DONE]`，有的不发；有的用 `event:` 命名，有的只有 `data:`
//   * 换行可能是 `\n` 也可能是 `\r\n`
//   * 一个网络包可能包含多个事件，也可能只有半个事件
//
// 因此解析器必须是**增量 + 容错**的：绝不"攒完再 parse"。

/// 一个已解析的 SSE 事件
public struct SSEEvent: Sendable, Equatable {
    /// `event:` 字段（Anthropic 用它做事件分类）
    public var name: String?
    /// `data:` 字段（多行 data 会以换行拼接）
    public var data: String
    /// `id:` 字段
    public var id: String?

    public init(name: String? = nil, data: String, id: String? = nil) {
        self.name = name
        self.data = data
        self.id = id
    }

    public var isDoneMarker: Bool { data == "[DONE]" }
}

/// 增量 SSE 解析器。
///
/// 用法：每次收到网络数据就 `ingest(data)`，拿到**本次新完成的**事件；
/// 流结束时调用 `finish()` 处理残留缓冲（有些服务端不发最后的空行）。
public struct SSEParser: Sendable {
    private var buffer = Data()
    private var currentName: String?
    private var currentData: [String] = []
    private var currentID: String?
    /// 已产出的事件数（诊断用）
    public private(set) var eventCount = 0
    /// 丢弃的注释行数（用于诊断"这个渠道发了多少心跳"）
    public private(set) var commentCount = 0

    public init() {}

    /// 喂入原始字节；返回本次新完成的事件
    public mutating func ingest(_ data: Data) -> [SSEEvent] {
        buffer.append(data)
        var events: [SSEEvent] = []

        // 逐行扫描。注意：**必须按字节找换行**，不能先把 buffer 转成 String —— 
        // 否则一个断在 UTF-8 多字节字符中间的网络包会解码失败、丢掉数据。
        while let newlineIndex = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer[buffer.startIndex..<newlineIndex]
            buffer.removeSubrange(buffer.startIndex...newlineIndex)

            // 去掉行尾的 \r（CRLF）
            var line = lineData
            if line.last == 0x0D { line = line.dropLast() }

            guard let text = String(data: line, encoding: .utf8) else {
                // 单行不是合法 UTF-8：极罕见，跳过而不是让整个流崩掉
                continue
            }

            if text.isEmpty {
                // 空行 = 事件分隔符
                if let event = flushEvent() { events.append(event) }
                continue
            }
            if text.hasPrefix(":") {
                commentCount += 1       // 心跳 / keepalive，忽略
                continue
            }

            let (field, value) = Self.splitField(text)
            switch field {
            case "event": currentName = value
            case "data":  currentData.append(value)
            case "id":    currentID = value
            case "retry": break          // 我们用自己的退避策略
            default: break               // 未知字段忽略
            }
        }
        return events
    }

    /// 流结束：处理残留（有些服务端最后一帧不带结尾空行）
    public mutating func finish() -> [SSEEvent] {
        var events: [SSEEvent] = []
        if !buffer.isEmpty {
            if let text = String(data: buffer, encoding: .utf8) {
                if text.hasPrefix(":") {
                    commentCount += 1
                } else {
                    let (field, value) = Self.splitField(text.hasSuffix("\r") ? String(text.dropLast()) : text)
                    if field == "data" { currentData.append(value) }
                    else if field == "event" { currentName = value }
                }
            }
            buffer.removeAll()
        }
        if let event = flushEvent() { events.append(event) }
        return events
    }

    private mutating func flushEvent() -> SSEEvent? {
        guard !currentData.isEmpty || currentName != nil else { return nil }
        let event = SSEEvent(
            name: currentName,
            data: currentData.joined(separator: "\n"),
            id: currentID
        )
        currentName = nil
        currentData = []
        currentID = nil
        eventCount += 1
        return event
    }

    /// 按第一个 `:` 切分；无冒号时整行是字段名，值为空串
    static func splitField(_ line: String) -> (field: String, value: String) {
        guard let colon = line.firstIndex(of: ":") else { return (line, "") }
        let field = String(line[line.startIndex..<colon])
        var value = String(line[line.index(after: colon)...])
        // 规范：冒号后的**一个**空格要吃掉
        if value.hasPrefix(" ") { value.removeFirst() }
        return (field, value)
    }

    public var diagnostics: String {
        "SSE：\(eventCount) 个事件，丢弃 \(commentCount) 条心跳/注释"
    }
}

// MARK: - NDJSON 解析（Ollama 原生端点）
//
// Ollama 的 `/api/chat` 返回的是**每行一个 JSON 对象**，不是 SSE。
// 别把两者搞混 —— 这是接入局域网模型时最容易踩的坑（docs/附录A §1）。

public struct NDJSONParser: Sendable {
    private var buffer = Data()
    public private(set) var lineCount = 0

    public init() {}

    /// 返回本次新完成的完整行（已去空行）
    public mutating func ingest(_ data: Data) -> [String] {
        buffer.append(data)
        var lines: [String] = []
        while let newlineIndex = buffer.firstIndex(of: 0x0A) {
            var lineData = buffer[buffer.startIndex..<newlineIndex]
            buffer.removeSubrange(buffer.startIndex...newlineIndex)
            if lineData.last == 0x0D { lineData = lineData.dropLast() }
            guard let text = String(data: lineData, encoding: .utf8) else { continue }
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            lines.append(trimmed)
            lineCount += 1
        }
        return lines
    }

    public mutating func finish() -> [String] {
        guard !buffer.isEmpty, let text = String(data: buffer, encoding: .utf8) else {
            buffer.removeAll()
            return []
        }
        buffer.removeAll()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        lineCount += 1
        return [trimmed]
    }
}
