//
//  AgentDispatchTaskToolPolicy.swift
//  WillDeep
//
//  Keeps task-conversation chrome focused on intervention and evidence.
//

import Foundation

nonisolated enum AgentDispatchTaskToolPolicy {
    static func primaryKinds(
        hasPlan: Bool,
        activeExperts: Set<AgentExpert>
    ) -> [AgentSidePanelKind] {
        var kinds: [AgentSidePanelKind] = []
        if hasPlan {
            kinds.append(.plan)
        }
        kinds.append(contentsOf: [.files, .terminal, .diff])
        return kinds.filter { $0.isAvailable(activeExperts: activeExperts) }
    }

    static func overflowKinds(
        activeExperts: Set<AgentExpert>
    ) -> [AgentSidePanelKind] {
        [.preview, .devServer, .widget].filter {
            $0.isAvailable(activeExperts: activeExperts)
        }
    }
}
