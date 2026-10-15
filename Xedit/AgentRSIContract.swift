import Foundation

nonisolated enum AgentRSIError: Error, LocalizedError, Equatable {
    case invalidContract, paidNotApproved, missingEvidence, quota, revoked, ownerChanged
    var errorDescription: String? {
        switch self {
        case .invalidContract: return String(localized: "实验契约或版本绑定无效", table: "AgentRSI")
        case .paidNotApproved: return String(localized: "真实模型评测尚未授权", table: "AgentRSI")
        case .missingEvidence: return String(localized: "目标未执行或验证证据不完整", table: "AgentRSI")
        case .quota: return String(localized: "实验预算或尝试次数已用完", table: "AgentRSI")
        case .revoked: return String(localized: "实验上传授权已撤销或过期", table: "AgentRSI")
        case .ownerChanged: return String(localized: "账号已切换，请重新选择实验", table: "AgentRSI")
        }
    }
}

extension AgentCanonicalJSON {
    var fields: [String: Self] { if case .object(let value) = self { value } else { [:] } }
    var elements: [Self] { if case .array(let value) = self { value } else { [] } }
    var text: String? { if case .string(let value) = self { value } else { nil } }
    var integer: Int? { if case .number(let value) = self { Int(value) } else { nil } }
    subscript(_ key: String) -> Self { fields[key] ?? .null }
    func replacing(_ key: String, _ value: Self) -> Self { var copy = fields; copy[key] = value; return .object(copy) }
    static func integer(_ value: Int) -> Self { .number(String(value)) }
}

/// Uses the frozen schema for shape validation and the existing raw tokenizer
/// for duplicate keys and numeric spelling; Foundation decoding is never the
/// authority for incoming wire documents.
nonisolated enum AgentRSIContract {
    static func resource(_ name: String) throws -> Data {
        guard let url = Bundle.main.url(forResource: name, withExtension: "json") else { throw AgentRSIError.invalidContract }
        return try Data(contentsOf: url)
    }
    static func raw(_ data: Data) throws -> AgentCanonicalJSON {
        guard data.count <= 4 * 1024 * 1024 else { throw AgentRSIError.invalidContract }
        var parser = AgentCanonicalJSON.Parser(data: data, allowNumbers: true)
        let value = try parser.parse(); try integers(value); return value
    }
    static func integers(_ value: AgentCanonicalJSON) throws {
        switch value {
        case .number(let text):
            guard text.range(of: "^(0|[1-9][0-9]*)$", options: .regularExpression) != nil,
                  let number = UInt64(text), number <= 9_007_199_254_740_991 else { throw AgentRSIError.invalidContract }
        case .object(let fields): for child in fields.values { try integers(child) }
        case .array(let children): for child in children { try integers(child) }
        default: break
        }
    }
    static func parse(_ data: Data, entity: String) throws -> AgentCanonicalJSON {
        let value = try raw(data), schema = try raw(resource("AgentRSISchema"))
        guard let definition = schema["$defs"].fields[entity] else { throw AgentRSIError.invalidContract }
        try validate(value, shape: definition, root: schema)
        try semantics(value, entity: entity)
        return value
    }
    private static func validate(_ value: AgentCanonicalJSON, shape: AgentCanonicalJSON, root: AgentCanonicalJSON) throws {
        if let reference = shape["$ref"].text {
            guard reference.hasPrefix("#/$defs/"), let resolved = root["$defs"].fields[String(reference.dropFirst(8))] else { throw AgentRSIError.invalidContract }
            try validate(value, shape: resolved, root: root); return
        }
        for key in ["anyOf", "oneOf"] where !shape[key].elements.isEmpty {
            let matches = shape[key].elements.filter { (try? validate(value, shape: $0, root: root)) != nil }.count
            guard key == "oneOf" ? matches == 1 : matches > 0 else { throw AgentRSIError.invalidContract }
        }
        if let constant = shape.fields["const"], constant != value { throw AgentRSIError.invalidContract }
        if !shape["enum"].elements.isEmpty, !shape["enum"].elements.contains(value) { throw AgentRSIError.invalidContract }
        switch shape["type"].text {
        case "object":
            guard case .object(let fields) = value else { throw AgentRSIError.invalidContract }
            let properties = shape["properties"].fields
            guard shape["required"].elements.allSatisfy({ fields[$0.text ?? ""] != nil }),
                  shape["additionalProperties"] != .bool(false) || Set(fields.keys).isSubset(of: Set(properties.keys)) else { throw AgentRSIError.invalidContract }
            for (key, child) in fields { if let nested = properties[key] { try validate(child, shape: nested, root: root) } }
        case "array":
            guard case .array(let children) = value,
                  children.count >= (shape["minItems"].integer ?? 0), children.count <= (shape["maxItems"].integer ?? Int.max),
                  shape["uniqueItems"] != .bool(true) || Set(children.map(\.canonical)).count == children.count else { throw AgentRSIError.invalidContract }
            if let nested = shape.fields["items"] { for child in children { try validate(child, shape: nested, root: root) } }
        case "string":
            guard let text = value.text, text.unicodeScalars.count >= (shape["minLength"].integer ?? 0),
                  text.unicodeScalars.count <= (shape["maxLength"].integer ?? Int.max) else { throw AgentRSIError.invalidContract }
            if let pattern = shape["pattern"].text, text.range(of: pattern, options: .regularExpression) == nil { throw AgentRSIError.invalidContract }
            if shape["format"].text == "date-time", !validDate(text) { throw AgentRSIError.invalidContract }
        case "integer":
            guard let number = value.integer, number >= (shape["minimum"].integer ?? 0), number <= (shape["maximum"].integer ?? Int.max) else { throw AgentRSIError.invalidContract }
        case "boolean": guard case .bool = value else { throw AgentRSIError.invalidContract }
        case "null": guard value == .null else { throw AgentRSIError.invalidContract }
        case nil: break
        default: throw AgentRSIError.invalidContract
        }
    }
    static func validDate(_ text: String) -> Bool {
        guard text.hasSuffix("Z") else { return false }
        let formatter = ISO8601DateFormatter()
        if formatter.date(from: text) != nil { return true }
        formatter.formatOptions.insert(.withFractionalSeconds)
        return formatter.date(from: text) != nil
    }
    static func semantics(_ value: AgentCanonicalJSON, entity: String) throws {
        switch entity {
        case "candidate":
            let baseline = try AgentPackageV1.decode(value["baseline_package"].bytes)
            let candidate = try AgentPackageV1.decode(value["candidate_package"].bytes)
            var comparable = candidate.definition
            comparable.version = baseline.definition.version; comparable.instructions = baseline.definition.instructions
            comparable.forked_from = baseline.definition.forked_from
            guard comparable == baseline.definition, candidate.sha256 != baseline.sha256,
                  candidate.definition.version != baseline.definition.version,
                  candidate.definition.instructions != baseline.definition.instructions,
                  candidate.definition.forked_from == baseline.sha256 else { throw AgentRSIError.invalidContract }
        case "experiment":
            try offline(value)
            let tasks = value["dataset"]["tasks"].elements
            guard Set(tasks.compactMap { $0["task_id"].text }).count == tasks.count,
                  Set(tasks.compactMap { $0["split"].text }) == ["validation", "regression", "holdout"],
                  value["baseline_revision"] != value["candidate_revision"] else { throw AgentRSIError.invalidContract }
        case "evidence":
            guard value["model"]["provider"].text == "mock",
                  value["model_route"].elements.allSatisfy({ $0["provider"].text == "mock" }) else { throw AgentRSIError.paidNotApproved }
            if value["target_executed"] == .bool(true) || value["status"].text == "passed" {
                guard !value["model_route"].elements.isEmpty else { throw AgentRSIError.missingEvidence }
            }
            if value["status"].text == "passed" {
                guard value["target_executed"] == .bool(true), value["worker_run_id"] != .null,
                      value["finished_at"] != .null, value["events_sha256"] != .null,
                      value["verifier"]["result"].text == "passed", value["verifier"]["exit_code"].integer == 0 else { throw AgentRSIError.missingEvidence }
            }
        default: break
        }
    }
    static func offline(_ experiment: AgentCanonicalJSON) throws {
        guard experiment["execution_policy"].text == "offline_only", experiment["model"]["provider"].text == "mock",
              experiment["budget"]["max_cost_microusd"].integer == 0 else { throw AgentRSIError.paidNotApproved }
    }
    static func bind(candidate: AgentCanonicalJSON, experiment: AgentCanonicalJSON, evidence: AgentCanonicalJSON? = nil) throws {
        guard candidate["candidate_id"] == experiment["candidate_id"], candidate["grant_id"] == experiment["grant_id"],
              candidate["baseline_package"]["definition"]["definition_id"] == experiment["definition_id"],
              candidate["baseline_package"]["sha256"] == experiment["baseline_revision"],
              candidate["candidate_package"]["sha256"] == experiment["candidate_revision"] else { throw AgentRSIError.invalidContract }
        guard let evidence else { return }
        let arm = evidence["arm"].text ?? ""
        let task = experiment["dataset"]["tasks"].elements.first { $0["task_id"] == evidence["task_id"] }
        guard evidence["experiment_id"] == experiment["experiment_id"], evidence["definition_id"] == experiment["definition_id"],
              evidence["definition_revision"] == experiment[arm + "_revision"],
              task?["task_sha256"] == evidence["task_sha256"], task?["split"] == evidence["split"],
              (evidence["repetition"].integer ?? Int.max) <= (experiment["repetitions"].integer ?? 0),
              (evidence["attempt"].integer ?? Int.max) <= (experiment["budget"]["max_attempts"].integer ?? 0),
              evidence["skills_sha256"] == experiment["conditions"]["skills_sha256"],
              evidence["dataset_sha256"] == experiment["dataset"]["suite_sha256"],
              evidence["fixture_sha256"] == experiment["dataset"]["fixture_sha256"],
              evidence["verifier"]["verifier_sha256"] == experiment["dataset"]["verifier_sha256"],
              ["runtime", "model", "conditions", "budget"].allSatisfy({ evidence[$0] == experiment[$0] }) else { throw AgentRSIError.invalidContract }
    }
}
