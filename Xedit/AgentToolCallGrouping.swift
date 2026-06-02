//
//  AgentToolCallGrouping.swift
//  VeilWriter
//
//  Codex-style collapsing of consecutive same-kind tool calls into a
//  single transcript row ("已运行 3 条命令" / "已探索 2 个文件"). The
//  Agent-mode transcript renders one card per group instead of one
//  card per tool call so a busy turn doesn't drown the chat.
//

import Foundation

/// Coarse category used purely for grouping. ask_user and patch
/// proposals are intentionally outside the grouped families — they
/// need explicit user interaction and must always render full-size.
enum AgentToolKind: Equatable {
    case runCommand
    case fileExploration
    case askUser
    case other(String)

    static func of(_ call: AgentToolCall) -> AgentToolKind {
        switch call.toolName {
        case "run_command":
            return .runCommand
        case "read_file", "list_directory",
             "grep_files", "search_files",
             "git_status":
            return .fileExploration
        case "ask_user":
            return .askUser
        default:
            return .other(call.toolName)
        }
    }

    /// Whether two adjacent calls of this kind are allowed to merge.
    /// `.askUser` always stands alone; everything else can group with a
    /// peer of the same kind.
    var isGroupable: Bool {
        switch self {
        case .askUser: return false
        default: return true
        }
    }

    func groupTitle(_ count: Int) -> String {
        switch self {
        case .runCommand:
            return "已运行 \(count) 条命令"
        case .fileExploration:
            return "已探索 \(count) 个文件"
        case .other(let name):
            return "已调用 \(count) 次 \(name)"
        case .askUser:
            return "向你提问"
        }
    }

    var groupIcon: String {
        switch self {
        case .runCommand: return "terminal"
        case .fileExploration: return "doc.text.magnifyingglass"
        case .askUser: return "bubble.left.and.text.bubble.right"
        case .other: return "wrench.and.screwdriver"
        }
    }
}

/// Either a single call (rendered as the existing AgentToolCallCard)
/// or a merged run of N adjacent calls (rendered as the new compact
/// row). Single tool calls in groupable kinds still arrive here as a
/// group of size 1 — the renderer decides to fall back to the full
/// card in that case, so the user sees the rich UI when there's only
/// one call but the dense row when there are many.
/// Renamed from `AgentToolCallGroup` to avoid colliding with the view
/// type of the same name in AgentPanelView. This is the model layer —
/// the view consumes `segments[i].calls` directly.
struct AgentToolCallSegment: Identifiable, Equatable {
    let id: UUID
    let kind: AgentToolKind
    let calls: [AgentToolCall]

    init(kind: AgentToolKind, calls: [AgentToolCall]) {
        // Stable id derived from the first call so SwiftUI keeps the
        // same view identity as the group grows during streaming.
        self.id = calls.first?.id ?? UUID()
        self.kind = kind
        self.calls = calls
    }

    var count: Int { calls.count }
}

enum AgentToolCallGrouping {
    /// Walk the given (already-filtered) tool calls in order and
    /// produce a flat list of segments. Adjacent calls of the same
    /// groupable kind merge; everything else lands as a singleton
    /// segment of size 1.
    static func group(_ calls: [AgentToolCall]) -> [AgentToolCallSegment] {
        var result: [AgentToolCallSegment] = []
        var pendingKind: AgentToolKind?
        var pending: [AgentToolCall] = []

        func flush() {
            guard let kind = pendingKind, !pending.isEmpty else { return }
            result.append(AgentToolCallSegment(kind: kind, calls: pending))
            pendingKind = nil
            pending = []
        }

        for call in calls {
            let kind = AgentToolKind.of(call)
            if kind.isGroupable, pendingKind == kind {
                pending.append(call)
            } else {
                flush()
                pendingKind = kind
                pending = [call]
                if !kind.isGroupable {
                    // Non-groupable kinds (.askUser) flush themselves
                    // immediately so the next call starts a fresh group.
                    flush()
                }
            }
        }
        flush()
        return result
    }
}
