import Foundation
import Testing
import GRDB
import RuneKernel
@testable import RuneStore

@Suite("运行状态与事件原子落盘")
struct RuntimeCheckpointTests {
    @Test("状态和事件共同往返，审批元数据仍在")
    func roundTrip() throws {
        let store = try RuneEventStore(inMemory: true)
        let initial = TurnState(objective: "修复文件")
        let outcome = TurnRunner.step(initial, deps: .init(modelEvents: { _ in [] }), config: .init())
        let revision = try store.commitRuntime(state: outcome.state, metadata: Data("approval".utf8), events: outcome.newEvents, expectedRevision: 0)
        let saved = try #require(try store.loadRuntime(sessionID: initial.sessionID))
        #expect(saved.state == outcome.state)
        #expect(saved.metadata == Data("approval".utf8))
        #expect(saved.revision == revision)
    }
    @Test("状态不匹配时，已经 INSERT 的事件也必须回滚")
    func rollbackTransaction() throws {
        let store = try RuneEventStore(inMemory: true)
        let initial = TurnState(objective: "检查")
        let outcome = TurnRunner.step(initial, deps: .init(modelEvents: { _ in [] }), config: .init())
        var bad = outcome.state; bad.eventSequence += 1
        #expect(throws: RuntimeStorageError.invalidState) {
            try store.commitRuntime(state: bad, metadata: Data(), events: outcome.newEvents, expectedRevision: 0)
        }
        #expect(try store.count(sessionID: initial.sessionID) == 0)
        #expect(try store.loadRuntime(sessionID: initial.sessionID) == nil)
    }
    @Test("无事件的两个状态更新也不能互相覆盖")
    func revisionCAS() throws {
        let store = try RuneEventStore(inMemory: true)
        let state = TurnState(objective: "检查")
        _ = try store.commitRuntime(state: state, metadata: Data(), events: [], expectedRevision: 0)
        #expect(throws: RuntimeStorageError.staleRevision) {
            try store.commitRuntime(state: state, metadata: Data("stale".utf8), events: [], expectedRevision: 0)
        }
    }
    @Test("落盘状态被修改后拒绝恢复")
    func corruption() throws {
        let store = try RuneEventStore(inMemory: true)
        let state = TurnState(objective: "检查")
        _ = try store.commitRuntime(state: state, metadata: Data(), events: [], expectedRevision: 0)
        try store.dbQueue.write { db in try db.execute(sql: "UPDATE runtime_checkpoint SET metadata = ?", arguments: [Data("tampered".utf8)]) }
        #expect(throws: RuntimeStorageError.corruptedCheckpoint) { try store.loadRuntime(sessionID: state.sessionID) }
    }
    @Test("关闭数据库再打开仍能恢复状态")
    func reopen() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let state = TurnState(objective: "检查")
        do { let store = try RuneEventStore(path: url.path); _ = try store.commitRuntime(state: state, metadata: Data(), events: [], expectedRevision: 0) }
        let reopened = try RuneEventStore(path: url.path)
        #expect(try reopened.loadRuntime(sessionID: state.sessionID)?.state == state)
    }
    @Test("v1 事件库迁移到 v2 保留已有事件")
    func migrationFromV1() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let session = UUID()
        do {
            let store = try RuneEventStore(path: url.path)
            _ = try store.append(sessionID: session, kind: .userMessage, payload: ["text": .string("保留")])
            try store.dbQueue.write { db in
                try db.execute(sql: "DROP TABLE runtime_checkpoint")
                try db.execute(sql: "PRAGMA user_version = 1")
            }
        }
        let migrated = try RuneEventStore(path: url.path)
        #expect(try migrated.count(sessionID: session) == 1)
        #expect(try migrated.eventLog(sessionID: session).verify(full: true).isOK)
        let newState = TurnState(objective: "new")
        _ = try migrated.commitRuntime(state: newState, metadata: Data(), events: [], expectedRevision: 0)
        #expect(try migrated.loadRuntime(sessionID: newState.sessionID) != nil)
    }

}
