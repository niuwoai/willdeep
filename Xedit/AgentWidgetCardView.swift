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
//   2. **Navigation 拦截**：`decidePolicyFor navigationAction` 全部
//      `.cancel`。点击 <a href> 不会跳走（外链改成"复制到剪贴板"或
//      丢弃；MVP 直接丢弃）。
//   3. **scheme 黑名单**：`file://` `ws://` `wss://` 全部拒。
//   4. **JS 通信**：MVP **不**接 WKScriptMessageHandler，widget 不能反
//      向调 Swift。phase 2 加 `sendPrompt(text)` 时再开。
//   5. **主题 CSS 变量注入**：跟随 SwiftUI 当前 colorScheme 注入
//      `--bg --fg --accent --secondary`，widget 写 `var(--fg)` 就能
//      自动适配。
//

import SwiftUI
import WebKit

struct AgentWidgetCardView: View {
    let widget: AgentWidget

    @State private var expanded: Bool = true
    @Environment(\.colorScheme) private var colorScheme

    /// Card 内 WKWebView 的可调高度。Web 视图本身高度不容易由内容
    /// 撑开（needs JS measurement），MVP 给一个固定高度让用户拖。
    @State private var height: CGFloat = 360

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if expanded {
                AgentWidgetWebView(html: composedHTML, height: $height)
                    .frame(height: height)
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.primary.opacity(0.06), lineWidth: 1)
                    )
                resizeHandle
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

    // MARK: - Subviews

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
            Text("· Sandbox: no network, no navigation")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Spacer(minLength: 4)
        }
    }

    /// 简易拖动调高度的小灰条。WKWebView 自身没有 intrinsic content
    /// height（HTML 文档高度需要 JS 测，phase 2 加），现在让用户手动调。
    private var resizeHandle: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.08))
            .frame(height: 6)
            .clipShape(RoundedRectangle(cornerRadius: 3))
            .gesture(
                DragGesture()
                    .onChanged { value in
                        let next = height + value.translation.height
                        height = max(120, min(900, next))
                    }
            )
            .help("Drag to resize")
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

    // MARK: - Composed HTML with CSP + theme

    /// 把 widget.html 包一层 `<html><head>...</head><body>...</body></html>`，
    /// 注入 CSP meta + 主题 CSS 变量。如果 LLM 已经写了完整 doctype，我们
    /// 仍然外包一层 wrapper —— 双重 html 浏览器会无视外层，CSP meta 仍
    /// 生效（最先解析的优先）。
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
        </body>
        </html>
        """
    }
}

// MARK: - WKWebView bridge

private struct AgentWidgetWebView: NSViewRepresentable {
    let html: String
    @Binding var height: CGFloat

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        // No JS evaluation hook into Swift in MVP. Phase 2 adds
        // sendPrompt(text) via WKScriptMessageHandler.
        let preferences = WKWebpagePreferences()
        preferences.allowsContentJavaScript = true
        configuration.defaultWebpagePreferences = preferences

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")
        // Background = transparent so the SwiftUI .thinMaterial backdrop
        // shows through if the HTML doesn't fill the frame.
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        webView.loadHTMLString(html, baseURL: nil)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        /// Block every navigation except the initial loadHTMLString.
        /// `decidePolicyFor` is called for the synthetic `about:blank`
        /// load that backs `loadHTMLString` too — we allow scheme `about`
        /// and `data`, block everything else.
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
            } else {
                // Drop the click on the floor. Phase 2 can route http(s) to
                // the user's default browser via NSWorkspace.shared.open.
                decisionHandler(.cancel)
            }
        }

        // Refuse popups, new windows, JS alerts — sandbox stays in this
        // single embedded view.
        func webView(_ webView: WKWebView,
                     createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction,
                     windowFeatures: WKWindowFeatures) -> WKWebView? {
            nil
        }
    }
}
