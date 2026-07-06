//
//  AgentWidgetCardView.swift
//  WillDeep
//
//  1.84.0-rc1：Transcript-inline 卡片，把 `AgentWidget` 的 HTML 放进
//  WKWebView 渲染。整个 web 视图被一组沙箱约束圈死：
//
//   1. **CSP**：通过 `<meta http-equiv="Content-Security-Policy" ...>`
//      注入到 HTML 头部。`default-src 'self' 'unsafe-inline' data:` +
//      `connect-src 'none'` + `frame-src 'none'` —— 最关键的是
//      `connect-src 'none'`，LLM 不论怎么写 fetch / XHR / WebSocket 都
//      发不出去网络请求。
//   2. **Navigation 拦截**：`decidePolicyFor navigationAction` 只放行
//      about/data 与本 widget baseURL 目录内的 file 资源。
//   3. **scheme 黑名单**：ws:// / wss:// 一律拒；file:// 导航只允许
//      widget 自己的本地 baseURL 目录，用来加载用户明确给出的 CSS/图片。
//   4. **JS 通信**：1.84.0-rc2 通过 `WKScriptMessageHandler` 加了双向
//      桥，但仅暴露 `window.sendPrompt(text)` 和
//      `window.sendToolAction(action)` 给 widget 反向触发 chat；自动高度
//      `height` 事件由注入脚本静默上报。
//      Widget 拿不到 read 任何 Swift 状态，只能 push 这两类消息。
//   5. **主题 CSS 变量注入**：跟随 SwiftUI 当前 colorScheme 注入
//      `--bg --fg --accent --secondary`。
//

import SwiftUI
import WebKit

struct AgentWidgetCardView: View {
    let widget: AgentWidget

    @EnvironmentObject var appState: AppState
    @State private var expanded: Bool = true
    @State private var height: CGFloat = 360
    @Environment(\.colorScheme) private var colorScheme

    /// 自动高度上报后的最小 / 最大 clamp。Widget body 高度 > 900px
    /// 时滚动；小于 120px 时给一个最小展示空间。
    private static let minHeight: CGFloat = 120
    private static let maxAutoHeight: CGFloat = 900

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if expanded {
                AgentWidgetWebView(
                    widgetID: widget.id,
                    widgetTitle: widget.title,
                    widgetContext: widget.contextBlock,
                    html: composedHTML,
                    baseURL: widget.sourceBaseURL,
                    appState: appState,
                    onHeightChange: { reported in
                        let clamped = max(Self.minHeight, min(Self.maxAutoHeight, reported))
                        if abs(clamped - height) > 2 {
                            height = clamped
                        }
                    }
                )
                .frame(height: height)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.primary.opacity(0.06), lineWidth: 1)
                )
            }
            footer
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 8).fill(.thinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.accentColor.opacity(0.25), lineWidth: 1)
        )
        .frame(maxWidth: AgentDesign.chatMaxContentWidth, alignment: .leading)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "rectangle.dashed")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.accentColor)
            Text(widget.title)
                .font(.system(size: 13, weight: .semibold))
            Text("Widget")
                .font(.system(size: 10, weight: .medium))
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(Capsule().fill(Color.accentColor.opacity(0.12)))
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Button {
                expanded.toggle()
            } label: {
                Image(systemName: expanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help(expanded ? "Collapse widget" : "Expand widget")
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Text(byteLabel)
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(.secondary)
            Text("· Sandbox: no network, no navigation · sendPrompt()/sendToolAction() available")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Spacer(minLength: 4)
        }
    }

    private var byteLabel: String {
        let b = widget.byteCount
        if b >= 1024 * 1024 {
            return String(format: "%.1f MB", Double(b) / (1024 * 1024))
        }
        if b >= 1024 {
            return "\(b / 1024) KB"
        }
        return "\(b) B"
    }

    private var composedHTML: String {
        let isDark = colorScheme == .dark
        let bg = isDark ? "#1c1c1e" : "#ffffff"
        let fg = isDark ? "#f0f0f3" : "#1a1a1c"
        let secondary = isDark ? "#9b9ba0" : "#6c6c70"
        let accent = "#0a84ff"
        let csp = "default-src 'self' 'unsafe-inline' data: blob:; "
            + "script-src 'self' 'unsafe-inline'; "
            + "style-src 'self' 'unsafe-inline'; "
            + "img-src 'self' data: blob:; "
            + "connect-src 'none'; "
            + "frame-src 'none'; "
            + "object-src 'none'; "
            + "base-uri 'none'; "
            + "form-action 'none';"
        // Bridge script — injected at the END of <body> so user HTML
        // can override window.sendPrompt if it really wants to (it
        // shouldn't, but the WKScriptMessageHandler on the Swift side
        // also gates by message `type` so a hijack can only post the
        // two allowed events anyway).
        let bridgeScript = """
        (function() {
          if (!window.webkit || !window.webkit.messageHandlers || !window.webkit.messageHandlers.willdeep) {
            return;
          }
          var handler = window.webkit.messageHandlers.willdeep;
          window.sendPrompt = function(text) {
            if (typeof text !== 'string' || text.length === 0) { return; }
            try { handler.postMessage({type: 'sendPrompt', text: text}); } catch (e) {}
          };
          window.sendToolAction = function(action, args, note) {
            var payload = (action && typeof action === 'object')
              ? action
              : {tool: action, arguments: args, note: note};
            try { handler.postMessage({type: 'sendToolAction', action: payload}); } catch (e) {}
          };
          var lastReportedHeight = 0;
          function reportHeight() {
            var h = Math.max(
              document.body ? document.body.scrollHeight : 0,
              document.documentElement ? document.documentElement.scrollHeight : 0
            );
            if (h && Math.abs(h - lastReportedHeight) > 2) {
              lastReportedHeight = h;
              try { handler.postMessage({type: 'height', value: h}); } catch (e) {}
            }
          }
          if (typeof ResizeObserver === 'function') {
            new ResizeObserver(reportHeight).observe(document.body);
          }
          window.addEventListener('load', reportHeight);
          setTimeout(reportHeight, 50);
          setTimeout(reportHeight, 250);
          setTimeout(reportHeight, 1000);
        })();
        """
        return """
        <!DOCTYPE html>
        <html>
        <head>
            <meta charset="utf-8">
            <meta http-equiv="Content-Security-Policy" content="\(csp)">
            <style>
                :root {
                    --bg: \(bg);
                    --fg: \(fg);
                    --secondary: \(secondary);
                    --accent: \(accent);
                }
                html, body {
                    margin: 0;
                    padding: 0;
                    background: var(--bg);
                    color: var(--fg);
                    font-family: -apple-system, "SF Pro Text", sans-serif;
                    font-size: 13px;
                    -webkit-text-size-adjust: 100%;
                }
                body { padding: 12px; box-sizing: border-box; }
                a { color: var(--accent); }
            </style>
        </head>
        <body>
            \(widget.html)
            <script>\(bridgeScript)</script>
        </body>
        </html>
        """
    }
}

// MARK: - WKWebView bridge

private struct AgentWidgetWebView: NSViewRepresentable {
    let widgetID: UUID
    let widgetTitle: String
    let widgetContext: String
    let html: String
    let baseURL: URL?
    let appState: AppState
    let onHeightChange: (CGFloat) -> Void

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        let preferences = WKWebpagePreferences()
        preferences.allowsContentJavaScript = true
        configuration.defaultWebpagePreferences = preferences

        // Bridge: widget JS → Swift. Only the `willdeep` channel exists;
        // any other webkit.messageHandlers.* are undefined.
        configuration.userContentController.add(
            context.coordinator,
            name: "willdeep"
        )

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.widgetID = widgetID
        context.coordinator.widgetTitle = widgetTitle
        context.coordinator.widgetContext = widgetContext
        context.coordinator.baseURL = baseURL
        context.coordinator.appState = appState
        context.coordinator.onHeightChange = onHeightChange
        webView.loadHTMLString(html, baseURL: baseURL)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(widgetID: widgetID, widgetTitle: widgetTitle, widgetContext: widgetContext, baseURL: baseURL, appState: appState, onHeightChange: onHeightChange)
    }

    static func dismantleNSView(_ nsView: WKWebView, coordinator: Coordinator) {
        // 解开 message handler 避免 retain cycle（WKWebView 强引用
        // configuration → contentController → handler）。
        nsView.configuration.userContentController.removeScriptMessageHandler(forName: "willdeep")
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
        var widgetID: UUID
        var widgetTitle: String
        var widgetContext: String
        var baseURL: URL?
        weak var appState: AppState?
        var onHeightChange: (CGFloat) -> Void

        init(widgetID: UUID, widgetTitle: String, widgetContext: String, baseURL: URL?, appState: AppState, onHeightChange: @escaping (CGFloat) -> Void) {
            self.widgetID = widgetID
            self.widgetTitle = widgetTitle
            self.widgetContext = widgetContext
            self.baseURL = baseURL
            self.appState = appState
            self.onHeightChange = onHeightChange
        }

        // MARK: Navigation

        func webView(_ webView: WKWebView,
                     decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = navigationAction.request.url else {
                decisionHandler(.allow)
                return
            }
            let scheme = (url.scheme ?? "").lowercased()
            if scheme == "about" || scheme == "data" {
                decisionHandler(.allow)
            } else if scheme == "file", isAllowedLocalResource(url) {
                decisionHandler(.allow)
            } else {
                decisionHandler(.cancel)
            }
        }

        private func isAllowedLocalResource(_ url: URL) -> Bool {
            guard let baseURL else { return false }
            let base = baseURL.standardizedFileURL.path
            let path = url.standardizedFileURL.path
            return path == base || path.hasPrefix(base.hasSuffix("/") ? base : base + "/")
        }

        func webView(_ webView: WKWebView,
                     createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction,
                     windowFeatures: WKWindowFeatures) -> WKWebView? {
            nil
        }

        // MARK: Bridge

        func userContentController(_ controller: WKUserContentController,
                                   didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any],
                  let type = body["type"] as? String else {
                return
            }
            switch type {
            case "sendPrompt":
                guard let text = body["text"] as? String else { return }
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                // 防护：单次最长 4 KB，防止 widget 不小心 / 故意推一个
                // 巨大 prompt 进 composer。
                guard !trimmed.isEmpty, trimmed.count <= 4096 else { return }
                Task { @MainActor [weak appState] in
                    guard let appState else { return }
                    appState.recordAgentImageChoiceFromWidget(
                        widgetID: self.widgetID,
                        widgetTitle: self.widgetTitle,
                        prompt: trimmed
                    )
                    appState.agentInput = self.promptWithWidgetContext(trimmed)
                    appState.sendAgentMessage()
                }
            case "sendToolAction":
                guard let action = widgetToolAction(from: body) else { return }
                Task { @MainActor [weak appState] in
                    guard let appState else { return }
                    appState.recordAgentWidgetToolAction(action)
                    appState.recordAgentImageChoiceFromWidget(
                        widgetID: self.widgetID,
                        widgetTitle: self.widgetTitle,
                        prompt: action.userPromptBlock
                    )
                    appState.previewAgentWidgetToolActionLocally(action)
                    appState.agentInput = action.userPromptBlock
                    appState.sendAgentMessage()
                }
            case "height":
                guard let raw = body["value"] as? CGFloat else {
                    if let intRaw = body["value"] as? Int {
                        onHeightChange(CGFloat(intRaw))
                    } else if let doubleRaw = body["value"] as? Double {
                        onHeightChange(CGFloat(doubleRaw))
                    }
                    return
                }
                onHeightChange(raw)
            default:
                // Ignore unknown event types — defense against a future
                // widget trying to abuse the channel.
                break
            }
        }

        private func promptWithWidgetContext(_ prompt: String) -> String {
            """
            <widget-action>
            action: widget_send_prompt
            widget_id: \(widgetID.uuidString)
            widget_title: \(widgetTitle)
            source: sendPrompt
            \(widgetContext)
            </widget-action>

            \(prompt)
            """
        }

        private func widgetToolAction(from body: [String: Any]) -> AgentWidgetToolAction? {
            let payload = body["action"] as? [String: Any] ?? body
            guard let tool = cleanWidgetActionString(payload["tool"] as? String),
                  tool.count <= 96 else {
                return nil
            }
            let arguments = widgetActionArguments(from: payload["arguments"] ?? payload["args"])
            let note = cleanWidgetActionString(payload["note"] as? String)
            let actionKey = cleanWidgetActionString(
                payload["action_key"] as? String
                    ?? payload["key"] as? String
                    ?? payload["action"] as? String
            )
            guard (arguments?.count ?? 0) <= 4096,
                  (note?.count ?? 0) <= 1024,
                  (actionKey?.count ?? 0) <= 128 else {
                return nil
            }
            return AgentWidgetToolAction(
                widgetID: widgetID,
                widgetTitle: widgetTitle,
                actionKey: actionKey,
                tool: tool,
                arguments: arguments,
                note: note,
                widgetContext: widgetContext
            )
        }

        private func widgetActionArguments(from value: Any?) -> String? {
            if let stringValue = cleanWidgetActionString(value as? String) {
                return stringValue
            }
            guard let value,
                  JSONSerialization.isValidJSONObject(value),
                  let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
                  let json = String(data: data, encoding: .utf8) else {
                return nil
            }
            return cleanWidgetActionString(json)
        }

        private func cleanWidgetActionString(_ value: String?) -> String? {
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return trimmed.isEmpty ? nil : trimmed
        }
    }
}
