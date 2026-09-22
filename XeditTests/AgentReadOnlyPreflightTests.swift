import Foundation
import Testing
@testable import WillDeep

@Suite
@MainActor
struct AgentReadOnlyPreflightTests {
    @Test("预检轮数上限远低于工种正常预算，但不会把本来更小的预算放大")
    func preflightRoundBudgetIsTight() {
        let ops = AgentSubagentProfileStore.resolvedProfile(id: AgentSubagentProfileCatalog.opsRunnerID)
        #expect(ops.maxRounds > AppState.preflightMaxRounds)
        let bounded = AppState.preflightProfile(ops)
        #expect(bounded.maxRounds == AppState.preflightMaxRounds)
        #expect(bounded.id == ops.id)
        #expect(bounded.toolNames == ops.toolNames)

        var small = ops
        small.maxRounds = 2
        #expect(AppState.preflightProfile(small).maxRounds == 2)
    }

    @Test("preflight defaults off and is explicitly enabled by shared config")
    func preflightDefaultsOff() {
        // Serial preflight delays the root model's first token, so an absent
        // config now protects latency. Large repositories can opt back in.
        #expect(!AppState.readOnlyPreflightEnabled(sharedConfig: AgentSharedRuntimeConfig()))

        var shared = AgentSharedRuntimeConfig()
        shared.autoDispatchReadOnly = true
        #expect(AppState.readOnlyPreflightEnabled(sharedConfig: shared))

        shared.autoDispatchReadOnly = false
        #expect(!AppState.readOnlyPreflightEnabled(sharedConfig: shared))
    }

    @Test("the worker brief is self-contained and forbids guessing")
    func preflightPromptIsSelfContained() {
        let prompt = AppState.preflightPrompt(requestText: "用户权限检查在哪个文件")

        // The child sees none of the parent conversation, so the request has
        // to survive on its own.
        #expect(prompt.contains("用户权限检查在哪个文件"))
        #expect(prompt.contains("read-only"))
        #expect(prompt.lowercased().contains("do not guess"))
    }

    @Test("the report is folded into the existing steering rather than replacing it")
    func reportFoldsIntoSteering() {
        let steering = AppState.steeringWithReport(
            existing: "<runtime-route tier=\"worker\" profile=\"scout\">…</runtime-route>",
            profileID: "scout",
            model: "someim-32b-scout",
            report: "AuthGate.swift:42 gates the permission check."
        )

        #expect(steering.contains("<runtime-route"))
        #expect(steering.contains("<runtime-preflight profile=\"scout\""))
        #expect(steering.contains("AuthGate.swift:42"))
        // Evidence, not verdict — the root model must stay willing to check.
        #expect(steering.contains("evidence"))
    }

    @Test("with no prior steering the report stands alone")
    func reportWithoutExistingSteering() {
        let steering = AppState.steeringWithReport(
            existing: nil,
            profileID: "reader",
            model: "someim-32b-reader",
            report: "The module has three entry points."
        )

        #expect(steering.hasPrefix("<runtime-preflight"))
        #expect(!steering.contains("<runtime-route"))
    }

    @Test("an oversized report is truncated and says it was truncated")
    func oversizedReportIsClampedHonestly() {
        let huge = String(repeating: "x", count: 40_000)
        let clamped = AppState.clampedReport(huge)

        #expect(clamped.count < huge.count)
        #expect(clamped.hasPrefix("x"))
        // Silence would be read as "the worker looked and found nothing",
        // which is exactly the wrong conclusion to draw from a cut report.
        #expect(clamped.contains("truncated"))
        #expect(clamped.contains("not evidence") || clamped.contains("do not read the absence"))
    }

    @Test("a report within budget is passed through untouched")
    func smallReportIsUnchanged() {
        let report = "AuthGate.swift:42 gates the permission check."

        #expect(AppState.clampedReport(report) == report)
    }

    @Test("only read-only classifications are preflight candidates")
    func onlyReadOnlyWorkIsEligible() {
        // The executing half keys off exactly this flag, so the invariant
        // "a preflight never edits" is enforced by the classifier.
        for request in ["定位并修复用户权限检查", "实现新的重试策略", "测试失败了，修复这个断言"] {
            #expect(!AgentRequestRouter.classify(request).autoDispatchEligible, "\(request)")
        }
        for request in ["用户权限检查在哪个文件", "扫一下这个仓库，解释当前架构", "哪个提交引入这个问题的"] {
            #expect(AgentRequestRouter.classify(request).autoDispatchEligible, "\(request)")
        }
    }
}
