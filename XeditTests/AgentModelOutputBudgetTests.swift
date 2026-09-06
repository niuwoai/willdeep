import Foundation
import Testing
@testable import WillDeep

@Suite("实际模型输出额度")
struct AgentModelOutputBudgetTests {
    @Test("每个协议把剩余额度应用到实际请求且保留其他字段")
    func protocolLimits() throws {
        let formats: [AgentModelRequestFormat] = [.openAIChat, .compatibleChat, .responses, .anthropic, .gemini]
        for format in formats {
            let body = Data(#"{"temperature":0.5,"messages":[],"generationConfig":{"temperature":0.5}}"#.utf8)
            let result = try AgentModelRequestReservation.prepare(body, format: format, remaining: 5_000)
            let object = try #require(JSONSerialization.jsonObject(with: result.body) as? [String: Any])
            let generation = object["generationConfig"] as? [String: Any]
            let raw = object["max_completion_tokens"] ?? object["max_tokens"] ?? object["max_output_tokens"] ?? generation?["maxOutputTokens"]
            let output = try #require(raw as? Int)
            #expect(output > 0 && output < 1_000)
            #expect(object["temperature"] as? Double == 0.5)
            #expect(generation?["temperature"] as? Double == 0.5)
            #expect(try #require(result.tokens) <= 5_000)
        }
    }

    @Test("无限政策不重编码，已有上限不放大且兼容端点保留现代字段")
    func preservesExplicitCaps() throws {
        let body = Data(#"{ "max_completion_tokens": 32, "max_tokens": 64, "messages": [] }"#.utf8)
        let unlimited = try AgentModelRequestReservation.prepare(body, format: .compatibleChat, remaining: nil)
        #expect(unlimited.body == body)
        let bounded = try AgentModelRequestReservation.prepare(body, format: .compatibleChat, remaining: 20_000)
        let object = try #require(JSONSerialization.jsonObject(with: bounded.body) as? [String: Any])
        #expect(object["max_completion_tokens"] as? Int == 32)
        #expect(object["max_tokens"] == nil)
    }

    @Test("本地工具的媒体参数定义不是实际媒体输入")
    func localSchemaIsNotMedia() throws {
        let declarations = [
            #"{"type":"function","function":{"name":"inspect","parameters":{"type":"object","properties":{"image_url":{"type":"string"},"file_id":{"type":"string"}}}}}"#,
            #"{"name":"inspect","input_schema":{"type":"object","properties":{"image_url":{"type":"string"}}}}"#,
            #"{"functionDeclarations":[{"name":"inspect","parameters":{"type":"object","properties":{"inlineData":{"type":"string"}}}}]}"#
        ]
        for declaration in declarations {
            let body = Data(("{\"messages\":[],\"max_tokens\":32,\"tools\":[" + declaration + "]}").utf8)
            #expect(AgentModelRequestReservation.tokens(for: body) != nil)
            let prepared = try AgentModelRequestReservation.prepare(body, format: .compatibleChat, remaining: 20_000)
            #expect(prepared.tokens != nil)
        }
    }

    @Test("真实媒体隐藏历史多候选与无法估算的服务端工作拒绝有限预算")
    func unsupportedExposureIsRejected() throws {
        for json in [
            #"{"messages":[{"content":[{"type":"image_url","image_url":{"url":"https://example.invalid/a.png"}}]}]}"#,
            #"{"previous_response_id":"prior"}"#,
            #"{"tools":[{"type":"web_search"}]}"#,
            #"{"n":2}"#, #"{"generationConfig":{"candidateCount":2}}"#,
            #"{"modalities":["audio"]}"#, #"{"web_search_options":{}}"#,
            #"{"generationConfig":{"responseModalities":["IMAGE"]}}"#
        ] {
            #expect(throws: AgentModelRequestLedger.Failure.unknownExposure) {
                try AgentModelRequestReservation.prepare(Data(json.utf8), format: .compatibleChat, remaining: 20_000)
            }
        }
    }

    @Test("思考预算不静默降低，过小或无效额度在发送前拒绝")
    func thinkingAndInvalidCaps() throws {
        for json in [
            #"{"thinking":{"type":"enabled","budget_tokens":1024},"max_tokens":2048}"#,
            #"{"generationConfig":{"thinkingConfig":{"thinkingBudget":1024},"maxOutputTokens":2048}}"#
        ] {
            #expect(throws: AgentModelRequestLedger.Failure.budgetExceeded) {
                try AgentModelRequestReservation.prepare(Data(json.utf8), format: .anthropic, remaining: 4_500)
            }
        }
        for json in [#"{"max_tokens":true}"#, #"{"max_tokens":1.5}"#, #"{"max_tokens":0}"#] {
            #expect(throws: AgentModelRequestLedger.Failure.invalidReservation) {
                try AgentModelRequestReservation.prepare(Data(json.utf8), format: .compatibleChat, remaining: 20_000)
            }
        }
    }

    @Test("分配事务使用当前余额，准备失败不插入请求")
    func admissionPreparationIsAtomic() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("output-admission-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let ledger = AgentModelRequestLedger(directory: root, ownerID: UUID())
        try ledger.setAdmissionLimit(100, expectedRevision: 0)
        for expected in [100, 60, 20] {
            let value: Int = try ledger.admit(id: UUID(), providerID: "fixture", modelID: "fixture") { remaining in
                #expect(remaining == expected)
                return (expected, min(expected, 40))
            }
            #expect(value == expected)
        }
        #expect(try ledger.exposure().estimatedTokens == 100)
        #expect(throws: AgentModelRequestLedger.Failure.invalidReservation) {
            let _: Int = try ledger.admit(id: UUID(), providerID: "fixture", modelID: "fixture") { _ in
                throw AgentModelRequestLedger.Failure.invalidReservation
            }
        }
        #expect(try ledger.summary().attempts == 3)
    }
}
