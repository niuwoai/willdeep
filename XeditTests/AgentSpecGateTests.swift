//
//  AgentSpecGateTests.swift
//  WillDeepTests
//

import Testing

@testable import WillDeep

@Suite("Spec gate 准入筛")
nonisolated struct AgentSpecGateTests {
    private func input(
        _ text: String,
        hasWorkspace: Bool = true,
        isGoalMode: Bool = false,
        isUnattendedDispatch: Bool = false
    ) -> AgentSpecGateSignals.Input {
        AgentSpecGateSignals.Input(
            requestText: text,
            hasWorkspace: hasWorkspace,
            isGoalMode: isGoalMode,
            isUnattendedDispatch: isUnattendedDispatch
        )
    }

    private func kinds(_ text: String) -> Set<AgentSpecGateSignal.Kind> {
        Set(AgentSpecGateSignals.signals(for: input(text)).map(\.kind))
    }

    // MARK: - 单条信号

    @Test("明说要设计是强信号，单条即可过阈值")
    func explicitRequestAloneClears() {
        let signals = AgentSpecGateSignals.signals(for: input("这个功能你先出个方案，别急着写代码"))
        #expect(signals.contains { $0.kind == .explicitRequest })
        #expect(AgentSpecGateSignals.clearsThreshold(signals))
    }

    @Test("新增子系统是强信号")
    func newSubsystemAloneClears() {
        let signals = AgentSpecGateSignals.signals(for: input("我们要新增一个子系统来管配额"))
        #expect(signals.contains { $0.kind == .newSubsystem })
        #expect(AgentSpecGateSignals.clearsThreshold(signals))
    }

    @Test("改存档格式是强信号")
    func persistenceAloneClears() {
        let signals = AgentSpecGateSignals.signals(for: input("会话的落盘格式要改，老数据得能迁移过来"))
        #expect(signals.contains { $0.kind == .persistenceChange })
        #expect(AgentSpecGateSignals.clearsThreshold(signals))
    }

    /// 弱信号单独出现不足以拦人。这条守的是当年那个失败的方向：
    /// 一句话里提到「架构」不等于这是一次架构改造。
    @Test("单条弱信号不过阈值")
    func singleWeakSignalDoesNotClear() {
        let signals = AgentSpecGateSignals.signals(for: input("顺手把这段按现在的架构风格挪一下位置"))
        #expect(signals.allSatisfy { !$0.kind.isStrong })
        #expect(AgentSpecGateSignals.clearsThreshold(signals) == false)
    }

    @Test("两条弱信号合起来过阈值")
    func twoWeakSignalsClear() {
        let signals = AgentSpecGateSignals.signals(
            for: input("这次要动通信协议，macOS 和 android 两端都得跟着改")
        )
        #expect(signals.count >= 2)
        #expect(signals.allSatisfy { !$0.kind.isStrong })
        #expect(AgentSpecGateSignals.clearsThreshold(signals))
    }

    @Test("只提一个端不算跨端")
    func singleSurfaceIsNotMultiSurface() {
        #expect(kinds("把 macos 上这个按钮的标题改一下").contains(.multiSurface) == false)
    }

    // MARK: - 愿望与落点

    /// vagueGoal 的两个半边都要成立。带了具体落点的愿望是普通需求，
    /// 不是需要先收敛的问题陈述。
    @Test("愿望带了代码落点就不算模糊")
    func wishWithAnchorIsNotVague() {
        #expect(kinds("我希望 AgentSessionStore.swift 里那个全量解码能快点").contains(.vagueGoal) == false)
    }

    @Test("愿望没有落点才算模糊")
    func wishWithoutAnchorIsVague() {
        #expect(kinds("我希望它别老是卡在那里转圈，用起来太难受了").contains(.vagueGoal))
    }

    @Test("没有愿望词就不判模糊")
    func statementWithoutWishIsNotVague() {
        #expect(kinds("这里的排序结果每次都不一样，看着像渲染问题").contains(.vagueGoal) == false)
    }

    // MARK: - 排除

    @Test("目标模式一律不判定")
    func goalModeIsExcluded() {
        let signals = AgentSpecGateSignals.signals(
            for: input("先出个技术方案，新增一个子系统", isGoalMode: true)
        )
        #expect(signals.isEmpty)
    }

    @Test("无人值守子任务一律不判定")
    func unattendedDispatchIsExcluded() {
        let signals = AgentSpecGateSignals.signals(
            for: input("先出个技术方案，新增一个子系统", isUnattendedDispatch: true)
        )
        #expect(signals.isEmpty)
    }

    @Test("没有工作区就没有 docs 可写，不判定")
    func missingWorkspaceIsExcluded() {
        let signals = AgentSpecGateSignals.signals(
            for: input("先出个技术方案，新增一个子系统", hasWorkspace: false)
        )
        #expect(signals.isEmpty)
    }

    /// 「继续」「好的」这类短消息推进的是已经在跑的活，不是新需求。
    @Test("过短的消息不进筛")
    func shortMessagesAreIgnored() {
        #expect(AgentSpecGateSignals.signals(for: input("继续")).isEmpty)
        #expect(AgentSpecGateSignals.signals(for: input("我希望能")).isEmpty)
    }

    @Test("空信号不过阈值")
    func emptySignalsDoNotClear() {
        #expect(AgentSpecGateSignals.clearsThreshold([]) == false)
    }

    // MARK: - 证据

    @Test("证据是原句片段且长度有上限")
    func evidenceIsBoundedExcerpt() {
        let long = String(repeating: "跨模块的架构改造涉及很多地方", count: 40)
        let signals = AgentSpecGateSignals.signals(for: input(long))
        #expect(signals.isEmpty == false)
        for signal in signals {
            #expect(signal.evidence.isEmpty == false)
            #expect(signal.evidence.count <= AgentSpecGateSignals.evidenceLimit)
        }
    }

    // MARK: - 裁决

    /// 裁决必须能区分「问过了，判为简单」和「压根没问到」。审批裁判
    /// 当年连续失败数月没人发现，就是因为这两件事返回同一个值。
    @Test("放行原因彼此独立，不能压成一个值")
    func proceedReasonsStayDistinct() {
        let downgraded = AgentSpecGateVerdict.proceed(.judgeDowngraded)
        let unavailable = AgentSpecGateVerdict.proceed(.judgeUnavailable)
        #expect(downgraded.reason != unavailable.reason)
        #expect(downgraded.outcome == .proceed)
        #expect(unavailable.outcome == .proceed)
    }

    /// 影子期的输出是 proceed，但它必须能被数出来，否则误报率无从算起。
    @Test("影子期虽然放行但计入将被拦截")
    func shadowOnlyCountsAsWouldGate() {
        let shadow = AgentSpecGateVerdict(
            outcome: .proceed,
            reason: .shadowOnly,
            signals: [AgentSpecGateSignal(kind: .explicitRequest, evidence: "先出个方案")]
        )
        #expect(shadow.outcome == .proceed)
        #expect(shadow.wouldGate)
    }

    @Test("未命中阈值不计入将被拦截")
    func belowThresholdDoesNotCountAsWouldGate() {
        #expect(AgentSpecGateVerdict.proceed(.belowThreshold).wouldGate == false)
        #expect(AgentSpecGateVerdict.proceed(.disabled).wouldGate == false)
        #expect(AgentSpecGateVerdict.proceed(.excluded).wouldGate == false)
    }

    @Test("裁决可编解码且往返相等")
    func verdictRoundTrips() throws {
        let verdict = AgentSpecGateVerdict(
            outcome: .gate,
            reason: .confirmed,
            signals: [AgentSpecGateSignal(kind: .persistenceChange, evidence: "落盘格式要改")],
            judgeModel: "someim-judge",
            judgeLatencyMS: 412
        )
        let data = try JSONEncoder().encode(verdict)
        let decoded = try JSONDecoder().decode(AgentSpecGateVerdict.self, from: data)
        #expect(decoded == verdict)
    }

    @Test("强弱之分定义在信号上，不散落在调用点")
    func strengthIsDeclaredOnTheCase() {
        #expect(AgentSpecGateSignal.Kind.explicitRequest.isStrong)
        #expect(AgentSpecGateSignal.Kind.newSubsystem.isStrong)
        #expect(AgentSpecGateSignal.Kind.persistenceChange.isStrong)
        #expect(AgentSpecGateSignal.Kind.crossModuleKeywords.isStrong == false)
        #expect(AgentSpecGateSignal.Kind.multiSurface.isStrong == false)
        #expect(AgentSpecGateSignal.Kind.vagueGoal.isStrong == false)
    }
}
