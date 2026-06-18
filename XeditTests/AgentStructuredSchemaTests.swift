//
//  AgentStructuredSchemaTests.swift
//  XeditTests
//
//  1.85.0-rc18:Workflow agent structured-output schema 验证器单测。覆盖
//  最常用形态(object+required+properties / array+minItems+maxItems /
//  enum) —— 也是 DeepResearchWorkflow rewrite 那一刀真正会跑的形态。
//

import Foundation
import Testing
@testable import WillDeep

extension WillDeepTests {
    @MainActor
    @Test("schema 把 object/required/properties/items/enum 一起验通过")
    func structuredSchemaValidatesComplexObject() throws {
        let schema = AgentStructuredSchema(
            type: .object,
            properties: [
                "question": AgentStructuredSchema(type: .string),
                "summary": AgentStructuredSchema(type: .string),
                "angles": AgentStructuredSchema(
                    type: .array,
                    items: AgentStructuredSchema(
                        type: .object,
                        properties: [
                            "label": AgentStructuredSchema(type: .string),
                            "query": AgentStructuredSchema(type: .string),
                            "relevance": AgentStructuredSchema(
                                type: .string,
                                enumValues: [.string("high"), .string("medium"), .string("low")]
                            ),
                        ],
                        required: ["label", "query"]
                    ),
                    minItems: 3,
                    maxItems: 6
                ),
            ],
            required: ["question", "angles"]
        )

        let json = """
        {
          "question": "What is X?",
          "summary": "Refined wording",
          "angles": [
            {"label": "news",    "query": "X recent updates", "relevance": "high"},
            {"label": "docs",    "query": "X official docs",  "relevance": "medium"},
            {"label": "reviews", "query": "X user reviews",   "relevance": "low"}
          ]
        }
        """
        let value = AgentJSONValue.decode(from: json)
        let issues = schema.validate(value)
        #expect(issues.isEmpty, "expected clean validate, got: \(issues)")
    }

    @MainActor
    @Test("missing required 报具体哪个 key 漏了")
    func structuredSchemaReportsMissingRequiredKey() {
        let schema = AgentStructuredSchema(
            type: .object,
            properties: [
                "label": AgentStructuredSchema(type: .string),
                "query": AgentStructuredSchema(type: .string),
            ],
            required: ["label", "query"]
        )
        let value = AgentJSONValue.decode(from: #"{"label": "news"}"#)
        let issues = schema.validate(value)
        #expect(issues.contains(where: { $0.contains("missing required key `query`") }))
    }

    @MainActor
    @Test("enum 拒绝不在闭集里的值")
    func structuredSchemaRejectsOutOfEnumValue() {
        let schema = AgentStructuredSchema(
            type: .string,
            enumValues: [.string("high"), .string("medium"), .string("low")]
        )
        let issues = schema.validate(.string("very-high"))
        #expect(issues.count == 1)
        #expect(issues.first!.contains("not in enum"))
    }

    @MainActor
    @Test("array minItems / maxItems 越界都报")
    func structuredSchemaCatchesArrayBounds() {
        let schema = AgentStructuredSchema(
            type: .array,
            items: AgentStructuredSchema(type: .string),
            minItems: 2,
            maxItems: 4
        )
        let tooFew = schema.validate(.array([.string("only one")]))
        #expect(tooFew.contains(where: { $0.contains("at least 2") }))

        let tooMany = schema.validate(.array([
            .string("a"), .string("b"), .string("c"), .string("d"), .string("e"),
        ]))
        #expect(tooMany.contains(where: { $0.contains("at most 4") }))
    }

    @MainActor
    @Test("integer schema 拒绝带小数的 number")
    func structuredSchemaIntegerRejectsFloats() {
        let schema = AgentStructuredSchema(type: .integer)
        let bad = schema.validate(.number(3.14))
        #expect(bad.count == 1)
        #expect(bad.first!.contains("expected type `integer`"))
    }

    @MainActor
    @Test("type 错误时不再追问下层 properties,issues 噪音可控")
    func structuredSchemaShortCircuitsOnTypeMismatch() {
        let schema = AgentStructuredSchema(
            type: .object,
            properties: [
                "label": AgentStructuredSchema(type: .string),
            ],
            required: ["label"]
        )
        // 传一个 array 进去 —— 顶层 type 就错了。
        let issues = schema.validate(.array([.string("hello")]))
        #expect(issues.count == 1)
        #expect(issues.first!.contains("expected type `object`"))
    }

    @MainActor
    @Test("schema renderedJSON 是有效 JSON 且包含核心字段")
    func structuredSchemaRendersValidJSON() throws {
        let schema = AgentStructuredSchema(
            type: .object,
            properties: [
                "claim": AgentStructuredSchema(type: .string, description: "the claim being verified"),
            ],
            required: ["claim"]
        )
        let rendered = schema.renderedJSON()
        let data = try #require(rendered.data(using: .utf8))
        let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(parsed?["type"] as? String == "object")
        let props = parsed?["properties"] as? [String: Any]
        #expect(props?["claim"] != nil)
        let required = parsed?["required"] as? [String]
        #expect(required == ["claim"])
    }

    @MainActor
    @Test("additionalProperties: false 时拒绝未声明的 key")
    func structuredSchemaAdditionalPropertiesFalse() {
        let schema = AgentStructuredSchema(
            type: .object,
            properties: [
                "label": AgentStructuredSchema(type: .string),
            ],
            required: [],
            additionalProperties: false
        )
        let issues = schema.validate(.object([
            "label": .string("ok"),
            "extra": .string("nope"),
        ]))
        #expect(issues.contains(where: { $0.contains("unexpected extra key `extra`") }))
    }
}
