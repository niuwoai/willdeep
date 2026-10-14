import Foundation
import CryptoKit

/// Exchange assets contain no model credentials or execution grants.
nonisolated struct AgentDefinitionV1: Codable, Equatable, Sendable {
    struct Skill: Codable, Equatable, Sendable {
        var id: String
        var content: String
        var sha256: String
        var required: Bool
    }
    var schema: String
    var definition_id: String
    var version: String
    var name: [String: String]
    var purpose: String
    var base_role: String
    var instructions: String
    var input_modalities: [String]
    var tools: [String]
    var skills: [Skill]
    var forked_from: String?

    static let schemaID = "willdeep.agent-definition.v1"
    static let roles: Set<String> = ["generalist", "implementer", "tester", "reviewer", "ops_runner"]
    static let capabilities: Set<String> = ["workspace.read", "workspace.edit", "process.verify", "repository.inspect"]

    func validate() throws {
        guard schema == Self.schemaID,
              definition_id.range(of: "^[a-z0-9][a-z0-9._/-]{0,95}$", options: .regularExpression) != nil,
              !definition_id.contains(".."),
              definition_id.hasPrefix("user/") || definition_id.hasPrefix("official/"),
              version.range(of: "^(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)(-rc[1-9][0-9]*)?$", options: .regularExpression) != nil,
              !name.isEmpty, name.count <= 16, name["en"] != nil || name["zh-Hans"] != nil,
              name.allSatisfy({ $0.key.range(of: "^[A-Za-z0-9-]{1,32}$", options: .regularExpression) != nil && (1...128).contains($0.value.unicodeScalars.count) }),
              !purpose.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, (1...1024).contains(purpose.unicodeScalars.count),
              Self.roles.contains(base_role),
              !instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, (1...16000).contains(instructions.unicodeScalars.count),
              !input_modalities.isEmpty, Set(input_modalities).count == input_modalities.count,
              Set(input_modalities).isSubset(of: ["text", "image"]),
              Set(tools).count == tools.count, Set(tools).isSubset(of: Self.capabilities),
              skills.count <= 8, Set(skills.map(\.id)).count == skills.count,
              forked_from == nil || AgentPackageV1.isHash(forked_from!) else {
            throw AgentAssetError.invalidDefinition
        }
        for skill in skills {
            guard skill.id.range(of: "^[a-z0-9][a-z0-9._/-]{0,95}$", options: .regularExpression) != nil, !skill.id.contains(".."),
                  skill.content.unicodeScalars.count <= 24000,
                  !skill.required || !skill.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  AgentPackageV1.hash(Data(skill.content.utf8)) == skill.sha256 else {
                throw AgentAssetError.invalidSkill
            }
        }
        let text = ([purpose, instructions, definition_id] + Array(name.values) + skills.map(\.content)).joined(separator: "\n")
        guard text.range(of: "(?i)((sk-|sk_|sk_live_|mt_live_)[a-z0-9_-]{20,}|-----BEGIN [A-Z ]*PRIVATE KEY-----)", options: .regularExpression) == nil else {
            throw AgentAssetError.invalidDefinition
        }
    }
}

nonisolated enum AgentAssetError: Error, LocalizedError {
    case invalidDefinition, invalidSkill, invalidJSON, invalidHash, untrustedSignature
    case unavailableCapability, immutableVersion, missingRevision, authentication, conflict, server
    var errorDescription: String? {
        switch self {
        case .invalidDefinition: return String(localized: "智能体定义无效", table: "AgentRegistry")
        case .invalidSkill: return String(localized: "技能正文缺失或校验失败", table: "AgentRegistry")
        case .invalidJSON: return String(localized: "JSON 包含未知字段、重复键或不支持的值", table: "AgentRegistry")
        case .invalidHash: return String(localized: "智能体版本内容校验失败", table: "AgentRegistry")
        case .untrustedSignature: return String(localized: "官方签名验证失败", table: "AgentRegistry")
        case .unavailableCapability: return String(localized: "当前原生子智能体不支持请求的模态或工具", table: "AgentRegistry")
        case .immutableVersion: return String(localized: "同一智能体版本不可修改，请增加版本号", table: "AgentRegistry")
        case .missingRevision: return String(localized: "智能体固定版本不存在", table: "AgentRegistry")
        case .authentication: return String(localized: "请先登录 some.im 客户账号", table: "AgentRegistry")
        case .conflict: return String(localized: "同步冲突已保留双方版本，请选择保留版本", table: "AgentRegistry")
        case .server: return String(localized: "智能体服务请求失败", table: "AgentRegistry")
        }
    }
}

nonisolated struct AgentPackageV1: Codable, Equatable, Sendable {
    struct Signature: Codable, Equatable, Sendable { var key_id: String; var value: String }
    var definition: AgentDefinitionV1
    var sha256: String
    var signature: Signature?
    static let byteLimit = 256 * 1024

    static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    static func isHash(_ value: String) -> Bool { isHex(value, count: 64) }
    static func isHex(_ value: String, count: Int) -> Bool {
        value.utf8.count == count && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    static func hexData(_ value: String) -> Data? {
        guard value.count.isMultiple(of: 2), isHex(value, count: value.count) else { return nil }
        var bytes: [UInt8] = []; var index = value.startIndex
        while index < value.endIndex {
            let end = value.index(index, offsetBy: 2)
            guard let byte = UInt8(value[index..<end], radix: 16) else { return nil }
            bytes.append(byte); index = end
        }
        return Data(bytes)
    }
    static func decode(_ data: Data) throws -> Self {
        guard data.count <= byteLimit else { throw AgentAssetError.invalidJSON }
        var parser = AgentCanonicalJSON.Parser(data: data)
        let root = try parser.parse()
        try root.requireKeys(["definition", "sha256", "signature"])
        guard case .object(let fields) = root, let definition = fields["definition"] else { throw AgentAssetError.invalidJSON }
        try definition.requireKeys(["schema", "definition_id", "version", "name", "purpose", "base_role", "instructions", "input_modalities", "tools", "skills", "forked_from"])
        if case .object(let def) = definition, case .array(let skills) = def["skills"] {
            for skill in skills { try skill.requireKeys(["id", "content", "sha256", "required"]) }
        }
        if let signature = fields["signature"], signature != .null { try signature.requireKeys(["key_id", "value"]) }
        let package = try JSONDecoder().decode(Self.self, from: data)
        try package.definition.validate()
        guard isHash(package.sha256), hash(definition.bytes) == package.sha256 else { throw AgentAssetError.invalidHash }
        if let signature = package.signature {
            guard !signature.key_id.isEmpty, signature.key_id.count <= 128, isHex(signature.value, count: 128) else { throw AgentAssetError.untrustedSignature }
        }
        return package
    }
    static func unsigned(_ definition: AgentDefinitionV1) throws -> Self {
        try definition.validate()
        let data = try JSONEncoder().encode(definition)
        // Codable omits optional nil fields; the exchange contract requires explicit null.
        var parser = AgentCanonicalJSON.Parser(data: data)
        guard case .object(var fields) = try parser.parse() else { throw AgentAssetError.invalidJSON }
        fields["forked_from"] = definition.forked_from.map(AgentCanonicalJSON.string) ?? .null
        return Self(definition: definition, sha256: hash(AgentCanonicalJSON.object(fields).bytes), signature: nil)
    }
    static func fromDefinitionData(_ data: Data) throws -> Self {
        guard data.count <= byteLimit else { throw AgentAssetError.invalidJSON }
        var parser = AgentCanonicalJSON.Parser(data: data)
        let definition = try parser.parse()
        return try decode(AgentCanonicalJSON.object(["definition": definition, "sha256": .string(hash(definition.bytes)), "signature": .null]).bytes)
    }
    func definitionEditorData() throws -> Data {
        var parser = AgentCanonicalJSON.Parser(data: try encoded())
        guard case .object(let root) = try parser.parse(), let definition = root["definition"] else { throw AgentAssetError.invalidJSON }
        let object = try JSONSerialization.jsonObject(with: definition.bytes)
        return try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }
    func encoded() throws -> Data {
        let data = try JSONEncoder().encode(self)
        var parser = AgentCanonicalJSON.Parser(data: data)
        guard case .object(var root) = try parser.parse(), case .object(var definition) = root["definition"] else { throw AgentAssetError.invalidJSON }
        definition["forked_from"] = self.definition.forked_from.map(AgentCanonicalJSON.string) ?? .null
        root["definition"] = .object(definition)
        root["signature"] = root["signature"] ?? .null
        let bytes = AgentCanonicalJSON.object(root).bytes
        guard bytes.count <= Self.byteLimit else { throw AgentAssetError.invalidJSON }
        return bytes
    }
    func verify(keys: [String: String]) throws {
        guard definition.definition_id.hasPrefix("official/"), let signature,
              let hex = keys[signature.key_id], Self.isHex(hex, count: 64),
              let publicKey = Self.hexData(hex), let signatureBytes = Self.hexData(signature.value),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKey),
              key.isValidSignature(signatureBytes, for: Data(("willdeep.agent-package.v1\n" + sha256).utf8)) else { throw AgentAssetError.untrustedSignature }
    }
}

/// Strict parser prevents JSONDecoder's duplicate-key and unknown-field acceptance.
nonisolated indirect enum AgentCanonicalJSON: Equatable {
    case object([String: Self]), array([Self]), string(String), bool(Bool), null, number(String)
    func requireKeys(_ expected: Set<String>) throws {
        guard case .object(let fields) = self, Set(fields.keys) == expected else { throw AgentAssetError.invalidJSON }
    }
    var bytes: Data { Data(canonical.utf8) }
    var canonical: String {
        switch self {
        case .null: return "null"
        case .number(let value): return value
        case .bool(let bool): return bool ? "true" : "false"
        case .string(let value): return Self.quoted(value)
        case .array(let values): return "[" + values.map(\.canonical).joined(separator: ",") + "]"
        case .object(let fields):
            return "{" + fields.keys.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
                .map { Self.quoted($0) + ":" + fields[$0]!.canonical }.joined(separator: ",") + "}"
        }
    }
    static func quoted(_ value: String) -> String {
        var result = "\""
        for unit in value.utf16 {
            switch unit {
            case 34: result += "\\\""
            case 92: result += "\\\\"
            case 32...126: result += String(UnicodeScalar(unit)!)
            default: result += String(format: "\\u%04x", unit)
            }
        }
        return result + "\""
    }
    struct Parser {
        let data: Data
        var bytes: [UInt8]
        var offset = 0
        var allowNumbers = false
        init(data: Data, allowNumbers: Bool = false) { self.data = data; bytes = Array(data); self.allowNumbers = allowNumbers }
        mutating func parse() throws -> AgentCanonicalJSON {
            guard String(data: data, encoding: .utf8) != nil else { throw AgentAssetError.invalidJSON }
            let value = try value(depth: 0); skipSpace()
            guard offset == bytes.count else { throw AgentAssetError.invalidJSON }
            return value
        }
        mutating func skipSpace() { while offset < bytes.count, [9, 10, 13, 32].contains(bytes[offset]) { offset += 1 } }
        mutating func consume(_ byte: UInt8) -> Bool {
            skipSpace(); guard offset < bytes.count, bytes[offset] == byte else { return false }; offset += 1; return true
        }
        mutating func value(depth: Int) throws -> AgentCanonicalJSON {
            skipSpace(); guard depth < 32, offset < bytes.count else { throw AgentAssetError.invalidJSON }
            switch bytes[offset] {
            case 34: return .string(try string())
            case 123:
                offset += 1; var fields: [String: AgentCanonicalJSON] = [:]
                if consume(125) { return .object(fields) }
                repeat {
                    skipSpace(); let key = try string()
                    guard fields[key] == nil, consume(58) else { throw AgentAssetError.invalidJSON }
                    fields[key] = try value(depth: depth + 1)
                    if consume(125) { return .object(fields) }
                } while consume(44)
            case 91:
                offset += 1; var values: [AgentCanonicalJSON] = []
                if consume(93) { return .array(values) }
                repeat {
                    values.append(try value(depth: depth + 1))
                    if consume(93) { return .array(values) }
                } while consume(44)
            default:
                if allowNumbers, bytes[offset] == 45 || (48...57).contains(bytes[offset]) {
                    let start = offset
                    while offset < bytes.count, (48...57).contains(bytes[offset]) || [45, 43, 46, 69, 101].contains(bytes[offset]) { offset += 1 }
                    let number = String(decoding: bytes[start..<offset], as: UTF8.self)
                    guard number.range(of: "^-?(0|[1-9][0-9]*)(\\.[0-9]+)?([eE][+-]?[0-9]+)?$", options: .regularExpression) != nil else { throw AgentAssetError.invalidJSON }
                    return .number(number)
                }
                for (literal, value) in [("null", SelfValue.null), ("true", .bool(true)), ("false", .bool(false))] {
                    let encoded = Array(literal.utf8)
                    if Array(bytes.dropFirst(offset).prefix(encoded.count)) == encoded { offset += encoded.count; return value }
                }
            }
            throw AgentAssetError.invalidJSON
        }
        typealias SelfValue = AgentCanonicalJSON
        mutating func string() throws -> String {
            guard offset < bytes.count, bytes[offset] == 34 else { throw AgentAssetError.invalidJSON }
            let start = offset; offset += 1
            while offset < bytes.count {
                let byte = bytes[offset]; offset += 1
                if byte == 34 {
                    let fragment = Data(bytes[start..<offset])
                    guard let value = try? JSONSerialization.jsonObject(with: fragment, options: .fragmentsAllowed) as? String else { throw AgentAssetError.invalidJSON }
                    return value
                }
                if byte == 92 { guard offset < bytes.count else { break }; offset += 1 }
                if byte < 32 { break }
            }
            throw AgentAssetError.invalidJSON
        }
    }
}
