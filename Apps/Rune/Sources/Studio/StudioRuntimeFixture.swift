#if DEBUG
import Foundation
import RuneKernel

/// UI 验收专用；Release 中不编译。脚本只替代 HTTP 响应，仍经过完整内核和数据库。
final class StudioRuntimeFixture: ModelTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var round = 0
    func send(_ request: ModelHTTPRequest) throws -> ModelHTTPResponse {
        lock.lock(); defer { lock.unlock() }
        round += 1
        let requestText = String(decoding: request.body, as: UTF8.self)
        let content: JSONValue
        if requestText.contains("tool_call_id") {
            content = ["choices": .array([.object(["delta": .object(["content": .string("已完成真实工具执行与落盘。")]), "finish_reason": .string("stop")])])]
        } else {
            let args = JSONValue.object(["path": .string("notes.md"), "content": .string("# Runtime verified\n\nThis file was written through RuneCore.\n")]).canonicalString()
            content = ["choices": .array([.object(["delta": .object(["tool_calls": .array([.object(["index": .int(0), "id": .string("runtime-fixture-write"), "function": .object(["name": .string("write_file"), "arguments": .string(args)])])])]), "finish_reason": .string("tool_calls")])])]
        }
        return ModelHTTPResponse(statusCode: 200, body: Data(("data: " + content.canonicalString() + "\n\ndata: [DONE]\n\n").utf8))
    }
}
#endif
