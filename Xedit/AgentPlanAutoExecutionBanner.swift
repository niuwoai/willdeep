//
//  AgentPlanAutoExecutionBanner.swift
//  WillDeep
//
//  Plan 模式下「计划已就绪」时浮在 composer 上方的小条。点 Execute 立刻
//  approve plan + 切回 Normal 模式 + 派发执行；点 Stay in Plan 拒绝；用户
//  在 composer 开始打字时由父 view 直接 hide（banner 自然销毁）。
//  1.79.0-rc1 引入；1.202.0 起去掉倒计时自动执行 —— Plan 模式是纯规划态，
//  执行必须由用户显式确认（勾过「本 workspace 不再询问」的除外，那是
//  用户自己的常设选择）。danger 关键词扫描保留，仅用于醒目警示。
//

import SwiftUI

struct AgentPlanAutoExecutionBanner: View {
    let plan: AgentPlan
    let workspacePath: String?
    let onConfirm: () -> Void
    let onReject: () -> Void
    let onRememberChange: (Bool) -> Void

    @State private var rememberChoice: Bool = false
    @State private var didFire: Bool = false
    /// 缓存 plan 危险词扫描结果。computed property 每次 body 重算都
    /// 会扫一遍整段 plan 文本（plan.summary + 所有 step.text），plan
    /// 步骤多 + body 频繁重算时会成为 CPU 热点。改在 onAppear 算一次，
    /// plan 在 banner 生命周期内不会变（plan 变了父 view 会用新的
    /// `.id()` 重建 banner），所以一次就够。
    @State private var isDestructive: Bool = false
    @State private var dangerScanEnabled: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: isDestructive ? "exclamationmark.triangle.fill" : "list.number")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(isDestructive ? Color.orange : Color.accentColor)

                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.PlanAutoExecutionBanner.title)
                        .font(.system(size: 13, weight: .semibold))
                    Text(isDestructive
                         ? L10n.PlanAutoExecutionBanner.dangerNotice
                         : L10n.PlanAutoExecutionBanner.subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                Spacer(minLength: 8)

                // 1.85.0-rc16:按 macOS 习惯把「拒绝」放最左、「确认/执行」
                // 放最右(显著的 borderedProminent),避免快速操作时误触。
                Button {
                    fireReject()
                } label: {
                    Text(L10n.PlanAutoExecutionBanner.rejectButton)
                        .font(.system(size: 12, weight: .medium))
                }
                .keyboardShortcut(.escape, modifiers: [])
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button {
                    fireConfirm()
                } label: {
                    Text(L10n.PlanAutoExecutionBanner.confirmButton)
                        .font(.system(size: 12, weight: .semibold))
                }
                .keyboardShortcut(.return, modifiers: [.command])
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }

            HStack(spacing: 8) {
                Toggle(isOn: $rememberChoice) {
                    Text(L10n.PlanAutoExecutionBanner.rememberToggle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .toggleStyle(.checkbox)
                .controlSize(.small)
                .onCompatibleChange(of: rememberChoice) { _, newValue in
                    onRememberChange(newValue)
                }

                Spacer(minLength: 8)

                if isDestructive {
                    Text(L10n.PlanAutoExecutionBanner.dangerNotice)
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                        .truncationMode(.tail)
                } else if !dangerScanEnabled {
                    Text(L10n.PlanAutoExecutionBanner.dangerScanDisabledHint)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else {
                    Text(L10n.PlanAutoExecutionBanner.manualConfirmHint)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(.thinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(
                    isDestructive ? Color.orange.opacity(0.5) : Color.accentColor.opacity(0.35),
                    lineWidth: 1
                )
        )
        .onAppear {
            // plan 在 banner 生命周期内固定（父 view 用 plan
            // fingerprint 作 `.id()`，plan 变 → banner 重建），所以
            // 危险词扫描和开关读取只需做一次。
            let scanOn = AgentSettingsStore.loadPlanAutoExecuteDangerScanEnabled()
            dangerScanEnabled = scanOn
            if scanOn {
                let blob = plan.summary + "\n" + plan.steps.map(\.text).joined(separator: "\n")
                isDestructive = AgentToolRegistry.planTextLooksDestructive(blob)
            } else {
                isDestructive = false
            }
        }
    }

    private func fireConfirm() {
        guard !didFire else { return }
        didFire = true
        if rememberChoice {
            AgentSettingsStore.savePlanAutoExecuteSilently(true, workspacePath: workspacePath)
        }
        onConfirm()
    }

    private func fireReject() {
        guard !didFire else { return }
        didFire = true
        onReject()
    }
}
