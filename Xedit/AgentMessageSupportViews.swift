//
//  AgentMessageSupportViews.swift
//  WillDeep
//
//  Support views and helpers for Agent message bubbles: long-token
//  wrapping, streaming cursor, image-description disclosure, message
//  footer, queued rows, and empty state.
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Insert zero-width breakpoints into runs of unbreakable characters.
///
/// SwiftUI's Text has a hard time with very long tokens that contain
/// no whitespace or hyphens — it'll try to lay out the whole token on
/// one line, fail, and start probing every character position to find
/// a break opportunity. On macOS this manifests as the entire chat
/// pane freezing while scrolling past a message that contains, e.g.,
/// a pnpm-store path listing where each line is a 150-char hash.
enum AgentLongTokenBreaker {
    /// Threshold above which we start inserting breakpoints. Roughly
    /// the width of a chat-bubble column at the default font size, so
    /// anything wider than this would have to wrap anyway.
    private static let threshold = 30

    /// Characters SwiftUI already treats as wrap opportunities. We
    /// only inject breakpoints into runs that contain none of these.
    private static let naturalBreakers: Set<Character> = [
        " ", "\t", "\n", "-", "/", ".", ",", ";", ":", "|", "(", ")",
        "[", "]", "{", "}", "<", ">", "=", "+", "?", "&"
    ]

    /// CJK 文本本来就允许**任意字符间断行**，塞假断点纯属白给。
    ///
    /// 这张表原先只有 ASCII，于是「，。：；（）」和汉字本身都被当成
    /// "不可断行"——任何超过 30 字的中文句子都会被均匀插上 U+200B。
    /// 英文用户偶尔踩，中文界面下是每条消息都踩，也是用户在剪贴板里
    /// 看到 `<200b>` 的主要来源。
    private static func isNaturalBreaker(_ ch: Character) -> Bool {
        if naturalBreakers.contains(ch) { return true }
        guard let scalar = ch.unicodeScalars.first,
              ch.unicodeScalars.count == 1 else {
            return false
        }
        switch scalar.value {
        case 0x2E80...0x303F,   // CJK 部首补充 / 康熙部首 / CJK 标点(、。「」)
             0x3040...0x30FF,   // 平假名 / 片假名
             0x3400...0x4DBF,   // CJK 扩展 A
             0x4E00...0x9FFF,   // CJK 基本区
             0xAC00...0xD7AF,   // 谚文音节
             0xF900...0xFAFF,   // CJK 兼容表意文字
             0xFF00...0xFF60,   // 全角 ASCII(，．：；（）！？)
             0xFF61...0xFF9F,   // 半角片假名
             0x20000...0x3FFFF: // CJK 扩展 B 及以后
            return true
        default:
            return false
        }
    }

    /// LRU keyed by source hash. Same reasoning as for
    /// `AgentUserContentSplitter`: SwiftUI re-evaluates user/
    /// assistant body many times per layout pass, and walking a
    /// 6+ KB string char-by-char on every pass adds up to a freeze.
    private static var cache: [Int: String] = [:]
    private static var cacheOrder: [Int] = []
    private static let cacheLock = NSLock()
    private static let cacheLimit = 128

    static func inject(into source: String) -> String {
        guard source.count > threshold else { return source }

        let key = source.hashValue
        cacheLock.lock()
        let hit = cache[key]
        cacheLock.unlock()
        if let hit { return hit }

        let result = compute(source)

        cacheLock.lock()
        cache[key] = result
        cacheOrder.append(key)
        if cacheOrder.count > cacheLimit {
            let evict = cacheOrder.removeFirst()
            cache.removeValue(forKey: evict)
        }
        cacheLock.unlock()
        return result
    }

    private static func compute(_ source: String) -> String {
        var result = ""
        result.reserveCapacity(source.count + source.count / threshold)
        var runLength = 0

        for ch in source {
            if isNaturalBreaker(ch) {
                result.append(ch)
                runLength = 0
                continue
            }
            if runLength >= threshold {
                result.append("\u{200B}")
                runLength = 0
            }
            result.append(ch)
            runLength += 1
        }
        return result
    }
}

/// 剪贴板出口的净化器：屏幕上可以有排版专用的不可见字符，剪贴板里
/// 一个都不许有。
///
/// 两个来源：
/// 1. `AgentLongTokenBreaker` 为了防止长 token 卡死布局插的 U+200B——
///    它是**渲染态**，跟着复制出去就变成了粘贴到终端/编译器里的隐形
///    地雷。
/// 2. 模型自己吐的零宽字符、BOM、软连字符。模型输出不保证干净，这层
///    顺手一起收了。
///
/// 刻意**不**清理的：U+200D(ZWJ，emoji 组合靠它)、U+200C(ZWNJ，波斯语
/// / 印度语系有语义)、U+200E/200F(双向控制符，RTL 文本靠它)。这些"不
/// 可见"但携带语义，一把梭会把用户的正文改错。
enum AgentCopyTextSanitizer {
    /// 纯排版用途、删掉不改变任何语言语义的不可见字符。
    private static let renderOnlyScalars: Set<UInt32> = [
        0x200B, // ZERO WIDTH SPACE —— 我们自己插的假断点
        0x2060, // WORD JOINER
        0xFEFF, // ZERO WIDTH NO-BREAK SPACE / BOM
        0x00AD, // SOFT HYPHEN
    ]

    static func sanitize(_ text: String) -> String {
        guard text.unicodeScalars.contains(where: { renderOnlyScalars.contains($0.value) }) else {
            return text
        }
        var scalars = String.UnicodeScalarView()
        scalars.reserveCapacity(text.unicodeScalars.count)
        for scalar in text.unicodeScalars where !renderOnlyScalars.contains(scalar.value) {
            scalars.append(scalar)
        }
        return String(scalars)
    }

    /// The transcript draws list markers as `•` / `◦` / `▪`; the clipboard
    /// gets the Markdown dash back so a copied list pastes as a list
    /// everywhere else. Only a marker at the start of a line (after
    /// indentation) followed by a space is touched — a bullet character in
    /// running prose is left alone.
    static func restoringMarkdownListMarkers(_ text: String) -> String {
        guard text.contains(where: { renderedListMarkers.contains($0) }) else { return text }
        return text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> Substring in
                let indent = line.prefix(while: { $0 == " " || $0 == "\t" })
                let rest = line.dropFirst(indent.count)
                guard let first = rest.first,
                      renderedListMarkers.contains(first),
                      rest.dropFirst().first == " " else { return line }
                return Substring(indent + "-" + rest.dropFirst())
            }
            .joined(separator: "\n")
    }

    private static let renderedListMarkers: Set<Character> = ["•", "◦", "▪"]

    /// 会回流给模型的出口（右键「加入任务」、引用选区）专用。
    ///
    /// 先净化再**重新打断注入标记**：`AgentInjectionDefense` 是靠往
    /// `<system-reminder>`、`</command>` 这类标记里插 U+200B 来废掉
    /// tokenizer 的识别的。只 sanitize 不补这一刀，等于把用户选中的
    /// 一段工具输出还原成一个可用的注入载荷再喂回去。
    static func sanitizeForModelRoundTrip(_ text: String) -> String {
        AgentInjectionDefense.neutralizeInjectionMarkers(in: sanitize(text))
    }
}

/// A small blinking bar that follows the assistant's last token. Pure
/// decoration — its parent removes it after output has been idle for
/// `AgentStreamingCursorPolicy.inactivityTimeout`.
/// 闪烁必须走 symbolEffect（渲染服务器驱动），禁用
/// withAnimation(.repeatForever) —— 那会让 SwiftUI 每帧跑一次图事务，
/// 避免状态装饰触发持续的主线程布局与图事务。
struct AgentStreamingCursor: View {
    var body: some View {
        Image(systemName: "rectangle.portrait.fill")
            .font(.system(size: 11))
            .foregroundStyle(Color.accentColor.opacity(0.85))
            .symbolPulseCompat()
            .frame(width: 7, height: 14)
    }
}

enum AgentStreamingCursorPolicy {
    private static let nanosecondsPerSecond: TimeInterval = 1_000_000_000
    static let inactivityTimeout: TimeInterval = 0.5
    static var inactivityTimeoutNanoseconds: UInt64 {
        UInt64(inactivityTimeout * nanosecondsPerSecond)
    }

    static func shouldShow(lastOutputAt: Date, now: Date) -> Bool {
        now.timeIntervalSince(lastOutputAt) < inactivityTimeout
    }
}

// MARK: - Attached prompt prelude

/// `composeAttachedPrompt` glues skill / file / workspace bodies in front
/// of the user's actual text so the model treats them as task setup. The
/// bubble UI should NOT show that full prelude as if the user typed it —
/// after context compression dropped the original turn, the bubble would
/// otherwise read like a giant SKILL.md dump (the rc7 bug report).
///
/// This helper turns the spliced prompt back into something human-shaped:
/// a one-line "📎 attached: ..." tag plus the user's prose.
nonisolated enum AgentAttachedPromptDisplay {
    /// Header emitted by `AppState.composeAttachedPrompt`. Keep in sync.
    static let preludeHeader = AgentAttachedPromptProtocol.preludeHeader

    /// One-line, human-shaped preview of a prompt that may be spliced.
    ///
    /// Splicing happens at *send* time, so anything holding a composed
    /// prompt — a queued message, a gateway snapshot — holds the model-facing
    /// prelude, English protocol header and all. Any surface that shows such
    /// a prompt to a person must go through here: the queue card and the
    /// mobile gateway both used the raw text and displayed
    /// "The user attached the following context for this turn…" where the
    /// operator expected to see their own sentence.
    ///
    /// Returns nil when the prompt is not spliced, so callers keep their own
    /// empty/attachment-count fallbacks for a genuinely empty message.
    static func singleLinePreview(of prompt: String) -> String? {
        let display = transform(prompt)
        guard display.isSplicedPrelude else { return nil }
        let visible = display.visibleContent
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return visible.isEmpty ? nil : visible
    }

    struct Display {
        /// `true` when the content was actually a spliced prelude and we
        /// rewrote it into a compact form. False when this is plain text.
        let isSplicedPrelude: Bool
        /// What the bubble / TextKit body should render. Always non-empty
        /// when `isSplicedPrelude` is true (falls back to a tag-only line
        /// when the user typed nothing alongside the attachments).
        let visibleContent: String
        /// Skill identifiers extracted from the prelude, useful as chips
        /// or tooltips when callers want more than a one-liner.
        let skills: [String]
        /// File paths extracted from the prelude.
        let files: [String]
        /// True when the prelude carried the workspace overview block.
        let hasWorkspace: Bool
        /// The verbatim text the operator typed this turn: the segment after
        /// the user-text boundary for spliced preludes (empty when the user
        /// sent attachments without prose), or the whole content for plain
        /// messages. Unlike `visibleContent` it carries NO host-synthesized
        /// chrome — no "[已附加技能: …]" tag line — so learning/audit mining
        /// must read this field, never `visibleContent`: the tag's own words
        /// ("技能") would re-trigger the skill-capture matchers this field
        /// exists to protect.
        let userAuthoredText: String
    }

    static func transform(_ content: String) -> Display {
        guard beginsWithAttachmentPrelude(content) else {
            return Display(
                isSplicedPrelude: false,
                visibleContent: content,
                skills: [],
                files: [],
                hasWorkspace: false,
                userAuthoredText: content
            )
        }

        var skills: [String] = []
        var files: [String] = []
        var hasWorkspace = false
        let lines = content.components(separatedBy: "\n")
        for line in lines {
            if line.hasPrefix("### Skill: ") {
                skills.append(String(line.dropFirst("### Skill: ".count)).trimmingCharacters(in: .whitespaces))
            } else if line.hasPrefix("### File: ") {
                files.append(String(line.dropFirst("### File: ".count)).trimmingCharacters(in: .whitespaces))
            } else if line.hasPrefix("### Workspace") {
                hasWorkspace = true
            }
        }

        // 新消息使用不可伪造的专用边界。附件正文会在进入 prompt 前
        // 转义该边界，因此 Markdown 自己的 `---` 不会再被误认成用户
        // 正文，导致附件尾部与 </untrusted-attachment> 泄漏到气泡。
        // 旧消息仍兼容 `---`，但有附件时只接受安全信封结束后的分隔线。
        var userText = ""
        if let boundaryIndex = lines.firstIndex(of: AgentAttachedPromptProtocol.userTextBoundary) {
            userText = lines[(boundaryIndex + 1)...]
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } else if let separatorIndex = legacyUserTextSeparatorIndex(in: lines, hasFiles: !files.isEmpty) {
            userText = lines[(separatorIndex + 1)...]
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let tag = attachmentTag(skills: skills, files: files, hasWorkspace: hasWorkspace)
        let visible: String
        if userText.isEmpty {
            visible = tag.isEmpty ? content : tag
        } else if tag.isEmpty {
            visible = userText
        } else {
            visible = "\(tag)\n\(userText)"
        }
        return Display(
            isSplicedPrelude: true,
            visibleContent: visible,
            skills: skills,
            files: files,
            hasWorkspace: hasWorkspace,
            userAuthoredText: userText
        )
    }

    /// Some sessions arrive through another host that uses the same English
    /// attachment preamble but not WillDeep's exact punctuation or suffix.
    /// Treat the stable opening phrase as generated chrome too. If that host
    /// did not preserve our user-text boundary, returning no authored text is
    /// safer than presenting prompt scaffolding as something the user typed.
    private static func beginsWithAttachmentPrelude(_ content: String) -> Bool {
        let firstLine = content
            .components(separatedBy: .newlines)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        return firstLine.hasPrefix(preludeHeader.lowercased())
            || firstLine.hasPrefix("the user attached the following")
    }

    private static func legacyUserTextSeparatorIndex(in lines: [String], hasFiles: Bool) -> Int? {
        guard hasFiles else { return lines.lastIndex(of: "---") }
        guard let envelopeEnd = lines.lastIndex(where: {
            $0.trimmingCharacters(in: .whitespaces) == "</untrusted-attachment>"
        }) else {
            return nil
        }
        return lines.indices.first(where: { $0 > envelopeEnd && lines[$0] == "---" })
    }

    private static func attachmentTag(skills: [String], files: [String], hasWorkspace: Bool) -> String {
        var parts: [String] = []
        if !skills.isEmpty { parts.append("已附加技能: \(skills.joined(separator: ", "))") }
        if !files.isEmpty { parts.append("已附加文件: \(files.joined(separator: ", "))") }
        if hasWorkspace { parts.append("已附加 workspace 概览") }
        guard !parts.isEmpty else { return "" }
        return "[\(parts.joined(separator: " · "))]"
    }
}

// MARK: - User content splitter

/// Pulls the spliced-in image description block out of a user message so
/// the bubble can render the user's own prose at full size and tuck the
/// AI-generated wall of bullets behind a disclosure chip.
nonisolated enum AgentUserContentSplitter {
    struct Split {
        let visible: String
        let description: String?
        let imageCount: Int
        let provider: String?
    }

    /// Matches the header emitted by AppState.contentByAppendingImageDescription.
    /// Capture 1 = provider/model slug, capture 2 = image count.
    private static let headerPattern: NSRegularExpression? = {
        try? NSRegularExpression(
            pattern: #"\[Image description generated by ([^\]]+?) for (\d+) attached image[s]?\]"#,
            options: []
        )
    }()

    /// Tiny LRU keyed by content hash. SwiftUI re-evaluates the user
    /// bubble's `body` many times per layout pass (measure / placement
    /// / cache invalidation cycles); without a cache, every pass
    /// re-runs the regex against the full message content.
    private static var cache: [Int: Split] = [:]
    private static var cacheOrder: [Int] = []
    private static let cacheLock = NSLock()
    private static let cacheLimit = 64

    static func split(_ content: String) -> Split {
        let key = content.hashValue
        cacheLock.lock()
        let hit = cache[key]
        cacheLock.unlock()
        if let hit { return hit }

        let result = computeSplit(content)

        cacheLock.lock()
        cache[key] = result
        cacheOrder.append(key)
        if cacheOrder.count > cacheLimit {
            let evict = cacheOrder.removeFirst()
            cache.removeValue(forKey: evict)
        }
        cacheLock.unlock()
        return result
    }

    private static func computeSplit(_ content: String) -> Split {
        guard let regex = headerPattern else {
            return Split(visible: content, description: nil, imageCount: 0, provider: nil)
        }
        let range = NSRange(content.startIndex..<content.endIndex, in: content)
        guard let match = regex.firstMatch(in: content, options: [], range: range) else {
            return Split(visible: content, description: nil, imageCount: 0, provider: nil)
        }
        guard let headerRange = Range(match.range, in: content),
              let providerRange = Range(match.range(at: 1), in: content),
              let countRange = Range(match.range(at: 2), in: content) else {
            return Split(visible: content, description: nil, imageCount: 0, provider: nil)
        }
        let visible = String(content[..<headerRange.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let description = String(content[headerRange.upperBound...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let provider = String(content[providerRange])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let imageCount = Int(content[countRange]) ?? 0
        return Split(
            visible: visible,
            description: description.isEmpty ? nil : description,
            imageCount: imageCount,
            provider: provider
        )
    }
}

/// Collapsed chip + on-demand body for the image description block. Lives
/// inside the user bubble (white-on-accent), so we tint everything against
/// the white text color and keep the chip itself tiny so it doesn't fight
/// the user's actual prose for attention.
struct AgentImageDescriptionDisclosure: View {
    let description: String
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "text.viewfinder")
                        .font(.system(size: 10, weight: .medium))
                    Text(isExpanded ? L10n.ImageDescription.hide : L10n.ImageDescription.show)
                        .font(.system(size: 11, weight: .medium))
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                }
                .foregroundStyle(.white.opacity(0.85))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color.white.opacity(0.18))
                .clipShape(Capsule())
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .help(L10n.ImageDescription.help)

            if isExpanded {
                Text(description)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.85))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(8)
                    .background(Color.white.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        }
    }
}

// MARK: - Message footer

enum AgentChatMessageMetrics {
    static func assistantStatus(for message: AgentMessage, isStreaming: Bool) -> String {
        if isStreaming {
            return L10n.MessageFooter.processing
        }
        guard let elapsed = message.elapsedSeconds, elapsed > 0 else {
            return L10n.MessageFooter.processed
        }
        return L10n.MessageFooter.processedDuration(formatElapsed(elapsed))
    }

    static func tokenSummary(for message: AgentMessage) -> String? {
        let usage: String
        if let prompt = message.promptTokens, let completion = message.completionTokens {
            usage = "\(formatTokens(prompt))/\(formatTokens(completion))"
        } else if let total = message.usageTokens, total > 0 {
            usage = formatTokens(total)
        } else {
            return nil
        }

        guard let rate = cacheHitRate(for: message) else { return usage }
        let percentage = Int((rate * 100).rounded())
        return "\(usage) · \(L10n.MessageFooter.cacheRate("\(percentage)%"))"
    }

    static func cacheHitRate(for message: AgentMessage) -> Double? {
        guard let prompt = message.promptTokens, prompt > 0,
              let cached = message.cachedPromptTokens else {
            return nil
        }
        return min(1, max(0, Double(cached) / Double(prompt)))
    }

    static func formatElapsed(_ seconds: Double) -> String {
        if seconds < 60 {
            return "\(max(1, Int(seconds.rounded())))s"
        }
        let minutes = Int(seconds) / 60
        let remainder = Int(seconds) % 60
        return "\(minutes)m \(remainder)s"
    }

    private static func formatTokens(_ count: Int) -> String {
        if count >= 1_000_000 {
            return String(format: "%.2fM", Double(count) / 1_000_000.0)
        }
        if count >= 1_000 {
            return String(format: "%.1fk", Double(count) / 1_000.0)
        }
        return String(count)
    }
}

/// Tiny caption row that sits directly under a chat bubble. Renders a
/// copy-to-clipboard button plus the compact prompt/completion token
/// summary for assistant messages. Elapsed time lives in the leading
/// "Processed" divider above the message body.
struct AgentMessageFooter: View {
    let message: AgentMessage
    /// `.leading` for assistant rows (left-aligned column), `.trailing`
    /// for the right-aligned user bubble so the footer hugs the same
    /// edge as the bubble.
    let alignment: HorizontalAlignment
    var showsUserTimestamp = false
    var baseFontSize: CGFloat = AgentSettingsStore.chatBaseFontSizeDefault

    @State private var didJustCopy = false
    @Environment(\.agentChatLineHeightMultiple) private var agentChatLineHeightMultiple

    var body: some View {
        HStack(spacing: 10) {
            if alignment == .trailing { Spacer(minLength: 0) }

            if message.role == .user && showsUserTimestamp {
                Text(formatTimestamp(message.createdAt))
                    .font(metadataFont)
                    .lineSpacing(metadataLineSpacing)
                    .foregroundStyle(.secondary)
            }

            Button(action: copyToClipboard) {
                Image(systemName: didJustCopy ? "checkmark" : "square.on.square")
                    .font(didJustCopy ? footerIconFont : copyIconFont)
                    .foregroundStyle(didJustCopy ? Color.green : Color.secondary)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(didJustCopy ? L10n.MessageFooter.copied : L10n.MessageFooter.copy)
            .accessibilityLabel(L10n.MessageFooter.copyAccessibility)

            if message.role == .assistant, let tokenSummary = AgentChatMessageMetrics.tokenSummary(for: message) {
                Text(tokenSummary)
                    .font(metadataFont)
                    .lineSpacing(metadataLineSpacing)
                    .foregroundStyle(.secondary)
            }

            if message.role == .assistant, let route = message.managedRoute {
                footerMetric(icon: "gearshape", text: route.footerChipText)
                    .help(route.selectedModel)
            }

            if alignment == .leading { Spacer(minLength: 0) }
        }
    }

    private var footerIconFont: Font {
        .system(size: 13, weight: .semibold)
    }

    private var copyIconFont: Font {
        .system(size: 13, weight: .regular)
    }

    private var footerTextFont: Font {
        metadataFont
    }

    private var metadataFont: Font {
        AgentDesign.chatSupportingFont(baseFontSize: baseFontSize, weight: .medium)
    }

    private var metadataLineSpacing: CGFloat {
        let fontSize = AgentDesign.chatSupportingFontSize(baseFontSize: baseFontSize)
        return AgentChatTypography.lineSpacing(
            fontSize: fontSize,
            lineHeightMultiple: agentChatLineHeightMultiple
        )
    }

    private func footerMetric(icon: String, text: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon)
                .font(footerIconFont)
            Text(text)
                .font(footerTextFont)
                .lineSpacing(metadataLineSpacing)
        }
        .foregroundStyle(.secondary)
    }

    private func formatTimestamp(_ date: Date) -> String {
        let calendar = Calendar.autoupdatingCurrent
        let dateStyle: DateFormatter.Style = calendar.isDateInToday(date) ? .none : .short
        return DateFormatter.localizedString(from: date, dateStyle: dateStyle, timeStyle: .short)
    }

    private func copyToClipboard() {
        let pb = NSPasteboard.general
        pb.clearContents()
        // copyableContent 是原始模型输出,不带我们插的断点;净化这一刀是
        // 冲着模型自己吐的零宽字符/BOM 去的——模型输出不保证干净。
        pb.setString(AgentCopyTextSanitizer.sanitize(message.copyableContent), forType: .string)
        didJustCopy = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_400_000_000)
            didJustCopy = false
        }
    }
}

struct AgentTextAttachmentBubbleStrip: View {
    let attachments: [AgentTextAttachment]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(attachments) { attachment in
                AgentTextAttachmentChip(attachment: attachment)
            }
        }
    }
}

// MARK: - Queued message

struct QueuedMessagesList: View {
    let messages: [AgentQueuedMessage]
    var baseFontSize: CGFloat = NSFont.systemFontSize
    var onEdit: (AgentQueuedMessage) -> Void = { _ in }
    var onSendNow: (AgentQueuedMessage) -> Void = { _ in }
    var onRemove: (AgentQueuedMessage) -> Void = { _ in }
    var onOpenInSideChat: (AgentQueuedMessage) -> Void = { _ in }
    var onCloseQueue: () -> Void = {}
    var onMove: (AgentQueuedMessage.ID, AgentQueuedMessage.ID) -> Void = { _, _ in }
    @State private var draggedMessageID: AgentQueuedMessage.ID?

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(messages.enumerated()), id: \.element.id) { offset, message in
                QueuedMessageRow(
                    message: message,
                    baseFontSize: baseFontSize,
                    onEdit: { onEdit(message) },
                    onSendNow: { onSendNow(message) },
                    onRemove: { onRemove(message) },
                    onOpenInSideChat: { onOpenInSideChat(message) },
                    onCloseQueue: onCloseQueue,
                    onDragStarted: { draggedMessageID = message.id }
                )
                .onDrop(
                    of: [UTType.text],
                    delegate: QueuedMessageDropDelegate(
                        targetID: message.id,
                        draggedMessageID: $draggedMessageID,
                        onMove: onMove
                    )
                )
                if offset < messages.count - 1 {
                    Divider()
                        .padding(.leading, 54)
                }
            }
        }
        .frame(maxWidth: AgentDesign.chatMaxContentWidth, alignment: .leading)
        // Waiting is not a warning. The queue is a normal, reversible state,
        // so the card sits in the same quiet gray as the rest of the chrome
        // instead of borrowing the amber that elsewhere means "look at this".
        .background(AgentComposerChrome.controlFill)
        .clipShape(RoundedRectangle(cornerRadius: AgentDesign.cardCornerRadius))
        .overlay(
            RoundedRectangle(cornerRadius: AgentDesign.cardCornerRadius)
                .stroke(AgentComposerChrome.border, lineWidth: 1)
        )
    }
}

private struct QueuedMessageRow: View {
    let message: AgentQueuedMessage
    /// Mirror of the Agent chat base font size so the queued preview
    /// text reads at the same scale as the user's actual message
    /// bubble once it's dispatched.
    var baseFontSize: CGFloat = NSFont.systemFontSize
    var onEdit: () -> Void = {}
    var onSendNow: () -> Void = {}
    var onRemove: () -> Void = {}
    var onOpenInSideChat: () -> Void = {}
    var onCloseQueue: () -> Void = {}
    var onDragStarted: () -> Void = {}
    @State private var isHovering = false

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            sixDotDragHandle
                .foregroundStyle(.tertiary)
                .frame(width: 12, height: 24)
                .opacity(isHovering ? 1 : 0)
                .contentShape(Rectangle())
                .onDrag {
                    onDragStarted()
                    return NSItemProvider(object: message.id.uuidString as NSString)
                } preview: {
                    sixDotDragHandle.padding(8)
                }
                .help(L10n.QueuedMessage.dragHelp)
            HStack(alignment: .center, spacing: 6) {
                Text(previewText)
                    .font(AgentDesign.chatSupportingFont(baseFontSize: baseFontSize))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .accessibilityLabel(L10n.QueuedMessage.label)
                Spacer(minLength: 8)
                HStack(spacing: 4) {
                    Button(action: onSendNow) {
                        HStack(spacing: 5) {
                            Image(systemName: "arrow.turn.down.right")
                            Text(L10n.QueuedMessage.adjustDirection)
                        }
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(minHeight: 24)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .focusable(false)
                    .accessibilityLabel(L10n.QueuedMessage.sendNowButton)
                    .help(L10n.QueuedMessage.sendNowButtonHelp)

                    iconButton(
                        systemName: "trash",
                        accessibilityLabel: L10n.QueuedMessage.deleteButton,
                        help: L10n.QueuedMessage.deleteButtonHelp,
                        action: onRemove
                    )

                    Menu {
                        Button(action: onEdit) {
                            Label(L10n.QueuedMessage.editButton, systemImage: "pencil")
                        }
                        Button(action: onOpenInSideChat) {
                            Label(L10n.QueuedMessage.openInSideChat, systemImage: "plus.bubble")
                        }
                        Divider()
                        Button(action: onCloseQueue) {
                            Label(L10n.QueuedMessage.closeQueue, systemImage: "arrow.turn.down.left")
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 12, weight: .semibold))
                            .frame(width: 24, height: 24)
                            .contentShape(Rectangle())
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .agentQuietMenuChrome()
                    .fixedSize()
                    .focusable(false)
                    .accessibilityLabel(L10n.QueuedMessage.actionsButton)
                    .help(L10n.QueuedMessage.actionsButtonHelp)
                }
            }
        }
        .padding(.horizontal, 10)
        // Single-line row: 28pt send-now button plus 4pt breathing room
        // top and bottom, down from the 46pt the two-line layout needed.
        .frame(height: 36)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
    }

    private var sixDotDragHandle: some View {
        VStack(spacing: 2) {
            ForEach(0..<3, id: \.self) { _ in
                HStack(spacing: 2) {
                    Circle().frame(width: 2.5, height: 2.5)
                    Circle().frame(width: 2.5, height: 2.5)
                }
            }
        }
    }

    private var previewText: String {
        // A queued message holds the already-composed prompt, so an attached
        // turn starts with the model-facing prelude rather than the operator's
        // own words. Show what they typed.
        if let spliced = AgentAttachedPromptDisplay.singleLinePreview(of: message.text) {
            return spliced
        }
        let text = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { return text.replacingOccurrences(of: "\n", with: " ") }
        if !message.textAttachments.isEmpty {
            return L10n.QueuedMessage.textAttachmentCount("\(message.textAttachments.count)")
        }
        if !message.images.isEmpty {
            return L10n.QueuedMessage.imageCount("\(message.images.count)")
        }
        return L10n.QueuedMessage.emptyPreview
    }

    private func iconButton(
        systemName: String,
        accessibilityLabel: String,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.secondary)
        .accessibilityLabel(accessibilityLabel)
        .help(help)
    }
}

private struct QueuedMessageDropDelegate: DropDelegate {
    let targetID: AgentQueuedMessage.ID
    @Binding var draggedMessageID: AgentQueuedMessage.ID?
    let onMove: (AgentQueuedMessage.ID, AgentQueuedMessage.ID) -> Void

    func dropEntered(info: DropInfo) {
        guard let sourceID = draggedMessageID, sourceID != targetID else { return }
        onMove(sourceID, targetID)
    }

    func performDrop(info: DropInfo) -> Bool {
        draggedMessageID = nil
        return true
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }
}

// MARK: - Empty state

struct AgentChatEmptyState: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        Group {
            // Once usage exists, the profile card owns the complete new-chat
            // hierarchy, matching Codex without a second greeting above it.
            if appState.agentSessions.isEmpty {
                VStack(spacing: 18) {
                    heroLine
                    Text(subtitle)
                        .agentChatSupportingFont()
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 360)
                }
            } else {
                // 宽度由面板自己按当前页决定（单日详情要更宽），这里只给
                // 一个不让它铺满整个窗口的上限。
                AgentStatsDashboard()
                    .frame(maxWidth: AgentStatsDashboardLayout.dayDetailMaxWidth)
            }
        }
        .foregroundStyle(.secondary)
    }

    private var heroLine: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .foregroundStyle(.tertiary)
                Text(L10n.EmptyState.hero(NSUserName()))
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(.primary)
            }
        }
    }

    private var subtitle: String {
        if appState.rootDirectory == nil {
            return L10n.EmptyState.subtitleNoFolder
        }
        return L10n.EmptyState.subtitleWithFolder(appState.rootDirectory?.lastPathComponent ?? "")
    }
}
