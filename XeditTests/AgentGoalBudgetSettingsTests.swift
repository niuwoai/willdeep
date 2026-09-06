import AppKit
import Foundation
import SwiftUI
import Testing
@testable import WillDeep

@MainActor
@Suite("目标预算编辑与展示", .serialized, .timeLimit(.minutes(1)))
struct AgentGoalBudgetSettingsTests {
    private struct Fixture {
        let root: URL
        let ledger: AgentModelRequestLedger
        let model: AgentGoalBudgetSettings
        func cleanup() {
            do { try FileManager.default.removeItem(at: root) }
            catch { Issue.record("Budget fixture cleanup failed: \(error)") }
        }
    }

    private func fixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("goal-budget-settings-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let ledger = AgentModelRequestLedger(directory: root, ownerID: UUID())
        return .init(root: root, ledger: ledger, model: .init(ledger: ledger))
    }

    @Test("只接受范围内正整数，不误解小数分隔符或指数")
    func validatesInput() {
        for input in ["", "0", "-1", "+1", "1.5", "1e6", "1,000", "1 000", "١٠", "999999999999999999999999"] {
            #expect(AgentGoalBudgetSettings.parseLimit(input) == nil)
        }
        #expect(AgentGoalBudgetSettings.parseLimit(" 100000\n") == 100_000)
        #expect(AgentGoalBudgetSettings.parseLimit(String(Int.max)) == Int.max)
    }

    @Test("保存和重开保留已消耗与未知预留，降低额度不是充值")
    func settingsPreserveSpend() async throws {
        let f = try fixture(); defer { f.cleanup() }
        let known = UUID(), unknown = UUID()
        try f.ledger.begin(id: known, providerID: "fixture", modelID: "fixture", reservedTokens: 40)
        try f.ledger.finish(id: known, receipt: .init(outcome: .failed,
            usage: .init(prompt: 20, completion: 5, total: 25, cachedPrompt: nil, cacheWritePrompt: nil, reasoning: 0)))
        try f.ledger.begin(id: unknown, providerID: "fixture", modelID: "fixture", reservedTokens: 40)
        try f.ledger.finish(id: unknown, receipt: .init(outcome: .cancelled, usage: nil))
        await f.model.load()
        #expect(!f.model.isLimited)
        f.model.isLimited = true
        f.model.limitText = "100"
        #expect(await f.model.save())
        #expect(f.model.snapshot?.remainingTokens == 35)
        f.model.limitText = "20"
        #expect(await f.model.save())
        #expect(f.model.snapshot?.remainingTokens == 0)
        #expect(f.model.snapshot?.exposure == .init(accountedTokens: 25, estimatedTokens: 40, unquantifiedAttempts: 0))
        let restored = AgentGoalBudgetSettings(ledger: f.ledger)
        await restored.load()
        #expect(restored.limitText == "20")
        restored.isLimited = false
        #expect(await restored.save())
        #expect(try f.ledger.summary().attempts == 2)
        #expect(restored.snapshot?.exposure == f.model.snapshot?.exposure)
    }

    @Test("未知历史不给出假余额，提高额度不能绕过未知消耗")
    func unknownRemainsUnknown() async throws {
        let f = try fixture(); defer { f.cleanup() }
        try f.ledger.begin(id: UUID(), providerID: "fixture", modelID: "fixture")
        try f.ledger.setAdmissionLimit(100, expectedRevision: 0)
        await f.model.load()
        #expect(f.model.snapshot?.exposure.unquantifiedAttempts == 1)
        #expect(f.model.snapshot?.remainingTokens == nil)
        f.model.limitText = "200"
        #expect(await f.model.save())
        #expect(throws: AgentModelRequestLedger.Failure.unknownExposure) {
            try f.ledger.begin(id: UUID(), providerID: "fixture", modelID: "fixture", reservedTokens: 1)
        }
    }

    @Test("过期编辑不覆盖其他窗口，必须明确重新载入")
    func staleEditorDoesNotOverwrite() async throws {
        let f = try fixture(); defer { f.cleanup() }
        await f.model.load()
        f.model.isLimited = true
        f.model.limitText = "100"
        try f.ledger.setAdmissionLimit(200, expectedRevision: 0)
        #expect(await f.model.save() == false)
        #expect(f.model.errorMessage == L10n.GoalBudget.stalePolicy)
        #expect(!f.model.canSave)
        #expect(await f.model.save() == false)
        #expect(try f.ledger.admissionPolicy().tokenLimit == 200)
        await f.model.load()
        #expect(f.model.limitText == "200")
        #expect(f.model.canSave)
    }

    @Test("编辑器固定账本身份，另一个目标不受保存影响")
    func ownerIsolationAndNoRuntimeResume() async throws {
        let f = try fixture(); defer { f.cleanup() }
        let other = AgentModelRequestLedger(directory: f.root, ownerID: UUID())
        try other.setAdmissionLimit(300, expectedRevision: 0)
        let runtime = AgentRuntime(session: .init(id: f.ledger.ownerID, interactionMode: .goal,
            currentGoal: .init(statement: "Keep paused", checklist: [.init(text: "Pending")],
                               continuationBudget: .init(wrapUpDispatched: true, modelAdmissionPaused: true))))
        let originalGoal = runtime.currentGoal
        await f.model.load()
        f.model.isLimited = true
        f.model.limitText = "100"
        #expect(await f.model.save())
        #expect(try other.admissionPolicy().tokenLimit == 300)
        #expect(runtime.currentGoal == originalGoal)
        #expect(!runtime.isResponding)
        #expect(runtime.requestTask == nil)
    }

    @Test("账本不可读取时不能将默认无限保存为新政策")
    func storageFailureDisablesSave() async throws {
        let f = try fixture(); defer { f.cleanup() }
        let invalid = f.root.appendingPathComponent("regular-file")
        try Data("fixture".utf8).write(to: invalid)
        let model = AgentGoalBudgetSettings(ledger: .init(directory: invalid, ownerID: UUID()))
        await model.load()
        #expect(model.snapshot == nil)
        #expect(model.errorMessage == L10n.GoalBudget.storageError)
        #expect(!model.canSave)
        #expect(await model.save() == false)
    }

    @Test("预算面板实际渲染浅色与深色，保留可检查图像")
    func rendersBudgetPanel() async throws {
        let f = try fixture(); defer { f.cleanup() }
        try f.ledger.setAdmissionLimit(100_000, expectedRevision: 0)
        await f.model.load()
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("goal-budget-qa-\(UUID())")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for dark in [false, true] {
            let view = NSHostingView(rootView: AgentGoalBudgetSheet(model: f.model)
                // The real sheet supplies an opaque window surface. A bare
                // offscreen NSHostingView is transparent and cannot prove
                // contrast when exported against a viewer's black background.
                .background(dark ? Color(white: 0.12) : Color(white: 0.96))
                .preferredColorScheme(dark ? .dark : .light))
            view.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            view.frame = .init(x: 0, y: 0, width: 480, height: 1)
            view.layoutSubtreeIfNeeded()
            let height = ceil(view.fittingSize.height)
            #expect(height > 350 && height < 850)
            view.frame.size.height = height
            view.layoutSubtreeIfNeeded()
            let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            #expect(try #require(bitmap.colorAt(x: 2, y: 2)).alphaComponent > 0.99)
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: output.appendingPathComponent(dark ? "dark.png" : "light.png"))
        }
        print("GoalBudgetQA: \(output.path)")
    }
}
