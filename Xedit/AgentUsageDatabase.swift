//
//  AgentUsageDatabase.swift
//  WillDeep
//
//  统计数据的专用库。
//
//  在这之前，统计走的是「一个会话一个 usage-v1 侧车 JSON」。那套东西是
//  为了不在启动时全量解码会话原文而做的，它确实做到了，但自己长成了新的
//  胖子：本机实测 299 个文件、21.5 MB，而其中字段值只占 5 MB——剩下十几
//  MB 全是同一批字段名被重复写了 28,127 遍。打开统计面板要把这 21.5 MB
//  逐个解析出来，光解析就是一秒的量级。
//
//  换成 SQLite 之后，字段名在表结构里只存一次，标量各占一列，读取只碰
//  需要的列，单个会话更新也不必重写整个文件。
//
//  几条刻意的设计选择：
//
//   · **双写，不迁移。** 侧车照旧写、照旧能读。库坏了、被删了、schema
//     版本对不上，读取路径直接回落到侧车扫描，用户什么都不会察觉。统计
//     数据是可以从会话原文重建的派生物，为它引入一个「坏了就没救」的
//     单点不值得。
//   · **标量进列，嵌套进 JSON。** `subagentRuns`、`hostWorkerRuns` 这类
//     嵌套记录实测加起来不到 0.01 MB，为它们建表要跟着上游类型一起演进，
//     成本远大于收益。工具调用名例外——聚合天天按它分组，所以单独成表。
//   · **往返必须逐字节等价。** 快照要能原样出入，任何字段的丢失都会让
//     面板上的数字悄悄变小。`AgentUsageDatabaseTests` 用与侧车同一份
//     富样本钉这件事。
//

import Foundation
import SQLite3

/// SQLite 要求告诉它字符串缓冲区是不是临时的。Swift 的字符串桥接过去
/// 之后随时可能失效，所以一律按临时处理，让 SQLite 自己拷一份。
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// 时间一律截到整秒再入库。
///
/// 侧车用 `JSONEncoder.dateEncodingStrategy = .iso8601` 落盘，那个格式
/// 不带小数秒，等于把时间截到整秒；而库存的是 `Double`，原样保留小数。
/// 两条路径于是会对同一个会话给出「看起来一模一样、比较起来不相等」的
/// 快照——`Date` 的 description 只印到秒，这种不等在日志里完全看不出来，
/// 是最难查的一类。库既然是侧车的快路径，就得跟它对齐到同一个精度。
///
/// 截断（不是四舍五入）是因为 ISO8601 就是截断的。统计按天和小时分桶，
/// 丢掉小数秒不影响任何一个数字。
private func usageSecondPrecision(_ date: Date) -> TimeInterval {
    date.timeIntervalSince1970.rounded(.down)
}

/// 源文件指纹：文件大小加修改时间。与 `AgentSessionStore` 的侧车用的是
/// 同一套判据，所以库和侧车对「这个会话的统计过期了没有」的看法永远
/// 一致，不会出现一边说要重建一边说不用的分裂。
nonisolated struct AgentUsageSourceStamp: Equatable {
    let fileSize: UInt64
    let modificationTime: TimeInterval

    /// 读一次文件属性。读不到就返回 nil——拿不到指纹时宁可当成过期。
    static func read(at url: URL) -> AgentUsageSourceStamp? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attributes[.size] as? NSNumber)?.uint64Value,
              let date = attributes[.modificationDate] as? Date else {
            return nil
        }
        return AgentUsageSourceStamp(fileSize: size, modificationTime: date.timeIntervalSince1970)
    }
}

nonisolated final class AgentUsageDatabase {
    /// 表结构版本。改了列就得加一，旧库会被整个丢掉重建——它是派生数据，
    /// 重建比写迁移脚本便宜得多，也不会有迁移写错把统计弄脏的风险。
    static let schemaVersion = 1

    private var handle: OpaquePointer?
    private let lock = NSLock()
    // Only fixed write SQL reaches this cache, under `lock`. Reuse the same
    // VM for every history row instead of parsing/compiling thousands of INSERTs.
    private var writeStatements: [String: OpaquePointer] = [:]
    // Keep a bounded, committed baseline, not the conversation's text. Streaming
    // updates usually change one usage row; rewriting the prefix dominated rc7
    // CPU profiles. A different SQLite connection invalidates this baseline.
    private static let maximumCachedSessions = 4
    private static let maximumCachedMessages = 4096
    private var committedSnapshots: [UUID: AgentUsageSessionSnapshot] = [:]
    private var snapshotOrder: [UUID] = []
    private var committedDataVersion: Int64?

    // MARK: - 生命周期

    /// 打开（必要时创建）指定路径上的库。打不开就返回 nil——调用方回落
    /// 到侧车扫描，不该因为统计库有问题就让功能整个不可用。
    init?(url: URL) {
        var database: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(url.path, &database, flags, nil) == SQLITE_OK, let database else {
            if let database { sqlite3_close_v2(database) }
            return nil
        }
        handle = database
        // WAL：读不挡写。设置窗口、桌宠等多个 AppState 实例会同时读这个库。
        exec("PRAGMA journal_mode = WAL;")
        // NORMAL：统计数据丢最后几条也只是少几个 token 的账，不值得每次
        // 写入都等一次 fsync。
        exec("PRAGMA synchronous = NORMAL;")
        exec("PRAGMA foreign_keys = ON;")
        guard prepareSchema() else {
            sqlite3_close_v2(database)
            handle = nil
            return nil
        }
    }

    deinit {
        for statement in writeStatements.values { sqlite3_finalize(statement) }
        if let handle { sqlite3_close_v2(handle) }
    }

    /// 库文件放在会话目录旁边，跟着同一份用户数据走。
    static func defaultURL(in directory: URL) -> URL {
        directory.appendingPathComponent("usage.sqlite")
    }

    // MARK: - 表结构

    private func prepareSchema() -> Bool {
        let storedVersion = queryScalarInt("PRAGMA user_version;") ?? 0
        if storedVersion != 0 && storedVersion != Self.schemaVersion {
            // 版本对不上就整个推倒。库是派生数据，重建的代价是一次全量
            // 扫描，写一套迁移脚本的代价是永远得维护它。
            guard exec("DROP TABLE IF EXISTS message_tool_calls;"),
                  exec("DROP TABLE IF EXISTS messages;"),
                  exec("DROP TABLE IF EXISTS sessions;") else { return false }
        }
        let schema = """
        CREATE TABLE IF NOT EXISTS sessions (
            id TEXT PRIMARY KEY NOT NULL,
            model_id TEXT,
            provider_id TEXT,
            provider_display_name TEXT,
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL,
            workspace_identifier TEXT,
            edited_file_count INTEGER NOT NULL,
            artifact_count INTEGER NOT NULL,
            is_managed_routing INTEGER NOT NULL,
            source_size INTEGER NOT NULL,
            source_mtime REAL NOT NULL,
            extras TEXT
        );
        CREATE INDEX IF NOT EXISTS idx_sessions_updated_at ON sessions(updated_at DESC);

        CREATE TABLE IF NOT EXISTS messages (
            session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
            seq INTEGER NOT NULL,
            message_id TEXT,
            role TEXT NOT NULL,
            created_at REAL NOT NULL,
            is_operator_input INTEGER,
            worker_route_profile_id TEXT,
            content_characters INTEGER NOT NULL,
            reasoning_characters INTEGER NOT NULL,
            image_count INTEGER NOT NULL,
            tool_argument_characters INTEGER NOT NULL,
            tool_call_id TEXT,
            tool_call_status TEXT,
            tool_error_message TEXT,
            usage_tokens INTEGER,
            prompt_tokens INTEGER,
            completion_tokens INTEGER,
            cached_prompt_tokens INTEGER,
            cache_write_prompt_tokens INTEGER,
            reasoning_tokens INTEGER,
            origin TEXT,
            origin_label TEXT,
            request_model_id TEXT,
            request_provider_id TEXT,
            request_provider_display_name TEXT,
            request_stable_prefix_characters INTEGER,
            elapsed_seconds REAL,
            first_response_seconds REAL,
            request_is_local INTEGER,
            extras TEXT,
            PRIMARY KEY (session_id, seq)
        );
        CREATE INDEX IF NOT EXISTS idx_messages_created_at ON messages(created_at);

        CREATE TABLE IF NOT EXISTS message_tool_calls (
            session_id TEXT NOT NULL,
            seq INTEGER NOT NULL,
            ord INTEGER NOT NULL,
            name TEXT,
            external_id TEXT,
            PRIMARY KEY (session_id, seq, ord)
        );
        CREATE INDEX IF NOT EXISTS idx_tool_calls_name ON message_tool_calls(name);
        """
        guard exec(schema) else { return false }
        return exec("PRAGMA user_version = \(Self.schemaVersion);")
    }

    // MARK: - 写入

    /// 覆盖写入一个会话。整体一个事务：要么这个会话的新内容全在，要么
    /// 旧内容原封不动。半个会话的统计比没有统计更难查。
    @discardableResult
    func upsert(_ snapshot: AgentUsageSessionSnapshot, signature: AgentUsageSourceStamp) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard handle != nil else { return false }
        guard exec("BEGIN IMMEDIATE;") else { return false }
        let version = dataVersion()
        if version == nil || version != committedDataVersion {
            clearCommittedSnapshots()
        }
        if writeSession(snapshot, signature: signature, previous: committedSnapshots[snapshot.id]),
           exec("COMMIT;") {
            rememberCommitted(snapshot, dataVersion: version)
            return true
        }
        _ = exec("ROLLBACK;")
        clearCommittedSnapshots()
        return false
    }

    private func dataVersion() -> Int64? {
        guard let statement = prepare("PRAGMA data_version;") else { return nil }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return sqlite3_column_int64(statement, 0)
    }

    private func clearCommittedSnapshots() {
        committedSnapshots.removeAll()
        snapshotOrder.removeAll()
        committedDataVersion = nil
    }

    private func rememberCommitted(_ snapshot: AgentUsageSessionSnapshot, dataVersion: Int64?) {
        committedDataVersion = dataVersion
        snapshotOrder.removeAll { $0 == snapshot.id }
        committedSnapshots.removeValue(forKey: snapshot.id)
        guard snapshot.messages.count <= Self.maximumCachedMessages else { return }
        committedSnapshots[snapshot.id] = snapshot
        snapshotOrder.append(snapshot.id)
        while snapshotOrder.count > Self.maximumCachedSessions {
            committedSnapshots.removeValue(forKey: snapshotOrder.removeFirst())
        }
    }

    /// 批量写入，一个事务包全部。回填几百个会话时逐条开事务会慢一个
    /// 数量级——每个事务都要落一次 WAL。
    @discardableResult
    func replaceAll(with entries: [(snapshot: AgentUsageSessionSnapshot, signature: AgentUsageSourceStamp)]) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        clearCommittedSnapshots()
        guard handle != nil else { return false }
        guard exec("BEGIN IMMEDIATE;") else { return false }
        guard exec("DELETE FROM message_tool_calls;"),
              exec("DELETE FROM messages;"),
              exec("DELETE FROM sessions;") else {
            _ = exec("ROLLBACK;")
            return false
        }
        for entry in entries where !writeSession(entry.snapshot, signature: entry.signature) {
            _ = exec("ROLLBACK;")
            return false
        }
        return exec("COMMIT;")
    }

    @discardableResult
    func delete(id: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        clearCommittedSnapshots()
        let key = id.uuidString
        // messages 靠外键级联，message_tool_calls 刻意没设外键（它按
        // (session_id, seq) 复合定位，加外键要多一个索引却换不来什么），
        // 所以手动删。
        return executeBinding("DELETE FROM message_tool_calls WHERE session_id = ?;", [.text(key)])
            && executeBinding("DELETE FROM messages WHERE session_id = ?;", [.text(key)])
            && executeBinding("DELETE FROM sessions WHERE id = ?;", [.text(key)])
    }

    /// 库里每个会话对应的源文件指纹。判断哪些会话需要重建就靠它——与
    /// 侧车用的是同一套判据（文件大小 + 修改时间），所以两条路径对
    /// 「什么算过期」的看法永远一致。
    func storedSignatures() -> [UUID: AgentUsageSourceStamp] {
        lock.lock()
        defer { lock.unlock() }
        guard let statement = prepare("SELECT id, source_size, source_mtime FROM sessions;") else { return [:] }
        defer { sqlite3_finalize(statement) }
        var stamps: [UUID: AgentUsageSourceStamp] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let raw = columnText(statement, 0), let id = UUID(uuidString: raw) else { continue }
            stamps[id] = AgentUsageSourceStamp(
                fileSize: UInt64(max(0, sqlite3_column_int64(statement, 1))),
                modificationTime: sqlite3_column_double(statement, 2)
            )
        }
        return stamps
    }

    private func writeSession(
        _ snapshot: AgentUsageSessionSnapshot,
        signature: AgentUsageSourceStamp,
        previous: AgentUsageSessionSnapshot? = nil
    ) -> Bool {
        let key = snapshot.id.uuidString
        // 先清空这个会话的旧行。ON DELETE CASCADE 只管 messages，工具
        // 调用表刻意不设外键（它按 (session_id, seq) 复合定位，加外键
        // 要多一个索引却换不来什么），所以这里手动删。
        if previous == nil {
            guard executeBinding("DELETE FROM message_tool_calls WHERE session_id = ?;", [.text(key)]),
              executeBinding("DELETE FROM messages WHERE session_id = ?;", [.text(key)]),
              executeBinding("DELETE FROM sessions WHERE id = ?;", [.text(key)]) else {
                return false
            }
        } else {
            let tail: [Binding] = [.text(key), .integer(Int64(snapshot.messages.count))]
            guard executeBinding("DELETE FROM message_tool_calls WHERE session_id = ? AND seq >= ?;", tail),
                  executeBinding("DELETE FROM messages WHERE session_id = ? AND seq >= ?;", tail) else {
                return false
            }
        }

        let sessionExtras = SessionExtras(
            hostWorkerRuns: snapshot.hostWorkerRuns,
            coordinatorWorkerRuns: snapshot.coordinatorWorkerRuns,
            auxiliaryModelRequests: snapshot.auxiliaryModelRequests,
            artifactPaths: snapshot.artifactPaths
        )
        let sessionBindings: [Binding] = [
            .text(key),
            .optionalText(snapshot.modelID),
            .optionalText(snapshot.providerID),
            .optionalText(snapshot.providerDisplayName),
            .real(usageSecondPrecision(snapshot.createdAt)),
            .real(usageSecondPrecision(snapshot.updatedAt)),
            .optionalText(snapshot.workspaceIdentifier),
            .integer(Int64(snapshot.editedFileCount)),
            .integer(Int64(snapshot.artifactCount)),
            .integer(snapshot.isManagedRouting ? 1 : 0),
            .integer(Int64(clamping: signature.fileSize)),
            .real(signature.modificationTime),
            .optionalText(sessionExtras.encoded()),
        ]
        guard executeBinding(
            """
            INSERT INTO sessions (
                id, model_id, provider_id, provider_display_name, created_at, updated_at,
                workspace_identifier, edited_file_count, artifact_count, is_managed_routing,
                source_size, source_mtime, extras
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                model_id=excluded.model_id, provider_id=excluded.provider_id,
                provider_display_name=excluded.provider_display_name,
                created_at=excluded.created_at, updated_at=excluded.updated_at,
                workspace_identifier=excluded.workspace_identifier,
                edited_file_count=excluded.edited_file_count, artifact_count=excluded.artifact_count,
                is_managed_routing=excluded.is_managed_routing,
                source_size=excluded.source_size, source_mtime=excluded.source_mtime, extras=excluded.extras;
            """,
            sessionBindings
        ) else { return false }

        for (index, message) in snapshot.messages.enumerated() {
            if let previous, index < previous.messages.count {
                if previous.messages[index] == message { continue }
                let row: [Binding] = [.text(key), .integer(Int64(index))]
                guard executeBinding("DELETE FROM message_tool_calls WHERE session_id = ? AND seq = ?;", row),
                      executeBinding("DELETE FROM messages WHERE session_id = ? AND seq = ?;", row) else {
                    return false
                }
            }
            let extras = MessageExtras(
                subagentProfileIDs: message.subagentProfileIDs,
                subagentRuns: message.subagentRuns
            )
            let messageBindings: [Binding] = [
                .text(key),
                .integer(Int64(index)),
                .optionalText(message.id?.uuidString),
                .text(message.role.rawValue),
                .real(usageSecondPrecision(message.createdAt)),
                .optionalBool(message.isOperatorInput),
                .optionalText(message.workerRouteProfileID),
                .integer(Int64(message.contentCharacterCount)),
                .integer(Int64(message.reasoningCharacterCount)),
                .integer(Int64(message.imageCount)),
                .integer(Int64(message.toolCallArgumentCharacterCount)),
                .optionalText(message.toolCallID),
                .optionalText(message.toolCallStatus?.rawValue),
                .optionalText(message.toolErrorMessage),
                .optionalInteger(message.usageTokens),
                .optionalInteger(message.promptTokens),
                .optionalInteger(message.completionTokens),
                .optionalInteger(message.cachedPromptTokens),
                .optionalInteger(message.cacheWritePromptTokens),
                .optionalInteger(message.reasoningTokens),
                .optionalText(message.origin?.rawValue),
                .optionalText(message.originLabel),
                .optionalText(message.requestModelID),
                .optionalText(message.requestProviderID),
                .optionalText(message.requestProviderDisplayName),
                .optionalInteger(message.requestStablePrefixCharacters),
                .optionalReal(message.elapsedSeconds),
                .optionalReal(message.firstResponseSeconds),
                .optionalBool(message.requestIsLocal),
                .optionalText(extras.encoded()),
            ]
            guard executeBinding(
                """
                INSERT INTO messages (
                    session_id, seq, message_id, role, created_at, is_operator_input,
                    worker_route_profile_id, content_characters, reasoning_characters, image_count,
                    tool_argument_characters, tool_call_id, tool_call_status, tool_error_message,
                    usage_tokens, prompt_tokens, completion_tokens, cached_prompt_tokens,
                    cache_write_prompt_tokens, reasoning_tokens, origin, origin_label,
                    request_model_id, request_provider_id, request_provider_display_name,
                    request_stable_prefix_characters, elapsed_seconds, first_response_seconds,
                    request_is_local, extras
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
                """,
                messageBindings
            ) else { return false }

            // 名字与外部 id 两个数组长度可以不等（历史数据里确实有），
            // 所以按两者的最大长度铺行，短的那边补 NULL，读回时各自
            // compactMap 就能还原成原来的两个数组。
            let toolCallCount = max(message.toolCallNames.count, message.toolCallExternalIDs.count)
            for ord in 0..<toolCallCount {
                guard executeBinding(
                    "INSERT INTO message_tool_calls (session_id, seq, ord, name, external_id) VALUES (?, ?, ?, ?, ?);",
                    [
                        .text(key),
                        .integer(Int64(index)),
                        .integer(Int64(ord)),
                        .optionalText(ord < message.toolCallNames.count ? message.toolCallNames[ord] : nil),
                        .optionalText(ord < message.toolCallExternalIDs.count ? message.toolCallExternalIDs[ord] : nil),
                    ]
                ) else { return false }
            }
        }
        return true
    }

    // MARK: - 读取

    /// 全部会话，按 updatedAt 倒序——与侧车扫描同一个顺序，调用方感觉
    /// 不到换了后端。
    func loadAll() -> [AgentUsageSessionSnapshot] {
        lock.lock()
        defer { lock.unlock() }
        guard handle != nil else { return [] }

        var messagesBySession: [String: [(seq: Int, message: AgentUsageMessageSnapshot)]] = [:]
        var toolCalls: [String: [Int: [(ord: Int, name: String?, externalID: String?)]]] = [:]

        if let statement = prepare(
            "SELECT session_id, seq, ord, name, external_id FROM message_tool_calls ORDER BY session_id, seq, ord;"
        ) {
            defer { sqlite3_finalize(statement) }
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let sessionID = columnText(statement, 0) else { continue }
                let seq = Int(sqlite3_column_int64(statement, 1))
                toolCalls[sessionID, default: [:]][seq, default: []].append((
                    ord: Int(sqlite3_column_int64(statement, 2)),
                    name: columnText(statement, 3),
                    externalID: columnText(statement, 4)
                ))
            }
        }

        if let statement = prepare("SELECT * FROM messages ORDER BY session_id, seq;") {
            defer { sqlite3_finalize(statement) }
            let columns = columnIndexMap(statement)
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let sessionID = text(statement, columns, "session_id") else { continue }
                let seq = Int(integer(statement, columns, "seq") ?? 0)
                let calls = (toolCalls[sessionID]?[seq] ?? []).sorted { $0.ord < $1.ord }
                let extras = MessageExtras.decode(text(statement, columns, "extras"))
                // 每个可选字段先落成局部量。三十个参数的构造调用里塞满
                // `map`/`flatMap` 链，类型检查器会直接放弃（SourceKit 报
                // "unable to type-check in reasonable time"），整个文件的
                // 编译时间跟着爆掉。
                let messageID = text(statement, columns, "message_id").flatMap(UUID.init(uuidString:))
                let role = AgentRole(rawValue: text(statement, columns, "role") ?? "") ?? .assistant
                let usageTokens: Int? = integer(statement, columns, "usage_tokens").map { Int($0) }
                let promptTokens: Int? = integer(statement, columns, "prompt_tokens").map { Int($0) }
                let completionTokens: Int? = integer(statement, columns, "completion_tokens").map { Int($0) }
                let cachedTokens: Int? = integer(statement, columns, "cached_prompt_tokens").map { Int($0) }
                let cacheWriteTokens: Int? = integer(statement, columns, "cache_write_prompt_tokens").map { Int($0) }
                let reasoningTokens: Int? = integer(statement, columns, "reasoning_tokens").map { Int($0) }
                let stablePrefix: Int? = integer(statement, columns, "request_stable_prefix_characters")
                    .map { Int($0) }
                let status = text(statement, columns, "tool_call_status")
                    .flatMap(AgentToolCallStatus.init(rawValue:))
                let origin = text(statement, columns, "origin").flatMap(AgentMessageOrigin.init(rawValue:))
                let message = AgentUsageMessageSnapshot(
                    id: messageID,
                    role: role,
                    isOperatorInput: bool(statement, columns, "is_operator_input"),
                    workerRouteProfileID: text(statement, columns, "worker_route_profile_id"),
                    contentCharacterCount: Int(integer(statement, columns, "content_characters") ?? 0),
                    reasoningCharacterCount: Int(integer(statement, columns, "reasoning_characters") ?? 0),
                    imageCount: Int(integer(statement, columns, "image_count") ?? 0),
                    toolCallArgumentCharacterCount: Int(integer(statement, columns, "tool_argument_characters") ?? 0),
                    toolCallNames: calls.compactMap(\.name),
                    toolCallExternalIDs: calls.compactMap(\.externalID),
                    subagentProfileIDs: extras.subagentProfileIDs,
                    subagentRuns: extras.subagentRuns,
                    toolCallID: text(statement, columns, "tool_call_id"),
                    toolCallStatus: status,
                    toolErrorMessage: text(statement, columns, "tool_error_message"),
                    usageTokens: usageTokens,
                    promptTokens: promptTokens,
                    completionTokens: completionTokens,
                    cachedPromptTokens: cachedTokens,
                    cacheWritePromptTokens: cacheWriteTokens,
                    reasoningTokens: reasoningTokens,
                    origin: origin,
                    originLabel: text(statement, columns, "origin_label"),
                    requestModelID: text(statement, columns, "request_model_id"),
                    requestProviderID: text(statement, columns, "request_provider_id"),
                    requestProviderDisplayName: text(statement, columns, "request_provider_display_name"),
                    requestStablePrefixCharacters: stablePrefix,
                    elapsedSeconds: real(statement, columns, "elapsed_seconds"),
                    firstResponseSeconds: real(statement, columns, "first_response_seconds"),
                    requestIsLocal: bool(statement, columns, "request_is_local"),
                    createdAt: Date(timeIntervalSince1970: real(statement, columns, "created_at") ?? 0)
                )
                messagesBySession[sessionID, default: []].append((seq, message))
            }
        }

        guard let statement = prepare("SELECT * FROM sessions ORDER BY updated_at DESC;") else { return [] }
        defer { sqlite3_finalize(statement) }
        let columns = columnIndexMap(statement)
        var snapshots: [AgentUsageSessionSnapshot] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let rawID = text(statement, columns, "id"), let id = UUID(uuidString: rawID) else { continue }
            let extras = SessionExtras.decode(text(statement, columns, "extras"))
            let ordered = (messagesBySession[rawID] ?? [])
                .sorted { $0.seq < $1.seq }
                .map(\.message)
            snapshots.append(AgentUsageSessionSnapshot(
                id: id,
                modelID: text(statement, columns, "model_id"),
                providerID: text(statement, columns, "provider_id"),
                providerDisplayName: text(statement, columns, "provider_display_name"),
                createdAt: Date(timeIntervalSince1970: real(statement, columns, "created_at") ?? 0),
                updatedAt: Date(timeIntervalSince1970: real(statement, columns, "updated_at") ?? 0),
                messages: ordered,
                hostWorkerRuns: extras.hostWorkerRuns,
                coordinatorWorkerRuns: extras.coordinatorWorkerRuns,
                auxiliaryModelRequests: extras.auxiliaryModelRequests,
                workspaceIdentifier: text(statement, columns, "workspace_identifier"),
                editedFileCount: Int(integer(statement, columns, "edited_file_count") ?? 0),
                artifactCount: Int(integer(statement, columns, "artifact_count") ?? 0),
                artifactPaths: extras.artifactPaths,
                isManagedRouting: (integer(statement, columns, "is_managed_routing") ?? 0) != 0
            ))
        }
        return snapshots
    }

    // MARK: - 嵌套字段

    /// 会话级的嵌套记录。实测这几项加起来不到 0.01 MB，为它们各自建表
    /// 要跟着上游类型一起演进，成本远大于收益。
    private struct SessionExtras: Codable {
        var hostWorkerRuns: [AgentHostWorkerRunRecord]?
        var coordinatorWorkerRuns: [AgentSubagentRunUsage]?
        var auxiliaryModelRequests: [AgentAuxiliaryModelRequestRecord]
        var artifactPaths: [String]

        func encoded() -> String? {
            guard hostWorkerRuns != nil || coordinatorWorkerRuns != nil
                || !auxiliaryModelRequests.isEmpty || !artifactPaths.isEmpty else { return nil }
            guard let data = try? JSONEncoder.usageExtras.encode(self) else { return nil }
            return String(data: data, encoding: .utf8)
        }

        static func decode(_ raw: String?) -> SessionExtras {
            guard let raw, let data = raw.data(using: .utf8),
                  let decoded = try? JSONDecoder.usageExtras.decode(SessionExtras.self, from: data) else {
                return SessionExtras(
                    hostWorkerRuns: nil,
                    coordinatorWorkerRuns: nil,
                    auxiliaryModelRequests: [],
                    artifactPaths: []
                )
            }
            return decoded
        }
    }

    private struct MessageExtras: Codable {
        var subagentProfileIDs: [String]
        var subagentRuns: [AgentSubagentRunUsage]

        func encoded() -> String? {
            guard !subagentProfileIDs.isEmpty || !subagentRuns.isEmpty else { return nil }
            guard let data = try? JSONEncoder.usageExtras.encode(self) else { return nil }
            return String(data: data, encoding: .utf8)
        }

        static func decode(_ raw: String?) -> MessageExtras {
            guard let raw, let data = raw.data(using: .utf8),
                  let decoded = try? JSONDecoder.usageExtras.decode(MessageExtras.self, from: data) else {
                return MessageExtras(subagentProfileIDs: [], subagentRuns: [])
            }
            return decoded
        }
    }

    // MARK: - SQLite 细务

    private enum Binding {
        case text(String)
        case optionalText(String?)
        case integer(Int64)
        case optionalInteger(Int?)
        case real(Double)
        case optionalReal(Double?)
        case optionalBool(Bool?)
    }

    private func executeBinding(_ sql: String, _ bindings: [Binding]) -> Bool {
        guard let statement = writeStatement(for: sql) else { return false }
        defer {
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
        }
        for (offset, binding) in bindings.enumerated() {
            let index = Int32(offset + 1)
            switch binding {
            case .text(let value):
                bindText(statement, index, value)
            case .optionalText(let value):
                if let value { bindText(statement, index, value) } else { sqlite3_bind_null(statement, index) }
            case .integer(let value):
                sqlite3_bind_int64(statement, index, value)
            case .optionalInteger(let value):
                if let value { sqlite3_bind_int64(statement, index, Int64(value)) }
                else { sqlite3_bind_null(statement, index) }
            case .real(let value):
                sqlite3_bind_double(statement, index, value)
            case .optionalReal(let value):
                if let value { sqlite3_bind_double(statement, index, value) }
                else { sqlite3_bind_null(statement, index) }
            case .optionalBool(let value):
                if let value { sqlite3_bind_int64(statement, index, value ? 1 : 0) }
                else { sqlite3_bind_null(statement, index) }
            }
        }
        return sqlite3_step(statement) == SQLITE_DONE
    }

    private func writeStatement(for sql: String) -> OpaquePointer? {
        if let statement = writeStatements[sql] { return statement }
        guard let statement = prepare(sql) else { return nil }
        writeStatements[sql] = statement
        return statement
    }

    private func prepare(_ sql: String) -> OpaquePointer? {
        guard let handle else { return nil }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            if let statement { sqlite3_finalize(statement) }
            return nil
        }
        return statement
    }

    private func bindText(_ statement: OpaquePointer?, _ index: Int32, _ value: String) {
        sqlite3_bind_text(statement, index, value, -1, SQLITE_TRANSIENT)
    }

    @discardableResult
    private func exec(_ sql: String) -> Bool {
        guard let handle else { return false }
        return sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK
    }

    private func queryScalarInt(_ sql: String) -> Int? {
        guard let statement = prepare(sql) else { return nil }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return Int(sqlite3_column_int64(statement, 0))
    }

    /// `SELECT *` 的列名到序号。按名字取列，加列时不必回来改一串下标。
    private func columnIndexMap(_ statement: OpaquePointer?) -> [String: Int32] {
        var map: [String: Int32] = [:]
        let count = sqlite3_column_count(statement)
        for index in 0..<count {
            guard let name = sqlite3_column_name(statement, index) else { continue }
            map[String(cString: name)] = index
        }
        return map
    }

    private func columnText(_ statement: OpaquePointer?, _ index: Int32) -> String? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL,
              let raw = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: raw)
    }

    private func text(_ statement: OpaquePointer?, _ columns: [String: Int32], _ name: String) -> String? {
        guard let index = columns[name] else { return nil }
        return columnText(statement, index)
    }

    private func integer(_ statement: OpaquePointer?, _ columns: [String: Int32], _ name: String) -> Int64? {
        guard let index = columns[name], sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
        return sqlite3_column_int64(statement, index)
    }

    private func real(_ statement: OpaquePointer?, _ columns: [String: Int32], _ name: String) -> Double? {
        guard let index = columns[name], sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
        return sqlite3_column_double(statement, index)
    }

    private func bool(_ statement: OpaquePointer?, _ columns: [String: Int32], _ name: String) -> Bool? {
        integer(statement, columns, name).map { $0 != 0 }
    }
}

private extension JSONEncoder {
    /// 嵌套字段的编码要与侧车一致，否则同一条记录在两条路径上会长得不
    /// 一样，往返等价的断言就守不住了。
    static let usageExtras: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
}

private extension JSONDecoder {
    static let usageExtras: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
