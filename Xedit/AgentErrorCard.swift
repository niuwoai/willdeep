//
//  AgentErrorCard.swift
//  WillDeep
//
//  Error banner for Agent transcripts. Split from AgentPanelView.swift so
//  the panel file can stay focused on layout and transcript orchestration.
//

import SwiftUI

struct AgentErrorCard: View {
    @EnvironmentObject var appState: AppState
    let message: String
    let details: AgentErrorDetails?
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .top, spacing: 7) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
                    .padding(.top, 1)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if appState.canRetryLastAgentTurn {
                    Button {
                        appState.retryLastAgentTurn()
                    } label: {
                        Label("重试", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .help("重新发送上一条消息")
                }
                if details != nil {
                    Button {
                        isExpanded.toggle()
                    } label: {
                        Label(isExpanded ? "收起详情" : "详情",
                              systemImage: isExpanded ? "chevron.up" : "chevron.down")
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .help(isExpanded ? "隐藏详细错误信息" : "查看详细错误信息")
                }
                Button {
                    appState.dismissAgentError()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(2)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("关闭")
            }

            if isExpanded, let details {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(details.sections) { section in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(section.title)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            // Vertical-only scrolling on purpose: with a
                            // horizontal axis the Text gets an unbounded
                            // width proposal, and a single 8 KB JSON line
                            // (tool results stay one-line in pretty print)
                            // blows the renderer's texture limit. Wrapping
                            // keeps it readable and renderable.
                            ScrollView(.vertical) {
                                Text(section.text)
                                    .font(.system(size: 11, design: .monospaced))
                                    .textSelection(.enabled)
                                    .padding(7)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .frame(maxHeight: section.title == "Request Body" ? 180 : 120)
                            .background(Color(nsColor: .textBackgroundColor))
                            .clipShape(RoundedRectangle(cornerRadius: 5))
                        }
                    }
                }
            }
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.red.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.red.opacity(0.18), lineWidth: 1)
        )
    }
}
