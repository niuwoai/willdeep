import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct AgentFeedbackReviewView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject var runtime: AgentRuntime

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let review = runtime.feedbackReview, !runtime.isResponding, review.disposition == nil {
                HStack {
                    Text(L10n.RSI.feedbackTitle).font(.caption)
                    Button(L10n.RSI.accepted) { runtime.recordHumanDisposition(.accepted) }
                    Button(L10n.RSI.needsChanges) { runtime.recordHumanDisposition(.needsChanges) }
                    Button(L10n.RSI.skip) { runtime.recordHumanDisposition(.unknown) }
                    Spacer(minLength: 0)
                    Button(L10n.RSI.assess) { appState.assessFeedbackReview(for: runtime) }
                        .disabled(review.isAssessing || review.assessment != nil)
                }
                .buttonStyle(.borderless)
                Text(L10n.RSI.evidence(successes: review.toolSuccesses, failures: review.toolFailures))
                    .font(.caption).foregroundStyle(.secondary)
                if review.isAssessing { Text(L10n.RSI.assessing).font(.caption).foregroundStyle(.secondary) }
                if let assessment = review.assessment {
                    Text(assessment.judgment == "needs_review" ? L10n.RSI.modelNeedsReview : L10n.RSI.modelUnknown)
                        .font(.caption).foregroundStyle(.secondary)
                }
                if review.assessmentFailed { Text(L10n.RSI.assessmentFailed).font(.caption).foregroundStyle(.secondary) }
            }
            if let parameters = runtime.runtimeParameters {
                DisclosureGroup(L10n.RSI.runtimeConfiguration) {
                    Text(parameters.canonical).font(.caption.monospaced()).textSelection(.enabled)
                    HStack {
                        Button(L10n.RSI.copyConfiguration) {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(parameters.canonical, forType: .string)
                        }
                        Button(L10n.RSI.exportConfiguration) { export(parameters) }
                    }
                    .buttonStyle(.borderless)
                }
                .font(.caption)
            }
        }
        .accessibilityIdentifier("agent.rsi.feedback-review")
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
