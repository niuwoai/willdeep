//
//  RoundtableDiscussionComponents.swift
//  WillDeep
//
//  专家圆桌的视觉身份、可提交多行输入框与划词引用文本。
//

import AppKit
import SwiftUI

enum RoundtableMarkdownTextRenderer {
    private static let bodyFont = NSFont.systemFont(ofSize: 14)

    /// 将专家回复里的行内 Markdown 烘焙为 TextKit 富文本。
    /// 文本仍由原生 NSTextView 承载，因此加粗/斜体/代码不再露出标记，
    /// 同时保留字符级选择，选中的内容可以原样进入引用草稿。
    static func attributedString(from raw: String) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let lines = raw.components(separatedBy: "\n")
        for (index, line) in lines.enumerated() {
            result.append(attributedLine(from: line))
            if index < lines.count - 1 {
                result.append(NSAttributedString(string: "\n", attributes: baseAttributes))
            }
        }
        return result
    }

    /// `inlineOnlyPreservingWhitespace` 不接受完整的多段 Markdown 文档。
    /// 按行解析既能保留讨论正文原有的空行，也避免主持人轮次小结因含多个
    /// Markdown 段落而整体回退成带 `**` 标记的纯文本。
    private static func attributedLine(from raw: String) -> NSAttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        )
        guard let parsed = try? AttributedString(markdown: raw, options: options) else {
            return NSAttributedString(string: raw, attributes: baseAttributes)
        }

        let visible = String(parsed.characters)
        let result = NSMutableAttributedString(string: visible, attributes: baseAttributes)
        var characterOffset = 0

        for run in parsed.runs {
            let characterCount = parsed.characters[run.range].count
            defer { characterOffset += characterCount }
            guard characterCount > 0 else { continue }

            let lower = visible.index(visible.startIndex, offsetBy: characterOffset)
            let upper = visible.index(lower, offsetBy: characterCount)
            let range = NSRange(lower..<upper, in: visible)

            if let intent = run.inlinePresentationIntent {
                if intent.contains(.code) {
                    result.addAttributes([
                        .font: NSFont.monospacedSystemFont(ofSize: 13.5, weight: .regular),
                        .backgroundColor: NSColor.labelColor.withAlphaComponent(0.08),
                        .baselineOffset: 1,
                    ], range: range)
                } else if intent.contains(.stronglyEmphasized) {
                    result.addAttribute(
                        .font,
                        value: NSFont.systemFont(ofSize: 14, weight: .semibold),
                        range: range
                    )
                } else if intent.contains(.emphasized) {
                    let italic = NSFontManager.shared.convert(
                        bodyFont,
                        toHaveTrait: .italicFontMask
                    )
                    result.addAttribute(.font, value: italic, range: range)
                }
            }
        }

        return result
    }

    private static var baseAttributes: [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 2
        return [
            .font: bodyFont,
            .foregroundColor: NSColor.textColor,
            .paragraphStyle: paragraph,
        ]
    }
}

enum RoundtableVisuals {
    static func accent(for role: AgentRoundtableExpertRole) -> Color {
        switch role {
        case .product: return Color(nsColor: .systemTeal)
        case .architecture: return Color(nsColor: .systemBlue)
        case .finance: return Color(nsColor: .systemPink)
        case .risk: return Color(nsColor: .systemOrange)
        case .strategy: return Color(nsColor: .systemIndigo)
        case .psychology: return Color(nsColor: .systemMint)
        }
    }

    static func color(for stance: RoundtableOSR.Stance) -> Color {
        switch stance {
        case .support: return Color(nsColor: .systemGreen)
        case .oppose: return Color(nsColor: .systemRed)
        case .neutral: return Color(nsColor: .systemBlue)
        case .undecided: return Color(nsColor: .systemOrange)
        }
    }

    static func symbol(for stance: RoundtableOSR.Stance) -> String {
        switch stance {
        case .support: return "checkmark.circle.fill"
        case .oppose: return "xmark.octagon.fill"
        case .neutral: return "equal.circle.fill"
        case .undecided: return "questionmark.circle.fill"
        }
    }
}

struct RoundtableExpertAvatar: View {
    let role: AgentRoundtableExpertRole
    var size: CGFloat = 38
    var isActive = false
    @State private var pulse = false

    var body: some View {
        Image(role.avatarAssetName)
            .resizable()
            .scaledToFill()
            .frame(width: size, height: size)
            .clipShape(Circle())
            .overlay {
                Circle()
                    .stroke(RoundtableVisuals.accent(for: role), lineWidth: isActive ? 2.5 : 1)
            }
            .overlay(alignment: .bottomTrailing) {
                if isActive {
                    Circle()
                        .fill(RoundtableVisuals.accent(for: role))
                        .frame(width: max(8, size * 0.24), height: max(8, size * 0.24))
                        .overlay(Circle().stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 2))
                        .scaleEffect(pulse ? 1.16 : 0.86)
                }
            }
            .shadow(
                color: isActive ? RoundtableVisuals.accent(for: role).opacity(0.45) : .clear,
                radius: 7
            )
            .onAppear {
                guard isActive else { return }
                withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                    pulse = true
                }
            }
            .onChange(of: isActive) { active in
                if active {
                    withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                        pulse = true
                    }
                } else {
                    pulse = false
                }
            }
            .accessibilityLabel(role.displayName)
    }
}

/// macOS 13 可用的多行输入框：Return 提交，Shift/Option/Control + Return 换行。
struct RoundtableComposerTextView: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
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

        let textView = RoundtableComposerNSTextView(frame: .zero)
        textView.delegate = context.coordinator
        textView.font = .systemFont(ofSize: 13.5)
        textView.textColor = .textColor
        textView.isRichText = false
        textView.isEditable = true
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
        guard let textView = nsView.documentView as? RoundtableComposerNSTextView else { return }
        context.coordinator.onSubmit = onSubmit
        textView.placeholder = placeholder
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
            let modifiers = NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let wantsLineBreak = modifiers.contains(.shift)
                || modifiers.contains(.option)
                || modifiers.contains(.control)
            guard !wantsLineBreak else { return false }
            onSubmit()
            return true
        }
    }
}

private final class RoundtableComposerNSTextView: NSTextView {
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

/// 包装只读 NSTextView，既保留原生文本选择，也把选区实时回传给引用操作。
struct RoundtableSelectableMessageText: NSViewRepresentable {
    let text: String
    @Binding var measuredHeight: CGFloat
    let onSelectionChange: (String?) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(height: $measuredHeight, onSelectionChange: onSelectionChange)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder

        let textView = NSTextView(frame: .zero)
        textView.delegate = context.coordinator
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.drawsBackground = false
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textStorage?.setAttributedString(
            RoundtableMarkdownTextRenderer.attributedString(from: text)
        )
        context.coordinator.renderedSource = text
        scrollView.documentView = textView
        context.coordinator.measure(textView)
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = nsView.documentView as? NSTextView else { return }
        context.coordinator.onSelectionChange = onSelectionChange
        if context.coordinator.renderedSource != text {
            textView.textStorage?.setAttributedString(
                RoundtableMarkdownTextRenderer.attributedString(from: text)
            )
            context.coordinator.renderedSource = text
        }
        context.coordinator.measure(textView)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        private var height: Binding<CGFloat>
        var onSelectionChange: (String?) -> Void
        var renderedSource: String?

        init(height: Binding<CGFloat>, onSelectionChange: @escaping (String?) -> Void) {
            self.height = height
            self.onSelectionChange = onSelectionChange
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            let range = textView.selectedRange()
            guard range.length > 0,
                  range.location != NSNotFound,
                  NSMaxRange(range) <= (textView.string as NSString).length else {
                onSelectionChange(nil)
                return
            }
            let value = (textView.string as NSString)
                .substring(with: range)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            onSelectionChange(value.isEmpty ? nil : value)
        }

        func measure(_ textView: NSTextView) {
            DispatchQueue.main.async { [weak self, weak textView] in
                guard let self, let textView, let container = textView.textContainer else { return }
                let width = max(1, textView.enclosingScrollView?.contentSize.width ?? textView.bounds.width)
                container.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
                textView.layoutManager?.ensureLayout(for: container)
                let used = textView.layoutManager?.usedRect(for: container).height ?? 20
                let next = max(22, ceil(used + 2))
                if abs(self.height.wrappedValue - next) > 0.5 {
                    self.height.wrappedValue = next
                }
            }
        }
    }
}
