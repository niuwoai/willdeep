import Foundation
import SQLite3
import Darwin

/// Authoritative attempt receipts, separate from the prunable usage dashboard.
/// The owner and storage directory are captured by the host, never model args.
/// Admission uses reported spend plus outstanding estimates. It is not a
/// provider billing guarantee; unknown legacy attempts never become free.
nonisolated struct AgentModelRequestLedger: Equatable, Sendable {
    let directory: URL
    let ownerID: UUID

    var databaseURL: URL { directory.appendingPathComponent("\(ownerID.uuidString).sqlite3") }

    struct Usage: Codable, Equatable, Sendable {
        let prompt: Int
        let completion: Int
        let total: Int
        let cachedPrompt: Int?
        let cacheWritePrompt: Int?
        let reasoning: Int

        var isValid: Bool {
            [prompt, completion, total, reasoning].allSatisfy { $0 >= 0 }
                && (cachedPrompt.map { $0 >= 0 } ?? true)
                && (cacheWritePrompt.map { $0 >= 0 } ?? true)
        }
    }

    enum Outcome: String, Codable, Sendable { case succeeded, failed, cancelled }
    struct Receipt: Codable, Equatable, Sendable {
        let outcome: Outcome
        /// Missing is unknown, not zero. Failure may still have billed usage.
        let usage: Usage?
    }
    struct Summary: Equatable, Sendable {
        let attempts: Int
        let unfinished: Int
        let unknownUsage: Int
        let reportedTokens: Int
    }
    struct AdmissionPolicy: Equatable, Sendable {
        let tokenLimit: Int?
        let revision: Int
    }
    struct Exposure: Equatable, Sendable {
        let accountedTokens: Int
        let estimatedTokens: Int
        let unquantifiedAttempts: Int
    }
    struct BudgetSnapshot: Equatable, Sendable {
        let policy: AdmissionPolicy
        let exposure: Exposure

        /// Nil is either unlimited or unknown, never an inferred free balance.
        var remainingTokens: Int? {
            guard let limit = policy.tokenLimit, exposure.unquantifiedAttempts == 0 else { return nil }
            let spent = exposure.accountedTokens.addingReportingOverflow(exposure.estimatedTokens)
            guard !spent.overflow else { return 0 }
            return spent.partialValue >= limit ? 0 : limit - spent.partialValue
        }
    }
    enum Failure: Error, LocalizedError, Equatable {
        case database(operation: String, code: Int32)
        case unsupportedSchema
        case duplicateRequest
        case missingRequest
        case conflictingReceipt
        case invalidUsage
        case unsafeStorage
        case invalidReservation
        case stalePolicy
        case ownerMismatch
        case budgetExceeded
        case unknownExposure

        var errorDescription: String? {
            switch self {
            case .database(let operation, let code):
                "Model request accounting failed during \(operation) (SQLite \(code)). No free budget may be inferred."
            case .unsupportedSchema: "Model request ledger schema is unsupported; existing receipts were preserved."
            case .duplicateRequest: "This model request ID was already registered; do not send it again."
            case .missingRequest: "Cannot finish an unregistered model request."
            case .conflictingReceipt: "Conflicting model request receipt; the original receipt was preserved."
            case .invalidUsage: "Invalid model usage receipt; usage must remain unknown."
            case .unsafeStorage: "Model request ledger storage is not a regular private location."
            case .invalidReservation: "A nonnegative request reservation or positive admission limit is required."
            case .stalePolicy: "The budget policy changed; reload it before changing the limit."
            case .ownerMismatch: "The model request ledger belongs to a different Goal."
            case .budgetExceeded: "The model request would exceed the Goal admission budget. No request was sent."
            case .unknownExposure: "Previous or proposed model usage cannot be quantified. Bounded admission is paused."
            }
        }
    }

    /// Commits before transport is entered. An unfinished row after a crash
    /// is uncertain; it is never permission to replay the request.
    func begin(id: UUID, providerID: String, modelID: String, reservedTokens: Int? = nil) throws {
        guard reservedTokens.map({ $0 >= 0 }) ?? true else { throw Failure.invalidReservation }
        let _: Void = try admit(id: id, providerID: providerID, modelID: modelID) { _ in ((), reservedTokens) }
    }

    /// Prepare the actual transport payload while holding the same reservation
    /// transaction. A separate "read remaining then reserve" sequence races
    /// other workers and policy changes. The closure must do local work only.
    func admit<T>(id: UUID, providerID: String, modelID: String,
                  prepare: (Int?) throws -> (value: T, reservedTokens: Int?)) throws -> T {
        try withDatabase { db in
            try transaction(db) {
                guard try !exists(id: id, db: db) else { throw Failure.duplicateRequest }
                let remaining: Int?
                if let limit = try policy(db).tokenLimit {
                    let exposure = try exposure(db)
                    guard exposure.unquantifiedAttempts == 0 else { throw Failure.unknownExposure }
                    let spent = exposure.accountedTokens.addingReportingOverflow(exposure.estimatedTokens)
                    guard !spent.overflow, spent.partialValue <= limit else { throw Failure.budgetExceeded }
                    remaining = limit - spent.partialValue
                } else { remaining = nil }
                let prepared = try prepare(remaining)
                let reservedTokens = prepared.reservedTokens
                guard reservedTokens.map({ $0 >= 0 }) ?? true else { throw Failure.invalidReservation }
                if let remaining {
                    guard let reservedTokens else { throw Failure.unknownExposure }
                    guard reservedTokens <= remaining else { throw Failure.budgetExceeded }
                }
                try statement(db, "INSERT INTO requests (id, provider_id, model_id, reserved_tokens) VALUES (?, ?, ?, ?)",
                              [.text(id.uuidString), .text(providerID), .text(modelID),
                               reservedTokens.map(Binding.integer) ?? .null]) { sql in
                    try stepDone(sql, db: db)
                }
                return prepared.value
            }
        }
    }

    func admissionPolicy() throws -> AdmissionPolicy { try withDatabase { try policy($0) } }
    func exposure() throws -> Exposure { try withDatabase { try exposure($0) } }

    /// UI reads policy and spend from one transaction, not two independently
    /// changing connections. The caller runs this disk work off the main actor.
    func budgetSnapshot() throws -> BudgetSnapshot {
        try withDatabase { db in
            try transaction(db) {
                BudgetSnapshot(policy: try policy(db), exposure: try exposure(db))
            }
        }
    }

    /// Host-only explicit policy change. Compare-and-swap prevents stale UI or
    /// workers from overwriting a newer grant. Changing limits never resets spend.
    @discardableResult
    func setAdmissionLimit(_ limit: Int?, expectedRevision: Int) throws -> AdmissionPolicy {
        guard limit.map({ $0 > 0 }) ?? true else { throw Failure.invalidReservation }
        return try withDatabase { db in
            try transaction(db) {
                let current = try policy(db)
                guard current.revision == expectedRevision else { throw Failure.stalePolicy }
                if current.tokenLimit == limit { return current }
                let next = current.revision.addingReportingOverflow(1)
                guard !next.overflow else { throw Failure.stalePolicy }
                try statement(db, "UPDATE admission_policy SET token_limit = ?, revision = ?, updated_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now') WHERE singleton = 1",
                              [limit.map(Binding.integer) ?? .null, .integer(next.partialValue)]) { sql in
                    try stepDone(sql, db: db)
                }
                return AdmissionPolicy(tokenLimit: limit, revision: next.partialValue)
            }
        }
    }

    private func policy(_ db: OpaquePointer) throws -> AdmissionPolicy {
        try statement(db, "SELECT owner_id, token_limit, revision FROM admission_policy WHERE singleton = 1") { sql in
            guard sqlite3_step(sql) == SQLITE_ROW else { throw databaseFailure(db, "policy") }
            guard sqlite3_column_text(sql, 0).map({ String(cString: $0) }) == ownerID.uuidString else {
                throw Failure.ownerMismatch
            }
            return AdmissionPolicy(tokenLimit: sqlite3_column_type(sql, 1) == SQLITE_NULL ? nil : Int(sqlite3_column_int64(sql, 1)),
                                   revision: Int(sqlite3_column_int64(sql, 2)))
        }
    }

    private func exposure(_ db: OpaquePointer) throws -> Exposure {
        try statement(db, """
            SELECT COALESCE(SUM(total_tokens), 0),
            COALESCE(SUM(CASE WHEN total_tokens IS NULL THEN reserved_tokens ELSE 0 END), 0),
            COALESCE(SUM(total_tokens IS NULL AND reserved_tokens IS NULL), 0) FROM requests
            """) { sql in
            guard sqlite3_step(sql) == SQLITE_ROW else { throw databaseFailure(db, "exposure") }
            return Exposure(accountedTokens: Int(sqlite3_column_int64(sql, 0)),
                            estimatedTokens: Int(sqlite3_column_int64(sql, 1)),
                            unquantifiedAttempts: Int(sqlite3_column_int64(sql, 2)))
        }
    }

    /// Exactly one terminal receipt per attempt. Duplicate delivery is a no-op,
    /// but a conflicting retry cannot replace a previously recorded cost.
    func finish(id: UUID, receipt: Receipt) throws {
        guard receipt.usage?.isValid != false else { throw Failure.invalidUsage }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let payload = String(decoding: try encoder.encode(receipt), as: UTF8.self)
        try withDatabase { db in
            try transaction(db) {
                guard try exists(id: id, db: db) else { throw Failure.missingRequest }
                if let existing = try receiptPayload(id: id, db: db) {
                    guard existing == payload else { throw Failure.conflictingReceipt }
                    return
                }
                try statement(db, """
                    UPDATE requests SET receipt_json = ?, total_tokens = ?,
                    updated_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now') WHERE id = ?
                    """, [.text(payload), receipt.usage.map { .integer($0.total) } ?? .null, .text(id.uuidString)]) { sql in
                    try stepDone(sql, db: db)
                }
            }
        }
    }

    func receipt(id: UUID) throws -> Receipt? {
        try withDatabase { db in
            guard let payload = try receiptPayload(id: id, db: db) else { return nil }
            return try JSONDecoder().decode(Receipt.self, from: Data(payload.utf8))
        }
    }

    func summary() throws -> Summary {
        try withDatabase { db in
            try statement(db, """
                SELECT COUNT(*), COALESCE(SUM(receipt_json IS NULL), 0),
                COALESCE(SUM(total_tokens IS NULL), 0), COALESCE(SUM(total_tokens), 0) FROM requests
                """) { sql in
                guard sqlite3_step(sql) == SQLITE_ROW else { throw databaseFailure(db, "summary") }
                return Summary(attempts: Int(sqlite3_column_int64(sql, 0)),
                               unfinished: Int(sqlite3_column_int64(sql, 1)),
                               unknownUsage: Int(sqlite3_column_int64(sql, 2)),
                               reportedTokens: Int(sqlite3_column_int64(sql, 3)))
            }
        }
    }

    private func withDatabase<T>(_ operation: (OpaquePointer) throws -> T) throws -> T {
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true,
                                    attributes: [.posixPermissions: 0o700])
        guard try directory.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
            throw Failure.unsafeStorage
        }
        // Foundation may intentionally normalize /private/var back to /var.
        // SQLite NOFOLLOW checks ancestor symlinks too, so use POSIX realpath
        // on the existing directory, WITHOUT resolving the database leaf.
        guard let resolved = realpath(directory.path, nil) else { throw Failure.unsafeStorage }
        let path = String(cString: resolved) + "/\(ownerID.uuidString).sqlite3"
        free(resolved)
        var pointer: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX | SQLITE_OPEN_NOFOLLOW
        let code = sqlite3_open_v2(path, &pointer, flags, nil)
        guard code == SQLITE_OK, let db = pointer else {
            if let pointer { sqlite3_close_v2(pointer) }
            throw Failure.database(operation: "open", code: code)
        }
        defer { sqlite3_close_v2(db) }
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        sqlite3_busy_timeout(db, 3_000)
        // EXTRA includes the rollback-journal directory sync. Unlike dashboard
        // NORMAL mode, acknowledge a receipt only after SQLite's durable commit.
        try execute(db, "PRAGMA synchronous = EXTRA")
        try transaction(db) {
            let version = try statement(db, "PRAGMA user_version") { sql in
                guard sqlite3_step(sql) == SQLITE_ROW else { throw databaseFailure(db, "schema version") }
                return sqlite3_column_int(sql, 0)
            }
            guard (0...2).contains(version) else { throw Failure.unsupportedSchema }
            try execute(db, """
                CREATE TABLE IF NOT EXISTS requests (
                    id TEXT PRIMARY KEY NOT NULL,
                    provider_id TEXT NOT NULL,
                    model_id TEXT NOT NULL,
                    receipt_json TEXT,
                    total_tokens INTEGER CHECK(total_tokens >= 0),
                    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
                    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
                )
                """)
            if version < 2 {
                try execute(db, "ALTER TABLE requests ADD COLUMN reserved_tokens INTEGER CHECK(reserved_tokens >= 0)")
                try execute(db, """
                    CREATE TABLE admission_policy (
                        singleton INTEGER PRIMARY KEY CHECK(singleton = 1),
                        owner_id TEXT NOT NULL,
                        token_limit INTEGER CHECK(token_limit > 0),
                        revision INTEGER NOT NULL CHECK(revision >= 0),
                        created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
                        updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
                    )
                    """)
                try statement(db, "INSERT INTO admission_policy (singleton, owner_id, revision) VALUES (1, ?, 0)",
                              [.text(ownerID.uuidString)]) { sql in try stepDone(sql, db: db) }
                try execute(db, "PRAGMA user_version = 2")
            }
            _ = try policy(db)
        }
        return try operation(db)
    }

    private func transaction<T>(_ db: OpaquePointer, _ operation: () throws -> T) throws -> T {
        try execute(db, "BEGIN IMMEDIATE")
        do {
            let result = try operation()
            try execute(db, "COMMIT")
            return result
        } catch {
            // Closing the connection also rolls back. Preserve the original
            // failure if rollback itself cannot run; never erase the database.
            let code = sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
            if code != SQLITE_OK { NSLog("Model ledger rollback failed (SQLite %d)", code) }
            throw error
        }
    }

    private enum Binding { case text(String), integer(Int), null }

    private func statement<T>(_ db: OpaquePointer, _ query: String, _ bindings: [Binding] = [],
                              _ operation: (OpaquePointer) throws -> T) throws -> T {
        var pointer: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &pointer, nil) == SQLITE_OK, let sql = pointer else {
            throw databaseFailure(db, "prepare")
        }
        defer { sqlite3_finalize(sql) }
        for (offset, binding) in bindings.enumerated() {
            let index = Int32(offset + 1)
            let code: Int32
            switch binding {
            case .text(let value):
                code = sqlite3_bind_text(sql, index, value, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            case .integer(let value): code = sqlite3_bind_int64(sql, index, Int64(value))
            case .null: code = sqlite3_bind_null(sql, index)
            }
            guard code == SQLITE_OK else { throw databaseFailure(db, "bind") }
        }
        return try operation(sql)
    }

    private func execute(_ db: OpaquePointer, _ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw databaseFailure(db, "transaction/schema") }
    }

    private func stepDone(_ sql: OpaquePointer, db: OpaquePointer) throws {
        guard sqlite3_step(sql) == SQLITE_DONE else { throw databaseFailure(db, "write") }
    }

    private func exists(id: UUID, db: OpaquePointer) throws -> Bool {
        try statement(db, "SELECT 1 FROM requests WHERE id = ?", [.text(id.uuidString)]) { sql in
            switch sqlite3_step(sql) {
            case SQLITE_ROW: return true
            case SQLITE_DONE: return false
            default: throw databaseFailure(db, "lookup")
            }
        }
    }

    private func receiptPayload(id: UUID, db: OpaquePointer) throws -> String? {
        try statement(db, "SELECT receipt_json FROM requests WHERE id = ?", [.text(id.uuidString)]) { sql in
            switch sqlite3_step(sql) {
            case SQLITE_ROW:
                return sqlite3_column_text(sql, 0).map { String(cString: $0) }
            case SQLITE_DONE: return nil
            default: throw databaseFailure(db, "receipt")
            }
        }
    }

    private func databaseFailure(_ db: OpaquePointer, _ operation: String) -> Failure {
        .database(operation: operation, code: sqlite3_errcode(db))
    }
}
