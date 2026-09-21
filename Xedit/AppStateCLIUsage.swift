//
//  AppStateCLIUsage.swift
//  WillDeep
//
//  Feeds the willdeep-rs usage ledger into the stats dashboard
//  (docs/USAGE_LEDGER_DESIGN.md §6.3).
//

import Foundation

extension AppState {
    static func loadAgentUsageSourceFilter() -> AgentUsageSourceFilter {
        UserDefaults.standard.string(forKey: agentUsageSourceFilterDefaultsKey)
            .flatMap(AgentUsageSourceFilter.init(rawValue:)) ?? .all
    }

    /// Whether any CLI usage exists; the source switch hides without it.
    var hasAgentCLIUsage: Bool {
        !agentCLIUsageRecords.isEmpty
    }

    /// Desktop snapshots under the current 全部 / 桌面 / CLI switch. Every
    /// dashboard page reads through these two, so the calendar and day
    /// detail can't drift from the heatmap again.
    var agentUsageFilteredSnapshots: [AgentUsageSessionSnapshot] {
        agentUsageSourceFilter.includes(.desktop) ? agentUsageSnapshots : []
    }

    var agentUsageFilteredCLIRecords: [AgentCLIUsageRecord] {
        agentUsageSourceFilter.includes(.cli) ? agentCLIUsageRecords : []
    }

    /// Parses whatever the CLI appended since the last pass, off the main
    /// thread. The reader is a value type carrying its per-file cursors, so it
    /// travels to the background task and back instead of being shared.
    func refreshAgentCLIUsageRecords() async {
        guard var reader = agentCLIUsageLedgerReader, !isRefreshingAgentCLIUsage else { return }
        isRefreshingAgentCLIUsage = true
        defer { isRefreshingAgentCLIUsage = false }
        let (updatedReader, newRecords) = await Task.detached(priority: .userInitiated) {
            let records = reader.readNewRecords()
            return (reader, records)
        }.value
        agentCLIUsageLedgerReader = updatedReader
        guard !newRecords.isEmpty else { return }
        agentCLIUsageRecords.append(contentsOf: newRecords)
    }

    /// Called when the stats dashboard appears. Watching stops when it goes
    /// away — nothing listens to the ledger while nobody is looking (§16 Q7).
    func startWatchingAgentCLIUsage() {
        guard let directory = agentCLIUsageLedgerReader?.directory else { return }
        let watcher = agentCLIUsageLedgerWatcher ?? AgentCLIUsageLedgerWatcher(directory: directory) { [weak self] in
            guard let self else { return }
            Task { await self.refreshAgentCLIUsageRecords() }
        }
        agentCLIUsageLedgerWatcher = watcher
        watcher.start()
        Task { await refreshAgentCLIUsageRecords() }
    }

    func stopWatchingAgentCLIUsage() {
        agentCLIUsageLedgerWatcher?.stop()
    }
}
