//
//  AgentFileObservationLedger.swift
//  WillDeep
//
//  「我看过 / 写过哪些文件，当时是什么样」的台账。
//
//  设计见 docs/FILE_CHANGE_PROVENANCE_DESIGN.md。它要回答的是用户原话里
//  那句「这处改动不是我做的，文件时间戳是 20:29」——写集只记得动过哪些
//  路径，记不住动成什么样，所以说不出时间戳这种证据。
//
//  探针用 `AppStateGitStatus.fileSignatureMetadata` 的一次 `lstat`，不算
//  内容 hash（首版决策，见文档 §3.3）。`read_file` 本来就要取一次 size，
//  换成这个函数一次拿齐两个数，净开销约等于零。
//
//  两条不可让渡的规矩，都在 `drift(for:)` 里：
//    - 台账里没有这个路径时返回 nil，不是「没变过」。缺凭据不等于没变。
//    - 从打开的 tab buffer 读来的内容不参与漂移判定。那份内容本来就不是
//      磁盘上的那份，拿磁盘 mtime 去比它必然误报。
//

import Foundation

public nonisolated struct AgentFileObservation: Codable, Equatable {
    public nonisolated enum Source: String, Codable, Equatable {
        case disk
        /// 内容来自编辑器里打开的那个 tab 的内存 buffer，不是磁盘。
        case buffer
    }

    public nonisolated enum Kind: String, Codable, Equatable {
        case read
        case write
    }

    public var sizeBytes: Int64
    public var modifiedAt: Date
    public var source: Source
    public var kind: Kind
    /// 本会话最后一次观察到它是这个样子的时刻。
    public var observedAt: Date

    public nonisolated init(
        sizeBytes: Int64,
        modifiedAt: Date,
        source: Source,
        kind: Kind,
        observedAt: Date = Date()
    ) {
        self.sizeBytes = sizeBytes
        self.modifiedAt = modifiedAt
        self.source = source
        self.kind = kind
        self.observedAt = observedAt
    }
}

/// 一个路径在观察之后发生的漂移。
public nonisolated struct AgentFileDrift: Equatable {
    public let path: String
    /// 本会话观察到它的时刻。
    public let observedAt: Date
    /// 磁盘现在报的修改时刻。
    public let currentModifiedAt: Date
    public let observedSizeBytes: Int64
    public let currentSizeBytes: Int64
}

public nonisolated enum AgentFileObservationLedger {
    /// 每会话上限。一次长任务读几百个文件是常态，不设上限会把会话存档撑大。
    /// 淘汰按 `observedAt` 从旧到新。
    public static let maximumEntries = 500

    /// 记一次观察。同一路径重复观察时覆盖——台账要的是「最后一次看到的样子」。
    public nonisolated static func recording(
        _ ledger: [String: AgentFileObservation],
        path: String,
        observation: AgentFileObservation
    ) -> [String: AgentFileObservation] {
        let key = normalize(path)
        guard !key.isEmpty else { return ledger }
        var next = ledger
        next[key] = observation
        return trimmed(next)
    }

    /// 超出上限时按 observedAt 丢最旧的。
    public nonisolated static func trimmed(
        _ ledger: [String: AgentFileObservation]
    ) -> [String: AgentFileObservation] {
        guard ledger.count > maximumEntries else { return ledger }
        let keep = ledger
            .sorted { $0.value.observedAt > $1.value.observedAt }
            .prefix(maximumEntries)
        return Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
    }

    /// 这个路径在本会话观察之后被改过吗。
    ///
    /// nil 有三种含义，调用方一律按「无从判断」处理，不得当成「没变过」：
    /// 台账里没有它、观察来自 tab buffer、或者现在读不到它的 stat。
    public nonisolated static func drift(
        for path: String,
        in ledger: [String: AgentFileObservation],
        currentSizeBytes: Int64,
        currentModifiedAt: Date
    ) -> AgentFileDrift? {
        let key = normalize(path)
        guard let observation = ledger[key] else { return nil }
        // buffer 里那份内容和磁盘本来就可以不同，拿磁盘 mtime 比它必然误报。
        guard observation.source == .disk else { return nil }
        // mtime 用秒级比较：lstat 给的是纳秒，但落盘 JSON 的 Date 编码会丢
        // 精度，逐纳秒比会把「同一次观察」判成漂移。
        let sameTime = Int(observation.modifiedAt.timeIntervalSince1970)
            == Int(currentModifiedAt.timeIntervalSince1970)
        guard !(sameTime && observation.sizeBytes == currentSizeBytes) else { return nil }
        return AgentFileDrift(
            path: key,
            observedAt: observation.observedAt,
            currentModifiedAt: currentModifiedAt,
            observedSizeBytes: observation.sizeBytes,
            currentSizeBytes: currentSizeBytes
        )
    }

    /// 给模型看的一句话。刻意带上两个时刻——「什么时候读的」和「什么时候被
    /// 改的」放在一起，模型才说得出用户原话里那种交代。
    public nonisolated static func driftNotice(_ drift: AgentFileDrift) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return "注意：\(drift.path) 在本会话读取之后被改动过。"
            + "读取时是 \(formatter.string(from: drift.observedAt))、"
            + "\(drift.observedSizeBytes) 字节；"
            + "磁盘现在是 \(formatter.string(from: drift.currentModifiedAt))、"
            + "\(drift.currentSizeBytes) 字节。"
            + "这处改动不是本会话做的，动它之前先确认。"
    }

    /// git 报的是相对仓库根的裸路径，而写集历史上带过 `./` 前缀。两边不归一，
    /// 同一个文件会被读成两个。
    public nonisolated static func normalize(_ path: String) -> String {
        var value = path.trimmingCharacters(in: .whitespaces)
        while value.hasPrefix("./") { value.removeFirst(2) }
        while value.hasPrefix("/") { value.removeFirst() }
        return value
    }
}
