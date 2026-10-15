import Foundation

/// Strict host-side shape validation, never a semantic reproduction verdict.
/// The only executable reproduction is the separate shared host grader.
nonisolated enum AgentRSIFreeReviewContract {
    static let maximumBytes = 16_384
    static let maximumDepth = 8
    static let maximumItems = 128
    static let maximumStringBytes = 4096
    static let forbiddenKeys: Set<String> = ["__proto__", "prototype", "constructor"]

    static func validate(_ data: Data) throws -> AgentCanonicalJSON {
        guard data.count <= maximumBytes else { throw AgentRSIError.invalidContract }
        let value = try AgentRSIContract.raw(data)
        var items = 0
        try bound(value, depth: 1, items: &items)
        try value.requireKeys(["has_defect", "line", "reason", "reproduction"])
        guard case .bool(let defect) = value["has_defect"],
              let reason = value["reason"].text, !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AgentRSIError.invalidContract
        }
        if defect {
            guard let line = value["line"].integer, line > 0 else { throw AgentRSIError.invalidContract }
            try value["reproduction"].requireKeys(["input", "expected", "actual"])
        } else {
            guard value["line"] == .null && value["reproduction"] == .null else { throw AgentRSIError.invalidContract }
        }
        return value
    }

    private static func bound(_ value: AgentCanonicalJSON, depth: Int, items: inout Int) throws {
        guard depth <= maximumDepth else { throw AgentRSIError.invalidContract }
        let children: [AgentCanonicalJSON]
        switch value {
        case .object(let fields):
            guard Set(fields.keys).isDisjoint(with: forbiddenKeys), fields.keys.allSatisfy({ $0.utf8.count <= maximumStringBytes }) else { throw AgentRSIError.invalidContract }
            children = Array(fields.values)
        case .array(let values): children = values
        case .string(let text):
            guard text.utf8.count <= maximumStringBytes else { throw AgentRSIError.invalidContract }
            return
        default: return
        }
        items += children.count
        guard items <= maximumItems else { throw AgentRSIError.invalidContract }
        for child in children { try bound(child, depth: depth + 1, items: &items) }
    }
}
