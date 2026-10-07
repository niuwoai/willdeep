import Foundation

nonisolated enum AgentRoundtableChatTimeline {
    static let completedPreviewLimit = 220
    static let livePreviewLimit = 1_600
    static let visibleEntryLimit = 3

    struct Entry: Identifiable {
        let id: String
        let seat: RoundtableSeat?
        let name: String
        let text: String
        let timestamp: String
        let state: AgentPluginRoundtableChatSpeech.State
        let isLive: Bool
        let isTruncated: Bool
        let isError: Bool
    }

    static func entries(from report: AgentRoundtableReport) -> [Entry] {
        let active = report.activeSeat
        let hasLiveDraft = active != nil && !isTerminal(report.phase)
        let messages = report.messages.filter {
            $0.speaker == .expert && !(hasLiveDraft && $0.seatID == active?.id && $0.round == report.currentRound)
        }.suffix(hasLiveDraft ? visibleEntryLimit - 1 : visibleEntryLimit)
        var entries = messages.map { message in
            Entry(
                id: message.id.uuidString,
                seat: report.seat(for: message),
                name: report.seat(for: message)?.displayName ?? message.speakerName,
                text: String(message.content.prefix(completedPreviewLimit)),
                timestamp: elapsed(from: report.createdAt, to: message.createdAt),
                state: .finished,
                isLive: false,
                isTruncated: message.content.count > completedPreviewLimit || message.content.components(separatedBy: "\n").count > 3,
                isError: message.isError == true
            )
        }
        if hasLiveDraft, let active, let speech = AgentPluginRoundtableChatSpeech.make(from: report) {
            entries.append(Entry(
                id: "live-\(report.currentRound)-\(active.id)",
                seat: active,
                name: speech.name,
                text: speech.text,
                timestamp: elapsed(from: report.createdAt, to: report.updatedAt),
                state: speech.state,
                isLive: true,
                isTruncated: (report.activeExpertDraft?.count ?? 0) > livePreviewLimit,
                isError: false
            ))
        }
        return entries
    }

    static func elapsed(from start: Date, to end: Date) -> String {
        let seconds = max(0, Int(end.timeIntervalSince(start)))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    static func isTerminal(_ phase: AgentRoundtableReport.Phase) -> Bool {
        phase == .completed || phase == .failed || phase == .cancelled
    }
}
