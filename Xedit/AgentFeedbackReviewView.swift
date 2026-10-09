import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct AgentFeedbackReviewView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject var runtime: AgentRuntime

    var body: some View {
        AgentFeedbackReviewCard(
            review: runtime.isResponding || runtime.feedbackReview?.disposition != nil ? nil : runtime.feedbackReview,
            parameters: runtime.runtimeParameters,
            onDisposition: { runtime.recordHumanDisposition($0) },
            onAssess: { appState.assessFeedbackReview(for: runtime) },
            onExport: { export($0) }
        )
        .id(runtime.session.id)
    }

    private func export(_ parameters: AgentRuntimeParameters) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = AgentRuntimeParameters.fileName
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try Data(parameters.canonical.utf8).write(to: url, options: .atomic) }
        catch { runtime.errorMessage = L10n.RSI.exportFailed }
    }
}

/// Presentation stays independent of the runtime so every state can be previewed.
struct AgentFeedbackReviewCard: View {
    let review: AgentFeedbackReview?
    let parameters: AgentRuntimeParameters?
    let onDisposition: (AgentFeedbackReview.Disposition) -> Void
    let onAssess: () -> Void
    let onExport: (AgentRuntimeParameters) -> Void
    @State private var configurationExpanded = false

    var body: some View {
        if review != nil || parameters != nil {
            VStack(alignment: .leading, spacing: 0) {
                if let review {
                    feedbackContent(review)
                        .padding(FeedbackDesign.cardInset)
                }
                if let parameters {
                    if review != nil {
                        Divider().opacity(FeedbackDesign.dividerOpacity)
                    }
                    configuration(parameters)
                        .padding(.horizontal, FeedbackDesign.cardInset)
                        .padding(.vertical, FeedbackDesign.footerInset)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor).opacity(FeedbackDesign.surfaceOpacity))
            .clipShape(RoundedRectangle(cornerRadius: FeedbackDesign.cardRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: FeedbackDesign.cardRadius, style: .continuous)
                    .strokeBorder(Color.primary.opacity(FeedbackDesign.cardBorderOpacity), lineWidth: FeedbackDesign.borderWidth)
            }
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(Color.primary.opacity(FeedbackDesign.railOpacity))
                    .frame(width: FeedbackDesign.railWidth)
                    .allowsHitTesting(false)
            }
            .clipShape(RoundedRectangle(cornerRadius: FeedbackDesign.cardRadius, style: .continuous))
            .accessibilityIdentifier("agent.rsi.feedback-review")
        }
    }

    private func feedbackContent(_ review: AgentFeedbackReview) -> some View {
        VStack(alignment: .leading, spacing: FeedbackDesign.sectionSpacing) {
            AgentFeedbackFlowLayout(spacing: FeedbackDesign.headerSpacing, trailingLastItem: true) {
                feedbackHeading(review)
                feedbackActions(review)
            }
            assessmentStatus(review)
        }
    }

    private func feedbackActions(_ review: AgentFeedbackReview) -> some View {
        AgentFeedbackFlowLayout(spacing: FeedbackDesign.actionSpacing) {
            acceptButton
            needsChangesButton
            skipButton
            assessmentButton(review)
        }
    }

    private func feedbackHeading(_ review: AgentFeedbackReview) -> some View {
        VStack(alignment: .leading, spacing: FeedbackDesign.labelSpacing) {
            Text(L10n.RSI.feedbackTitle)
                .font(.system(size: FeedbackDesign.titleSize, weight: .semibold))
                .foregroundStyle(.primary)
            AgentFeedbackFlowLayout(spacing: FeedbackDesign.labelSpacing) {
                evidenceBadge(L10n.RSI.successes(review.toolSuccesses), symbol: "checkmark.circle")
                evidenceBadge(L10n.RSI.failures(review.toolFailures), symbol: "xmark.circle")
                evidenceBadge(L10n.RSI.unverified, symbol: "info.circle")
            }
        }
    }

    private func evidenceBadge(_ title: String, symbol: String) -> some View {
        Label(title, systemImage: symbol)
            .font(.system(size: FeedbackDesign.textSize))
            .foregroundStyle(.secondary)
            .padding(.horizontal, FeedbackDesign.badgeHorizontalInset)
            .padding(.vertical, FeedbackDesign.badgeVerticalInset)
            .background(Color.primary.opacity(FeedbackDesign.buttonBackgroundOpacity),
                        in: RoundedRectangle(cornerRadius: FeedbackDesign.codeRadius))
            .fixedSize()
    }

    private var acceptButton: some View {
        Button { onDisposition(.accepted) } label: {
            Label(L10n.RSI.accepted, systemImage: "checkmark")
        }
        .buttonStyle(AgentFeedbackButtonStyle(emphasized: true))
        .accessibilityIdentifier("agent.rsi.accepted")
    }

    private var needsChangesButton: some View {
        Button { onDisposition(.needsChanges) } label: {
            Label(L10n.RSI.needsChanges, systemImage: "pencil")
        }
        .buttonStyle(AgentFeedbackButtonStyle())
        .accessibilityIdentifier("agent.rsi.needs-changes")
    }

    private var skipButton: some View {
        Button(L10n.RSI.skip) { onDisposition(.unknown) }
            .buttonStyle(.plain)
            .font(.system(size: FeedbackDesign.textSize))
            .foregroundStyle(.secondary)
            .padding(.horizontal, FeedbackDesign.skipInset)
            .padding(.vertical, FeedbackDesign.buttonVerticalInset)
            .accessibilityIdentifier("agent.rsi.skip")
    }

    private func assessmentButton(_ review: AgentFeedbackReview) -> some View {
        Button(action: onAssess) {
            HStack(spacing: FeedbackDesign.labelSpacing) {
                if review.isAssessing {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: "sparkles")
                }
                Text(review.isAssessing ? L10n.RSI.assessing : L10n.RSI.assess)
            }
            .fixedSize()
        }
        .buttonStyle(AgentFeedbackButtonStyle())
        .disabled(review.isAssessing || review.assessment != nil)
        .accessibilityIdentifier("agent.rsi.assess")
    }

    @ViewBuilder
    private func assessmentStatus(_ review: AgentFeedbackReview) -> some View {
        if let assessment = review.assessment {
            Label(assessment.judgment == "needs_review" ? L10n.RSI.modelNeedsReview : L10n.RSI.modelUnknown,
                  systemImage: "info.circle")
                .font(.system(size: FeedbackDesign.textSize))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else if review.assessmentFailed {
            Label(L10n.RSI.assessmentFailed, systemImage: "exclamationmark.circle")
                .font(.system(size: FeedbackDesign.textSize))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func configuration(_ parameters: AgentRuntimeParameters) -> some View {
        VStack(alignment: .leading, spacing: FeedbackDesign.detailSpacing) {
            Button {
                configurationExpanded.toggle()
            } label: {
                HStack(spacing: FeedbackDesign.disclosureSpacing) {
                    Spacer(minLength: 0)
                    Image(systemName: configurationExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: FeedbackDesign.chevronSize, weight: .semibold))
                        .frame(width: FeedbackDesign.chevronWidth)
                    Label(L10n.RSI.runtimeConfiguration, systemImage: "slider.horizontal.3")
                        .font(.system(size: FeedbackDesign.textSize))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityIdentifier("agent.rsi.configuration-toggle")
            .accessibilityValue(configurationExpanded ? L10n.PlanCard.expanded : L10n.PlanCard.collapsed)

            if configurationExpanded {
                configurationDetails(parameters)
            }
        }
    }

    private func configurationDetails(_ parameters: AgentRuntimeParameters) -> some View {
        VStack(alignment: .leading, spacing: FeedbackDesign.detailSpacing) {
            ScrollView([.horizontal, .vertical]) {
                Text(parameters.canonical)
                    .font(.system(size: FeedbackDesign.codeSize, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(FeedbackDesign.codeInset)
            }
            .frame(height: FeedbackDesign.configurationHeight)
            .background(Color.primary.opacity(FeedbackDesign.codeBackgroundOpacity), in: RoundedRectangle(cornerRadius: FeedbackDesign.codeRadius))
            HStack(spacing: FeedbackDesign.actionSpacing) {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(parameters.canonical, forType: .string)
                } label: {
                    Label(L10n.RSI.copyConfiguration, systemImage: "doc.on.doc")
                }
                Button { onExport(parameters) } label: {
                    Label(L10n.RSI.exportConfiguration, systemImage: "square.and.arrow.up")
                }
            }
            .buttonStyle(AgentFeedbackButtonStyle())
        }
    }
}

private struct AgentFeedbackButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    var emphasized = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: FeedbackDesign.textSize, weight: .medium))
            .padding(.horizontal, FeedbackDesign.buttonHorizontalInset)
            .padding(.vertical, FeedbackDesign.buttonVerticalInset)
            .foregroundStyle(emphasized ? Color.white : Color.primary.opacity(FeedbackDesign.buttonTextOpacity))
            .background {
                RoundedRectangle(cornerRadius: FeedbackDesign.buttonRadius, style: .continuous)
                    .fill(emphasized ? Color.black : Color.primary.opacity(FeedbackDesign.buttonBackgroundOpacity))
            }
            .overlay {
                RoundedRectangle(cornerRadius: FeedbackDesign.buttonRadius, style: .continuous)
                    .strokeBorder(emphasized ? Color.white.opacity(FeedbackDesign.buttonBorderOpacity) : Color.primary.opacity(FeedbackDesign.buttonBorderOpacity), lineWidth: FeedbackDesign.borderWidth)
            }
            .opacity(isEnabled ? (configuration.isPressed ? FeedbackDesign.pressedOpacity : 1) : FeedbackDesign.disabledOpacity)
    }
}

private enum FeedbackDesign {
    static let cardInset: CGFloat = 14
    static let footerInset: CGFloat = 10
    static let cardRadius: CGFloat = 8
    static let railWidth: CGFloat = 3
    static let railOpacity = 0.35
    static let badgeHorizontalInset: CGFloat = 7
    static let badgeVerticalInset: CGFloat = 5
    static let sectionSpacing: CGFloat = 12
    static let headerSpacing: CGFloat = 16
    static let actionSpacing: CGFloat = 8
    static let labelSpacing: CGFloat = 5
    static let disclosureSpacing: CGFloat = 6
    static let detailSpacing: CGFloat = 10
    static let titleSize: CGFloat = 12
    static let textSize: CGFloat = 11
    static let codeSize: CGFloat = 10
    static let chevronSize: CGFloat = 9
    static let chevronWidth: CGFloat = 10
    static let skipInset: CGFloat = 6
    static let buttonVerticalInset: CGFloat = 7
    static let buttonHorizontalInset: CGFloat = 10
    static let codeInset: CGFloat = 10
    static let configurationHeight: CGFloat = 140
    static let codeRadius: CGFloat = 6
    static let buttonRadius: CGFloat = 7
    static let borderWidth: CGFloat = 1
    static let surfaceOpacity = 0.65
    static let cardBorderOpacity = 0.07
    static let buttonTextOpacity = 0.75
    static let codeBackgroundOpacity = 0.035
    static let buttonBackgroundOpacity = 0.04
    static let buttonBorderOpacity = 0.06
    static let dividerOpacity = 0.5
    static let pressedOpacity = 0.65
    static let disabledOpacity = 0.45
}
