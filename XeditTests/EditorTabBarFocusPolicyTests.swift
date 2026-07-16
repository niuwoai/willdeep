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
}
