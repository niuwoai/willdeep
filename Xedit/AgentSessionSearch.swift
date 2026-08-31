//
//  AgentSessionSearch.swift
//  WillDeep
//
//  Searching past conversations.
//
//  The transcripts were always on disk; nothing could read them. The model
//  could list session titles and nothing else, so "we discussed this last
//  week" was unanswerable — it could see the shelf but not open a book.
//
//  Two constraints shape the design:
//
//   - Never load everything. `AgentSessionStore.loadAllWithMetadata()`
//     deliberately reads only small sidecars; full messages come from
//     `load(id:)` per session. Search follows the same discipline: filter on
//     metadata, then open only the candidates, and stop once enough matches
//     are found. Returning whole transcripts would blow the context window
//     this feature exists to save.
//   - Stay inside the current workspace by default. Old conversations hold
//     other projects' details; widening that is the user's call, not the
//     model's (the tool's risk tier escalates for a cross-workspace search
//     so it goes through the approval card).
//

import Foundation

nonisolated struct AgentSessionSearchMatch: Equatable {
    let sessionID: UUID
    let sessionTitle: String
    let workspaceName: String
    let lastActivityAt: Date
    /// 1-based index of the matching message within the conversation, so a
    /// follow-up read has somewhere concrete to start.
    let messageIndex: Int
    let role: String
    /// The matching message plus a little surrounding conversation, each
    /// piece already clamped.
    let excerpt: String
}

/// A selectable title-search destination. The palette searches both individual
/// conversations and user-defined projects; keeping those as distinct cases
/// lets the sidebar either activate a chat row or focus a workspace header.
nonisolated enum AgentSessionSearchResult: Identifiable, Equatable {
    case session(AgentSession)
    case project(AgentProject)

    var id: String {
        switch self {
        case .session(let session):
            return "session-\(session.id.uuidString)"
        case .project(let project):
            return "project-\(project.id.uuidString)"
        }
    }
}

nonisolated enum AgentSessionSearch {
    /// Caps chosen so a full result set stays a few thousand tokens: this is
    /// a pointer into history, not a replacement for reading it.
    enum Limits {
        /// Characters kept from each quoted message.
        static let excerptCharacters = 400
        /// 搜索面板空查询时默认列出的最近会话条数。
        static let recentSessions = 50
        /// Messages of surrounding context on each side of a hit.
        static let contextRadius = 1
        /// Sessions opened from disk in one search, however many match on
        /// metadata. Bounds the worst-case IO of a single tool call.
        static let sessionsScanned = 40
        /// Matches returned per session, so one chatty conversation cannot
        /// crowd out every other result.
        static let matchesPerSession = 3
    }

    /// Case-insensitive substring test. Deliberately not regex: the model
    /// writes these queries, and a malformed pattern silently matching
    /// nothing is worse than a literal search that plainly works.
    static func matches(_ text: String, query: String) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return text.range(of: trimmed, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }

    /// Finds title matches in both conversations and named projects. Projects
    /// lead the result list because a project-name hit is a direct request to
    /// navigate the sidebar group rather than to open one arbitrary chat in
    /// that group. Conversations remain newest-first, matching the old search
    /// behaviour; project ties use their latest edit time then a stable name.
    static func titleResults(
        sessions: [AgentSession],
        projects: [AgentProject],
        query: String,
        isMetadataOnly: (AgentSession.ID) -> Bool = { _ in false },
        metadataOnlyHasUserMessage: (AgentSession.ID) -> Bool = { _ in false }
    ) -> [AgentSessionSearchResult] {
        let projectResults = projects
            .filter { matches($0.resolvedDisplayName, query: query) }
            .sorted { lhs, rhs in
                if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
                let nameOrder = lhs.resolvedDisplayName.localizedCaseInsensitiveCompare(rhs.resolvedDisplayName)
                if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
                return lhs.id.uuidString < rhs.id.uuidString
            }
            .map(AgentSessionSearchResult.project)

        let sessionResults = sessions
            .filter {
                hasConversation($0, isMetadataOnly: isMetadataOnly,
                                metadataOnlyHasUserMessage: metadataOnlyHasUserMessage)
                    && matches($0.title, query: query)
            }
            .sorted { $0.updatedAt > $1.updatedAt }
            .map(AgentSessionSearchResult.session)

        return projectResults + sessionResults
    }

    /// 空查询时的默认列表：不分项目、不分组，按最后更新时间倒序的最近会话。
    /// 在截取条数前排除空会话；历史会话用所属 AppState 的元数据判定，
    /// 不为搜索加载全文，也不把尚未加载的正文误判为空。
    static func recentSessions(
        _ sessions: [AgentSession],
        limit: Int = Limits.recentSessions,
        isMetadataOnly: (AgentSession.ID) -> Bool = { _ in false },
        metadataOnlyHasUserMessage: (AgentSession.ID) -> Bool = { _ in false }
    ) -> [AgentSessionSearchResult] {
        sessions
            .filter {
                hasConversation($0, isMetadataOnly: isMetadataOnly,
                                metadataOnlyHasUserMessage: metadataOnlyHasUserMessage)
                    && !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            .sorted { lhs, rhs in
                if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
                return lhs.id.uuidString < rhs.id.uuidString
            }
            .prefix(limit)
            .map(AgentSessionSearchResult.session)
    }

    /// 与侧栏一致：发送过用户消息才算会话，纯附件消息也保留。
    private static func hasConversation(
        _ session: AgentSession,
        isMetadataOnly: (AgentSession.ID) -> Bool,
        metadataOnlyHasUserMessage: (AgentSession.ID) -> Bool
    ) -> Bool {
        if isMetadataOnly(session.id) {
            return metadataOnlyHasUserMessage(session.id)
        }
        return session.messages.contains { $0.role == .user }
    }

    /// Whether a session belongs to the workspace the user is looking at.
    ///
    /// Compares on `workspaceSidebarGroupKey` rather than the raw path so a
    /// conversation running in a Git worktree still counts as part of its
    /// project — matching what the sidebar shows and what "this workspace"
    /// means to the person asking.
    static func belongsToWorkspace(_ session: AgentSession, groupKey: String?) -> Bool {
        guard let groupKey, !groupKey.isEmpty else { return true }
        return session.workspaceSidebarGroupKey == groupKey
    }

    static func clamped(_ text: String, to limit: Int = Limits.excerptCharacters) -> String {
        let collapsed = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard collapsed.count > limit else { return collapsed }
        return String(collapsed.prefix(limit)) + "…"
    }

    /// Matches inside one conversation, newest first.
    ///
    /// Only user and assistant turns are searched: tool payloads are bulky,
    /// frequently machine-generated, and rarely what someone means by "what
    /// did we say about X".
    static func matches(
        in session: AgentSession,
        query: String,
        limit: Int = Limits.matchesPerSession
    ) -> [AgentSessionSearchMatch] {
        guard limit > 0 else { return [] }
        let searchable = session.messages.enumerated().filter { _, message in
            message.role == .user || message.role == .assistant
        }

        var found: [AgentSessionSearchMatch] = []
        for (index, message) in searchable.reversed() {
            guard matches(message.content, query: query) else { continue }
            found.append(
                AgentSessionSearchMatch(
                    sessionID: session.id,
                    sessionTitle: session.title,
                    workspaceName: session.workspaceName,
                    lastActivityAt: session.lastActivityAt,
                    messageIndex: index + 1,
                    role: message.role.rawValue,
                    excerpt: excerpt(around: index, in: session.messages)
                )
            )
            if found.count >= limit { break }
        }
        return found
    }

    /// The hit plus one turn either side, each clamped and labelled. Without
    /// the neighbours a bare quote often reads as unattributable — the
    /// question that prompted an answer is usually the useful half.
    static func excerpt(around index: Int, in messages: [AgentMessage]) -> String {
        let lower = max(0, index - Limits.contextRadius)
        let upper = min(messages.count - 1, index + Limits.contextRadius)
        guard lower <= upper else { return "" }

        return (lower...upper).compactMap { position -> String? in
            let message = messages[position]
            guard message.role == .user || message.role == .assistant else { return nil }
            let body = clamped(message.content)
            guard !body.isEmpty else { return nil }
            let marker = position == index ? "→ " : "  "
            return "\(marker)[\(message.role.rawValue)] \(body)"
        }
        .joined(separator: "\n")
    }

    /// Renders results for the model: enough to decide what to open next,
    /// never the whole transcript.
    static func renderPayload(
        _ matches: [AgentSessionSearchMatch],
        query: String,
        scopeDescription: String,
        sessionsScanned: Int,
        wasTruncated: Bool
    ) -> String {
        guard !matches.isEmpty else {
            return "No matches for “\(query)” in \(scopeDescription) (searched \(sessionsScanned) conversation\(sessionsScanned == 1 ? "" : "s")."
                + " Try a shorter or differently-worded query, or widen the scope.)"
        }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        var lines: [String] = [
            "\(matches.count) match\(matches.count == 1 ? "" : "es") for “\(query)” in \(scopeDescription), newest first."
        ]
        if wasTruncated {
            lines.append("More conversations matched than were opened (scan capped at \(Limits.sessionsScanned)). Narrow the query if the answer is not here.")
        }
        lines.append("")

        for match in matches {
            lines.append("── \(match.sessionTitle) · \(match.workspaceName) · \(formatter.string(from: match.lastActivityAt))")
            lines.append("   session_id: \(match.sessionID.uuidString) · message #\(match.messageIndex)")
            lines.append(match.excerpt)
            lines.append("")
        }
        lines.append("Excerpts are clamped to \(Limits.excerptCharacters) characters. If that is not enough, search again with a more specific phrase — whole transcripts are intentionally not retrievable. The session_id identifies the conversation for the user to open.")
        return lines.joined(separator: "\n")
    }
}
