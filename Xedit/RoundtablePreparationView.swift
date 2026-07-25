//
//  RoundtablePreparationView.swift
//  WillDeep
//
//  正式讨论前的议题准备室：展示精炼问题、讨论框架、澄清对话和专家建议。
//

import SwiftUI

struct RoundtablePreparationView: View {
    let report: AgentRoundtableReport
    var isBusy = false
    var errorMessage: String?
    /// 可选的 provider 库条目;为空时不显示 provider/模型选择器(跟随全局活跃 provider)。
    var providerOptions: [AgentProviderEntry] = []
    let onBack: () -> Void
    let onRefine: (String) -> Void
    let onChooseExperts: () -> Void
    /// 本场 provider/模型选择变化时回写 report,带到「选择专家」页作为初值。
    let onSelectProviderModel: (UUID?, String?) -> Void

    @State private var refinementDraft = ""
    /// nil = 跟随全局活跃 provider;非 nil = 仅本场用该 provider。
    @State private var selectedProviderID: UUID?
    /// nil = 用该 provider 的路由默认模型;非 nil = 本场钉死该模型。
    @State private var selectedModelID: String?

    init(
        report: AgentRoundtableReport,
        isBusy: Bool = false,
        errorMessage: String? = nil,
        providerOptions: [AgentProviderEntry] = [],
        onBack: @escaping () -> Void,
        onRefine: @escaping (String) -> Void,
        onChooseExperts: @escaping () -> Void,
        onSelectProviderModel: @escaping (UUID?, String?) -> Void = { _, _ in }
    ) {
        self.report = report
        self.isBusy = isBusy
        self.errorMessage = errorMessage
        self.providerOptions = providerOptions
        self.onBack = onBack
        self.onRefine = onRefine
        self.onChooseExperts = onChooseExperts
        self.onSelectProviderModel = onSelectProviderModel
        _selectedProviderID = State(initialValue: report.selectedProviderEntryID)
        _selectedModelID = State(initialValue: report.selectedModelID)
    }

    private var preparation: RoundtablePreparation {
        report.preparation ?? RoundtablePreparation(originalTopic: report.topic)
    }

    private var canChooseExperts: Bool {
        !isBusy
            && !preparation.refinedTopic.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && preparation.recommendations.count >= RoundtablePreparation.minimumExpertCount
    }

    var body: some View {
        ZStack {
            RoundtableSetupBackground()

            VStack(spacing: 0) {
                header
                Divider().opacity(0.55)
                content
                Divider().opacity(0.55)
                footer
            }
        }
        .animation(.easeInOut(duration: 0.2), value: isBusy)
    }

    private var header: some View {
        HStack(spacing: 13) {
            Button(action: onBack) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 26, height: 26)
            }
            .buttonStyle(.plain)
            .help(L10n.RoundtableSetup.backAction)

            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [.indigo.opacity(0.85), .cyan.opacity(0.78)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                Image(systemName: "scope")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 34, height: 34)
            .shadow(color: .indigo.opacity(0.28), radius: 8, y: 4)

            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.RoundtableSetup.preparationTitle)
                    .font(.system(size: 17, weight: .semibold))
                Text(L10n.RoundtableSetup.preparationSubtitle)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 0)

            if isBusy {
                HStack(spacing: 7) {
                    ProgressView()
                        .controlSize(.small)
                    Text(L10n.RoundtableSetup.preparing)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 11)
                .padding(.vertical, 7)
                .background(Capsule().fill(Color.accentColor.opacity(0.09)))
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 13)
        .background(.ultraThinMaterial)
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                topicCard

                HStack(alignment: .top, spacing: 16) {
                    frameworkCard
                        .frame(maxWidth: .infinity, alignment: .top)
                    recommendationCard
                        .frame(maxWidth: .infinity, alignment: .top)
                }

                if !preparation.conversation.isEmpty {
                    clarificationConversation
                }
                if !preparation.clarificationQuestions.isEmpty {
                    clarificationQuestions
                }

                if let errorMessage, !errorMessage.isEmpty {
                    errorCard(errorMessage)
                }
            }
            .padding(20)
            .frame(maxWidth: 940)
            .frame(maxWidth: .infinity)
        }
    }

    private var topicCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                setupSectionIcon("quote.bubble", color: .secondary)
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.RoundtableSetup.originalTopic)
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                    Text(preparation.originalTopic)
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }

            Divider().opacity(0.6)

            HStack(alignment: .top, spacing: 10) {
                setupSectionIcon("scope", color: .indigo)
                VStack(alignment: .leading, spacing: 5) {
                    Text(L10n.RoundtableSetup.refinedTopic)
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(.indigo)
                        .textCase(.uppercase)
                    if preparation.refinedTopic.isEmpty {
                        loadingLine
                    } else {
                        Text(preparation.refinedTopic)
                            .font(.system(size: 16, weight: .semibold))
                            .lineSpacing(3)
                            .textSelection(.enabled)
                    }
                }
            }
        }
        .roundtableSetupCard(accent: .indigo)
    }

    private var frameworkCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader(
                L10n.RoundtableSetup.frameworkTitle,
                symbol: "point.3.connected.trianglepath.dotted",
                color: .cyan
            )

            if preparation.framework.isEmpty {
                loadingLine
                loadingLine
                loadingLine
            } else {
                ForEach(Array(preparation.framework.enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .top, spacing: 9) {
                        Text("\(index + 1)")
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                            .foregroundStyle(.cyan)
                            .frame(width: 21, height: 21)
                            .background(Circle().fill(Color.cyan.opacity(0.12)))
                        Text(item)
                            .font(.system(size: 12.5))
                            .lineSpacing(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .roundtableSetupCard(accent: .cyan)
    }

    private var recommendationCard: some View {
        VStack(alignment: .leading, spacing: 11) {
            sectionHeader(
                L10n.RoundtableSetup.recommendationTitle,
                symbol: "person.3.fill",
                color: .orange
            )

            if preparation.recommendations.isEmpty {
                loadingLine
                loadingLine
            } else {
                ForEach(preparation.recommendations) { recommendation in
                    HStack(alignment: .top, spacing: 9) {
                        RoundtableExpertAvatar(role: recommendation.role, size: 32)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(recommendation.role.displayName)
                                .font(.system(size: 12, weight: .semibold))
                            Text(recommendation.reason)
                                .font(.system(size: 10.5))
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                }
                Text(L10n.RoundtableSetup.recommendationHint)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
                    .padding(.top, 2)
            }
        }
        .roundtableSetupCard(accent: .orange)
    }

    private var clarificationQuestions: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader(
                L10n.RoundtableSetup.clarificationTitle,
                symbol: "questionmark.bubble",
                color: .accentColor
            )
            ForEach(Array(preparation.clarificationQuestions.enumerated()), id: \.offset) {
                _, question in
                Text(question)
                    .font(.system(size: 12.5))
                    .padding(.horizontal, 11)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 9)
                            .fill(Color.accentColor.opacity(0.07))
                    )
            }
        }
        .roundtableSetupCard(accent: .accentColor)
    }

    private var clarificationConversation: some View {
        VStack(alignment: .leading, spacing: 11) {
            sectionHeader(
                L10n.RoundtableSetup.clarificationTitle,
                symbol: "bubble.left.and.bubble.right",
                color: .accentColor
            )
            ForEach(preparation.conversation) { message in
                HStack(alignment: .top, spacing: 9) {
                    Image(
                        systemName: message.speaker == .assistant
                            ? "sparkles"
                            : "person.crop.circle"
                    )
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(message.speaker == .assistant ? Color.accentColor : .secondary)
                    .frame(width: 22, height: 22)
                    .background(
                        Circle().fill(
                            message.speaker == .assistant
                                ? Color.accentColor.opacity(0.12)
                                : Color.secondary.opacity(0.10)
                        )
                    )

                    VStack(alignment: .leading, spacing: 2) {
                        Text(
                            message.speaker == .assistant
                                ? L10n.RoundtableSetup.assistantName
                                : L10n.RoundtableSetup.userName
                        )
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(.secondary)
                        Text(message.content)
                            .font(.system(size: 12.5))
                            .lineSpacing(2)
                            .textSelection(.enabled)
                    }
                }
            }
        }
        .roundtableSetupCard(accent: .accentColor)
    }

    private var footer: some View {
        VStack(spacing: 10) {
            if !providerOptions.isEmpty {
                HStack(spacing: 8) {
                    Text(
                        String(
                            localized: "roundtable.setup.provider.label",
                            defaultValue: "本场使用的模型"
                        )
                    )
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)

                    RoundtableProviderModelPicker(
                        providerOptions: providerOptions,
                        selectedProviderID: $selectedProviderID,
                        selectedModelID: $selectedModelID,
                        isBusy: isBusy
                    )
                    .onChange(of: selectedProviderID) { _ in
                        onSelectProviderModel(selectedProviderID, selectedModelID)
                    }
                    .onChange(of: selectedModelID) { _ in
                        onSelectProviderModel(selectedProviderID, selectedModelID)
                    }

                    Spacer(minLength: 0)
                }
            }

            HStack(alignment: .bottom, spacing: 11) {
                RoundtableComposerTextView(
                    text: $refinementDraft,
                    placeholder: L10n.RoundtableSetup.refinePlaceholder,
                    onSubmit: submitRefinement
                )
                .frame(height: 76)
                .background(
                    RoundedRectangle(cornerRadius: 11)
                        .fill(Color(nsColor: .textBackgroundColor).opacity(0.92))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 11)
                        .stroke(Color.accentColor.opacity(0.22), lineWidth: 1)
                )

                // 两个按钮统一大尺寸 + 等宽成对:主次靠填充色区分(选择专家实心强调、
                // 继续细化描边次级),体量一致不再一强一弱。
                VStack(spacing: 8) {
                    Button(action: submitRefinement) {
                        Label(
                            isBusy
                                ? L10n.RoundtableSetup.refining
                                : L10n.RoundtableSetup.refineAction,
                            systemImage: "sparkles"
                        )
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .disabled(isBusy || trimmedDraft.isEmpty)

                    Button(action: onChooseExperts) {
                        Label(
                            L10n.RoundtableSetup.chooseExpertsAction,
                            systemImage: "person.3.fill"
                        )
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(!canChooseExperts)
                }
                .frame(width: 208)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 13)
        .background(.ultraThinMaterial)
    }

    private var trimmedDraft: String {
        refinementDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func submitRefinement() {
        let input = trimmedDraft
        guard !isBusy, !input.isEmpty else { return }
        refinementDraft = ""
        onRefine(input)
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

    private var loadingLine: some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(Color.secondary.opacity(0.10))
            .frame(height: 12)
            .overlay(alignment: .leading) {
                if isBusy {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.accentColor.opacity(0.13))
                        .frame(width: 92)
                }
            }
    }

    private func sectionHeader(_ title: String, symbol: String, color: Color) -> some View {
        HStack(spacing: 8) {
            setupSectionIcon(symbol, color: color)
            Text(title)
                .font(.system(size: 12.5, weight: .semibold))
            Spacer(minLength: 0)
        }
    }

    private func setupSectionIcon(_ symbol: String, color: Color) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(color)
            .frame(width: 25, height: 25)
            .background(Circle().fill(color.opacity(0.11)))
    }
}

struct RoundtableSetupBackground: View {
    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            LinearGradient(
                colors: [
                    Color.indigo.opacity(0.055),
                    Color.clear,
                    Color.cyan.opacity(0.04),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Circle()
                .fill(Color.purple.opacity(0.055))
                .frame(width: 340, height: 340)
                .blur(radius: 70)
                .offset(x: -310, y: -220)
            Circle()
                .fill(Color.cyan.opacity(0.05))
                .frame(width: 300, height: 300)
                .blur(radius: 75)
                .offset(x: 360, y: 240)
        }
        .ignoresSafeArea()
    }
}

private extension View {
    func roundtableSetupCard(accent: Color) -> some View {
        padding(15)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(Color(nsColor: .controlBackgroundColor).opacity(0.76))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(
                        LinearGradient(
                            colors: [accent.opacity(0.28), Color.secondary.opacity(0.10)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
            )
            .shadow(color: Color.black.opacity(0.045), radius: 12, y: 5)
    }
}
