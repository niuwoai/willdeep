//
//  AgentWidgetToolAction.swift
//  WillDeep
//
//  Runtime context for structured tool actions emitted by sandboxed widgets.
//  Widgets still cannot call tools directly; they can only ask the chat loop
//  to review and execute a named action with explicit arguments.
//

import Foundation

struct AgentWidgetToolAction: Equatable, Identifiable {
    let id: UUID
    var widgetID: UUID
    var widgetTitle: String
    var actionKey: String?
    var tool: String
    var arguments: String?
    var note: String?
    var widgetContext: String
    var createdAt: Date

    init(
        id: UUID = UUID(),
        widgetID: UUID,
        widgetTitle: String,
        actionKey: String? = nil,
        tool: String,
        arguments: String? = nil,
        note: String? = nil,
        widgetContext: String,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.widgetID = widgetID
        self.widgetTitle = widgetTitle
        self.actionKey = Self.clean(actionKey)
        self.tool = tool
        self.arguments = Self.clean(arguments)
        self.note = Self.clean(note)
        self.widgetContext = widgetContext
        self.createdAt = createdAt
    }

    var systemPromptBlock: String {
        var lines = [
            "=== Latest Widget Tool Action ===",
            "<latest-widget-tool-action>",
            "widget_id: \(widgetID.uuidString)",
            "widget_title: \(widgetTitle)",
            "tool: \(tool)",
            "source: widget_send_tool_action",
            "action_note: widgets cannot execute tools directly; inspect this action, preserve safety checks, use dry-run when available, then call the matching tool if appropriate."
        ]
        appendCleanLine("action_key", actionKey, to: &lines)
        appendCleanLine("arguments", arguments, to: &lines)
        appendCleanLine("note", note, to: &lines)
        if !widgetContext.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.append("widget_context:")
            lines.append(widgetContext)
        }
        lines.append("</latest-widget-tool-action>")
        return lines.joined(separator: "\n")
    }

    var userPromptBlock: String {
        var lines = [
            "请根据网页组件发来的结构化工具动作继续协作。先检查参数是否需要 dry-run 或用户确认，再调用对应工具。",
            "",
            "<widget-tool-action>",
            "action: run_widget_tool_action",
            "widget_id: \(widgetID.uuidString)",
            "widget_title: \(widgetTitle)",
            "tool: \(tool)",
            "source: sendToolAction"
        ]
        appendCleanLine("action_key", actionKey, to: &lines)
        appendCleanLine("arguments", arguments, to: &lines)
        appendCleanLine("note", note, to: &lines)
        if !widgetContext.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.append(widgetContext)
        }
        lines.append("</widget-tool-action>")
        return lines.joined(separator: "\n")
    }

    private func appendCleanLine(_ key: String, _ value: String?, to lines: inout [String]) {
        guard let value = Self.clean(value) else { return }
        lines.append("\(key): \(value)")
    }

    private static func clean(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}

@MainActor
extension AppState {
    var agentLatestWidgetToolAction: AgentWidgetToolAction? {
        get { activeRuntime?.latestWidgetToolAction }
        set { activeRuntime?.latestWidgetToolAction = newValue }
    }

    func recordAgentWidgetToolAction(_ action: AgentWidgetToolAction) {
        activeRuntime?.latestWidgetToolAction = action
    }
}
