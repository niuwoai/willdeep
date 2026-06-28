//
//  AgentWidgetRegistry.swift
//  WillDeep
//
//  1.84.0-rc1：`show_widget` 调用产物的中转。完全照搬
//  `AgentSubagentRegistry` 的「pending → consume in next round」管线：
//  工具 handler 把 widget enqueue 到 pendingWidgets[runtimeID]，
//  AppStateAgentLoop 在每个 turn 顶部 drain 队列，append `.widget` 消息
//  到 runtime.messages。这条路径不需要走 LLM，因为 widget 卡片不发回
//  模型（AgentClient 各 adapter 都对 `.widget` `continue`）。
//

import Foundation
import Combine

@MainActor
final class AgentWidgetRegistry: ObservableObject {
    static let shared = AgentWidgetRegistry()

    @Published private var latestByRuntime: [UUID: AgentWidget] = [:]
    @Published private var historyByRuntime: [UUID: [AgentWidget]] = [:]
    private var pending: [UUID: [AgentWidget]] = [:]
    private let historyLimit = 20

    private init() {}

    /// 工具 handler 调用。runtimeID 取自 AgentToolContext。
    func add(_ widget: AgentWidget, forRuntime runtimeID: UUID) {
        pending[runtimeID, default: []].append(widget)
        latestByRuntime[runtimeID] = widget
        remember(widget, forRuntime: runtimeID)
    }

    /// AppStateAgentLoop turn 顶部调用，跟 spawn_agent / background-job
    /// 走同一条注入管道。
    func consumePending(forRuntime runtimeID: UUID) -> [AgentWidget] {
        guard let queued = pending.removeValue(forKey: runtimeID), !queued.isEmpty else {
            return []
        }
        return queued
    }

    func latestWidget(forRuntime runtimeID: UUID?) -> AgentWidget? {
        guard let runtimeID else { return nil }
        return latestByRuntime[runtimeID]
    }

    func widgets(forRuntime runtimeID: UUID?) -> [AgentWidget] {
        guard let runtimeID else { return [] }
        return historyByRuntime[runtimeID] ?? []
    }

    func remember(_ widget: AgentWidget, forRuntime runtimeID: UUID) {
        var widgets = historyByRuntime[runtimeID] ?? []
        widgets.removeAll { $0.id == widget.id }
        widgets.insert(widget, at: 0)
        if widgets.count > historyLimit {
            widgets = Array(widgets.prefix(historyLimit))
        }
        historyByRuntime[runtimeID] = widgets
        latestByRuntime[runtimeID] = widgets.first
    }
}
