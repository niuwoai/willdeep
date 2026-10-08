import Foundation
import Testing
@testable import WillDeep

@Suite("跨端运行参数契约")
@MainActor
struct AgentRuntimeParametersTests {
    @Test("完整配置往返与字段顺序无关")
    func roundTrip() throws {
        let value = AgentRuntimeParameters()
        #expect(try AgentRuntimeParameters.decode(Data(value.canonical.utf8)) == value)
        #expect(value.fingerprint.count == 64)
        #expect(value.fingerprint == "cbbe63a9094a7d8546d52f38775bf9e8e0f5e010cfabc767a9d4ffb42ee00e1b")
        let encoded = try JSONEncoder().encode(value)
        #expect(try AgentRuntimeParameters.decode(encoded) == value)
        let data = try JSONSerialization.data(withJSONObject:
            JSONSerialization.jsonObject(with: Data(value.canonical.utf8)), options: [.sortedKeys])
        #expect(try AgentRuntimeParameters.decode(data).fingerprint == value.fingerprint)
    }

    @Test("错字、缺字段、重复字段和错误类型不能悄悄退回默认值")
    func invalidStructures() {
        let canonical = AgentRuntimeParameters().canonical
        for invalid in [
            canonical.replacingOccurrences(of: "\"max_turns\":200", with: "\"max_turns\":200,\"max_turns\":201"),
            canonical.replacingOccurrences(of: "\"token_budget\":null,", with: ""),
            canonical.replacingOccurrences(of: "\"max_turns\":200", with: "\"max_turns\":\"200\""),
            canonical.replacingOccurrences(of: "\"max_turns\":200", with: "\"max_turns\":200.0"),
            canonical.replacingOccurrences(of: "\"input_suggestions\":true", with: "\"input_suggestions\":1"),
            canonical.replacingOccurrences(of: "\"max_turns\":200", with: "\"max_turns\":1001"),
            canonical.replacingOccurrences(of: "\"token_budget\":null", with: "\"token_budget\":0")
        ] { #expect(throws: (any Error).self) { try AgentRuntimeParameters.decode(Data(invalid.utf8)) } }
    }

    @Test("只有不存在的文件才能回退；坏文件必须报错")
    func missingVersusInvalidFile() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent(AgentRuntimeParameters.fileName)
        #expect(try AgentRuntimeParameters.load(from: url) == nil)
        try Data("{}".utf8).write(to: url)
        #expect(throws: (any Error).self) { try AgentRuntimeParameters.load(from: url) }
    }

    @Test("共享 JSON 覆盖旧设置，并冻结每轮预算")
    func profilePrecedence() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        var profile = AgentRuntimeParameters()
        profile.maxTurns = 17
        profile.tokenBudget = 1000
        try Data(profile.canonical.utf8).write(to: url)
        let legacy = AgentSharedRuntimeConfig.parse("[agent]\nmax_turns = 40\ntoken_budget = 2000\n")
        let frozen = try AgentRuntimeParameters.resolve(shared: legacy, profileURL: url)
        profile.maxTurns = 30
        try Data(profile.canonical.utf8).write(to: url)
        #expect(frozen.maxTurns == 17)
        #expect(frozen.turnBudgetReached(input: 500, output: 500, usageKnown: true))
        #expect(frozen.turnBudgetReached(input: 0, output: 0, usageKnown: false))
        #expect(!frozen.turnBudgetReached(input: 500, output: 499, usageKnown: true))
        #expect(try AgentRuntimeParameters.resolve(shared: legacy, profileURL: url).maxTurns == 30)
    }

    @Test("累计流式 usage 去重，重试与未知用量不能清空预算")
    func cumulativeUsage() {
        let budget = AgentRuntimeTokenBudget(limit: 1000)
        let first = UUID()
        budget.begin(first)
        #expect(budget.isBlocked)
        budget.report(first, total: 400)
        budget.report(first, total: 400)
        #expect(budget.used == 400)
        #expect(!budget.isBlocked)
        budget.report(first, total: 600)
        #expect(budget.used == 600)
        let retry = UUID()
        budget.begin(retry)
        #expect(budget.isBlocked)
        budget.report(retry, total: 400)
        #expect(budget.used == 1000)
        #expect(budget.isBlocked)
    }

    @Test("共享 Goal 时钟只累计运行时间，暂停不会消耗下一段预算")
    func activeGoalClock() {
        let now = Date(timeIntervalSince1970: 10000)
        var budget = AgentGoalContinuationBudget(wallClockLimit: 100, segmentStartedAt: now)
        budget.activeElapsedSeconds = 50
        #expect(budget.elapsed(at: now.addingTimeInterval(20)) == 70)
        budget.activeElapsedSeconds = budget.elapsed(at: now.addingTimeInterval(20))
        budget.segmentStartedAt = nil
        #expect(budget.elapsed(at: now.addingTimeInterval(1000)) == 70)
        #expect(AgentGoalWakePolicy.hasWallClockRunway(budget, now: now.addingTimeInterval(1000)))
        #expect(budget.restarted.activeElapsedSeconds == 0)
    }

    @Test("旧 TOML 中的重复参数与无效布尔值必须拒绝")
    func malformedLegacy() {
        #expect(!AgentSharedRuntimeConfig.parse("[agent]\nmax_turns = 3\nmax_turns = 4").runtimeParameterErrors.isEmpty)
        #expect(!AgentSharedRuntimeConfig.parse("[agent]\nsmall_model_routing = TRUE").runtimeParameterErrors.isEmpty)
    }
}
