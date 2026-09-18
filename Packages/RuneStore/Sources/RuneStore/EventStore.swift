import Foundation
import GRDB
import RuneKernel

// MARK: - 事件落盘（docs/12 §2 的 event 表）
//
// 这是「事件日志是唯一真相源」从**内存里的一句话**变成**磁盘上的一份事实**的地方。
// 在此之前 `EventLog` 只活在内存里：进程一退，20 条事件、哈希链、检查点全没了，
// 所谓"崩溃恢复"也就无从谈起。
//
// ## 两个刻意的设计决定
//
// ① **额外存一份 `envelope_json`**（docs/12 的 DDL 里没有这一列）。
//    理由：其余列是为**查询/索引**服务的（按 session、turn、kind 检索），
//    而我们要的是**逐字段无损往返**。`RuntimeEvent` 字段全是 `let`、哈希在构造时算好，
//    靠"把各列拼回一个 JSON 再解码"会在类型演进时**静默错位** ——
//    那种错不会报错，只会让恢复出来的事件与原始事件不是同一条。
//    ⚠️ 代价是磁盘多一点；而"恢复出来的东西必须等于当初写进去的东西"更值钱。
//
// ② **v1 不建 `REFERENCES` 外键**。
//    docs/12 的 `REFERENCES session(id)` 是**意图声明**：它描述的是最终的完整性约束。
//    但眼下 session/turn/goal 三张投影表还不存在，而事件是**先于投影**写入的
//    （事件是真相源，投影是它的函数）。这时打开外键强制，只会让"写第一条事件"直接失败。
//    等投影写入接上，再把外键补上（那时它们才有意义）。
//
// ③ **主键是 `(session_id, seq)`，不是单列 `seq`**（docs/12 的 DDL 原本写的是 `seq INTEGER PRIMARY KEY`）。
//    理由：序号是**按会话**算的，两个会话各有一条 `seq = 1` →
//    单列主键会让「开第二个会话」直接撞 UNIQUE 约束。
//    ⚠️ 这不是推测，是 `chainsArePerSession` 当场抓出来的：
//       写第二个会话的第一条事件时得到 `UNIQUE constraint failed: event.seq`。
//    根因是 **`docs/12` 那句「全局单调」与内核实现不符** ——
//    内核里 `EventLog` 是**每个会话一个实例**（`EventLog(sessionID:)`），
//    `verify()` 按会话内序号定位锚点，`EventProjector.lastSequence`、
//    `turn.lastCheckpointSeq` 也全是会话内的值。
//    也就是说：**全部消费方都按「会话内序号」读它**，没有任何一处需要跨会话单调。
//    所以对的是内核、过时的是文档（docs/12 已同步修正）。
//
// ⚠️ 只用 GRDB 里最稳的那层 API（`execute` / `Row.fetchAll` / 手写迁移），
//    不用 `Record`/`Codable` 那套 —— 在没有 Mac、每次验证都要走 CI 的条件下，
//    **少一个 API 面就少一类要在 CI 上迭代的错误**。

/// 事件存储：唯一真相源的磁盘形态。
public final class RuneEventStore: Sendable {

    /// v1：事件表；v2：与事件同事务的运行状态检查点。已有 v1 数据库原位迁移。
    public static let schemaVersion = 2

    let dbQueue: DatabaseQueue

    /// 打开（或新建）一个磁盘上的库。
    public init(path: String) throws {
        var configuration = Configuration()
        // 见文件头 ②：外键在投影表接上之前不强制
        configuration.foreignKeysEnabled = false
        dbQueue = try DatabaseQueue(path: path, configuration: configuration)
        try migrate()
    }

    /// 内存库（测试与演示用）。
    public init(inMemory: Bool) throws {
        var configuration = Configuration()
        configuration.foreignKeysEnabled = false
        dbQueue = try DatabaseQueue(configuration: configuration)
        try migrate()
    }

    /// 迁移。用 `user_version` 手写，逻辑一眼能看完（没有隐藏状态）。
    public func migrate() throws {
        try dbQueue.write { db in
            let version = try Int.fetchOne(db, sql: "PRAGMA user_version") ?? 0
            guard version < Self.schemaVersion else { return }
            if version < 1 {
                // 列与 docs/12 §2 的 DDL 一致（除了刻意的 envelope_json，见文件头 ①）
                // ⚠️ 主键是 **(session_id, seq)** 而不是 `seq` 单列 —— 这一条是被测试逼出来的：
                //    序号是**按会话**算的（`EventLog.append` 用的是 `events.count + 1`），
                //    所以两个会话各有一条 `seq = 1`。写成 `seq INTEGER PRIMARY KEY` 时，
                //    第二个会话的"第一条事件"会直接撞上 UNIQUE 约束 —— 报错是
                //    `UNIQUE constraint failed: event.seq`，而它真正的含义是
                //    「本地库根本存不下第二个会话」（用户开第二个会话就炸）。
                //    另注：SQLite 里 `INTEGER PRIMARY KEY` 是 rowid 的别名，**不能**加列，
                //    所以这里用表级 `PRIMARY KEY (...)`（非 INTEGER 主键，不占 rowid 别名）。
                try db.execute(sql: """
                    CREATE TABLE IF NOT EXISTS event (
                      session_id    TEXT NOT NULL,
                      seq           INTEGER NOT NULL,
                      id            TEXT NOT NULL UNIQUE,
                      turn_id       TEXT,
                      goal_id       TEXT,
                      subagent_id   TEXT,
                      kind          TEXT NOT NULL,
                      payload_json  TEXT NOT NULL,
                      payload_ref   TEXT,
                      origin_trust  TEXT NOT NULL,
                      tainted       INTEGER NOT NULL DEFAULT 0,
                      created_at    INTEGER NOT NULL,
                      prev_hash     BLOB,
                      hash          BLOB NOT NULL,
                      envelope_json TEXT NOT NULL,
                      PRIMARY KEY (session_id, seq)
                    )
                    """)
                try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_event_session ON event(session_id, seq)")
                try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_event_turn ON event(turn_id, seq)")
                try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_event_kind_time ON event(kind, created_at DESC)")
            }
            if version < 2 {
                try db.execute(sql: """
                    CREATE TABLE runtime_checkpoint (
                      session_id TEXT PRIMARY KEY NOT NULL,
                      revision INTEGER NOT NULL,
                      state_json BLOB NOT NULL,
                      metadata BLOB NOT NULL,
                      state_hash BLOB NOT NULL,
                      updated_at REAL NOT NULL
                    )
                    """)
            }
            try db.execute(sql: "PRAGMA user_version = \(Self.schemaVersion)")
        }
    }

    // MARK: 写

    /// 追加一条事件：**序号与哈希链由这里接续**，调用方不必自己维护。
    ///
    /// ⚠️ `previousHash` 取的是**该 session 的最后一条**（不是全局最后一条）：
    ///    链是按会话串的，两个会话各写各的互不干扰。
    @discardableResult
    public func append(
        sessionID: UUID,
        turnID: UUID? = nil,
        goalID: UUID? = nil,
        subagentID: UUID? = nil,
        kind: EventKind,
        payload: JSONValue = .object([:]),
        originTrust: TrustLevel = .toolResultTrusted,
        createdAt: Date = Date()
    ) throws -> RuntimeEvent {
        try dbQueue.write { db in
            let previous = try Self.lastRow(db, sessionID: sessionID)
            let event = RuntimeEvent(
                sequence: (previous?.sequence ?? 0) + 1,
                sessionID: sessionID, turnID: turnID, goalID: goalID, subagentID: subagentID,
                kind: kind, payload: payload, originTrust: originTrust,
                createdAt: createdAt, previousHash: previous?.hash
            )
            try Self.insert(db, event)
            return event
        }
    }

    /// 追加一条**已经构造好**的事件（例如内核的 `EventLog` 产出的那些）。
    public func append(_ event: RuntimeEvent) throws {
        try dbQueue.write { db in try Self.insert(db, event) }
    }

    static func insert(_ db: Database, _ event: RuntimeEvent) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        let envelope = try encoder.encode(event)
        try db.execute(
            sql: """
                INSERT INTO event
                  (seq, id, session_id, turn_id, goal_id, subagent_id, kind,
                   payload_json, payload_ref, origin_trust, tainted, created_at,
                   prev_hash, hash, envelope_json)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, NULL, ?, ?, ?, ?, ?, ?)
                """,
            arguments: [
                event.sequence,
                event.id.uuidString,
                event.sessionID.uuidString,
                event.turnID?.uuidString,
                event.goalID?.uuidString,
                event.subagentID?.uuidString,
                event.kind.rawValue,
                event.payload.canonicalString(),
                event.originTrust.rawValue,
                event.tainted ? 1 : 0,
                Int64(event.createdAt.timeIntervalSince1970 * 1000),
                event.previousHash,
                event.hash,
                String(decoding: envelope, as: UTF8.self),
            ]
        )
    }

    // MARK: 读

    public func count(sessionID: UUID) throws -> Int {
        try dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM event WHERE session_id = ?",
                             arguments: [sessionID.uuidString]) ?? 0
        }
    }

    /// 该会话最后一条的哈希（**锚点**要用它：锚点要存在 Agent 够不到的地方）
    public func lastHash(sessionID: UUID) throws -> Data? {
        try dbQueue.read { db in try Self.lastRow(db, sessionID: sessionID)?.hash }
    }

    /// 按序号读出整个会话的事件。
    ///
    /// ⚠️ **逐字段无损往返**：解码的是当初写进去的那份信封，
    ///    保证"读出来的等于写进去的"（否则哈希链会莫名其妙地校验不过）。
    public func loadAll(sessionID: UUID) throws -> [RuntimeEvent] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return try dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT envelope_json FROM event WHERE session_id = ? ORDER BY seq ASC",
                arguments: [sessionID.uuidString]
            )
            return try rows.map { row in
                let json = (row["envelope_json"] as? String) ?? ""
                return try decoder.decode(RuntimeEvent.self, from: Data(json.utf8))
            }
        }
    }

    /// 把落盘的事件装回内核的 `EventLog` —— **然后就能用内核的校验器验链**。
    ///
    /// 这个函数是"唯一真相源"这句话的落点：磁盘上的字节 → 内核的 `verify()`。
    public func eventLog(sessionID: UUID) throws -> EventLog {
        let log = EventLog(sessionID: sessionID)
        log.loadHistorical(try loadAll(sessionID: sessionID))
        return log
    }

    private struct LastRow {
        var sequence: Int64
        var hash: Data
    }

    private static func lastRow(_ db: Database, sessionID: UUID) throws -> LastRow? {
        guard let row = try Row.fetchOne(
            db,
            sql: "SELECT seq, hash FROM event WHERE session_id = ? ORDER BY seq DESC LIMIT 1",
            arguments: [sessionID.uuidString]
        ) else { return nil }
        return LastRow(sequence: row["seq"], hash: row["hash"])
    }
}
