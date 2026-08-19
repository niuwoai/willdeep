import Foundation
import Testing
@testable import WillDeep

@Suite
@MainActor
struct AgentReadOnlyPreflightTests {
    @Test("preflight ships off and is turned on by the shared config")
    func preflightDefaultsOff() {
        // Deliberately opt-in: it costs visible time-to-first-token in a GUI,
        // and the classifier that gates it is keyword matching.
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
