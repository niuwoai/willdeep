//
//  RoundtableExpertSelectionView.swift
//  WillDeep
//
//  用户确认圆桌阵容：AI 建议默认选中，仍可在完整专家池中增删 2-6 位。
//

import SwiftUI

struct RoundtableExpertSelectionView: View {
    let report: AgentRoundtableReport
    var isBusy = false
    var errorMessage: String?
    /// 可选的 provider 库条目;为空时不显示 provider/模型选择器(跟随全局活跃 provider)。
    var providerOptions: [AgentProviderEntry] = []
    let onBackToPreparation: () -> Void
    /// 确认阵容:专家名单 + 本场选定的 provider 条目(nil=跟随全局) + 模型(nil=provider 默认)。
    let onConfirm: ([AgentRoundtableExpertRole], UUID?, String?) -> Void

    @State private var selection: Set<AgentRoundtableExpertRole>
    @State private var reachedMaximum = false
    /// nil = 跟随全局活跃 provider;非 nil = 仅本场用该 provider。
    @State private var selectedProviderID: UUID?
    /// nil = 用该 provider 的路由默认模型;非 nil = 本场钉死该模型。
    @State private var selectedModelID: String?

    init(
        report: AgentRoundtableReport,
        isBusy: Bool = false,
        errorMessage: String? = nil,
        providerOptions: [AgentProviderEntry] = [],
        onBackToPreparation: @escaping () -> Void,
        onConfirm: @escaping ([AgentRoundtableExpertRole], UUID?, String?) -> Void
    ) {
        self.report = report
        self.isBusy = isBusy
        self.errorMessage = errorMessage
        self.providerOptions = providerOptions
        self.onBackToPreparation = onBackToPreparation
        self.onConfirm = onConfirm

        let prepared = report.preparation?.resolvedSelectedExperts ?? []
        let initial = prepared.isEmpty ? report.experts : prepared
        _selection = State(
            initialValue: Set(RoundtablePreparation.normalizedExperts(initial))
        )
        _selectedProviderID = State(initialValue: report.selectedProviderEntryID)
        _selectedModelID = State(initialValue: report.selectedModelID)
    }

    private var preparation: RoundtablePreparation {
        report.preparation ?? RoundtablePreparation(originalTopic: report.topic)
    }

    private var recommendedRoles: Set<AgentRoundtableExpertRole> {
        Set(preparation.recommendedExperts)
    }

    private var orderedSelection: [AgentRoundtableExpertRole] {
        AgentRoundtableExpertRole.allCases.filter(selection.contains)
    }

    private var isValidSelection: Bool {
        selection.count >= RoundtablePreparation.minimumExpertCount
            && selection.count <= RoundtablePreparation.maximumExpertCount
    }

    var body: some View {
        ZStack {
            RoundtableSetupBackground()

            VStack(spacing: 0) {
                header
                Divider().opacity(0.55)
                expertGrid
                Divider().opacity(0.55)
                footer
            }
        }
        .animation(.easeInOut(duration: 0.18), value: selection)
    }

    private var header: some View {
        HStack(spacing: 13) {
            Button(action: onBackToPreparation) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 26, height: 26)
            }
            .buttonStyle(.plain)
            .help(L10n.RoundtableSetup.editFrameworkAction)

            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [.orange.opacity(0.92), .pink.opacity(0.78)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                Image(systemName: "person.3.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 34, height: 34)
            .shadow(color: .orange.opacity(0.26), radius: 8, y: 4)

            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.RoundtableSetup.selectionTitle)
                    .font(.system(size: 17, weight: .semibold))
                Text(L10n.RoundtableSetup.selectionSubtitle)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 0)

            Text(L10n.RoundtableSetup.selectionCount(selection.count))
                .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                .foregroundStyle(isValidSelection ? Color.primary : Color.orange)
                .padding(.horizontal, 11)
                .padding(.vertical, 7)
                .background(
                    Capsule().fill(
                        isValidSelection
                            ? Color.secondary.opacity(0.09)
                            : Color.orange.opacity(0.12)
                    )
                )
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 13)
        .background(.ultraThinMaterial)
    }

    private var expertGrid: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 8) {
                    Image(systemName: "sparkles")
                        .foregroundStyle(.orange)
                    Text(L10n.RoundtableSetup.aiRecommended)
                        .font(.system(size: 12.5, weight: .semibold))
                    Spacer()
                    if selection.count < RoundtablePreparation.minimumExpertCount {
                        Label(
                            L10n.RoundtableSetup.tooFewExperts,
                            systemImage: "exclamationmark.circle.fill"
                        )
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.orange)
                    } else if reachedMaximum {
                        Label(
                            L10n.RoundtableSetup.maximumExpertsReached,
                            systemImage: "info.circle.fill"
                        )
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.orange)
                    }
                }

                LazyVGrid(
                    columns: [
                        GridItem(.adaptive(minimum: 245, maximum: 340), spacing: 12),
                    ],
                    alignment: .leading,
                    spacing: 12
                ) {
                    ForEach(AgentRoundtableExpertRole.allCases) { role in
                        expertCard(role)
                    }
                }

                if let errorMessage, !errorMessage.isEmpty {
                    errorCard(errorMessage)
                }
            }
            .padding(20)
            .frame(maxWidth: 1020)
            .frame(maxWidth: .infinity)
        }
    }

    private func expertCard(_ role: AgentRoundtableExpertRole) -> some View {
        let isSelected = selection.contains(role)
        let isRecommended = recommendedRoles.contains(role)

        return Button {
            toggle(role)
        } label: {
            VStack(alignment: .leading, spacing: 11) {
                HStack(alignment: .top, spacing: 11) {
                    RoundtableExpertAvatar(role: role, size: 46, isActive: isSelected)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(role.roleTitle)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Text(role.personalName)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        if isRecommended {
                            Label(
                                L10n.RoundtableSetup.aiRecommended,
                                systemImage: "sparkles"
                            )
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(.orange)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(Color.orange.opacity(0.11)))
                        }
                    }

                    Spacer(minLength: 0)

                    Image(
                        systemName: isSelected
                            ? "checkmark.circle.fill"
                            : "circle"
                    )
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(
                        isSelected
                            ? RoundtableVisuals.accent(for: role)
                            : Color.secondary.opacity(0.28)
                    )
                }

                Text(role.shortExpertise)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if let reason = recommendationReason(for: role) {
                    Divider().opacity(0.5)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(
                            L10n.RoundtableSetup.recommendedForTopic(
                                role.personalName
                            )
                        )
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(.orange)
                        Text(reason)
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 142, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(
                        isSelected
                            ? RoundtableVisuals.accent(for: role).opacity(0.085)
                            : Color(nsColor: .controlBackgroundColor).opacity(0.76)
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(
                        isSelected
                            ? RoundtableVisuals.accent(for: role).opacity(0.68)
                            : Color.secondary.opacity(0.12),
                        lineWidth: isSelected ? 1.5 : 1
                    )
            )
            .shadow(
                color: isSelected
                    ? RoundtableVisuals.accent(for: role).opacity(0.11)
                    : Color.black.opacity(0.035),
                radius: isSelected ? 11 : 7,
                y: 4
            )
        }
        .buttonStyle(.plain)
        .disabled(isBusy)
        .accessibilityLabel(role.displayName)
        .accessibilityValue(
            isSelected
                ? L10n.RoundtableSetup.selected
                : L10n.RoundtableSetup.available
        )
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Button(action: onBackToPreparation) {
                Label(
                    L10n.RoundtableSetup.editFrameworkAction,
                    systemImage: "slider.horizontal.3"
                )
            }
            .buttonStyle(.bordered)
            .disabled(isBusy)

            HStack(spacing: -8) {
                ForEach(orderedSelection) { role in
                    RoundtableExpertAvatar(role: role, size: 28)
                }
            }

            Spacer(minLength: 0)

            providerModelPicker

            if !isValidSelection {
                Text(L10n.RoundtableSetup.tooFewExperts)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.orange)
            }

            Button(action: confirmSelection) {
                if isBusy {
                    HStack(spacing: 7) {
                        ProgressView()
                            .controlSize(.small)
                        Text(L10n.RoundtableSetup.startingDiscussion)
                    }
                } else {
                    Label(
                        L10n.RoundtableSetup.confirmPanelAction,
                        systemImage: "arrow.right.circle.fill"
                    )
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(isBusy || !isValidSelection)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 13)
        .background(.ultraThinMaterial)
    }

    private func recommendationReason(for role: AgentRoundtableExpertRole) -> String? {
        preparation.recommendations.first(where: { $0.role == role })?.reason
    }

    private func toggle(_ role: AgentRoundtableExpertRole) {
        guard !isBusy else { return }
        if selection.contains(role) {
            selection.remove(role)
            reachedMaximum = false
            return
        }
        guard selection.count < RoundtablePreparation.maximumExpertCount else {
            reachedMaximum = true
            return
        }
        selection.insert(role)
        reachedMaximum = selection.count == RoundtablePreparation.maximumExpertCount
    }

    private func confirmSelection() {
        guard !isBusy, isValidSelection else { return }
        onConfirm(orderedSelection, selectedProviderID, selectedModelID)
    }

    /// 开会时选 provider / 模型(仅本场生效)。providerOptions 为空则整块不显示。
    /// 与会前准备室共用同一个可复用组件,保证两处交互与展示完全一致。
    private var providerModelPicker: some View {
        RoundtableProviderModelPicker(
            providerOptions: providerOptions,
            selectedProviderID: $selectedProviderID,
            selectedModelID: $selectedModelID,
            isBusy: isBusy
        )
    }

    private func errorCard(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
            VStack(alignment: .leading, spacing: 3) {
                Text(message)
                    .font(.system(size: 12.5, weight: .medium))
                Text(L10n.RoundtableSetup.retryHint)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 11).fill(Color.red.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 11).stroke(Color.red.opacity(0.20)))
    }
}

// MARK: - Provider / 模型选择器(会前准备室 + 选择专家页共用)

/// 「仅本场生效」的 provider + 模型二级下拉。选专家页和会前准备室都用它,保证
/// 两处交互一致。`providerOptions` 为空则整块不渲染(跟随全局活跃 provider)。
struct RoundtableProviderModelPicker: View {
    let providerOptions: [AgentProviderEntry]
    /// nil = 跟随全局活跃 provider;非 nil = 仅本场用该 provider。
    @Binding var selectedProviderID: UUID?
    /// nil = 用该 provider 的路由默认模型;非 nil = 本场钉死该模型。
    @Binding var selectedModelID: String?
    var isBusy = false

    private var selectedProviderEntry: AgentProviderEntry? {
        guard let id = selectedProviderID else { return nil }
        return providerOptions.first(where: { $0.id == id })
    }

    /// 选定 provider 的可选模型(flash + pro 去重)。
    private var modelOptions: [String] {
        guard let entry = selectedProviderEntry else { return [] }
        var seen = Set<String>()
        return (entry.allFlashModels + entry.allProModels).filter { seen.insert($0).inserted }
    }

    var body: some View {
        if !providerOptions.isEmpty {
            HStack(spacing: 6) {
                Image(systemName: "cpu")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)

                Menu {
                    Button {
                        selectedProviderID = nil
                        selectedModelID = nil
                    } label: {
                        if selectedProviderID == nil {
                            Label(
                                String(localized: "roundtable.provider.followActive", defaultValue: "跟随当前活跃 provider"),
                                systemImage: "checkmark"
                            )
                        } else {
                            Text(String(localized: "roundtable.provider.followActive", defaultValue: "跟随当前活跃 provider"))
                        }
                    }
                    Divider()
                    ForEach(providerOptions) { entry in
                        Button {
                            selectedProviderID = entry.id
                            selectedModelID = nil
                        } label: {
                            if selectedProviderID == entry.id {
                                Label(entry.displayName, systemImage: "checkmark")
                            } else {
                                Text(entry.displayName)
                            }
                        }
                    }
                } label: {
                    Text(
                        selectedProviderEntry?.displayName
                            ?? String(localized: "roundtable.provider.followActiveShort", defaultValue: "默认 provider")
                    )
                    .font(.system(size: 11.5, weight: .medium))
                    .lineLimit(1)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .disabled(isBusy)

                if !modelOptions.isEmpty {
                    Menu {
                        Button {
                            selectedModelID = nil
                        } label: {
                            if selectedModelID == nil {
                                Label(
                                    String(localized: "roundtable.model.providerDefault", defaultValue: "默认模型"),
                                    systemImage: "checkmark"
                                )
                            } else {
                                Text(String(localized: "roundtable.model.providerDefault", defaultValue: "默认模型"))
                            }
                        }
                        Divider()
                        ForEach(modelOptions, id: \.self) { model in
                            Button {
                                selectedModelID = model
                            } label: {
                                if selectedModelID == model {
                                    Label(model, systemImage: "checkmark")
                                } else {
                                    Text(model)
                                }
                            }
                        }
                    } label: {
                        Text(
                            selectedModelID
                                ?? String(localized: "roundtable.model.providerDefault", defaultValue: "默认模型")
                        )
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .disabled(isBusy)
                }
            }
        }
    }
}
