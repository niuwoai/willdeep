//
//  AgentStructuredSchema.swift
//  WillDeep
//
//  1.85.0-rc18:Workflow agent 的结构化输出基础设施。
//
//  动机:对齐 Claude Code workflow 里 `agent(prompt, { schema })` 那一套
//  —— 让 sub-agent 不再返回自由文本,而是被强制吐出符合 JSON Schema 的
//  结构,Workflow 这边直接 `Decodable` 解到 typed model。组合上一层
//  pipeline / parallel / verify,可以拼出有可信度的 research / review 之
//  类管线(对比 [Claude's deep-research workflow] 那种 5-angle scope →
//  fetch+extract → 3-vote adversarial verify → synthesize 的能力)。
//
//  机制(rc18 第一刀,只做最小可用集):
//   1. AgentStructuredSchema 是个 Codable 的 JSON Schema 子集(type /
//      properties / required / items / enum / minItems / maxItems /
//      additionalProperties)。Workflow 作者声明它,Engine 把它注入
//      sub-agent。
//   2. AgentSubagentRunner 看到非 nil schema 时,往工具表里塞一个
//      synthetic 的 `structured_output(data: string)`,system prompt 里
//      告诉模型「答完调它,data 是 JSON 字符串符合 <schema>」。
//   3. 收到 `structured_output` 调用时,捕获 args["data"],跑这里的
//      `validate(...)`;通过就退出 loop;不通过就把错误描述塞回 tool
//      result,让模型在下一轮重试。
//   4. 解码这一步在 WorkflowEngine.agent<T: Decodable>(...) 里,用
//      JSONDecoder + 严格 dateDecoding 拿到 typed 结果。
//
//  这里只验证「形态」(type/required/array bounds/enum),不验证
//  format/pattern/minimum/maximum 那些 —— 后者目前用不到,加了反而拖慢。
//  后续如果 deep-research 等场景真用上,再追加。
//

import Foundation

/// JSON Schema 节点 —— 递归结构,根节点和 properties / items 子节点
/// 共用同一类型。
///
/// 选 **final class** 而不是 struct,纯粹是为了把递归字段(`properties:
/// [String: AgentStructuredSchema]` / `items: AgentStructuredSchema?`)
/// 写得自然 —— struct 会被 Swift 拒绝("value type 不能递归包含自身")。
/// schema 一旦由 workflow 作者声明就只读,不存在 mutation,reference 语
/// 义没副作用。Codable 仍然是 JSON Schema 标准形态(类作为载体不影响
/// 编码结果)。
final class AgentStructuredSchema: Codable, Equatable {
    enum NodeType: String, Codable, Equatable {
        case object
        case array
        case string
        case number
        case integer
        case boolean
        case null
    }

    /// 单 type 写在 `type` 上;允许多 type(`["string", "null"]`)的场景
    /// 我们不开放,简化 validator。
    var type: NodeType
    /// 仅 object 用。
    var properties: [String: AgentStructuredSchema]?
    /// 仅 object 用,严格大小写匹配。
    var required: [String]?
    /// 仅 array 用。
    var items: AgentStructuredSchema?
    /// 取值闭集(string / number / boolean 都可)。
    var `enum`: [AgentJSONValue]?
    var minItems: Int?
    var maxItems: Int?
    /// 仅 object 用;rc18 不强制为 false,但 validator 在这里有空间扩展。
    var additionalProperties: Bool?
    /// 给模型读的描述,sub-agent 提示词会把它一起渲染出去。
    var description: String?

    enum CodingKeys: String, CodingKey {
        case type, properties, required, items
        case `enum`
        case minItems, maxItems, additionalProperties, description
    }

    init(
        type: NodeType,
        properties: [String: AgentStructuredSchema]? = nil,
        required: [String]? = nil,
        items: AgentStructuredSchema? = nil,
        enumValues: [AgentJSONValue]? = nil,
        minItems: Int? = nil,
        maxItems: Int? = nil,
        additionalProperties: Bool? = nil,
        description: String? = nil
    ) {
        self.type = type
        self.properties = properties
        self.required = required
        self.items = items
        self.`enum` = enumValues
        self.minItems = minItems
        self.maxItems = maxItems
        self.additionalProperties = additionalProperties
        self.description = description
    }

    static func == (lhs: AgentStructuredSchema, rhs: AgentStructuredSchema) -> Bool {
        lhs.type == rhs.type
            && lhs.properties == rhs.properties
            && lhs.required == rhs.required
            && lhs.items == rhs.items
            && lhs.`enum` == rhs.`enum`
            && lhs.minItems == rhs.minItems
            && lhs.maxItems == rhs.maxItems
            && lhs.additionalProperties == rhs.additionalProperties
            && lhs.description == rhs.description
    }

    // MARK: - Validation

    /// Validate a parsed `AgentJSONValue` against this schema. 返回所有
    /// 违规;空数组 = 通过。
    func validate(_ value: AgentJSONValue, path: String = "$") -> [String] {
        var issues: [String] = []

        // type 检查 —— null 单独处理,因为 Optional 字段在父层已经被
        // required 闸过了。
        if !matchesType(value) {
            issues.append("\(path): expected type `\(type.rawValue)`, got `\(jsonTypeName(value))`")
            // 类型对不上就别继续追问 properties 之类,会噪音。
            return issues
        }

        switch type {
        case .object:
            guard case .object(let dict) = value else { return issues }
            if let required {
                for key in required where dict[key] == nil {
                    issues.append("\(path): missing required key `\(key)`")
                }
            }
            if let properties {
                for (key, childSchema) in properties {
                    if let childValue = dict[key] {
                        issues.append(contentsOf: childSchema.validate(childValue, path: "\(path).\(key)"))
                    }
                }
            }
            // additionalProperties: false 时拒绝未声明的 key。
            if additionalProperties == false, let properties {
                for key in dict.keys where properties[key] == nil {
                    issues.append("\(path): unexpected extra key `\(key)`")
                }
            }
        case .array:
            guard case .array(let arr) = value else { return issues }
            if let minItems, arr.count < minItems {
                issues.append("\(path): expected at least \(minItems) item(s), got \(arr.count)")
            }
            if let maxItems, arr.count > maxItems {
                issues.append("\(path): expected at most \(maxItems) item(s), got \(arr.count)")
            }
            if let items {
                for (idx, element) in arr.enumerated() {
                    issues.append(contentsOf: items.validate(element, path: "\(path)[\(idx)]"))
                }
            }
        case .string, .number, .integer, .boolean, .null:
            if let `enum`, !enumMatches(value, in: `enum`) {
                let allowed = `enum`.map { $0.displaySummary }.joined(separator: ", ")
                issues.append("\(path): value `\(value.displaySummary)` not in enum [\(allowed)]")
            }
        }

        return issues
    }

    private func matchesType(_ value: AgentJSONValue) -> Bool {
        switch (type, value) {
        case (.object, .object): return true
        case (.array, .array): return true
        case (.string, .string): return true
        case (.boolean, .bool): return true
        case (.null, .null): return true
        // JSON Number → 整数判定要严:整数 schema 拒绝带小数的值。
        case (.integer, .number(let n)): return n.rounded() == n
        case (.number, .number): return true
        // integer schema 拒绝 bool(在 JSON 里 true/false 不是 1/0)。
        default: return false
        }
    }

    private func enumMatches(_ value: AgentJSONValue, in allowed: [AgentJSONValue]) -> Bool {
        allowed.contains { $0 == value }
    }

    private func jsonTypeName(_ value: AgentJSONValue) -> String {
        switch value {
        case .null: return "null"
        case .bool: return "boolean"
        case .number(let n): return n.rounded() == n ? "integer/number" : "number"
        case .string: return "string"
        case .array: return "array"
        case .object: return "object"
        }
    }

    // MARK: - Prompt rendering

    /// 把自身 JSON Schema 化打印出来,塞进 sub-agent 的 system prompt。
    /// 用 sortedKeys 让多次序列化稳定(测试断言友好)。
    func renderedJSON() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        // AgentJSONValue 不直接 Codable —— enum case 要手动桥到 JSONSerialization。
        // 这里走 dict 表示再 JSONSerialization,避免 Codable enum encoding 怪
        // (Swift 默认 enum 编码会带 "{"type":"object","properties":...}" 这种
        // 结构本来就是 JSON,直接编 self 即可)。
        do {
            let data = try encoder.encode(self)
            return String(data: data, encoding: .utf8) ?? "{}"
        } catch {
            return "{ \"_error\": \"schema encode failed: \(error.localizedDescription)\" }"
        }
    }
}

// MARK: - AgentJSONValue Codable bridge for `enum` field

extension AgentJSONValue: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let boolean = try? container.decode(Bool.self) {
            self = .bool(boolean)
        } else if let number = try? container.decode(Double.self) {
            self = .number(number)
        } else if let string = try? container.decode(String.self) {
            self = .string(string)
        } else if let array = try? container.decode([AgentJSONValue].self) {
            self = .array(array)
        } else if let dict = try? container.decode([String: AgentJSONValue].self) {
            self = .object(dict)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Cannot decode AgentJSONValue"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case .bool(let value):
            try container.encode(value)
        case .number(let value):
            try container.encode(value)
        case .string(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        }
    }
}
