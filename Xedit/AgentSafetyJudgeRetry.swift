//
//  AgentSafetyJudgeRetry.swift
//  WillDeep
//
//  裁判请求的瞬时失败重试，以及「裁判这次没裁到」的留痕。
//
//  背景：裁判收到的一直是完整命令，但长命令撞 502 的比例是短命令的三倍
//  （2026-09 实测 15.1% vs 4.6%），一次网关抖动就把最长、最难人工细看的
//  命令原样推给了用户。这里给瞬时失败补一次重试，并把「没裁到」记下来，
//  让审批解释能如实说明原因，而不是去猜命令有什么问题。
//

import Foundation

nonisolated enum AgentSafetyJudgeRetry {
    /// 瞬时失败后等多久再试。零散的 502 多半一秒内就恢复；再长就是真故障，
    /// 让用户多等也换不来结论。
    static let delay: Duration = .seconds(1)

    /// 失败的那次请求耗时超过这个值就不重试。超时类失败本身已经等满了
    /// 裁判超时，再来一次等于让用户对着一张空卡干等翻倍的时间。
    static let maxRetriableAttemptSeconds: TimeInterval = 15

    static func shouldRetry(reason: String, attemptDuration: TimeInterval) -> Bool {
        guard attemptDuration < maxRetriableAttemptSeconds else { return false }
        return isTransient(reason: reason)
    }

    /// 与各 adapter 的 `.unavailable` 原因字符串对齐：`http <status>` 与
    /// `network error`。4xx（除 429）是配置或请求本身的问题，重试无益。
    static func isTransient(reason: String) -> Bool {
        if reason == "network error" { return true }
        guard reason.hasPrefix("http "),
              let status = Int(reason.dropFirst("http ".count)) else { return false }
        return status == 429 || (500...599).contains(status)
    }
}

/// 裁判没给出结论的两种情形。审批解释据此告诉用户「为什么轮到你」。
enum AgentSafetyJudgeMiss: Equatable {
    case unconfigured
    case unreachable
}

/// 按工具 + 原始命令记住最近哪些命令没裁到。只给审批解释读，不参与任何
/// 放行判定——它是说明书，不是通行证。
struct AgentSafetyJudgeMissLedger {
    static let ttl: TimeInterval = 30 * 60
    static let capacity = 64

    private var entries: [String: (miss: AgentSafetyJudgeMiss, at: Date)] = [:]

    static func key(toolName: String, command: String) -> String {
        "\(toolName)\u{1F}\(command)"
    }

    mutating func record(_ miss: AgentSafetyJudgeMiss, toolName: String, command: String, now: Date = Date()) {
        if entries.count >= Self.capacity {
            entries = entries.filter { now.timeIntervalSince($0.value.at) < Self.ttl }
            if entries.count >= Self.capacity,
               let oldest = entries.min(by: { $0.value.at < $1.value.at })?.key {
                entries.removeValue(forKey: oldest)
            }
        }
        entries[Self.key(toolName: toolName, command: command)] = (miss, now)
    }

    mutating func clear(toolName: String, command: String) {
        entries.removeValue(forKey: Self.key(toolName: toolName, command: command))
    }

    func miss(toolName: String, command: String, now: Date = Date()) -> AgentSafetyJudgeMiss? {
        guard let entry = entries[Self.key(toolName: toolName, command: command)],
              now.timeIntervalSince(entry.at) < Self.ttl else { return nil }
        return entry.miss
    }
}
