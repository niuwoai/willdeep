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
    let createdAt: Date

    init(
        id: UUID = UUID(),
        title: String,
        html: String,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.html = html
        self.createdAt = createdAt
    }

    /// Rough byte count of the rendered HTML — used by the card footer
    /// so the user can spot when the LLM accidentally generated 500 KB
    /// of inline data.
    var byteCount: Int { html.utf8.count }
}
