//
//  AgentWidget.swift
//  WillDeep
//
//  1.84.0-rc1：`show_widget` 工具产物。模型生成 HTML / SVG，经
//  `AgentWidgetRegistry` 队列在下一轮 turn 开头注入到 transcript 成一条
//  `.widget` 消息，由 `AgentWidgetCardView` 在 WKWebView 里渲染。
//
//  数据本身只是元数据 + 一段 HTML 字符串 —— 真正的安全 sandbox 全在
//  `AgentWidgetCardView` 那一层（CSP、禁外网、禁 navigation、禁 file://、
//  注入主题 CSS 变量）。
//

import Foundation

struct AgentWidget: Codable, Equatable, Identifiable {
    let id: UUID
    /// 用户能看到的卡片标题，也作为 widget 的 download 文件名前缀
    /// （phase 2 加导出功能时用得到）。
    var title: String
    /// LLM 生成的原始 HTML / SVG 代码。直接进 WKWebView 当 HTMLString
    /// 装载；任何外联资源都会被 CSP 拦掉，所以 LLM 必须 inline 一切。
    var html: String
    /// Optional structured handoff lines supplied by `show_widget`.
    /// These are not exposed to JavaScript. They only ride along when the
    /// user sends the widget or a widget button back into chat.
    var contextLines: [String]
    let createdAt: Date

    init(
        id: UUID = UUID(),
        title: String,
        html: String,
        contextLines: [String] = [],
        createdAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.html = html
        self.contextLines = contextLines
        self.createdAt = createdAt
    }

    /// Rough byte count of the rendered HTML — used by the card footer
    /// so the user can spot when the LLM accidentally generated 500 KB
    /// of inline data.
    var byteCount: Int { html.utf8.count }

    var contextBlock: String {
        contextLines
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    var recommendedAction: AgentWidgetRecommendedAction? {
        guard let tool = contextValue(named: "recommended_tool"),
              !tool.isEmpty else {
            return nil
        }
        return AgentWidgetRecommendedAction(
            tool: tool,
            arguments: contextValue(named: "recommended_arguments")
        )
    }

    var sourceLabel: String? {
        contextValue(named: "source_label")
    }

    var sourcePath: String? {
        contextValue(named: "source_path") ?? contextValue(named: "html_path")
    }

    var packageDirectory: String? {
        contextValue(named: "package_directory")
    }

    var widgetContextNote: String? {
        contextValue(named: "widget_context")
    }

    var sourceSummary: String {
        let label = sourceLabel?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let package = packageDirectory?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let path = sourcePath?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !label.isEmpty, !package.isEmpty {
            return "\(label) · \(URL(fileURLWithPath: package).lastPathComponent)"
        }
        if !label.isEmpty {
            return label
        }
        if !package.isEmpty {
            return URL(fileURLWithPath: package).lastPathComponent
        }
        if !path.isEmpty {
            return URL(fileURLWithPath: path).lastPathComponent
        }
        return "inline widget"
    }

    var handoffActions: [AgentWidgetHandoffAction] {
        var seen: Set<String> = []
        var actions: [AgentWidgetHandoffAction] = []
        for line in contextLines {
            guard let (key, tool) = contextEntry(line),
                  key.hasSuffix("_tool"),
                  key != "recommended_tool",
                  !tool.isEmpty else {
                if let compactAction = compactHandoffAction(from: line),
                   seen.insert(compactAction.id).inserted {
                    actions.append(compactAction)
                }
                continue
            }
            let baseKey = String(key.dropLast("_tool".count))
            let arguments = contextValue(named: "\(baseKey)_arguments")
            let identity = "\(key)||\(tool)||\(arguments ?? "")"
            guard !seen.contains(identity) else { continue }
            seen.insert(identity)
            actions.append(AgentWidgetHandoffAction(
                key: key,
                label: baseKey.replacingOccurrences(of: "_", with: " "),
                tool: tool,
                arguments: arguments
            ))
        }
        return actions
    }

    private func contextValue(named name: String) -> String? {
        return contextLines
            .lazy
            .compactMap { line -> String? in
                guard let (key, value) = contextEntry(line),
                      key == name else {
                    return nil
                }
                return value.isEmpty ? nil : value
            }
            .first
    }

    private func contextEntry(_ line: String) -> (key: String, value: String)? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let separator = contextSeparator(in: trimmed) else { return nil }
        let key = trimmed[..<separator].trimmingCharacters(in: .whitespacesAndNewlines)
        let value = trimmed[trimmed.index(after: separator)...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard isContextKey(key) else { return nil }
        return (key, value)
    }

    private func contextSeparator(in line: String) -> String.Index? {
        ([":", "="] as [Character])
            .compactMap { line.firstIndex(of: $0) }
            .min()
    }

    private func compactHandoffAction(from line: String) -> AgentWidgetHandoffAction? {
        guard let tool = inlineContextValue(named: "tool", in: line),
              !tool.isEmpty else {
            return nil
        }
        let action = inlineContextValue(named: "action", in: line) ?? "widget_inline_action"
        return AgentWidgetHandoffAction(
            key: action,
            label: action.replacingOccurrences(of: "_", with: " "),
            tool: tool,
            arguments: inlineContextTailValue(named: "arguments", in: line)
        )
    }

    private func inlineContextValue(named name: String, in line: String) -> String? {
        guard let tail = inlineContextTailValue(named: name, in: line) else { return nil }
        let value = tail
            .split(separator: ",", maxSplits: 1, omittingEmptySubsequences: false)
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value?.isEmpty == false ? value : nil
    }

    private func inlineContextTailValue(named name: String, in line: String) -> String? {
        let patterns = ["\(name)=", "\(name):"]
        guard let match = patterns
            .compactMap({ pattern -> Range<String.Index>? in
                line.range(of: pattern, options: [.caseInsensitive])
            })
            .min(by: { $0.lowerBound < $1.lowerBound }) else {
            return nil
        }
        let value = line[match.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private func isContextKey(_ key: String) -> Bool {
        guard !key.isEmpty else { return false }
        return key.unicodeScalars.allSatisfy { scalar in
            CharacterSet.alphanumerics.contains(scalar) || scalar == UnicodeScalar("_")
        }
    }
}

struct AgentWidgetRecommendedAction: Equatable {
    let tool: String
    let arguments: String?

    var displayArguments: String {
        let trimmed = arguments?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "无额外参数" : trimmed
    }
}

struct AgentWidgetHandoffAction: Equatable, Identifiable {
    let key: String
    let label: String
    let tool: String
    let arguments: String?

    var id: String { "\(key)::\(tool)::\(arguments ?? "")" }

    var displayArguments: String {
        let trimmed = arguments?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "无额外参数" : trimmed
    }
}
