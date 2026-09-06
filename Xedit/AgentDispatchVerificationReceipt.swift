import Foundation

/// Written by a host verifier after checking an immutable candidate. Executor
/// prose and checklist flags are not verification receipts.
nonisolated struct AgentDispatchVerificationReceipt: Codable, Equatable, Sendable {
    let id: UUID
    let revision: String
    let commands: [String]
    let outputDigests: [String]
    let operatorOverride: Bool
    let verifiedAt: Date

    var isValid: Bool {
        operatorOverride || (!commands.isEmpty && commands.count == outputDigests.count && outputDigests.allSatisfy { !$0.isEmpty })
    }
}
