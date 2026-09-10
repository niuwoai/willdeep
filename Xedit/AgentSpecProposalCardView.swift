//
//  AgentSpecProposalCardView.swift
//  WillDeep
//
//  Transcript-inline card for the design gate.
//
//  Shows what the host noticed — in the user's own words, quoted back — the
//  document that came out of it, and three ways forward. The reasons are on
//  the card rather than behind a disclosure because a gate that says only
//  "this looked complex" is a gate people switch off.
//
//  The third button matters most. "Skip it, just build" is the escape hatch,
//  and it is also the measurement: every press is a false positive recorded to
//  spec-gate.jsonl, which is what decides whether this feature earns its
//  default. A gate without a cheap way out gets uninstalled instead of
//  corrected.
//

import SwiftUI

enum AgentSpecProposalCardLayout {
    static let maximumWidth: CGFloat = 520
    static let cornerRadius: CGFloat = 12
    static let iconTileSize: CGFloat = 36
    static let iconTileCornerRadius: CGFloat = 10
    static let buttonCornerRadius: CGFloat = 8
    /// Evidence lines shown before collapsing into a count. Three is enough to
    /// show the pattern; more turns a card into a wall.
    static let visibleSignalLimit = 3
}

struct AgentSpecProposalCardView: View {
    let proposal: AgentSpecProposal
    @EnvironmentObject private var appState: AppState

    private var isPending: Bool { proposal.isPending }

    var body: some View {
        let palette = appState.editorSettings.interfaceSkin.palette

        return content
            .frame(maxWidth: AgentSpecProposalCardLayout.maximumWidth, alignment: .leading)
            .background(
                RoundedRectangle(
                    cornerRadius: AgentSpecProposalCardLayout.cornerRadius,
                    style: .continuous
                )
                .fill(palette.panelFill.opacity(0.72))
            )
            .overlay(
                RoundedRectangle(
                    cornerRadius: AgentSpecProposalCardLayout.cornerRadius,
                    style: .continuous
                )
                .stroke(palette.hairline.opacity(0.9), lineWidth: 1)
            )
            .opacity(isPending ? 1 : 0.7)
    }

    private var content: some View {
        let palette = appState.editorSettings.interfaceSkin.palette

        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 11) {
                ZStack {
                    RoundedRectangle(
                        cornerRadius: AgentSpecProposalCardLayout.iconTileCornerRadius,
                        style: .continuous
                    )
                    .fill(palette.hoverFill.opacity(isPending ? 0.85 : 0.48))

                    Image(systemName: isPending ? "doc.text.magnifyingglass" : "checkmark.circle")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(palette.secondaryText)
                }
                .frame(
                    width: AgentSpecProposalCardLayout.iconTileSize,
                    height: AgentSpecProposalCardLayout.iconTileSize
                )

                VStack(alignment: .leading, spacing: 3) {
                    Text(L10n.SpecGateCard.title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(palette.primaryText)
                        .lineLimit(1)
                    Text(proposal.documentPath)
                        .font(.system(size: 12).monospaced())
                        .foregroundStyle(palette.secondaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .layoutPriority(1)

                Spacer(minLength: 8)
            }

            if !proposal.signals.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(
                        Array(proposal.signals.prefix(AgentSpecProposalCardLayout.visibleSignalLimit).enumerated()),
                        id: \.offset
                    ) { _, signal in
                        Text("· \(signal.evidence)")
                            .font(.system(size: 12))
                            .foregroundStyle(palette.secondaryText)
                            .lineLimit(2)
                    }
                    if proposal.signals.count > AgentSpecProposalCardLayout.visibleSignalLimit {
                        Text(
                            L10n.SpecGateCard.moreSignals(
                                proposal.signals.count - AgentSpecProposalCardLayout.visibleSignalLimit
                            )
                        )
                        .font(.system(size: 11))
                        .foregroundStyle(palette.secondaryText.opacity(0.8))
                    }
                }
            }

            if isPending {
                HStack(spacing: 8) {
                    actionButton(L10n.SpecGateCard.accept, prominent: true) {
                        appState.acceptSpecProposal(proposal.id)
                    }
                    actionButton(L10n.SpecGateCard.openDocument, prominent: false) {
                        appState.openSpecProposalDocument(proposal.id)
                    }
                    actionButton(L10n.SpecGateCard.dismiss, prominent: false) {
                        appState.dismissSpecProposal(proposal.id)
                    }
                    Spacer(minLength: 0)
                }
            } else {
                Text(settledLabel)
                    .font(.system(size: 12))
                    .foregroundStyle(palette.secondaryText)
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
    }

    private var settledLabel: String {
        switch proposal.choice {
        case .accepted: return L10n.SpecGateCard.accepted
        case .dismissed: return L10n.SpecGateCard.dismissed
        case .deferred, .none: return L10n.SpecGateCard.title
        }
    }

    private func actionButton(
        _ label: String,
        prominent: Bool,
        action: @escaping () -> Void
    ) -> some View {
        let palette = appState.editorSettings.interfaceSkin.palette

        return Button(action: action) {
            Text(label)
                .font(.system(size: 12, weight: prominent ? .medium : .regular))
                .foregroundStyle(prominent ? palette.primaryText : palette.secondaryText)
                .padding(.horizontal, 11)
                .frame(height: 28)
                .background(
                    RoundedRectangle(
                        cornerRadius: AgentSpecProposalCardLayout.buttonCornerRadius,
                        style: .continuous
                    )
                    .fill(palette.controlFill.opacity(prominent ? 0.75 : 0.4))
                )
                .overlay(
                    RoundedRectangle(
                        cornerRadius: AgentSpecProposalCardLayout.buttonCornerRadius,
                        style: .continuous
                    )
                    .stroke(palette.hairline.opacity(0.9), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }
}
