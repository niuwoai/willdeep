import AppKit
import Testing
@testable import WillDeep

@Suite("折叠工具摘要总行数")
@MainActor
struct AgentCollapsedToolSummaryLayoutTests {
    private func summary(isExpanded: Bool) -> NSAttributedString {
        let names = ["create_file", "edit_file", "read_file", "run_command", "custom_tool", "another_tool"]
        let calls = names.enumerated().map { index, name in
            AgentMessageToolCall(externalID: "call-\(index)", toolName: name,
                argumentsJSON: #"{"path":"private/file.txt","command":"git status"}"#)
        }
        let output = NSMutableAttributedString(string: "")
        AgentChatHistoryRenderer.appendToolCallGroup(
            .init(inlineMessageIDs: [UUID()], calls: calls), isExpanded: isExpanded, to: output,
            bodyFont: .systemFont(ofSize: 14), monoFont: .monospacedSystemFont(ofSize: 14, weight: .regular),
            lineSpacing: 3, secondaryColor: .secondaryLabelColor)
        return output
    }

    @Test("多分类摘要在窄、中、宽布局里仅占一行", arguments: [180.0, 420.0, 900.0])
    func collapsedFitsOneLine(width: Double) throws {
        let text = summary(isExpanded: false)
        #expect(!text.string.contains("\n"))
        #expect(!text.string.contains("private/file.txt"))
        let lines = lineFragmentHeights(in: text, width: width,
            intersecting: NSRange(location: 0, length: text.length))
        #expect(lines.count == 1)

        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: 64))
        view.isEditable = false
        view.drawsBackground = true
        view.backgroundColor = .white
        view.textStorage?.setAttributedString(text)
        let container = try #require(view.textContainer)
        view.layoutManager?.ensureLayout(for: container)
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: URL(fileURLWithPath: "/private/tmp/xedit-collapsed-tool-summary-\(Int(width)).png"))
    }

    @Test("展开后完整分类与工具参数仍可查看")
    func expandedRetainsDetails() {
        let text = summary(isExpanded: true)
        #expect(text.string.split(separator: "\n").count > 2)
        #expect(text.string.contains("create_file"))
        #expect(text.string.contains("read_file"))
        #expect(text.string.contains("private/file.txt"))
    }
}
