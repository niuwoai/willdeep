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

    /// 逐行解析:先识别块级(标题 `#`、无序/有序列表),其余行走 inline-only Markdown。
    /// 按行解析既保留讨论正文原有的空行,也避免整段 `.full` 解析吞掉空行/破坏选择;
    /// 而块级识别让主持人轮次小结的标题分级、列表缩进真正呈现,而非露出 `#` / `-` 标记。
    private static func attributedLine(from raw: String) -> NSAttributedString {
        if let heading = headingMatch(raw) {
            // 标题整行按层级放大加粗;标记不外露。
            return inlineAttributed(from: heading.text, base: headingAttributes(level: heading.level))
        }
        if let item = listItemMatch(raw) {
            let attrs = listAttributes(indent: item.indent)
            let result = NSMutableAttributedString(string: item.marker, attributes: attrs)
            result.append(inlineAttributed(from: item.text, base: attrs))
            return result
        }
        return inlineAttributed(from: raw, base: baseAttributes)
    }

    /// 行内 Markdown(加粗/斜体/代码)烘焙为富文本;标记不外露,保留字符级选择。
    /// `base` 决定底色字号,标题/列表传入各自的属性,强调字号随之适配。
    private static func inlineAttributed(
        from raw: String,
        base: [NSAttributedString.Key: Any]
    ) -> NSAttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        )
        guard let parsed = try? AttributedString(markdown: raw, options: options) else {
            return NSAttributedString(string: raw, attributes: base)
        }

        let visible = String(parsed.characters)
        let result = NSMutableAttributedString(string: visible, attributes: base)
        let baseFontValue = (base[.font] as? NSFont) ?? bodyFont
        let baseSize = baseFontValue.pointSize
        // 已经是标题这类加粗字重时,行内 strong 不再降级为普通 semibold。
        let baseIsBold = baseFontValue.fontDescriptor.symbolicTraits.contains(.bold)
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
                        .font: NSFont.monospacedSystemFont(ofSize: baseSize - 0.5, weight: .regular),
                        .backgroundColor: NSColor.labelColor.withAlphaComponent(0.08),
                        .baselineOffset: 1,
                    ], range: range)
                } else if intent.contains(.stronglyEmphasized), !baseIsBold {
                    result.addAttribute(
                        .font,
                        value: NSFont.systemFont(ofSize: baseSize, weight: .semibold),
                        range: range
                    )
                } else if intent.contains(.emphasized) {
                    let italic = NSFontManager.shared.convert(
                        NSFont.systemFont(ofSize: baseSize),
                        toHaveTrait: .italicFontMask
                    )
                    result.addAttribute(.font, value: italic, range: range)
                }
            }
        }

        return result
    }

    // MARK: - 块级识别

    /// `## 标题` → (层级, 去掉 # 和空格的正文)。1–6 级,超出按普通行。
    private static func headingMatch(_ line: String) -> (level: Int, text: String)? {
        let trimmed = line.drop(while: { $0 == " " })
        var level = 0
        var idx = trimmed.startIndex
        while idx < trimmed.endIndex, trimmed[idx] == "#", level < 6 {
            level += 1
            idx = trimmed.index(after: idx)
        }
        guard level > 0, idx < trimmed.endIndex, trimmed[idx] == " " else { return nil }
        let text = trimmed[idx...].trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        return (level, text)
    }

    /// `- 项` / `* 项` / `1. 项` → (缩进层级, 统一项目符号, 正文)。
    private static func listItemMatch(_ line: String) -> (indent: Int, marker: String, text: String)? {
        let leadingSpaces = line.prefix(while: { $0 == " " }).count
        let indent = leadingSpaces / 2   // 每 2 空格算一级缩进
        let body = line.drop(while: { $0 == " " })
        guard let first = body.first else { return nil }

        // 无序:- * +
        if "-*+".contains(first) {
            let after = body.dropFirst()
            guard after.first == " " else { return nil }
            let text = String(after.dropFirst())
            guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
            return (indent, "•  ", text)
        }

        // 有序:1. 2. …
        if first.isNumber {
            var digits = ""
            var idx = body.startIndex
            while idx < body.endIndex, body[idx].isNumber {
                digits.append(body[idx])
                idx = body.index(after: idx)
            }
            guard idx < body.endIndex, body[idx] == ".", digits.count <= 3 else { return nil }
            let afterDot = body.index(after: idx)
            guard afterDot < body.endIndex, body[afterDot] == " " else { return nil }
            let text = String(body[body.index(after: afterDot)...])
            guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
            return (indent, "\(digits).  ", text)
        }

        return nil
    }

    private static func headingAttributes(level: Int) -> [NSAttributedString.Key: Any] {
        let size: CGFloat
        let weight: NSFont.Weight
        switch level {
        case 1: size = 18; weight = .bold
        case 2: size = 15.5; weight = .bold
        default: size = 14; weight = .semibold
        }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 2
        paragraph.paragraphSpacingBefore = 5
        paragraph.paragraphSpacing = 2
        return [
            .font: NSFont.systemFont(ofSize: size, weight: weight),
            .foregroundColor: NSColor.textColor,
            .paragraphStyle: paragraph,
        ]
    }

    /// 列表项:悬挂缩进,换行文字对齐到项目符号之后而非回到最左。
    private static func listAttributes(indent: Int) -> [NSAttributedString.Key: Any] {
        let base = CGFloat(indent) * 14
        let hang: CGFloat = 16
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 2
        paragraph.firstLineHeadIndent = base
        paragraph.headIndent = base + hang
        return [
            .font: bodyFont,
            .foregroundColor: NSColor.textColor,
            .paragraphStyle: paragraph,
        ]
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
        case .legal: return Color(nsColor: .systemPurple)
        case .research: return Color(nsColor: .systemCyan)
        case .growth: return Color(nsColor: .systemGreen)
        case .operations: return Color(nsColor: .systemBrown)
        }
    }

    /// 自带专家没有专属色,按 id 的稳定散列从调色板里取一个;同一位专家整场一个颜色。
    private static let customPalette: [Color] = [
        Color(nsColor: .systemTeal), Color(nsColor: .systemIndigo), Color(nsColor: .systemPink),
        Color(nsColor: .systemOrange), Color(nsColor: .systemGreen), Color(nsColor: .systemPurple),
        Color(nsColor: .systemBlue), Color(nsColor: .systemBrown),
    ]

    static func accent(for seat: RoundtableSeat) -> Color {
        switch seat {
        case .builtin(let role): return accent(for: role)
        case .custom(let expert):
            let hash = expert.id.unicodeScalars.reduce(UInt32(5_381)) { ($0 &* 33) &+ UInt32($1.value) }
            return customPalette[Int(hash % UInt32(customPalette.count))]
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
        case .support: return "hand.thumbsup.fill"
        case .oppose: return "hand.thumbsdown.fill"
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

/// 席位头像(1.412.0-rc1):内置专家用矢量头像,自带专家(插件带来的)画首字圆标,
/// 颜色按 id 稳定取色;活跃态的脉冲点与内置专家一致。
struct RoundtableSeatAvatar: View {
    let seat: RoundtableSeat
    var size: CGFloat = 38
    var isActive = false
    @State private var pulse = false

    var body: some View {
        switch seat {
        case .builtin(let role):
            RoundtableExpertAvatar(role: role, size: size, isActive: isActive)
        case .custom(let expert):
            let accent = RoundtableVisuals.accent(for: seat)
            ZStack {
                Circle().fill(accent.opacity(0.16))
                Text(expert.avatarInitial)
                    .font(.system(size: max(10, size * 0.42), weight: .semibold))
                    .foregroundStyle(accent)
            }
            .frame(width: size, height: size)
            .overlay(Circle().stroke(accent, lineWidth: isActive ? 2.5 : 1))
            .overlay(alignment: .bottomTrailing) {
                if isActive {
                    Circle()
                        .fill(accent)
                        .frame(width: max(8, size * 0.24), height: max(8, size * 0.24))
                        .overlay(Circle().stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 2))
                        .scaleEffect(pulse ? 1.16 : 0.86)
                }
            }
            .shadow(color: isActive ? accent.opacity(0.45) : .clear, radius: 7)
            .onAppear {
                guard isActive else { return }
                withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { pulse = true }
            }
            .onChange(of: isActive) { active in
                if active {
                    withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { pulse = true }
                } else {
                    pulse = false
                }
            }
            .accessibilityLabel(expert.name)
        }
    }
}

// 圆桌的多行输入框（Return 提交）已收敛到共用的 `SubmitOnReturnTextView`
// （见 SubmitOnReturnTextView.swift），调度台的指令输入框用的是同一个。

/// 包装只读 NSTextView，既保留原生文本选择，也把选区实时回传给引用操作。
struct RoundtableSelectableMessageText: NSViewRepresentable {
    let text: String
    let onSelectionChange: (String?) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onSelectionChange: onSelectionChange)
    }

    func makeNSView(context: Context) -> NSTextView {
        let textView = NSTextView(frame: .zero)
        textView.delegate = context.coordinator
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.drawsBackground = false
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.heightTracksTextView = false
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.minSize = .zero
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textStorage?.setAttributedString(
            RoundtableMarkdownTextRenderer.attributedString(from: text)
        )
        context.coordinator.renderedSource = text
        return textView
    }

    func updateNSView(_ textView: NSTextView, context: Context) {
        context.coordinator.onSelectionChange = onSelectionChange
        if context.coordinator.renderedSource != text {
            textView.textStorage?.setAttributedString(
                RoundtableMarkdownTextRenderer.attributedString(from: text)
            )
            context.coordinator.renderedSource = text
            context.coordinator.invalidateMeasurement()
            textView.invalidateIntrinsicContentSize()
        }
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView textView: NSTextView,
        context: Context
    ) -> CGSize? {
        guard let width = proposal.width, width.isFinite, width > 1 else {
            // nil/无界/零宽的探测提议不能返回 nil：那会回退到 frame 为 .zero 的
            // NSTextView，理想宽度被当成 ~0，HStack 便把整列分给相邻的贪婪
            // Spacer，CJK 文本（任意两字间可断行）塌成一字一列的竖排。
            // 改为应答文本的自然尺寸，让气泡在探测阶段就占住应有宽度。
            return context.coordinator.naturalSize(textView)
        }
        return context.coordinator.sizeThatFits(textView, width: width)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        private static let minimumHeight: CGFloat = 22
        private static let measurementTolerance: CGFloat = 0.5
        /// 自然宽度测量上限：气泡 `.frame(maxWidth: 660)` 减去水平 padding 13pt×2。
        private static let maximumNaturalWidth: CGFloat = 634

        var onSelectionChange: (String?) -> Void
        var renderedSource: String?
        private var measuredWidth: CGFloat?
        private var measuredHeight: CGFloat?
        private var naturalMeasurement: CGSize?
        private var selectedText: String?

        init(onSelectionChange: @escaping (String?) -> Void) {
            self.onSelectionChange = onSelectionChange
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            let range = textView.selectedRange()
            guard range.length > 0,
                  range.location != NSNotFound,
                  NSMaxRange(range) <= (textView.string as NSString).length else {
                publishSelection(nil)
                return
            }
            let value = (textView.string as NSString)
                .substring(with: range)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            publishSelection(value.isEmpty ? nil : value)
        }

        private func publishSelection(_ value: String?) {
            guard value != selectedText else { return }
            selectedText = value
            onSelectionChange(value)
        }

        func invalidateMeasurement() {
            measuredWidth = nil
            measuredHeight = nil
            naturalMeasurement = nil
        }

        /// 无有效宽度提议（理想/最小尺寸探测）时的应答：按测量上限排版一次，
        /// 返回实际使用宽度（短文本贴合、长文本封顶），避免被判定为零宽视图。
        func naturalSize(_ textView: NSTextView) -> CGSize {
            if let naturalMeasurement {
                return naturalMeasurement
            }
            guard let container = textView.textContainer,
                  let layoutManager = textView.layoutManager else {
                return CGSize(width: Self.minimumHeight, height: Self.minimumHeight)
            }

            container.containerSize = NSSize(
                width: Self.maximumNaturalWidth,
                height: CGFloat.greatestFiniteMagnitude
            )
            layoutManager.ensureLayout(for: container)
            let used = layoutManager.usedRect(for: container)
            let size = CGSize(
                width: max(1, ceil(used.width)),
                height: max(Self.minimumHeight, ceil(used.height + 2))
            )
            naturalMeasurement = size
            return size
        }

        func sizeThatFits(_ textView: NSTextView, width: CGFloat) -> CGSize {
            if let measuredWidth,
               let measuredHeight,
               abs(measuredWidth - width) <= Self.measurementTolerance {
                return CGSize(width: width, height: measuredHeight)
            }

            guard let container = textView.textContainer,
                  let layoutManager = textView.layoutManager else {
                return CGSize(width: width, height: Self.minimumHeight)
            }

            container.containerSize = NSSize(
                width: width,
                height: CGFloat.greatestFiniteMagnitude
            )
            layoutManager.ensureLayout(for: container)
            let usedHeight = layoutManager.usedRect(for: container).height
            let height = max(Self.minimumHeight, ceil(usedHeight + 2))
            measuredWidth = width
            measuredHeight = height
            return CGSize(width: width, height: height)
        }
    }
}
