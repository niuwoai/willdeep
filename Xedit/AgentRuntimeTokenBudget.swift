import Foundation

/// Cumulative main/compression usage. Repeated cumulative stream receipts replace
/// the prior receipt; retries keep their own identity and never erase spending.
@MainActor
final class AgentRuntimeTokenBudget {
    let limit: Int?
    private(set) var used = 0
    private var receipts: [UUID: Int] = [:]
    private var unknown: Set<UUID> = []
    private var inconsistent: Set<UUID> = []

    init(limit: Int?) { self.limit = limit }
    func begin(_ id: UUID) { unknown.insert(id) }
    func report(_ id: UUID, total: Int) {
        guard total >= 0, total >= (receipts[id] ?? 0) else {
            unknown.insert(id)
            inconsistent.insert(id)
            return
        }
        let sum = used.addingReportingOverflow(total - (receipts[id] ?? 0))
        used = sum.overflow ? Int.max : sum.partialValue
        receipts[id] = total
        if !inconsistent.contains(id) { unknown.remove(id) }
    }
    func recordCompression(_ record: AgentAuxiliaryModelRequestRecord) {
        guard record.purpose == .contextCompression else { return }
        begin(record.id)
        if let input = record.promptTokens, let output = record.completionTokens {
            let total = input.addingReportingOverflow(output)
            if !total.overflow { report(record.id, total: total.partialValue) }
        }
    }
    var hasUnknownUsage: Bool { !unknown.isEmpty }
    var isBlocked: Bool { limit.map { used >= $0 || hasUnknownUsage } ?? false }
}
