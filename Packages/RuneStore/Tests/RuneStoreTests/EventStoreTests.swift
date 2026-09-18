import Testing
import Foundation
import GRDB
@testable import RuneStore
import RuneKernel

// MARK: - 事件落盘：唯一真相源的磁盘形态
//
// 这一组回答一个问题：**进程退了之后，事件还在不在、还对不对？**
// 在此之前 `EventLog` 只活在内存里 —— 崩一次，20 条事件、哈希链、检查点全没，
// 所谓"崩溃恢复"根本无从谈起。
//
// ⚠️ 这些测试跑在 macOS CI 上（GRDB），所以它们同时也验证了
//    "GRDB 在这个部署目标上真的能用"。

private let sessionA = UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000001")!
private let sessionB = UUID(uuidString: "BBBBBBBB-0000-0000-0000-000000000002")!
private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

/// 一个临时文件路径（磁盘库：要验证"真的落盘"）
private func tempDBPath() -> String {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("rune-store-\(UUID().uuidString).sqlite").path
}

private func store() throws -> RuneEventStore { try RuneEventStore(inMemory: true) }

@Suite("事件落盘 —— 写进去、读出来、还得是同一条")

struct EventStoreRoundTripTests {

    @Test("⭐ 追加 → 读回：字段逐一无损（哈希链因此还能校验）")
    func appendAndLoadPreservesEveryField() throws {
        let store = try store()
        let turn = UUID()
        let goal = UUID()

        _ = try store.append(sessionID: sessionA, turnID: turn, goalID: goal,
                             kind: .userMessage, payload: ["objective": .string("修退款 bug")],
                             originTrust: .userInstruction, createdAt: t0)
        _ = try store.append(sessionID: sessionA, turnID: turn,
                             kind: .toolCallRequested, payload: ["tool": .string("read_file")],
                             createdAt: t0.addingTimeInterval(1))

        let loaded = try store.loadAll(sessionID: sessionA)
        #expect(loaded.count == 2)
        #expect(loaded[0].kind == .turnStarted)
        #expect(loaded[0].payload.value(at: ["objective"]) == .string("修退款 bug"))
        #expect(loaded[0].originTrust == .userInstruction)
        #expect(loaded[0].turnID == turn)
        #expect(loaded[0].goalID == goal)
        #expect(loaded[0].sequence == 1)
        #expect(loaded[1].sequence == 2)
        #expect(loaded[1].payload.value(at: ["tool"]) == .string("read_file"))
        #expect(abs(loaded[1].createdAt.timeIntervalSince(t0.addingTimeInterval(1))) < 0.001)
        // ⚠️ 时间戳精度是"落盘再读回"最容易糊掉的地方：差一毫秒，哈希就对不上了
        #expect(loaded[0].createdAt == t0, "时间戳往返必须精确到毫秒")
    }

    @Test("⭐⭐ 落盘之后哈希链**仍然校验通过**（磁盘字节 → 内核校验器）")
    func hashChainSurvivesRoundTrip() throws {
        let store = try store()
        for index in 0..<6 {
            _ = try store.append(sessionID: sessionA, kind: .modelCallFinished,
                                 payload: ["round": .int(index)], createdAt: t0.addingTimeInterval(Double(index)))
        }
        let log = try store.eventLog(sessionID: sessionA)
        let verdict = log.verify(full: true)
        #expect(verdict.isOK, "从磁盘读回来的事件链必须校验通过：\(verdict)")
        #expect(try store.count(sessionID: sessionA) == 6)
    }

    @Test("⭐ 链是按**会话**串的：两个会话各写各的，互不干扰")
    func chainsArePerSession() throws {
        let store = try store()
        _ = try store.append(sessionID: sessionA, kind: .userMessage, createdAt: t0)
        let firstOfB = try store.append(sessionID: sessionB, kind: .userMessage, createdAt: t0)
        #expect(firstOfB.previousHash == nil, "另一个会话的第一条不该接在别人的链上")
        #expect(firstOfB.sequence == 1, "序号也是按会话算的")

        #expect(try store.count(sessionID: sessionA) == 1)
        #expect(try store.count(sessionID: sessionB) == 1)
        #expect(try store.eventLog(sessionID: sessionA).verify(full: true).isOK)
        #expect(try store.eventLog(sessionID: sessionB).verify(full: true).isOK)
    }

    @Test("⭐ 关闭再打开同一个文件：事件还在（这才是'落盘'）")
    func survivesReopen() throws {
        let path = tempDBPath()
        defer { try? FileManager.default.removeItem(atPath: path) }

        do {
            let store = try RuneEventStore(path: path)
            for index in 0..<4 {
                _ = try store.append(sessionID: sessionA, kind: .fileRead,
                                     payload: ["path": .string("/workspace/\(index).md")],
                                     createdAt: t0.addingTimeInterval(Double(index)))
            }
        }
        // 全新的实例，连的还是同一个文件
        let reopened = try RuneEventStore(path: path)
        #expect(try reopened.count(sessionID: sessionA) == 4)
        #expect(try reopened.eventLog(sessionID: sessionA).verify(full: true).isOK)
        // 续写要接在原来的链上，不能从头开始
        let next = try reopened.append(sessionID: sessionA, kind: .fileWritten, createdAt: t0.addingTimeInterval(9))
        #expect(next.sequence == 5)
        #expect(next.previousHash != nil, "续写必须接上已有的链")
        #expect(try reopened.eventLog(sessionID: sessionA).verify(full: true).isOK)
    }

    @Test("⭐ `lastHash` 能当锚点用 —— 锚点要存在 Agent 够不到的地方，而它就是那个值")
    func lastHashSupportsAnchors() throws {
        let store = try store()
        let last = try store.append(sessionID: sessionA, kind: .artifactCreated, createdAt: t0)
        #expect(try store.lastHash(sessionID: sessionA) == last.hash)
        #expect(try store.lastHash(sessionID: sessionB) == nil, "没有事件的会话没有锚点")
    }
}

@Suite("篡改可检测 —— 磁盘上的字节改了，链就断")

struct EventStoreTamperTests {

    @Test("⭐⭐ 直接改库里的内容 → 从磁盘读回来的链**必须**报错")
    func tamperingIsDetected() throws {
        let path = tempDBPath()
        defer { try? FileManager.default.removeItem(atPath: path) }

        let store = try RuneEventStore(path: path)
        for index in 0..<3 {
            _ = try store.append(sessionID: sessionA, kind: .fileRead,
                                 payload: ["path": .string("/workspace/\(index).md")],
                                 createdAt: t0.addingTimeInterval(Double(index)))
        }
        #expect(try store.eventLog(sessionID: sessionA).verify(full: true).isOK)

        // ⚠️ 绕过 store 的 API，**直接在 SQL 层**改一条事件的正文 ——
        //    这正是"有人（或某个 bug）动了数据库文件"的样子。
        //    改的是 envelope_json（读回时解码的就是它）。
        let queue = try DatabaseQueue(path: path)
        try queue.write { db in
            let row = try Row.fetchOne(db, sql: "SELECT envelope_json FROM event WHERE seq = 2")
            let json = (row?["envelope_json"] as? String) ?? ""
            let tampered = json.replacingOccurrences(of: "/workspace/1.md", with: "/etc/passwd")
            #expect(tampered != json, "测试本身要真的改到东西")
            try db.execute(sql: "UPDATE event SET envelope_json = ? WHERE seq = 2", arguments: [tampered])
        }

        let log = try store.eventLog(sessionID: sessionA)
        let verdict = log.verify(full: true)
        #expect(!verdict.isOK, "被改过的内容必须让链校验失败")
        #expect(verdict.outcome != .ok)
    }
}

@Suite("迁移 —— 一眼能看完，且不会重复建表")

struct EventStoreMigrationTests {

    @Test("⭐ 打两次迁移是幂等的（新实例连同一个文件不会出错）")
    func migrationIsIdempotent() throws {
        let path = tempDBPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        _ = try RuneEventStore(path: path)
        _ = try RuneEventStore(path: path)

        let queue = try DatabaseQueue(path: path)
        let version = try queue.read { db in try Int.fetchOne(db, sql: "PRAGMA user_version") }
        #expect(version == RuneEventStore.schemaVersion)

        // 表结构就是 docs/12 §2 那一列不差（除了刻意的 envelope_json）
        let columns = try queue.read { db in
            try Row.fetchAll(db, sql: "PRAGMA table_info(event)").map { ($0["name"] as? String) ?? "" }
        }
        for expected in ["seq", "id", "session_id", "turn_id", "goal_id", "subagent_id",
                         "kind", "payload_json", "payload_ref", "origin_trust", "tainted",
                         "created_at", "prev_hash", "hash"] {
            #expect(columns.contains(expected), "缺列：\(expected)")
        }
    }

    @Test("按 kind / turn 检索（索引存在的意义）")
    func queriesByKindAndTurn() throws {
        let store = try store()
        let turn = UUID()
        _ = try store.append(sessionID: sessionA, turnID: turn, kind: .planApproved, createdAt: t0)
        _ = try store.append(sessionID: sessionA, turnID: turn, kind: .toolCallRequested, createdAt: t0)
        _ = try store.append(sessionID: sessionA, kind: .artifactCreated, createdAt: t0)

        let all = try store.loadAll(sessionID: sessionA)
        #expect(all.filter { $0.turnID == turn }.count == 2)
        #expect(all.filter { $0.kind == .planApproved }.count == 1)
    }
}
