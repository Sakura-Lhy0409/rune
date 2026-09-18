import Foundation
import GRDB
import RuneKernel

public struct StoredRuntimeCheckpoint: Sendable {
    public let state: TurnState
    public let metadata: Data
    public let revision: Int64
}

public enum RuntimeStorageError: Error, Sendable, Equatable {
    case staleRevision
    case invalidEventChain
    case invalidState
    case corruptedCheckpoint
}

extension RuneEventStore {
    /// 状态与新事件在同一事务中提交；事务失败时调用方必须停止，不能推进下一次副作用。
    /// revision 同时保护无事件的审批/暂停变更，不能只比较事件数量。
    @discardableResult
    public func commitRuntime(state: TurnState, metadata: Data, events: [RuntimeEvent],
                              expectedRevision: Int64) throws -> Int64 {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let stateData = try encoder.encode(state)
        let digest = SHA256.hash(stateData + metadata)
        return try dbQueue.write { db in
            let revision = try Int64.fetchOne(db, sql: "SELECT revision FROM runtime_checkpoint WHERE session_id = ?",
                                              arguments: [state.sessionID.uuidString]) ?? 0
            guard revision == expectedRevision else { throw RuntimeStorageError.staleRevision }
            let row = try Row.fetchOne(db, sql: "SELECT seq, hash FROM event WHERE session_id = ? ORDER BY seq DESC LIMIT 1", arguments: [state.sessionID.uuidString])
            var seq: Int64 = row?["seq"] ?? 0
            var hash: Data? = row?["hash"]
            for event in events {
                guard event.sessionID == state.sessionID, event.turnID == state.turnID,
                      event.sequence == seq + 1, event.previousHash == hash, event.verifyHash() else {
                    throw RuntimeStorageError.invalidEventChain
                }
                try Self.insert(db, event)
                seq = event.sequence; hash = event.hash
            }
            guard state.eventSequence == seq, state.lastEventHash == hash else { throw RuntimeStorageError.invalidState }
            try db.execute(sql: """
                INSERT INTO runtime_checkpoint(session_id, revision, state_json, metadata, state_hash, updated_at)
                VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT(session_id) DO UPDATE SET revision=excluded.revision,
                    state_json=excluded.state_json, metadata=excluded.metadata,
                    state_hash=excluded.state_hash, updated_at=excluded.updated_at
                """, arguments: [state.sessionID.uuidString, revision + 1, stateData, metadata, digest, Date().timeIntervalSince1970])
            return revision + 1
        }
    }

    public func loadRuntime(sessionID: UUID) throws -> StoredRuntimeCheckpoint? {
        try dbQueue.read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM runtime_checkpoint WHERE session_id = ?", arguments: [sessionID.uuidString]) else { return nil }
            let data: Data = row["state_json"], metadata: Data = row["metadata"], digest: Data = row["state_hash"]
            guard SHA256.hash(data + metadata) == digest else { throw RuntimeStorageError.corruptedCheckpoint }
            let state = try JSONDecoder().decode(TurnState.self, from: data)
            guard state.sessionID == sessionID else { throw RuntimeStorageError.corruptedCheckpoint }
            let tail = try Row.fetchOne(db, sql: "SELECT seq, hash FROM event WHERE session_id = ? ORDER BY seq DESC LIMIT 1", arguments: [sessionID.uuidString])
            let seq: Int64 = tail?["seq"] ?? 0
            let hash: Data? = tail?["hash"]
            guard state.eventSequence == seq, state.lastEventHash == hash else { throw RuntimeStorageError.invalidState }
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .millisecondsSince1970
            let rows = try Row.fetchAll(db, sql: "SELECT envelope_json FROM event WHERE session_id = ? ORDER BY seq", arguments: [sessionID.uuidString])
            let events = try rows.map { row -> RuntimeEvent in
                let json: String = row["envelope_json"]
                return try decoder.decode(RuntimeEvent.self, from: Data(json.utf8))
            }
            let log = EventLog(sessionID: sessionID); log.loadHistorical(events)
            guard log.verify(full: true).isOK else { throw RuntimeStorageError.invalidEventChain }
            return .init(state: state, metadata: metadata, revision: row["revision"])
        }
    }

    public func runtimeSessionIDs() throws -> [UUID] {
        try dbQueue.read { db in
            try String.fetchAll(db, sql: "SELECT session_id FROM runtime_checkpoint ORDER BY updated_at DESC").compactMap(UUID.init(uuidString:))
        }
    }
}
