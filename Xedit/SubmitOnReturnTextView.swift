//
//  SubmitOnReturnTextView.swift
//  WillDeep
//
//  多行输入框：Return 提交，Shift/Option/Control + Return 换行。
//
//  SwiftUI 的 `TextEditor` 无法拦截 Return —— 回车永远只是插入换行，
//  于是每个用它做输入框的面板都只能靠鼠标点「发送」。这里用一个极简的
//  NSTextView 桥接补上这个键位：圆桌、调度台的目标指令与节点接管输入框
//  共用同一份实现，行为一致。
//
//  与 `ComposerTextEditor` 的分工：那个是主 Composer 的完整形态（历史
//  回溯、/ @ $ 面板、图片粘贴），需要十几个 binding；这里只要"多行 +
//  回车发送"的场景不必付那份复杂度。
//

import AppKit
import SwiftUI

struct SubmitOnReturnTextView: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    var fontSize: CGFloat = 13.5
    let onSubmit: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, onSubmit: onSubmit)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder

        let textView = SubmitOnReturnNSTextView(frame: .zero)
        textView.delegate = context.coordinator
        textView.font = .systemFont(ofSize: fontSize)
        textView.textColor = .textColor
        textView.isRichText = false
        textView.isEditable = context.environment.isEnabled
        textView.isSelectable = true
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.textContainerInset = NSSize(width: 8, height: 7)
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.placeholder = placeholder
        textView.string = text
        scrollView.documentView = textView
        context.coordinator.lastPublishedText = text
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = nsView.documentView as? SubmitOnReturnNSTextView else { return }
        context.coordinator.onSubmit = onSubmit
        textView.placeholder = placeholder
        textView.isEditable = context.environment.isEnabled
        if textView.font?.pointSize != fontSize {
            textView.font = .systemFont(ofSize: fontSize)
        }
        guard textView.string != text else { return }
        guard text != context.coordinator.lastPublishedText else { return }
        guard !textView.hasMarkedText() else { return }
        textView.string = text
        context.coordinator.lastPublishedText = text
        textView.needsDisplay = true
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        private var text: Binding<String>
        var onSubmit: () -> Void
        var lastPublishedText = ""

        init(text: Binding<String>, onSubmit: @escaping () -> Void) {
            self.text = text
            self.onSubmit = onSubmit
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            lastPublishedText = textView.string
            text.wrappedValue = textView.string
            textView.needsDisplay = true
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard commandSelector == #selector(NSResponder.insertNewline(_:)) else { return false }
            // 这个输入框只有一种提交，没有排队和立即发送的去处，所以只有裸回车
            // 算提交，⌘↩ 和 ⌥↩ 在这里仍是换行。
            guard SubmitOnReturnKeyPolicy.action(
                modifiers: NSEvent.modifierFlags,
                hasMarkedText: textView.hasMarkedText()
            ) == .send else {
                return false
            }
            onSubmit()
            return true
        }
    }
}

/// 一次回车要做的事。三档发送方式的含义不随回合忙闲变化：`send` 是今天的
/// 默认（空闲立刻发、忙碌入队），`sendNow` 要求这条马上生效，`enqueue` 要求
/// 先排着。`newline` 只换行。
enum ComposerReturnAction: Equatable {
    case send
    case sendNow
    case enqueue
    case newline
}

/// 回车键归属的判定单独抽出来，方便直接测：输入法组字期间的回车属于候选
/// 词上屏，绝不能当成发送——中文用户每打一个词都会按到它。
nonisolated enum SubmitOnReturnKeyPolicy {
    /// `treatsMarkedTextAsComposition` 为真时，组字期间的回车一律上屏。
    /// composer 的输入框历史上不看这个标记（组字回车由文本视图自己消化），
    /// 传 `false` 保持原行为，不要借这次键位改动顺手改掉它。
    static func action(
        modifiers: NSEvent.ModifierFlags,
        hasMarkedText: Bool,
        treatsMarkedTextAsComposition: Bool = true
    ) -> ComposerReturnAction {
        if treatsMarkedTextAsComposition, hasMarkedText { return .newline }
        let flags = modifiers.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command) { return .sendNow }
        if flags.contains(.option) { return .enqueue }
        if flags.contains(.shift) || flags.contains(.control) { return .newline }
        return .send
    }

    static func submits(modifiers: NSEvent.ModifierFlags, hasMarkedText: Bool) -> Bool {
        action(modifiers: modifiers, hasMarkedText: hasMarkedText) == .send
    }
}

private final class SubmitOnReturnNSTextView: NSTextView {
    var placeholder = "" {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholder.isEmpty else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font ?? NSFont.systemFont(ofSize: 13.5),
            .foregroundColor: NSColor.placeholderTextColor,
        ]
        let origin = NSPoint(x: textContainerInset.width, y: textContainerInset.height)
        placeholder.draw(at: origin, withAttributes: attributes)
    }
}
