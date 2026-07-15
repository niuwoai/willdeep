//
//  AgentPlanModeSuggestionBanner.swift
//  WillDeep
//
//  Pre-dispatch Plan-mode suggestion with an auto-resolution countdown.
//

import SwiftUI
import Combine

struct AgentPlanModeSuggestionBanner: View {
    static let countdownSeconds = AgentPlanModeSuggestionPolicy.autoResolutionSeconds

    let onEnterPlan: () -> Void
    let onContinueNormally: () -> Void

    @State private var secondsRemaining = AgentPlanModeSuggestionBanner.countdownSeconds
    @State private var didResolve = false

    private let timer = Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()

    private var countdownProgress: Double {
        let total = Double(Self.countdownSeconds)
        guard total > 0 else { return 0 }
        return max(0, min(1, Double(secondsRemaining) / total))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "list.number")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.accentColor)

                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.PlanModeSuggestion.title)
                        .font(.system(size: 13, weight: .semibold))
                    Text(L10n.PlanModeSuggestion.subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                Spacer(minLength: 8)

                Button {
                    resolve(enterPlan: false)
                } label: {
                    Text(L10n.PlanModeSuggestion.continueNormallyButton)
                        .font(.system(size: 12, weight: .medium))
                }
                .keyboardShortcut(.escape, modifiers: [])
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button {
                    resolve(enterPlan: true)
                } label: {
                    Text(L10n.PlanModeSuggestion.enterPlanButton)
                        .font(.system(size: 12, weight: .semibold))
                }
                .keyboardShortcut(.return, modifiers: [.command])
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }

            HStack {
                Spacer()
                Text(L10n.PlanModeSuggestion.countdownText(secondsRemaining: secondsRemaining))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
            }

            ProgressView(value: countdownProgress)
                .progressViewStyle(.linear)
                .tint(Color.accentColor)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(.thinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.accentColor.opacity(0.35), lineWidth: 1)
        )
        .onReceive(timer) { _ in
            guard !didResolve else { return }
            if secondsRemaining > 0 {
                secondsRemaining -= 1
            }
            if secondsRemaining == 0 {
                resolve(enterPlan: true)
            }
        }
    }

    private func resolve(enterPlan: Bool) {
        guard !didResolve else { return }
        didResolve = true
        if enterPlan {
            onEnterPlan()
        } else {
            onContinueNormally()
        }
    }
}
