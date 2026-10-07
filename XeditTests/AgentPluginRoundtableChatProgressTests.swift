import Foundation
import Testing
@testable import WillDeep

@Suite("主会话圆桌实时发言")
struct AgentPluginRoundtableChatProgressTests {
    private let seat = RoundtableCustomExpert(id: "chief", name: "总策划", expertise: "弧光", persona: "审读")

    @Test("反向请求只绑定唯一且正在响应的活动主会话")
    func originSelection() {
        let active = UUID(), other = UUID()
        #expect(AgentPluginRoundtableChatOrigin.resolve(activeSessionID: active, respondingSessionIDs: [active]) == active)
        #expect(AgentPluginRoundtableChatOrigin.resolve(activeSessionID: active, respondingSessionIDs: []) == nil)
        #expect(AgentPluginRoundtableChatOrigin.resolve(activeSessionID: active, respondingSessionIDs: [other]) == nil)
        #expect(AgentPluginRoundtableChatOrigin.resolve(activeSessionID: active, respondingSessionIDs: [active, other]) == nil)
        #expect(AgentPluginRoundtableChatOrigin.resolve(activeSessionID: nil, respondingSessionIDs: [active]) == nil)
    }

    @Test("发言增量立即可读，结束正文后明确标为分析中")
    func streamedSpeech() {
        var report = AgentRoundtableReport(topic: "剧本", phase: .discussing, currentRound: 2, customExperts: [seat], activeCustomExpertID: seat.id)
        #expect(AgentPluginRoundtableChatSpeech.make(from: report)?.state == .preparing)
        report.activeExpertDraft = "开场要更快。"
        let first = AgentPluginRoundtableChatSpeech.make(from: report)
        #expect(first?.name == "总策划")
        #expect(first?.round == 2)
        #expect(first?.text == "开场要更快。")
        #expect(first?.state == .streaming)
        report.activeExpertDraft = "开场要更快。先给冲突，再解释。"
        #expect(AgentPluginRoundtableChatSpeech.make(from: report)?.text == report.activeExpertDraft)
        report.activeExpertDraftIsComplete = true
        #expect(AgentPluginRoundtableChatSpeech.make(from: report)?.state == .analyzing)
    }

    @Test("专家切换时清空旧稿，主持人汇总时保留最近成功发言")
    func speakerTransitions() {
        var report = AgentRoundtableReport(topic: "剧本", phase: .discussing, currentRound: 1, customExperts: [seat])
        report.messages = [RoundtableMessage(speaker: .expert, round: 1, content: "删掉寒暄。", customExpertID: seat.id, speakerDisplayName: seat.name)]
        #expect(AgentPluginRoundtableChatSpeech.make(from: report)?.state == .finished)
        #expect(AgentPluginRoundtableChatSpeech.make(from: report)?.text == "删掉寒暄。")
        report.activeCustomExpertID = seat.id
        #expect(AgentPluginRoundtableChatSpeech.make(from: report)?.text == "")
        report.activeCustomExpertID = nil
        report.phase = .synthesizing
        report.messages.append(RoundtableMessage(speaker: .expert, round: 1, content: "请求失败", isError: true, customExpertID: seat.id))
        #expect(AgentPluginRoundtableChatSpeech.make(from: report)?.text == "删掉寒暄。")
    }

    @Test("长正文保留最新片段，旧外部圆桌存档仍能解码")
    func boundedPreviewAndCompatibility() throws {
        let text = String(repeating: "早", count: 2_000) + "最新观点🌱"
        let report = AgentRoundtableReport(topic: "剧本", phase: .discussing, currentRound: 1, activeExpertDraft: text, customExperts: [seat], activeCustomExpertID: seat.id)
        let speech = try #require(AgentPluginRoundtableChatSpeech.make(from: report))
        #expect(speech.text.count == AgentPluginRoundtableChatSpeech.previewLimit)
        #expect(speech.text.hasSuffix("最新观点🌱"))
        let oldReport = AgentRoundtableReport(topic: "旧圆桌")
        let old = try JSONEncoder().encode(oldReport)
        #expect(try JSONDecoder().decode(AgentRoundtableReport.self, from: old).originSessionID == nil)
        let origin = UUID()
        let run = AgentRoundtableReport(topic: "新圆桌", originSessionID: origin)
        #expect(try JSONDecoder().decode(AgentRoundtableReport.self, from: JSONEncoder().encode(run)).originSessionID == origin)
    }

    @Test("时间线仅保留最近三条，长历史取开头而实时正文取末尾")
    func boundedTimeline() {
        var report = AgentRoundtableReport(topic: "剧本", phase: .discussing, currentRound: 2, customExperts: [seat], activeCustomExpertID: seat.id)
        let longText = "开头" + String(repeating: "长文。", count: 3_000) + "末尾"
        report.messages = (0..<10).map { round in
            RoundtableMessage(speaker: .expert, round: round, content: longText, customExpertID: seat.id, speakerDisplayName: seat.name)
        }
        report.activeExpertDraft = longText
        let entries = AgentRoundtableChatTimeline.entries(from: report)
        #expect(entries.count == 3)
        #expect(entries[0].text.hasPrefix("开头"))
        #expect(entries[0].text.count == AgentRoundtableChatTimeline.completedPreviewLimit)
        #expect(entries[0].isTruncated)
        #expect(entries[2].text.hasSuffix("末尾"))
        #expect(entries[2].isLive)
        #expect(entries[2].text.count == AgentRoundtableChatTimeline.livePreviewLimit)
        let previousIDs = entries.map(\.id)
        report.activeExpertDraft?.append("更新")
        #expect(AgentRoundtableChatTimeline.entries(from: report).map(\.id) == previousIDs)
    }

    @Test("终态不继续展示活动草稿，错误发言明确标注")
    func terminalTimeline() {
        let report = AgentRoundtableReport(topic: "剧本", phase: .failed, messages: [
            .init(speaker: .expert, round: 1, content: "上游失败", isError: true, customExpertID: seat.id)
        ], activeExpertDraft: "旧草稿", customExperts: [seat], activeCustomExpertID: seat.id)
        let entries = AgentRoundtableChatTimeline.entries(from: report)
        #expect(entries.count == 1)
        #expect(entries[0].isError)
        #expect(!entries[0].isLive)
        #expect(AgentRoundtableChatTimeline.elapsed(from: Date(timeIntervalSince1970: 100), to: Date(timeIntervalSince1970: 90)) == "00:00")
    }

    @Test("启动工具可直接发现，专家阵容严格校验")
    @MainActor
    func toolContract() throws {
        #expect(AgentToolPackCatalog.coreToolNames.contains("start_roundtable"))
        #expect(AgentToolRegistry.descriptor(for: "start_roundtable")?.risk == .write)
        #expect(AgentToolRegistry.descriptor(for: "get_roundtable_status")?.risk == .read)
        #expect(try AgentRoundtableTools.validatedExperts(nil).isEmpty)
        #expect(try AgentRoundtableTools.validatedExperts(.array([.string("product"), .string("risk")])) == [.product, .risk])
        #expect(throws: (any Error).self) { try AgentRoundtableTools.validatedExperts(.array([.string("risk"), .string("risk")])) }
        #expect(throws: (any Error).self) { try AgentRoundtableTools.validatedExperts(.array([.string("product"), .string("unknown")])) }
    }
}
