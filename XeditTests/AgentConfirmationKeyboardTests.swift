import AppKit
import Testing
@testable import WillDeep

@Suite("确认快捷键")
@MainActor
struct AgentConfirmationKeyboardTests {
    private final class KeyWindow: NSWindow {
        override var isKeyWindow: Bool { true }
    }

    @Test("真实窗口事件限定窗口与修饰键，拆除后停止接收")
    func windowEventsAreScopedAndConsumed() throws {
        let window = KeyWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
                               styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        var decisions = 0
        let view = AgentConfirmationKeyboard.KeyboardView { _ in decisions += 1; return true }
        window.contentView = view
        defer { view.removeMonitor(); window.close() }
        func event(_ flags: NSEvent.ModifierFlags = [], windowNumber: Int? = nil) throws -> NSEvent {
            try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                timestamp: 0, windowNumber: windowNumber ?? window.windowNumber, context: nil,
                characters: "y", charactersIgnoringModifiers: "y", isARepeat: false, keyCode: 16))
        }
        #expect(view.process(try event(.command)) != nil)
        #expect(view.process(try event(windowNumber: 0)) != nil)
        #expect(decisions == 0)
        #expect(view.process(try event()) == nil)
        #expect(decisions == 1)
        view.removeMonitor()
        #expect(view.process(try event()) != nil)
        #expect(decisions == 1)
    }

    @Test("选项数字受边界约束，Y/N 支持大小写，A 只能在可长期授权时使用")
    func keysRespectAvailableActions() {
        #expect(AgentConfirmationKey.parse("2", optionCount: 3, isQuestion: true, allowsAlways: false) == .option(1))
        #expect(AgentConfirmationKey.parse("4", optionCount: 3, isQuestion: true, allowsAlways: false) == nil)
        #expect(AgentConfirmationKey.parse("0", optionCount: 3, isQuestion: true, allowsAlways: false) == nil)
        #expect(AgentConfirmationKey.parse("Y", optionCount: 0, isQuestion: false, allowsAlways: false) == .allow)
        #expect(AgentConfirmationKey.parse("n", optionCount: 0, isQuestion: false, allowsAlways: false) == .deny)
        #expect(AgentConfirmationKey.parse("A", optionCount: 0, isQuestion: false, allowsAlways: true) == .alwaysAllow)
        #expect(AgentConfirmationKey.parse("a", optionCount: 0, isQuestion: false, allowsAlways: false) == nil)
        #expect(AgentConfirmationKey.parse("a", optionCount: 3, isQuestion: true, allowsAlways: true) == nil)
        #expect(AgentConfirmationKey.parse("1", optionCount: 0, isQuestion: false, allowsAlways: false) == nil)
    }

    @Test("已有草稿、其他文本框和输入法组字不会被确认快捷键截走")
    func textEditingRetainsKeys() {
        let composer = ComposerNSTextView(frame: .zero)
        #expect(AgentConfirmationKey.permitsTextResponder(composer))
        composer.string = "正文"
        #expect(!AgentConfirmationKey.permitsTextResponder(composer))
        #expect(!AgentConfirmationKey.permitsTextResponder(NSTextView(frame: .zero)))
        composer.string = ""
        composer.setMarkedText("拼", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(!AgentConfirmationKey.permitsTextResponder(composer))
    }
}
