//
//  AgentTurnProgressPresentation.swift
//  WillDeep
//
//  Turns the model-facing ```progress protocol into a compact, native
//  per-turn progress summary. The protocol remains in the stored message so
//  AgentPlanParser can update the authoritative plan, but it never appears as
//  a raw code block in either the streaming SwiftUI path or TextKit history.
//

import AppKit
import SwiftUI

nonisolated enum AgentTurnProgressLayoutMetrics {
    static let contentSpacing: CGFloat = 14
}

nonisolated struct AgentTurnProgressPresentation: Equatable {
    struct Item: Identifiable, Equatable {
        let index: Int
        let status: AgentPlan.StepStatus
        let title: String

        var id: Int { index }
    }

    let items: [Item]

    var completedCount: Int {
        items.count { $0.status == .done || $0.status == .skipped }
    }

    var inProgressCount: Int {
        items.count { $0.status == .inProgress }
    }

    var failedCount: Int {
        items.count { $0.status == .failed }
    }

    var pendingCount: Int {
        items.count { $0.status == .pending }
    }

    var detailItems: [Item] {
        items.filter { $0.status == .inProgress || $0.status == .failed }
    }

    static func extract(
        from content: String,
        plan: AgentPlan?
    ) -> (visibleContent: String, presentation: AgentTurnProgressPresentation?) {
        let lines = content.components(separatedBy: .newlines)
        var visibleLines: [String] = []
        var updates: [Int: AgentPlan.StepStatus] = [:]
        var progressBody: [String] = []
        var activeProtocolBlock: String?
        var foundProgressBlock = false
        var foundGoalCheckBlock = false

        func applyProgressBody() {
            for line in progressBody {
                guard let (index, status) = parseUpdate(line) else { continue }
                updates[index] = status
            }
            progressBody.removeAll(keepingCapacity: true)
        }

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if let protocolBlock = activeProtocolBlock {
                if trimmed.hasPrefix("```") {
                    if protocolBlock == "progress" {
                        applyProgressBody()
                    }
                    activeProtocolBlock = nil
                } else if protocolBlock == "progress" {
                    progressBody.append(line)
                }
                continue
            }

            if isProgressFenceStart(trimmed) {
                foundProgressBlock = true
                activeProtocolBlock = "progress"
                continue
            }
            if isGoalCheckFenceStart(trimmed) {
                foundGoalCheckBlock = true
                activeProtocolBlock = "goal-check"
                continue
            }
            visibleLines.append(line)
        }

        if activeProtocolBlock == "progress" {
            applyProgressBody()
        }

        guard foundProgressBlock || foundGoalCheckBlock else { return (content, nil) }
        let visibleContent = normalizedVisibleContent(visibleLines.joined(separator: "\n"))
        guard foundProgressBlock, !updates.isEmpty else { return (visibleContent, nil) }

        let items = updates.keys.sorted().compactMap { index -> Item? in
            guard let status = updates[index] else { return nil }
            let title: String
            if let plan, plan.steps.indices.contains(index - 1) {
                title = plan.steps[index - 1].text
            } else {
                // Parsing is intentionally nonisolated so the same protocol
                // adapter can be reused by both SwiftUI and TextKit renderers.
                // Resolve the localized fallback later on the UI actor.
                title = ""
            }
            return Item(index: index, status: status, title: title)
        }
        return (visibleContent, AgentTurnProgressPresentation(items: items))
    }

    private static func isProgressFenceStart(_ trimmed: String) -> Bool {
        guard trimmed.hasPrefix("```") else { return false }
        let info = trimmed.dropFirst(3)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return info == "progress"
    }

    private static func isGoalCheckFenceStart(_ trimmed: String) -> Bool {
        guard trimmed.hasPrefix("```") else { return false }
        let info = trimmed.dropFirst(3)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return info == "goal-check"
    }

    private static func parseUpdate(_ rawLine: String) -> (Int, AgentPlan.StepStatus)? {
        let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let digitStart = trimmed.firstIndex(where: { $0.isNumber }) else { return nil }
        let digitEnd = trimmed[digitStart...].firstIndex(where: { !$0.isNumber }) ?? trimmed.endIndex
        guard let index = Int(trimmed[digitStart..<digitEnd]), index > 0 else { return nil }

        let remainder = trimmed[digitEnd...].drop {
            $0 == ":" || $0 == "." || $0 == ")" || $0 == "-" || $0.isWhitespace
        }
        guard let token = remainder.split(whereSeparator: { $0.isWhitespace }).first else { return nil }
        switch token.lowercased() {
        case "pending", "todo", "waiting": return (index, .pending)
        case "in_progress", "in-progress", "doing", "running": return (index, .inProgress)
        case "done", "completed", "complete": return (index, .done)
        case "skipped", "skip": return (index, .skipped)
        case "failed", "failure", "error": return (index, .failed)
        default: return nil
        }
    }

    private static func normalizedVisibleContent(_ content: String) -> String {
        var normalized = content.trimmingCharacters(in: .whitespacesAndNewlines)
        while normalized.contains("\n\n\n") {
            normalized = normalized.replacingOccurrences(of: "\n\n\n", with: "\n\n")
        }
        return normalized
    }
}

struct AgentTurnProgressView: View {
    let presentation: AgentTurnProgressPresentation
    let baseFontSize: CGFloat
    let showsPlanAction: Bool
    let onShowPlan: () -> Void

    @State private var isExpanded = false

    init(
        presentation: AgentTurnProgressPresentation,
        baseFontSize: CGFloat = AgentSettingsStore.chatBaseFontSizeDefault,
        showsPlanAction: Bool = false,
        initiallyExpanded: Bool = false,
        onShowPlan: @escaping () -> Void = {}
    ) {
        self.presentation = presentation
        self.baseFontSize = baseFontSize
        self.showsPlanAction = showsPlanAction
        self.onShowPlan = onShowPlan
        _isExpanded = State(initialValue: initiallyExpanded)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) {
                    isExpanded.toggle()
                }
            } label: {
                header
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.AgentTurnProgress.title)
            .accessibilityValue(isExpanded
                ? L10n.AgentTurnProgress.expanded
                : L10n.AgentTurnProgress.collapsed)

            if isExpanded {
                if !presentation.detailItems.isEmpty {
                    Divider().opacity(0.35)
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(presentation.detailItems.enumerated()), id: \.element.id) { offset, item in
                            detailRow(item)
                            if offset < presentation.detailItems.count - 1 {
                                Divider()
                                    .opacity(0.25)
                                    .padding(.leading, 34)
                            }
                        }
                    }
                }

                if showsPlanAction {
                    Divider().opacity(0.35)
                    Button(action: onShowPlan) {
                        HStack(spacing: 6) {
                            Text(L10n.AgentTurnProgress.viewFullPlan)
                                .font(supportingFont(visualMinimum: 12, weight: .medium))
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 9, weight: .semibold))
                        }
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.035))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.primary.opacity(0.07), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(L10n.AgentTurnProgress.title)
                .font(supportingFont(visualMinimum: 12, weight: .semibold))
                .foregroundStyle(.secondary)

            statusMetric(
                icon: "checkmark.circle",
                color: .green,
                text: L10n.AgentTurnProgress.completed(presentation.completedCount)
            )
            statusMetric(
                icon: "minus.circle",
                color: .blue,
                text: L10n.AgentTurnProgress.inProgress(presentation.inProgressCount)
            )
            statusMetric(
                icon: "xmark.circle",
                color: .red,
                text: L10n.AgentTurnProgress.failed(presentation.failedCount)
            )
            if presentation.completedCount == 0,
               presentation.inProgressCount == 0,
               presentation.failedCount == 0 {
                statusMetric(
                    icon: "circle",
                    color: .secondary,
                    text: L10n.AgentTurnProgress.pending(presentation.pendingCount)
                )
            }

            Spacer(minLength: 4)
            Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .contentShape(Rectangle())
    }

    private func statusMetric(icon: String, color: Color, text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(color)
            Text(text)
                .font(supportingFont(visualMinimum: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }

    private func detailRow(_ item: AgentTurnProgressPresentation.Item) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: detailIcon(for: item.status))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(detailColor(for: item.status))
                .frame(width: 16, height: 18)
            Text("\(item.index)")
                .font(supportingFont(visualMinimum: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(minWidth: 16, alignment: .trailing)
            Text(displayTitle(for: item))
                .font(supportingFont(visualMinimum: 12, weight: .medium))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Text(statusLabel(for: item.status))
                .font(supportingFont(visualMinimum: 11, weight: .medium))
                .foregroundStyle(detailColor(for: item.status))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private func detailIcon(for status: AgentPlan.StepStatus) -> String {
        switch status {
        case .inProgress: return "arrow.right.circle"
        case .failed: return "xmark.circle"
        case .done: return "checkmark.circle"
        case .skipped: return "forward.circle"
        case .pending: return "circle"
        }
    }

    private func detailColor(for status: AgentPlan.StepStatus) -> Color {
        switch status {
        case .inProgress: return .blue
        case .failed: return .red
        case .done: return .green
        case .skipped, .pending: return .secondary
        }
    }

    private func statusLabel(for status: AgentPlan.StepStatus) -> String {
        switch status {
        case .inProgress: return L10n.AgentTurnProgress.statusInProgress
        case .failed: return L10n.AgentTurnProgress.statusFailed
        case .done: return L10n.AgentTurnProgress.statusDone
        case .skipped: return L10n.AgentTurnProgress.statusSkipped
        case .pending: return L10n.AgentTurnProgress.statusPending
        }
    }

    private func displayTitle(for item: AgentTurnProgressPresentation.Item) -> String {
        item.title.isEmpty
            ? L10n.AgentTurnProgress.stepNumber(item.index)
            : item.title
    }

    private func supportingFont(
        visualMinimum: CGFloat = 0,
        weight: Font.Weight = .regular,
        design: Font.Design = .default
    ) -> Font {
        AgentDesign.chatSupportingFont(
            baseFontSize: baseFontSize,
            visualMinimum: visualMinimum,
            weight: weight,
            design: design
        )
    }
}

enum AgentTurnProgressHistoryRenderer {
    static let toggleLinkValue = "agent-chat-history-toggle-progress"
    static let showPlanLinkValue = "agent-chat-history-show-plan"

    static func attributedString(
        _ presentation: AgentTurnProgressPresentation,
        id: String,
        isExpanded: Bool,
        showsPlanAction: Bool,
        baseFontSize: CGFloat = AgentSettingsStore.chatBaseFontSizeDefault
    ) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let textFontSize = AgentDesign.chatSupportingFontSize(baseFontSize: baseFontSize)
        appendHeader(
            presentation,
            id: id,
            isExpanded: isExpanded,
            textFontSize: textFontSize,
            to: result
        )

        if isExpanded {
            for item in presentation.detailItems {
                result.append(NSAttributedString(string: "\n"))
                appendDetail(item, textFontSize: textFontSize, to: result)
            }
            if showsPlanAction {
                result.append(NSAttributedString(string: "\n"))
                appendShowPlan(textFontSize: textFontSize, to: result)
            }
        }

        if result.length > 0 {
            result.addAttribute(
                .agentChatHistoryProgressBlockID,
                value: id,
                range: NSRange(location: 0, length: result.length)
            )
        }
        return result
    }

    private static func appendHeader(
        _ presentation: AgentTurnProgressPresentation,
        id: String,
        isExpanded: Bool,
        textFontSize: CGFloat,
        to result: NSMutableAttributedString
    ) {
        let font = NSFont.systemFont(ofSize: textFontSize, weight: .medium)
        let secondary = NSColor.secondaryLabelColor
        let start = result.length
        result.append(symbolAttachmentString(
            named: "arrow.right",
            fallback: "→",
            pointSize: 11,
            color: secondary
        ))
        result.append(label("  \(L10n.AgentTurnProgress.title)   ", font: font, color: secondary))
        appendMetric(
            icon: "checkmark.circle",
            text: L10n.AgentTurnProgress.completed(presentation.completedCount),
            color: .systemGreen,
            font: font,
            to: result
        )
        appendMetric(
            icon: "minus.circle",
            text: L10n.AgentTurnProgress.inProgress(presentation.inProgressCount),
                color: .systemBlue,
            font: font,
            to: result
        )
        appendMetric(
            icon: "xmark.circle",
            text: L10n.AgentTurnProgress.failed(presentation.failedCount),
            color: .systemRed,
            font: font,
            to: result
        )
        if presentation.completedCount == 0,
           presentation.inProgressCount == 0,
           presentation.failedCount == 0 {
            appendMetric(
                icon: "circle",
                text: L10n.AgentTurnProgress.pending(presentation.pendingCount),
                color: secondary,
                font: font,
                to: result
            )
        }
        result.append(symbolAttachmentString(
            named: isExpanded ? "chevron.up" : "chevron.down",
            fallback: isExpanded ? "⌃" : "⌄",
            pointSize: 9,
            color: NSColor.tertiaryLabelColor
        ))
        let range = NSRange(location: start, length: result.length - start)
        result.addAttributes([
            .link: toggleLinkValue,
            .agentChatHistoryProgressToggleID: id,
            .underlineStyle: 0,
        ], range: range)
    }

    private static func appendMetric(
        icon: String,
        text: String,
        color: NSColor,
        font: NSFont,
        to result: NSMutableAttributedString
    ) {
        result.append(symbolAttachmentString(
            named: icon,
            fallback: "•",
            pointSize: 10,
            color: color
        ))
        result.append(label(" \(text)   ", font: font, color: NSColor.secondaryLabelColor))
    }

    private static func appendDetail(
        _ item: AgentTurnProgressPresentation.Item,
        textFontSize: CGFloat,
        to result: NSMutableAttributedString
    ) {
        let color: NSColor = item.status == .failed ? .systemRed : .systemBlue
        let icon = item.status == .failed ? "xmark.circle" : "arrow.right.circle"
        result.append(symbolAttachmentString(
            named: icon,
            fallback: item.status == .failed ? "×" : "→",
            pointSize: 11,
            color: color
        ))
        let title = item.title.isEmpty
            ? L10n.AgentTurnProgress.stepNumber(item.index)
            : item.title
        result.append(label(
            "  \(item.index) · \(title)  ",
            font: NSFont.systemFont(ofSize: textFontSize, weight: .medium),
            color: NSColor.labelColor
        ))
        let status = item.status == .failed
            ? L10n.AgentTurnProgress.statusFailed
            : L10n.AgentTurnProgress.statusInProgress
        result.append(label(
            status,
            font: NSFont.systemFont(ofSize: textFontSize, weight: .medium),
            color: color
        ))
    }

    private static func appendShowPlan(
        textFontSize: CGFloat,
        to result: NSMutableAttributedString
    ) {
        let start = result.length
        result.append(label(
            L10n.AgentTurnProgress.viewFullPlan,
            font: NSFont.systemFont(ofSize: textFontSize, weight: .medium),
            color: NSColor.secondaryLabelColor
        ))
        result.append(label(
            "  ",
            font: NSFont.systemFont(ofSize: textFontSize),
            color: .secondaryLabelColor
        ))
        result.append(symbolAttachmentString(
            named: "chevron.right",
            fallback: ">",
            pointSize: 9,
            color: NSColor.secondaryLabelColor
        ))
        result.addAttributes([
            .link: showPlanLinkValue,
            .agentChatHistoryProgressShowPlan: NSNumber(value: true),
            .underlineStyle: 0,
        ], range: NSRange(location: start, length: result.length - start))
    }

    private static func label(_ text: String, font: NSFont, color: NSColor) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: color,
        ])
    }
}
