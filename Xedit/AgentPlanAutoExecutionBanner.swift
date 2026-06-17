//
//  AgentPlanAutoExecutionBanner.swift
//  WillDeep
//
//  Plan 模式下「计划已就绪」时浮在 composer 上方的小条。点 Execute 立刻
//  approve plan + 派发执行；点 Stay in Plan 拒绝；用户在 composer 开始
//  打字时由父 view 直接 hide（banner 自然销毁、timer 跟着销毁）；倒计时
//  归零自动 Execute（**当 plan 文本未命中 destructive 关键词时**才会
//  自动跑，命中时倒计时灰显，必须手点）。1.79.0-rc1 引入。
//

import SwiftUI
import Combine

struct AgentPlanAutoExecutionBanner: View {
    /// banner 总倒计时长度。用户上手时希望"过了 8 秒还没说话就跑"。
    static let countdownSeconds: Int = 8

    let plan: AgentPlan
    let workspacePath: String?
    let onConfirm: () -> Void
    let onReject: () -> Void
    let onRememberChange: (Bool) -> Void

    @State private var secondsRemaining: Int = AgentPlanAutoExecutionBanner.countdownSeconds
    @State private var rememberChoice: Bool = false
    @State private var didFire: Bool = false

    /// Timer publisher 每秒推一次 tick。@State 持有最新 tick 触发 view
    /// 重算 —— 计时状态完全本地，不写父 view 的 @Published，避免触发
    /// [[project-swiftui-sheet-published-loop]] 那一族死循环。
    private let timer = Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()

    private var isDestructive: Bool {
        guard AgentSettingsStore.loadPlanAutoExecuteDangerScanEnabled() else {
            return false
        }
        let blob = plan.summary + "\n" + plan.steps.map(\.text).joined(separator: "\n")
        return AgentToolRegistry.planTextLooksDestructive(blob)
    }

    private var dangerScanEnabled: Bool {
        AgentSettingsStore.loadPlanAutoExecuteDangerScanEnabled()
    }

    private var countdownProgress: Double {
        let total = Double(Self.countdownSeconds)
        guard total > 0 else { return 0 }
        return max(0, min(1, Double(secondsRemaining) / total))
    }

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

                Button {
                    fireConfirm(source: .manual)
                } label: {
                    Text(L10n.PlanAutoExecutionBanner.confirmButton)
                        .font(.system(size: 12, weight: .semibold))
                }
                .keyboardShortcut(.return, modifiers: [.command])
                .buttonStyle(.borderedProminent)
                .controlSize(.small)

                Button {
                    fireReject()
                } label: {
                    Text(L10n.PlanAutoExecutionBanner.rejectButton)
                        .font(.system(size: 12, weight: .medium))
                }
                .keyboardShortcut(.escape, modifiers: [])
                .buttonStyle(.bordered)
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
                .onChange(of: rememberChoice) { _, newValue in
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
                    Text(L10n.PlanAutoExecutionBanner.countdownText(secondsRemaining: secondsRemaining))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .monospacedDigit()
                }
            }

            ProgressView(value: countdownProgress)
                .progressViewStyle(.linear)
                .tint(isDestructive ? Color.secondary : Color.accentColor)
                .opacity(isDestructive ? 0.35 : 1.0)
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
        .onReceive(timer) { _ in
            // destructive 命中 → 倒计时停在初始值，不自动 fire。
            guard !isDestructive, !didFire else { return }
            if secondsRemaining > 0 {
                secondsRemaining -= 1
            }
            if secondsRemaining == 0 {
                fireConfirm(source: .countdown)
            }
        }
    }

    private enum ConfirmSource {
        case manual
        case countdown
    }

    private func fireConfirm(source: ConfirmSource) {
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
