import AppKit
import SwiftUI

struct AgentFeedbackReviewView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject var runtime: AgentRuntime

    var body: some View {
        AgentFeedbackReviewCard(
            review: runtime.isResponding || runtime.feedbackReview?.disposition != nil ? nil : runtime.feedbackReview,
            onDisposition: { runtime.recordHumanDisposition($0) },
            onAssess: { appState.assessFeedbackReview(for: runtime) }
        )
        .id(runtime.session.id)
    }
}

/// Presentation stays independent of the runtime so every state can be previewed.
struct AgentFeedbackReviewCard: View {
    let review: AgentFeedbackReview?
    let onDisposition: (AgentFeedbackReview.Disposition) -> Void
    let onAssess: () -> Void
    @State private var detailsExpanded: Bool

    init(review: AgentFeedbackReview?, initiallyExpanded: Bool = false,
         onDisposition: @escaping (AgentFeedbackReview.Disposition) -> Void,
         onAssess: @escaping () -> Void) {
        self.review = review
        self.onDisposition = onDisposition
        self.onAssess = onAssess
        _detailsExpanded = State(initialValue: initiallyExpanded)
    }

    var body: some View {
        cardContent
            .onCompatibleChange(of: review?.id) { _, _ in detailsExpanded = false }
    }

    @ViewBuilder private var cardContent: some View {
        if let review {
            VStack(alignment: .leading, spacing: 0) {
                compactFeedback
                    .padding(.horizontal, FeedbackDesign.compactHorizontalInset)
                    .padding(.vertical, FeedbackDesign.compactVerticalInset)
                if detailsExpanded {
                    Divider().opacity(FeedbackDesign.dividerOpacity)
                    feedbackContent(review)
                        .padding(FeedbackDesign.cardInset)
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

    private var compactFeedback: some View {
        HStack(spacing: FeedbackDesign.actionSpacing) {
            Text(L10n.RSI.feedbackTitle)
                .font(.system(size: FeedbackDesign.textSize, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
            compactDispositionButton(.accepted, symbol: "hand.thumbsup", title: L10n.RSI.accepted)
            compactDispositionButton(.needsChanges, symbol: "hand.thumbsdown", title: L10n.RSI.needsChanges)
            Button { detailsExpanded.toggle() } label: {
                Image(systemName: detailsExpanded ? "chevron.up" : "chevron.down")
                    .frame(width: FeedbackDesign.compactButtonSize, height: FeedbackDesign.compactButtonSize)
            }
            .help(detailsExpanded ? L10n.RSI.collapseFeedback : L10n.RSI.expandFeedback)
            .accessibilityLabel(detailsExpanded ? L10n.RSI.collapseFeedback : L10n.RSI.expandFeedback)
            .accessibilityValue(detailsExpanded ? L10n.PlanCard.expanded : L10n.PlanCard.collapsed)
            .accessibilityIdentifier("agent.rsi.feedback-toggle")
        }
        .buttonStyle(.plain)
        .font(.system(size: FeedbackDesign.textSize, weight: .medium))
        .foregroundStyle(.secondary)
    }

    private func compactDispositionButton(_ disposition: AgentFeedbackReview.Disposition,
                                          symbol: String, title: String) -> some View {
        Button { onDisposition(disposition) } label: {
            Image(systemName: symbol)
                .frame(width: FeedbackDesign.compactButtonSize, height: FeedbackDesign.compactButtonSize)
                .contentShape(Rectangle())
        }
        .help(title)
        .accessibilityLabel(title)
        .accessibilityIdentifier("agent.rsi.\(disposition.rawValue)-compact")
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
        AgentFeedbackFlowLayout(spacing: FeedbackDesign.labelSpacing) {
            evidenceBadge(L10n.RSI.successes(review.toolSuccesses), symbol: "checkmark.circle")
            evidenceBadge(L10n.RSI.failures(review.toolFailures), symbol: "xmark.circle")
            evidenceBadge(L10n.RSI.unverified, symbol: "info.circle")
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
    static let compactHorizontalInset: CGFloat = 12
    static let compactVerticalInset: CGFloat = 4
    static let compactButtonSize: CGFloat = 26
    static let cardRadius: CGFloat = 8
    static let railWidth: CGFloat = 3
    static let railOpacity = 0.35
    static let badgeHorizontalInset: CGFloat = 7
    static let badgeVerticalInset: CGFloat = 5
    static let sectionSpacing: CGFloat = 12
    static let headerSpacing: CGFloat = 16
    static let actionSpacing: CGFloat = 8
    static let labelSpacing: CGFloat = 5
    static let textSize: CGFloat = 11
    static let skipInset: CGFloat = 6
    static let buttonVerticalInset: CGFloat = 7
    static let buttonHorizontalInset: CGFloat = 10
    static let codeRadius: CGFloat = 6
    static let buttonRadius: CGFloat = 7
    static let borderWidth: CGFloat = 1
    static let surfaceOpacity = 0.65
    static let cardBorderOpacity = 0.07
    static let buttonTextOpacity = 0.75
    static let buttonBackgroundOpacity = 0.04
    static let buttonBorderOpacity = 0.06
    static let dividerOpacity = 0.5
    static let pressedOpacity = 0.65
    static let disabledOpacity = 0.45
}
