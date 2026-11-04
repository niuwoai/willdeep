//
//  AgentChildSessionSidebar.swift
//  WillDeep
//
//  A presentation-only projection of workspace conversations. Ownership is
//  defined solely by parentSessionID; dispatch task ownership stays separate.
//

import Foundation

/// Rows retain their original sessions, so the existing pin, archive, search
/// reveal and conversation actions continue to target the same session ID.
enum AgentChildSessionSidebar {
    struct Row: Identifiable {
        let session: AgentSession
        let depth: Int
        let rootID: AgentSession.ID

        var id: AgentSession.ID { session.id }
    }

    /// Input is already sorted and filtered for one section (pinned, active or
    /// archived). A parent in another section or an unavailable parent makes
    /// its child a root here instead of dropping the child from the sidebar.
    static func rows(from sessions: [AgentSession], groupRelated: Bool = true) -> [Row] {
        // Pinned and archived sections retain their own chronological order.
        if !groupRelated {
            return sessions.map { Row(session: $0, depth: 0, rootID: $0.id) }
        }
        let ids = Set(sessions.map(\.id))
        var children: [AgentSession.ID: [AgentSession]] = [:]
        for session in sessions {
            if let parentID = session.parentSessionID, parentID != session.id, ids.contains(parentID) {
                children[parentID, default: []].append(session)
            }
        }

        var result: [Row] = []
        var visited: Set<AgentSession.ID> = []

        func append(_ session: AgentSession, depth: Int, rootID: AgentSession.ID) {
            guard visited.insert(session.id).inserted else { return }
            result.append(Row(session: session, depth: depth, rootID: rootID))
            for child in children[session.id] ?? [] {
                append(child, depth: depth + 1, rootID: rootID)
            }
        }

        for session in sessions {
            if let parentID = session.parentSessionID,
               parentID != session.id,
               ids.contains(parentID) {
                continue
            }
            append(session, depth: 0, rootID: session.id)
        }
        // Corrupt cycles have no root. Pick the first entry in the existing
        // section order and retain each conversation exactly once.
        for session in sessions where !visited.contains(session.id) {
            append(session, depth: 0, rootID: session.id)
        }
        return result
    }

    private static let previewDescendantsPerRoot = 3

    /// Preview a bounded number of descendants per root. Unfinished tasks and
    /// their ancestors stay visible even when their root is past "See more".
    static func initialRows(_ rows: [Row], rootLimit: Int) -> [Row] {
        guard rootLimit > 0 else { return [] }
        let urgent = rows.filter { row in
            guard let status = row.session.childSessionAssignment?.status else { return false }
            return status == .queued || status == .running || status == .waiting
        }
        let shownRoots = Set(rows.filter { $0.depth == 0 }.prefix(rootLimit).map(\.rootID))
            .union(urgent.map(\.rootID))
        let rowsByID = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
        var shownIDs: Set<AgentSession.ID> = []

        func includeWithAncestors(_ row: Row) {
            guard shownIDs.insert(row.id).inserted else { return }
            if let parentID = row.session.parentSessionID,
               let parent = rowsByID[parentID], parent.rootID == row.rootID {
                includeWithAncestors(parent)
            }
        }

        for row in rows where shownRoots.contains(row.rootID) && row.depth == 0 {
            includeWithAncestors(row)
        }
        for row in urgent where shownRoots.contains(row.rootID) {
            includeWithAncestors(row)
        }
        var previewCounts: [AgentSession.ID: Int] = [:]
        for row in rows where shownRoots.contains(row.rootID) && row.depth > 0 {
            guard !shownIDs.contains(row.id),
                  previewCounts[row.rootID, default: 0] < previewDescendantsPerRoot else { continue }
            includeWithAncestors(row)
            previewCounts[row.rootID, default: 0] += 1
        }
        return rows.filter { shownIDs.contains($0.id) }
    }
}
