//
//  AgentToolInputSchema.swift
//  WillDeep
//
//  插件 MCP 工具自带的参数表（`tools/list` 里的 `inputSchema`）→ 模型接口收得下的 JSON Schema。
//
//  起因（1.410.0-rc1）：插件工具以前只给模型一个 `arguments_json` 字符串参数，参数表整个丢掉，
//  模型只能照着描述猜参数名和结构。短剧工坊有一百多个工具，`episode.generate_frames` 一类的
//  参数（target、countPerModel、onlyMissing、requestID……）猜错一个就是一次白跑或一次重复计费。
//
//  规矩：
//  - 收敛只做「去掉接口不认的、展开本地引用」，不改语义：`$schema` / `$id` / `$comment` /
//    `examples` 去掉，`#/$defs/X`、`#/definitions/X` 就地展开（有深度上限，防循环），`oneOf` 换成
//    `anyOf`（OpenAI 非严格模式与 Anthropic 都认 anyOf）。
//  - 顶层必须是对象。不是对象、解析不了、收敛后仍超过体积上限的，返回 nil，调用方退回 `arguments_json`。
//  - Gemini 只认 OpenAPI 子集（大写类型、没有自由对象、没有 additionalProperties）：`gemini(_:)`
//    能转就转，碰到没写 properties 的对象就整份放弃，由调用方退回 `arguments_json`。
//

import Foundation

nonisolated enum AgentToolInputSchema {
    /// 单个工具参数表序列化后的上限。超了先去掉嵌套层的说明文字，还超就放弃。
    static let maxEncodedBytes = 16_000
    /// `$ref` 展开与递归的深度上限。
    static let maxDepth = 12

    private static let droppedKeys: Set<String> = ["$schema", "$id", "$comment", "examples", "$defs", "definitions"]
    /// 值本身是「一张 schema」的键。
    private static let schemaValuedKeys: Set<String> = ["items", "additionalProperties", "not", "contains"]
    /// 值是「schema 数组」的键。
    private static let schemaArrayKeys: Set<String> = ["anyOf", "allOf", "oneOf", "prefixItems"]

    // MARK: - 通用（Anthropic / OpenAI Chat / OpenAI Responses）

    /// 收敛后的参数表文本（键排序，稳定，可以直接放进请求、也适合做缓存键）。nil = 用不了。
    static func normalizedJSON(_ raw: Any?) -> String? {
        guard let schema = normalized(raw),
              let data = try? JSONSerialization.data(withJSONObject: schema, options: [.sortedKeys]) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    /// 收敛后的参数表。`raw` 可以是 JSON 文本，也可以是已经解析好的字典。
    static func normalized(_ raw: Any?) -> [String: Any]? {
        let root: [String: Any]
        if let dictionary = raw as? [String: Any] {
            root = dictionary
        } else if let text = raw as? String, let data = text.data(using: .utf8),
                  let parsed = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            root = parsed
        } else {
            return nil
        }
        if let type = root["type"] as? String, type != "object" { return nil }
        let definitions = (root["$defs"] as? [String: Any]) ?? (root["definitions"] as? [String: Any]) ?? [:]
        guard var schema = clean(root, definitions: definitions, depth: 0) as? [String: Any] else { return nil }
        schema["type"] = "object"
        if !(schema["properties"] is [String: Any]) { schema["properties"] = [String: Any]() }
        if encodedSize(schema) <= maxEncodedBytes { return schema }
        let trimmed = strippingNestedDescriptions(schema)
        return encodedSize(trimmed) <= maxEncodedBytes ? trimmed : nil
    }

    /// 把参数表文本解回字典给客户端用；坏了返回 nil。
    static func object(fromJSON json: String?) -> [String: Any]? {
        guard let json, let data = json.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func clean(_ value: Any, definitions: [String: Any], depth: Int) -> Any {
        guard depth <= maxDepth else { return [String: Any]() }
        if let array = value as? [Any] {
            return array.map { clean($0, definitions: definitions, depth: depth + 1) }
        }
        guard let dictionary = value as? [String: Any] else { return value }
        if let reference = dictionary["$ref"] as? String {
            guard let target = resolve(reference, definitions: definitions) else { return [String: Any]() }
            // 引用旁边的说明（description）保留，覆盖被引用那张的。
            var merged = clean(target, definitions: definitions, depth: depth + 1) as? [String: Any] ?? [:]
            if let description = dictionary["description"] as? String { merged["description"] = description }
            return merged
        }
        var result: [String: Any] = [:]
        for (key, item) in dictionary where !droppedKeys.contains(key) {
            switch key {
            case "properties", "patternProperties":
                // 属性名可以叫任何名字（甚至 `$comment`），只清洗值，不过滤键。
                guard let properties = item as? [String: Any] else { continue }
                result[key] = properties.mapValues { clean($0, definitions: definitions, depth: depth + 1) }
            case "oneOf":
                result["anyOf"] = clean(item, definitions: definitions, depth: depth + 1)
            case _ where schemaValuedKeys.contains(key) || schemaArrayKeys.contains(key):
                result[key] = clean(item, definitions: definitions, depth: depth + 1)
            default:
                // enum、required、const、default 之类是字面量，原样保留。
                result[key] = item
            }
        }
        return result
    }

    private static func resolve(_ reference: String, definitions: [String: Any]) -> Any? {
        for prefix in ["#/$defs/", "#/definitions/"] where reference.hasPrefix(prefix) {
            return definitions[String(reference.dropFirst(prefix.count))]
        }
        return nil
    }

    private static func encodedSize(_ schema: [String: Any]) -> Int {
        (try? JSONSerialization.data(withJSONObject: schema, options: []))?.count ?? Int.max
    }

    /// 顶层属性的说明留着（模型最需要它），更深层的说明去掉。
    private static func strippingNestedDescriptions(_ schema: [String: Any]) -> [String: Any] {
        var result = schema
        guard let properties = schema["properties"] as? [String: Any] else { return result }
        result["properties"] = properties.mapValues { property -> Any in
            guard var dictionary = property as? [String: Any] else { return property }
            for (key, value) in dictionary where key != "description" {
                dictionary[key] = withoutDescriptions(value)
            }
            return dictionary
        }
        return result
    }

    private static func withoutDescriptions(_ value: Any) -> Any {
        if let array = value as? [Any] { return array.map(withoutDescriptions) }
        guard let dictionary = value as? [String: Any] else { return value }
        var result: [String: Any] = [:]
        for (key, item) in dictionary where key != "description" {
            result[key] = (key == "properties")
                ? ((item as? [String: Any])?.mapValues(withoutDescriptions) ?? item)
                : withoutDescriptions(item)
        }
        return result
    }

    // MARK: - Gemini

    private static let geminiKeys: Set<String> = [
        "type", "format", "description", "nullable", "enum", "properties", "required",
        "items", "minItems", "maxItems", "minimum", "maximum"
    ]

    /// Gemini 的函数参数表（OpenAPI 子集）。收不下就返回 nil。
    static func gemini(_ schema: [String: Any]) -> [String: Any]? {
        geminiNode(schema, depth: 0)
    }

    private static func geminiNode(_ value: Any, depth: Int) -> [String: Any]? {
        guard depth <= maxDepth, var node = value as? [String: Any] else { return nil }
        var nullable = false
        // anyOf：Gemini 旧接口不认，取第一个非 null 分支，有 null 分支就记 nullable。
        if let options = node["anyOf"] as? [[String: Any]] {
            nullable = options.contains { ($0["type"] as? String) == "null" }
            guard let first = options.first(where: { ($0["type"] as? String) != "null" }) else { return nil }
            let description = node["description"]
            node = first
            if node["description"] == nil, let description { node["description"] = description }
        }
        var type = node["type"]
        if let types = type as? [String] {
            nullable = nullable || types.contains("null")
            type = types.first { $0 != "null" }
        }
        var typeName = (type as? String)?.lowercased()
        if typeName == nil {
            if node["properties"] != nil { typeName = "object" } else if node["items"] != nil { typeName = "array" }
        }
        guard let typeName else { return nil }
        var result: [String: Any] = [:]
        for (key, item) in node where geminiKeys.contains(key) {
            switch key {
            case "type", "properties", "items", "enum":
                continue
            default:
                result[key] = item
            }
        }
        switch typeName {
        case "object":
            // 自由对象（没写 properties）Gemini 收不下：整份放弃，比让它把参数压成字符串强。
            guard let properties = node["properties"] as? [String: Any], !properties.isEmpty else { return nil }
            var converted: [String: Any] = [:]
            for (name, property) in properties {
                guard let child = geminiNode(property, depth: depth + 1) else { return nil }
                converted[name] = child
            }
            result["type"] = "OBJECT"
            result["properties"] = converted
            if let required = node["required"] as? [String] {
                result["required"] = required.filter { converted[$0] != nil }
            }
        case "array":
            guard let items = node["items"], let child = geminiNode(items, depth: depth + 1) else { return nil }
            result["type"] = "ARRAY"
            result["items"] = child
        case "string", "integer", "number", "boolean":
            result["type"] = typeName.uppercased()
            // Gemini 的 enum 只收字符串。
            if typeName == "string", let values = node["enum"] as? [String] { result["enum"] = values }
        default:
            return nil
        }
        if nullable { result["nullable"] = true }
        return result
    }
}

nonisolated extension AgentJSONValue {
    /// 转成 `JSONSerialization` 用的值，转发给 MCP `tools/call`。
    /// 整数值的数字还原成 Int：模型接口一律给 Double，插件那头的 `order == 3` 不该收到 `3.0`。
    var foundationValue: Any {
        switch self {
        case .null: return NSNull()
        case .bool(let value): return value
        case .number(let value):
            if value.rounded() == value, abs(value) < 9_007_199_254_740_992 { return Int(value) }
            return value
        case .string(let value): return value
        case .array(let values): return values.map(\.foundationValue)
        case .object(let fields): return fields.mapValues(\.foundationValue)
        }
    }
}
