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
    var severity: AgentBannerSeverity = .error
    @State private var isExpanded = false
    /// Title of the section whose copy button was just clicked — drives the
    /// transient checkmark feedback so the user can tell the copy happened.
    @State private var copiedSectionTitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .top, spacing: 7) {
                Image(systemName: iconName)
                    .font(.system(size: 12))
                    .foregroundStyle(accentStyle)
                    .padding(.top, 1)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(textStyle)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if appState.agentErrorRequiresSomeIMLogin {
                    Button {
                        EditorSettingsNavigation.shared.openSomeIM(
                            autogenerateBrowserLogin: true,
                            appState: appState
                        )
                    } label: {
                        Label("去登录 some.im", systemImage: "person.crop.circle.badge.plus")
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .help("打开 some.im 登录页；登录后点「重试」重新发送")
                }
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
                        let preview = AgentErrorDetailsPreview.text(for: section)
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Text(section.title)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                if preview.isTruncated {
                                    Text("已省略过长内容")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 0)
                                if copiedSectionTitle == section.title {
                                    Text("已复制")
                                        .font(.caption2)
                                        .foregroundStyle(.green)
                                }
                                Button {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(section.text, forType: .string)
                                    copiedSectionTitle = section.title
                                    let copied = section.title
                                    Task { @MainActor in
                                        try? await Task.sleep(nanoseconds: 1_500_000_000)
                                        if copiedSectionTitle == copied {
                                            copiedSectionTitle = nil
                                        }
                                    }
                                } label: {
                                    // 10pt 的裸 SF Symbol 命中区只有十几个点，
                                    // 很容易"点了没反应"——补 padding + contentShape
                                    // 把可点区域撑到正常按钮大小。
                                    Image(systemName: copiedSectionTitle == section.title
                                          ? "checkmark" : "doc.on.doc")
                                        .font(.system(size: 10))
                                        .foregroundStyle(copiedSectionTitle == section.title
                                                         ? AnyShapeStyle(.green)
                                                         : AnyShapeStyle(.secondary))
                                        .padding(4)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.borderless)
                                .help("复制完整详情")
                            }
                            // Vertical-only scrolling on purpose: with a
                            // horizontal axis the Text gets an unbounded
                            // width proposal, and a single 8 KB JSON line
                            // (tool results stay one-line in pretty print)
                            // blows the renderer's texture limit. Wrapping
                            // keeps it readable and renderable.
                            ScrollView(.vertical) {
                                Text(preview.text)
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
        .background(accentColor.opacity(severity == .error ? 0.06 : 0.07))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(accentColor.opacity(severity == .error ? 0.18 : 0.22), lineWidth: 1)
        )
    }

    // MARK: - Severity styling
    //
    // `.notice` deliberately drops red and the warning triangle: those
    // banners hand control back to the user without anything having failed,
    // and the alarm treatment made a healthy run look broken.

    private var accentColor: Color {
        switch severity {
        case .error: return .red
        case .notice: return .accentColor
        }
    }

    private var accentStyle: AnyShapeStyle {
        AnyShapeStyle(accentColor)
    }

    private var textStyle: AnyShapeStyle {
        switch severity {
        case .error: return AnyShapeStyle(.red)
        case .notice: return AnyShapeStyle(.primary)
        }
    }

    private var iconName: String {
        switch severity {
        case .error: return "exclamationmark.triangle.fill"
        case .notice: return "info.circle.fill"
        }
    }
}

enum AgentErrorDetailsPreview {
    struct Result: Equatable {
        let text: String
        let isTruncated: Bool
    }

    nonisolated static func text(for section: AgentErrorDetails.Section) -> Result {
        text(section.text, totalLimit: totalLimit(for: section.title), lineLimit: lineLimit(for: section.title))
    }

    nonisolated static func text(_ raw: String, totalLimit: Int, lineLimit: Int) -> Result {
        let normalized = raw.replacingOccurrences(of: "\r\n", with: "\n")
        var truncated = false
        let lineLimited = normalized
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> String in
                let value = String(line)
                guard value.count > lineLimit else { return value }
                truncated = true
                return middleEllipsize(
                    value,
                    limit: lineLimit,
                    omittedLabel: " ... [本行已省略 \(value.count - lineLimit) 个字符] ... "
                )
            }
            .joined(separator: "\n")

        guard lineLimited.count > totalLimit else {
            return Result(text: lineLimited, isTruncated: truncated)
        }

        return Result(
            text: middleEllipsize(
                lineLimited,
                limit: totalLimit,
                omittedLabel: "\n\n... [中间已省略 \(lineLimited.count - totalLimit) 个字符] ...\n\n"
            ),
            isTruncated: true
        )
    }

    nonisolated private static func totalLimit(for title: String) -> Int {
        switch title {
        case "Request Body":
            return 9_000
        case "Input Messages":
            return 7_000
        case "Response":
            return 6_000
        default:
            return 4_000
        }
    }

    nonisolated private static func lineLimit(for title: String) -> Int {
        switch title {
        case "Request Body":
            return 1_200
        case "Input Messages":
            return 900
        default:
            return 1_000
        }
    }

    nonisolated private static func middleEllipsize(_ text: String, limit: Int, omittedLabel: String) -> String {
        guard text.count > limit else { return text }
        let labelCount = omittedLabel.count
        guard limit > labelCount + 20 else {
            return String(text.prefix(max(1, limit - 3))) + "..."
        }
        let remaining = limit - labelCount
        let prefixCount = max(1, remaining / 2)
        let suffixCount = max(1, remaining - prefixCount)
        return String(text.prefix(prefixCount)) + omittedLabel + String(text.suffix(suffixCount))
    }
}
