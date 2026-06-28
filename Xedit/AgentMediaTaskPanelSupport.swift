//
//  AgentMediaTaskPanelSupport.swift
//  WillDeep
//
//  Shared small UI pieces for the media task side panel.
//

import SwiftUI

enum AgentMediaTaskStatusFilter: String, CaseIterable, Identifiable {
    case all
    case active
    case stale
    case attention
    case finished

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .all: return "全部"
        case .active: return "运行中"
        case .stale: return "卡住"
        case .attention: return "需处理"
        case .finished: return "已完成"
        }
    }

    func matches(_ task: AgentMediaTask) -> Bool {
        switch self {
        case .all:
            return true
        case .active:
            return task.isActive
        case .stale:
            return task.isStaleActive()
        case .attention:
            return task.needsAttention
        case .finished:
            return !task.isActive && !task.needsAttention
        }
    }
}

struct AgentMediaPanelSection<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 7) {
                Image(systemName: systemImage)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                Spacer(minLength: 0)
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct AgentMediaMetaRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.primary)
        }
    }
}
