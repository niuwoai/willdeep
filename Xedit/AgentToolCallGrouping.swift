//
//  AgentToolCallGrouping.swift
//  WillDeep
//
//  Codex-style collapsing of consecutive same-kind tool calls into a
//  single transcript row ("已运行 3 条命令" / "已读取 2 个文件"). The
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
    case subagent
    case claudeCode
    case codexCLI
    case cursorAgent
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
        case "spawn_agent":
            return .subagent
        case "claude_code":
            return .claudeCode
        case "codex_cli":
            return .codexCLI
        case "cursor_agent":
            return .cursorAgent
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
        case .subagent:
            return "已派出 \(count) 个子 agent"
        case .claudeCode:
            return "已委派 \(count) 个 Claude Code 任务"
        case .codexCLI:
            return "已委派 \(count) 个 Codex CLI 任务"
        case .cursorAgent:
            return "已委派 \(count) 个 Cursor Agent 任务"
        case .other(let name):
            return "已调用 \(count) 次 \(name)"
        case .askUser:
            return "向你提问"
        }
    }

    func groupTitle(for calls: [AgentToolCall]) -> String {
        switch self {
        case .fileExploration:
            return AgentToolActivitySummary(calls: calls).explorationText ?? groupTitle(calls.count)
        case .runCommand:
            return "已运行 \(calls.count) 条命令"
        default:
            return groupTitle(calls.count)
        }
    }

    var groupIcon: String {
        switch self {
        case .runCommand: return "terminal"
        case .fileExploration: return "doc.text.magnifyingglass"
        case .subagent: return "person.2"
        case .claudeCode: return "sparkles.rectangle.stack"
        case .codexCLI: return "terminal.fill"
        case .cursorAgent: return "cursorarrow.rays"
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

    var title: String {
        kind.groupTitle(for: calls)
    }
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

struct AgentToolActivitySummary: Equatable {
    var readFileCount: Int
    var listedDirectoryCount: Int
    var searchCount: Int
    var gitStatusCount: Int
    var commandCount: Int

    init(calls: [AgentToolCall]) {
        var readFiles = Set<String>()
        var listedDirectories = Set<String>()
        var searches = 0
        var gitStatuses = 0
        var commands = 0

        for call in calls {
            switch call.toolName {
            case "read_file":
                if let path = call.arguments["path"]?.stringValue() {
                    readFiles.insert(path.isEmpty ? "." : path)
                } else {
                    readFiles.insert(".")
                }
            case "list_directory":
                if let path = call.arguments["path"]?.stringValue() {
                    listedDirectories.insert(path.isEmpty ? "." : path)
                } else {
                    listedDirectories.insert(".")
                }
            case "grep_files", "search_files":
                searches += 1
            case "git_status":
                gitStatuses += 1
            case "run_command":
                commands += 1
            default:
                break
            }
        }

        readFileCount = readFiles.count
        listedDirectoryCount = listedDirectories.count
        searchCount = searches
        gitStatusCount = gitStatuses
        commandCount = commands
    }

    var exploredPathCount: Int {
        readFileCount + listedDirectoryCount
    }

    var hasActivity: Bool {
        readFileCount > 0 || listedDirectoryCount > 0 || searchCount > 0 || gitStatusCount > 0 || commandCount > 0
    }

    var explorationText: String? {
        var parts: [String] = []
        if readFileCount > 0 {
            parts.append("已读取 \(readFileCount) 个文件")
        }
        if listedDirectoryCount > 0 {
            parts.append("已浏览 \(listedDirectoryCount) 个目录")
        }
        if searchCount > 0 {
            parts.append(searchCount == 1 ? "已搜索代码" : "已搜索代码 \(searchCount) 次")
        }
        if gitStatusCount > 0 {
            parts.append(gitStatusCount == 1 ? "已查看 Git 状态" : "已查看 Git 状态 \(gitStatusCount) 次")
        }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: " · ")
    }

    var commandText: String? {
        guard commandCount > 0 else { return nil }
        return "已运行 \(commandCount) 条命令"
    }

    var activityText: String? {
        let parts = [explorationText, commandText].compactMap(\.self)
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
