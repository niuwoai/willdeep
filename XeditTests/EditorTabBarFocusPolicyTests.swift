import Foundation
import Testing

@Suite("Editor tab-bar focus policy")
struct EditorTabBarFocusPolicyTests {
    @Test("Tab close buttons stay out of the keyboard focus chain")
    func closeButtonIsNotFocusable() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = repositoryRoot
            .appendingPathComponent("Xedit", isDirectory: true)
            .appendingPathComponent("ContentViewEditorChrome.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let tabBar = try #require(source.range(of: "struct EditorTabBar: View"))
        let trailingSource = source[tabBar.lowerBound...]
        let closeAction = try #require(trailingSource.range(of: "onClose(tab.id)"))
        let closeButtonSource = trailingSource[closeAction.lowerBound...]
        let buttonStyle = try #require(closeButtonSource.range(of: ".buttonStyle(.plain)"))
        let focusPolicy = try #require(closeButtonSource.range(of: ".focusable(false)"))

        #expect(focusPolicy.lowerBound > buttonStyle.lowerBound)
        #expect(closeButtonSource.distance(from: buttonStyle.lowerBound, to: focusPolicy.lowerBound) < 80)
    }

    @Test("Focus mode keeps the tab bar visible")
    func focusModeKeepsTabBarVisible() throws {
        // 专注模式曾整体隐藏 EditorTabBar，导致 (1) 无法切换标签,
        // (2) 正文首行顶进窗口红绿灯按钮底下(tab 栏自带 leadingReserve
        // 避让)。钉住:ContentView 里 EditorTabBar 的实例化不允许再被
        // isFocusModeEnabled 直接包裹。
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = repositoryRoot
            .appendingPathComponent("Xedit", isDirectory: true)
            .appendingPathComponent("ContentView.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let tabBar = try #require(source.range(of: "EditorTabBar("))
        let windowStart = source.index(
            tabBar.lowerBound,
            offsetBy: -220,
            limitedBy: source.startIndex
        ) ?? source.startIndex
        let precedingWindow = source[windowStart..<tabBar.lowerBound]

        #expect(!precedingWindow.contains("isFocusModeEnabled"))
    }
}
