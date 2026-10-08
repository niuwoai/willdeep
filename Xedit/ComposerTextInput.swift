//
//  ComposerTextInput.swift
//  WillDeep
//
//  NSTextView-backed composer input + coordinator, split out of
//  AgentModeComposerView.swift in rc42. Two pieces:
//   - `ComposerTextEditor` (NSViewRepresentable): the SwiftUI bridge.
//     Wires Return-submits, ↑/↓ history cycling, Cmd+V image intercept,
//     and the "/", "@", "$" popover state bindings owned by ComposerCard.
//   - `ComposerNSTextView` (NSTextView subclass): force-plain-text paste,
//     image-pasteboard detection via `AgentImagePasteboardHelper`.
//
//  The coordinator owns the history cursor (savedDraft + historyIndex)
//  and the @/$-token query derivation — both are stateful enough to need
//  a class rather than living inside the SwiftUI struct.
//

import AppKit
import SwiftUI

/// TextKit returns one union bounding box for a glyph range that wraps across
/// lines. A secret placeholder can wrap after `${` or one of the alias
/// separators, so drawing that union as one rounded rectangle paints unrelated
/// prose between the first and last fragment. Keep one precise rect per visual
/// line instead.
enum ComposerSecretTagLayout {
    static func highlightRects(
        forCharacterRange characterRange: NSRange,
        layoutManager: NSLayoutManager,
        textContainer: NSTextContainer
    ) -> [NSRect] {
        let glyphRange = layoutManager.glyphRange(
            forCharacterRange: characterRange,
            actualCharacterRange: nil
        )
        guard glyphRange.length > 0 else { return [] }

        var rects: [NSRect] = []
        layoutManager.enumerateLineFragments(forGlyphRange: glyphRange) {
            _, _, _, lineGlyphRange, _ in
            let fragmentGlyphRange = NSIntersectionRange(glyphRange, lineGlyphRange)
            guard fragmentGlyphRange.length > 0 else { return }
            let rect = layoutManager.boundingRect(
                forGlyphRange: fragmentGlyphRange,
                in: textContainer
            )
            guard rect.width > 0, rect.height > 0 else { return }
            rects.append(rect)
        }
        return rects
    }
}

/// 往输入框里拖东西时,谁来接。
///
/// NSTextView 自带的拖放会把文件**路径当成一段文字**插进缓冲区——用户拖张
/// 截图进来,得到的是 `/Users/…/微信图片_…jpg` 这一行字(还因为以 `/` 开头
/// 触发了斜杠命令面板,弹出「没有匹配的命令」)。SwiftUI 那层的 `.onDrop`
/// 根本轮不上,因为 AppKit 的文本视图先把事件吃掉了。
///
/// 所以在文本视图这一层拦截:文件和图片交给附件管线,其余(纯文本片段)
/// 仍然走 NSTextView 默认行为,原样插进去。
enum ComposerDropSupport {
    /// 需要接管的拖放类型。纯文本不在此列——拖一段文字进输入框,本来就
    /// 该变成文字。
    static let attachableTypes: [NSPasteboard.PasteboardType] = [.fileURL, .png, .tiff]

    static func shouldHandle(types: [NSPasteboard.PasteboardType]) -> Bool {
        types.contains { attachableTypes.contains($0) }
    }

    /// 拖进来的文件。Finder 一次可以拖多个,所以是数组。
    static func fileURLs(in pasteboard: NSPasteboard) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        let objects = pasteboard.readObjects(forClasses: [NSURL.self], options: options)
        return (objects as? [URL]) ?? []
    }

    /// 没有文件本体、只有图片数据的来源(浏览器里拖一张图、预览里拖选区)。
    static func imageData(in pasteboard: NSPasteboard) -> Data? {
        if let png = pasteboard.data(forType: .png) { return png }
        guard let tiff = pasteboard.data(forType: .tiff),
              let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }
}

struct ComposerTextEditor: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    /// Chat body size the composer scales with, so what the user types is
    /// sized like what they read. Defaulted so the many call sites that do
    /// not care keep the previous fixed size.
    var baseFontSize: CGFloat = AgentSettingsStore.chatBaseFontSizeDefault
    let onSubmit: () -> Void
    let onPasteImage: () -> Void
    let onPasteText: (String) -> Void
    /// 拖进输入框的文件/图片。返回 true 表示已经收下(变成附件),文本视图
    /// 就不再把路径当文字插进来。默认 nil = 保持 NSTextView 原行为。
    var onDropAttachments: ((NSPasteboard) -> Bool)?
    /// Returns the user's prior messages in chronological order. `↑` walks
    /// from the most recent backwards; `↓` walks forward and eventually
    /// restores the draft the user was typing before they started cycling.
    let historyProvider: () -> [String]
    /// Bound state for the "/" slash command palette. The composer card
    /// owns these so the menu can render in SwiftUI above the text view.
    @Binding var slashMenuVisible: Bool
    @Binding var slashMenuSelection: Int
    let slashMenuItemCount: () -> Int
    /// Called when the user presses Enter / Tab with the slash menu
    /// visible. Returning true tells the text view to swallow the key.
    let onSlashCommit: () -> Bool
    /// Pushes the live buffer to the slash palette so it can re-filter as
    /// the user types after "/". rc482: typing no longer repaints the
    /// composer through `appState` (see `suppressActiveRuntimeForward`), so
    /// the palette can't recompute off `appState.agentInput` anymore — it
    /// tracks this dedicated query the same way the "@" picker tracks its
    /// own (`onAtQueryChange`).
    let onSlashQueryChange: (String) -> Void
    /// Same shape as the slash palette, used for the "@" reference picker.
    @Binding var atMenuVisible: Bool
    @Binding var atMenuSelection: Int
    let atMenuItemCount: () -> Int
    let onAtCommit: () -> Bool
    let onAtCancel: () -> Void
    /// Notifies the composer card that the @ token in the buffer has
    /// changed (e.g. user kept typing letters after `@`), so the popover
    /// can re-filter its entries.
    let onAtQueryChange: (String?) -> Void
    /// Same shape as the @ picker, used for `$` skills.
    @Binding var skillMenuVisible: Bool
    @Binding var skillMenuSelection: Int
    let skillMenuItemCount: () -> Int
    let onSkillCommit: () -> Bool
    let onSkillCancel: () -> Void
    let onSkillQueryChange: (String?) -> Void
    /// Holder the parent passes in so it can hand the coordinator
    /// pointer back to SwiftUI menu callbacks (used by the @-token
    /// replacement helper). Filled in inside `makeCoordinator`.
    let coordinatorRef: ComposerCoordinatorRef
    /// 回合结束后预测的用户下一句。输入框为空时替代占位文字以灰字显示，
    /// Tab 采用、Esc 放弃；打字隐藏，删空恢复。nil = 不显示。
    var inputSuggestion: String? = nil
    var onDismissInputSuggestion: (() -> Void)? = nil
    var onAcceptInputSuggestion: (() -> Void)? = nil
    /// 缓冲区里被认成斜杠命令的词（UTF-16 范围）。这些词高亮显示，回删时
    /// 整个词一起删。nil = 不识别。
    var slashCommandTokenRanges: ((String) -> [NSRange])? = nil

    func makeCoordinator() -> Coordinator {
        let coord = Coordinator(
            text: $text,
            onSubmit: onSubmit,
            onPasteImage: onPasteImage,
            onPasteText: onPasteText,
            historyProvider: historyProvider,
            slashMenuVisible: $slashMenuVisible,
            slashMenuSelection: $slashMenuSelection,
            slashMenuItemCount: slashMenuItemCount,
            onSlashCommit: onSlashCommit,
            onSlashQueryChange: onSlashQueryChange,
            atMenuVisible: $atMenuVisible,
            atMenuSelection: $atMenuSelection,
            atMenuItemCount: atMenuItemCount,
            onAtCommit: onAtCommit,
            onAtCancel: onAtCancel,
            onAtQueryChange: onAtQueryChange,
            skillMenuVisible: $skillMenuVisible,
            skillMenuSelection: $skillMenuSelection,
            skillMenuItemCount: skillMenuItemCount,
            onSkillCommit: onSkillCommit,
            onSkillCancel: onSkillCancel,
            onSkillQueryChange: onSkillQueryChange
        )
        coordinatorRef.coordinator = coord
        return coord
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder

        let textView = ComposerNSTextView(frame: .zero)
        textView.delegate = context.coordinator
        textView.coordinator = context.coordinator
        textView.font = NSFont.systemFont(
            ofSize: AgentDesign.scaledComposerInputFontSize(baseFontSize: baseFontSize)
        )
        textView.isRichText = false
        // Composer 输入的是命令 / 代码 / prompt,任何系统「智能替换」都会
        // 篡改原文(半角直引号 "" → 弯引号 “”、`--` → 破折号、`(c)` → ©、
        // 半角标点被当成可替换项…),让用户以为「半角被自动改成了全角」。
        // 全部关掉,所见即所得。
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.allowsUndo = true
        textView.isEditable = true
        textView.isSelectable = true
        textView.autoresizingMask = [.width]
        textView.textContainerInset = NSSize(width: 0, height: 2)
        textView.placeholder = placeholder
        textView.inputSuggestion = inputSuggestion
        context.coordinator.onDismissInputSuggestion = onDismissInputSuggestion
        context.coordinator.onAcceptInputSuggestion = onAcceptInputSuggestion
        textView.slashCommandTokenRanges = slashCommandTokenRanges
        textView.string = text
        textView.onDropAttachments = onDropAttachments
        // NSTextView 默认注册的拖放类型里未必有文件/图片(取决于 isRichText
        // 等设置),补齐后 draggingEntered/performDragOperation 才会被调到。
        let registered = Set(textView.registeredDraggedTypes)
        textView.registerForDraggedTypes(
            textView.registeredDraggedTypes
                + ComposerDropSupport.attachableTypes.filter { !registered.contains($0) }
        )
        textView.drawsBackground = false
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true

        scrollView.documentView = textView
        // 初始化「我们最近一次 publish 的值」=  当前 binding,避免第一次
        // updateNSView 误判初始 text 是「外部塞进来的不同值」就跑去覆写。
        context.coordinator.lastPublishedValue = text
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = nsView.documentView as? ComposerNSTextView else { return }
        textView.placeholder = placeholder
        textView.inputSuggestion = inputSuggestion
        context.coordinator.onDismissInputSuggestion = onDismissInputSuggestion
        context.coordinator.onAcceptInputSuggestion = onAcceptInputSuggestion
        textView.slashCommandTokenRanges = slashCommandTokenRanges
        textView.onDropAttachments = onDropAttachments
        // Applied before the text-sync dance below: font is independent of the
        // binding-echo / IME-marked-text races guarded there, and skipping it
        // on those early returns would strand the composer at the old size
        // until the next unrelated refresh.
        textView.applyInputFont(
            ofSize: AgentDesign.scaledComposerInputFontSize(baseFontSize: baseFontSize)
        )
        if textView.string != text {
            // 1.85.0-rc15:绝大多数「我输了东西被覆盖掉/回退掉」的现象,
            // 根因是这里的 binding-echo 竞态。流程:
            //   ① 用户在 NSTextView 里敲字 → `textDidChange` 同步把新值
            //     写进 `text.wrappedValue`(= `activeRuntime.input`),
            //     `lastPublishedValue` 记下我们刚发出去的字符串。
            //   ② AppState 因为别的事(token streaming / timer / status
            //     bar 闪一下)发了 `objectWillChange` → SwiftUI 重算 body
            //     → `updateNSView` 跑了。
            //   ③ 如果用户在 ②③ 之间又敲了几个字,`textView.string` 已经
            //     比 `text` 长;此时 `text` 还是我们 ① 发出去的那个值(也
            //     就是 `lastPublishedValue`)。
            //   ④ 旧实现只判 `textView.string != text` 就直接覆写,等于
            //     把刚敲进去的字符给回退掉。
            // 兜底:`text` 等于我们最后一次主动 publish 的值 → 这一次
            // binding 通知就是我们自己的回声,跳过覆写,让 textView 保
            // 留更新的内容。
            if text == context.coordinator.lastPublishedValue { return }
            // During Chinese/Japanese/Korean IME composition, NSTextView
            // holds marked text that is not committed to the SwiftUI
            // binding yet. Parent view refreshes (streaming transcript,
            // timers, picker state) can arrive in that window; writing
            // the older binding value back here clears the marked text,
            // which feels like newly typed characters were swallowed.
            guard !textView.hasMarkedText() else { return }
            // Track programmatic text changes so the history cursor
            // doesn't think the user kept typing on top of a recalled
            // message — this also covers the slash-command path
            // emptying the buffer after running an action.
            context.coordinator.markTextReplacedExternally(to: text)
            textView.string = text
            // 同步标记:这次是 SwiftUI 这边新塞进来的值(slash 清空 /
            // history recall / editor selection prefill 之类),让下一轮
            // 比对也跳过同值回声。
            context.coordinator.lastPublishedValue = text
        }
        textView.needsDisplay = true
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        let onSubmit: () -> Void
        let onPasteImage: () -> Void
        let onPasteText: (String) -> Void
        let historyProvider: () -> [String]
        var slashMenuVisible: Binding<Bool>
        var slashMenuSelection: Binding<Int>
        let slashMenuItemCount: () -> Int
        let onSlashCommit: () -> Bool
        let onSlashQueryChange: (String) -> Void
        var atMenuVisible: Binding<Bool>
        var atMenuSelection: Binding<Int>
        let atMenuItemCount: () -> Int
        let onAtCommit: () -> Bool
        let onAtCancel: () -> Void
        let onAtQueryChange: (String?) -> Void
        var skillMenuVisible: Binding<Bool>
        var skillMenuSelection: Binding<Int>
        let skillMenuItemCount: () -> Int
        let onSkillCommit: () -> Bool
        let onSkillCancel: () -> Void
        let onSkillQueryChange: (String?) -> Void
        var onDismissInputSuggestion: (() -> Void)?
        var onAcceptInputSuggestion: (() -> Void)?

        // History cursor state. `historyIndex` counts back from the most
        // recent user message: 0 = newest, 1 = next-newest, etc. nil
        // means "not cycling — the buffer holds the user's own draft".
        private var historyIndex: Int? = nil
        private var savedDraft: String = ""
        /// The exact string the composer last published from history, so
        /// we can tell whether the user has edited on top of it.
        private var lastHistoryString: String? = nil
        /// Tracks the active NSTextView so textDidChange handlers can
        /// inspect the live selection (NSTextStorage's didChange fires
        /// before selection updates, so we use the cached pointer rather
        /// than relying on the notification's object).
        fileprivate weak var activeTextView: NSTextView?
        /// rc15:记下我们最近一次往 `text.wrappedValue` 写入的字符串。
        /// `updateNSView` 拿到的 binding 值如果 ===  这个,说明 SwiftUI
        /// 这一轮通知就是在回放我们刚发出去的内容,而 `textView` 在通
        /// 知派发期间可能又前进了几个字符 —— 不能覆写,否则就是「我
        /// 输了东西被覆盖掉/回退掉」。
        fileprivate var lastPublishedValue: String = ""

        init(
            text: Binding<String>,
            onSubmit: @escaping () -> Void,
            onPasteImage: @escaping () -> Void,
            onPasteText: @escaping (String) -> Void,
            historyProvider: @escaping () -> [String],
            slashMenuVisible: Binding<Bool>,
            slashMenuSelection: Binding<Int>,
            slashMenuItemCount: @escaping () -> Int,
            onSlashCommit: @escaping () -> Bool,
            onSlashQueryChange: @escaping (String) -> Void,
            atMenuVisible: Binding<Bool>,
            atMenuSelection: Binding<Int>,
            atMenuItemCount: @escaping () -> Int,
            onAtCommit: @escaping () -> Bool,
            onAtCancel: @escaping () -> Void,
            onAtQueryChange: @escaping (String?) -> Void,
            skillMenuVisible: Binding<Bool>,
            skillMenuSelection: Binding<Int>,
            skillMenuItemCount: @escaping () -> Int,
            onSkillCommit: @escaping () -> Bool,
            onSkillCancel: @escaping () -> Void,
            onSkillQueryChange: @escaping (String?) -> Void
        ) {
            self.text = text
            self.onSubmit = onSubmit
            self.onPasteImage = onPasteImage
            self.onPasteText = onPasteText
            self.historyProvider = historyProvider
            self.slashMenuVisible = slashMenuVisible
            self.slashMenuSelection = slashMenuSelection
            self.slashMenuItemCount = slashMenuItemCount
            self.onSlashCommit = onSlashCommit
            self.onSlashQueryChange = onSlashQueryChange
            self.atMenuVisible = atMenuVisible
            self.atMenuSelection = atMenuSelection
            self.atMenuItemCount = atMenuItemCount
            self.onAtCommit = onAtCommit
            self.onAtCancel = onAtCancel
            self.onAtQueryChange = onAtQueryChange
            self.skillMenuVisible = skillMenuVisible
            self.skillMenuSelection = skillMenuSelection
            self.skillMenuItemCount = skillMenuItemCount
            self.onSkillCommit = onSkillCommit
            self.onSkillCancel = onSkillCancel
            self.onSkillQueryChange = onSkillQueryChange
        }

        func markTextReplacedExternally(to newValue: String) {
            // If something other than the user typed (slash action,
            // history binding push), reset our cursor so the next ↑
            // starts fresh.
            if newValue != lastHistoryString {
                historyIndex = nil
                lastHistoryString = nil
            }
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            activeTextView = textView
            let newValue = textView.string
            // 顺序很关键:先写 lastPublishedValue 再 publish 到 binding。
            // 这样 SwiftUI 触发的 updateNSView 在比对时一定能看到「这就是
            // 我刚发出去的那个值」,从而跳过 clobber(详见 updateNSView 注释)。
            lastPublishedValue = newValue
            text.wrappedValue = newValue
            // Any user edit invalidates the history cursor and re-derives
            // slash + @ + $ visibility.
            if newValue != lastHistoryString {
                historyIndex = nil
                lastHistoryString = nil
            }
            updateSlashMenuVisibility(for: textView)
            // Keep the slash palette's filter in sync. rc482: the composer
            // no longer repaints through `appState` on each keystroke, so the
            // palette filters off this pushed query instead of reading
            // `appState.agentInput` in `body`.
            //
            // 推的是光标所在那个斜杠 token（带回斜杠，面板的过滤器认这个
            // 形状），不是整个缓冲区。斜杠不在开头时，整个缓冲区喂给过滤器
            // 会被它的 `hasPrefix("/")` 判掉。
            onSlashQueryChange(currentSlashQuery(in: textView).map { "/" + $0 } ?? "")
            updateAtMenuVisibility(for: textView)
            updateSkillMenuVisibility(for: textView)
            // 保留已展示建议；非空缓冲区只隐藏，删空后仍可 Tab 采用。
            textView.needsDisplay = true
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            activeTextView = textView
            // Slash command palette takes priority over history + submit
            // while it's open.
            if slashMenuVisible.wrappedValue {
                switch commandSelector {
                case #selector(NSResponder.moveUp(_:)):
                    let count = slashMenuItemCount()
                    guard count > 0 else { return true }
                    slashMenuSelection.wrappedValue = (slashMenuSelection.wrappedValue - 1 + count) % count
                    return true
                case #selector(NSResponder.moveDown(_:)):
                    let count = slashMenuItemCount()
                    guard count > 0 else { return true }
                    slashMenuSelection.wrappedValue = (slashMenuSelection.wrappedValue + 1) % count
                    return true
                case #selector(NSResponder.insertNewline(_:)),
                     #selector(NSResponder.insertTab(_:)):
                    return onSlashCommit()
                case #selector(NSResponder.cancelOperation(_:)):
                    slashMenuVisible.wrappedValue = false
                    return true
                default:
                    break
                }
            }

            // $ skill picker takes priority over submit while it's open,
            // but defers caret motion (↑/↓) ONLY when the menu actually
            // has items to step through.
            if skillMenuVisible.wrappedValue {
                switch commandSelector {
                case #selector(NSResponder.moveUp(_:)):
                    let count = skillMenuItemCount()
                    guard count > 0 else { break }
                    skillMenuSelection.wrappedValue = (skillMenuSelection.wrappedValue - 1 + count) % count
                    return true
                case #selector(NSResponder.moveDown(_:)):
                    let count = skillMenuItemCount()
                    guard count > 0 else { break }
                    skillMenuSelection.wrappedValue = (skillMenuSelection.wrappedValue + 1) % count
                    return true
                case #selector(NSResponder.insertNewline(_:)),
                     #selector(NSResponder.insertTab(_:)):
                    if onSkillCommit() { return true }
                case #selector(NSResponder.cancelOperation(_:)):
                    onSkillCancel()
                    return true
                default:
                    break
                }
            }

            // @ reference picker takes priority over submit while it's open,
            // but defers caret motion (↑/↓) ONLY when the menu actually
            // has items to step through — keeps multi-line composition
            // unaffected when there are no reference matches.
            if atMenuVisible.wrappedValue {
                switch commandSelector {
                case #selector(NSResponder.moveUp(_:)):
                    let count = atMenuItemCount()
                    guard count > 0 else { break }
                    atMenuSelection.wrappedValue = (atMenuSelection.wrappedValue - 1 + count) % count
                    return true
                case #selector(NSResponder.moveDown(_:)):
                    let count = atMenuItemCount()
                    guard count > 0 else { break }
                    atMenuSelection.wrappedValue = (atMenuSelection.wrappedValue + 1) % count
                    return true
                case #selector(NSResponder.insertNewline(_:)),
                     #selector(NSResponder.insertTab(_:)):
                    // `@` denotes an attachment operation, so Return/Tab must
                    // never fall through and send the raw token merely because
                    // the background workspace search has not returned yet.
                    // Escape remains the explicit way to keep literal `@text`.
                    _ = onAtCommit()
                    return true
                case #selector(NSResponder.cancelOperation(_:)):
                    onAtCancel()
                    return true
                default:
                    break
                }
            }

            // 预测的下一句：只在输入框为空、没有菜单开着时接管 Tab / Esc。
            if let suggestion = (textView as? ComposerNSTextView)?.visibleInputSuggestion {
                switch commandSelector {
                case #selector(NSResponder.insertTab(_:)):
                    _ = replaceComposerText(with: suggestion)
                    onAcceptInputSuggestion?()
                    return true
                case #selector(NSResponder.cancelOperation(_:)):
                    onDismissInputSuggestion?()
                    return true
                default:
                    break
                }
            }

            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                let modifiers = NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask)
                let wantsLineBreak = modifiers.contains(.shift)
                    || modifiers.contains(.option)
                    || modifiers.contains(.control)
                if !wantsLineBreak {
                    onSubmit()
                    historyIndex = nil
                    lastHistoryString = nil
                    return true
                }
            }

            if commandSelector == #selector(NSResponder.moveUp(_:)) {
                if let recalled = stepHistory(direction: -1, currentText: textView.string) {
                    applyHistory(recalled, to: textView)
                    return true
                }
            }
            if commandSelector == #selector(NSResponder.moveDown(_:)) {
                if let recalled = stepHistory(direction: +1, currentText: textView.string) {
                    applyHistory(recalled, to: textView)
                    return true
                }
            }
            return false
        }

        /// Returns the next/previous history entry (or the saved draft on
        /// the way back down) — or nil to let the text view's normal
        /// caret-movement command run.
        private func stepHistory(direction: Int, currentText: String) -> String? {
            let history = historyProvider()
            guard !history.isEmpty else { return nil }

            // Only intercept ↑/↓ when the buffer is empty OR currently
            // showing a recalled history entry. Anything else means the
            // user is editing prose and expects caret motion.
            let isOnHistory = historyIndex != nil && currentText == lastHistoryString
            let isEmpty = currentText.isEmpty
            guard isEmpty || isOnHistory else { return nil }

            if direction < 0 {
                // ↑ — walk further back. If we weren't cycling yet, save
                // whatever was in the buffer (probably empty) as the draft.
                if historyIndex == nil {
                    savedDraft = currentText
                    historyIndex = 0
                } else if let i = historyIndex, i + 1 < history.count {
                    historyIndex = i + 1
                } else {
                    return nil // already at oldest
                }
            } else {
                // ↓ — walk forward toward the draft.
                guard let i = historyIndex else { return nil }
                if i == 0 {
                    historyIndex = nil
                    return savedDraft
                }
                historyIndex = i - 1
            }
            guard let i = historyIndex else { return savedDraft }
            return history[history.count - 1 - i]
        }

        private func applyHistory(_ value: String, to textView: NSTextView) {
            textView.string = value
            // 主动 publish:同步更新 lastPublishedValue,免得 updateNSView
            // 后续误判这是「外部写入」再尝试覆写。
            lastPublishedValue = value
            text.wrappedValue = value
            lastHistoryString = value
            // Park the caret at end so the user can keep typing.
            let end = (value as NSString).length
            textView.setSelectedRange(NSRange(location: end, length: 0))
            textView.needsDisplay = true
        }

        private func updateSlashMenuVisibility(for textView: NSTextView) {
            // 光标是不是正停在一个斜杠 token 里。此前看的是整个缓冲区是否以
            // "/" 开头，于是斜杠后一有空格面板就消失，标记类的斜杠词也就写
            // 不到句尾去。
            let shouldShow = currentSlashQuery(in: textView) != nil
            if slashMenuVisible.wrappedValue != shouldShow {
                slashMenuVisible.wrappedValue = shouldShow
                if shouldShow {
                    slashMenuSelection.wrappedValue = 0
                }
            }
        }

        /// Looks at the caret position and decides whether the user is
        /// inside a trigger token (counting backwards from the caret to the
        /// nearest trigger, stopping at whitespace/newline/another trigger).
        /// Returns the substring after the trigger so the popover can filter.
        fileprivate func currentTriggerQuery(in textView: NSTextView, trigger: UInt16) -> String? {
            let nsString = textView.string as NSString
            let caret = textView.selectedRange().location
            guard caret > 0, caret <= nsString.length else { return nil }
            var i = caret - 1
            while i >= 0 {
                let ch = nsString.character(at: i)
                let scalar = UnicodeScalar(ch)
                if ch == trigger {
                    // Require that the trigger sits at the start of the buffer
                    // or right after whitespace — avoids matching email
                    // addresses, file paths, etc.
                    if i == 0 {
                        return (nsString.substring(with: NSRange(location: i + 1, length: caret - i - 1)))
                    }
                    let prev = nsString.character(at: i - 1)
                    if let prevScalar = UnicodeScalar(prev),
                       CharacterSet.whitespacesAndNewlines.contains(prevScalar) {
                        return (nsString.substring(with: NSRange(location: i + 1, length: caret - i - 1)))
                    }
                    return nil
                }
                if let s = scalar, CharacterSet.whitespacesAndNewlines.contains(s) {
                    return nil
                }
                i -= 1
            }
            return nil
        }

        /// Looks at the caret position and decides whether the user is
        /// inside an `@token`. Returns the substring after `@` so the popover can filter.
        fileprivate func currentAtQuery(in textView: NSTextView) -> String? {
            currentTriggerQuery(in: textView, trigger: 0x40)
        }

        fileprivate func currentSkillQuery(in textView: NSTextView) -> String? {
            currentTriggerQuery(in: textView, trigger: 0x24)
        }

        /// 斜杠 token。和 `@` / `$` 用同一条通用判定，再加两道防误触。
        ///
        /// 斜杠此前只在整条消息开头才认，理由说得通：多数斜杠命令就是整条
        /// 消息本身（`/code-review` 后面跟的是参数不是自然语言）。但像
        /// `/no-subagent` 这种只是个标记，写在句尾比写在开头自然得多，而旧
        /// 规则把标记类和命令类按同一套管，于是「把这批测试跑一遍
        /// /no-subagent」根本唤不起面板。
        ///
        /// 放宽的代价是路径会误触发，所以加两条：token 里只允许字母、数字、
        /// 连字符、下划线（`/Users/rocky` 一旦出现第二个斜杠就不再是候选），
        /// 且整段里不能有第二个斜杠。`src/App.tsx` 本来就被通用判定挡住了
        /// ——它的斜杠前面是字母不是空白。
        fileprivate func currentSlashQuery(in textView: NSTextView) -> String? {
            guard let token = currentTriggerQuery(in: textView, trigger: 0x2F) else { return nil }
            let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
            guard token.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return nil }
            // 紧跟着的斜杠意味着光标停在一条路径中间（`/Users|/rocky`），不是命令。
            // 此前要求整段只有一个斜杠，于是 `/no-sandbox /sub` 这种串写的第二个
            // 命令永远唤不起面板；路径已经由上面的字符集和「斜杠前必须是空白」挡住。
            let nsString = textView.string as NSString
            let caret = textView.selectedRange().location
            if caret < nsString.length, nsString.character(at: caret) == 0x2F { return nil }
            return token
        }

        private func updateAtMenuVisibility(for textView: NSTextView) {
            let query = currentAtQuery(in: textView)
            onAtQueryChange(query)
            let shouldShow = query != nil
            if atMenuVisible.wrappedValue != shouldShow {
                atMenuVisible.wrappedValue = shouldShow
                if shouldShow {
                    atMenuSelection.wrappedValue = 0
                }
            }
        }

        private func updateSkillMenuVisibility(for textView: NSTextView) {
            let query = currentSkillQuery(in: textView)
            onSkillQueryChange(query)
            let shouldShow = query != nil
            if skillMenuVisible.wrappedValue != shouldShow {
                skillMenuVisible.wrappedValue = shouldShow
                if shouldShow {
                    skillMenuSelection.wrappedValue = 0
                }
            }
        }

        /// Replace the in-progress trigger token at the caret and dismiss
        /// the matching popover. Returns true if it edited the buffer.
        func replaceCurrentTriggerToken(trigger: UInt16, replacement: String) -> Bool {
            guard let textView = activeTextView else { return false }
            let nsString = textView.string as NSString
            let caret = textView.selectedRange().location
            guard caret > 0, caret <= nsString.length else { return false }
            var i = caret - 1
            while i >= 0 {
                let ch = nsString.character(at: i)
                if ch == trigger { break }
                if let s = UnicodeScalar(ch), CharacterSet.whitespacesAndNewlines.contains(s) { return false }
                i -= 1
            }
            guard i >= 0 else { return false }
            let replaceRange = NSRange(location: i, length: caret - i)
            let mutable = NSMutableString(string: textView.string)
            mutable.replaceCharacters(in: replaceRange, with: replacement)
            let result = mutable as String
            textView.string = result
            // 同 applyHistory:主动 publish 后立刻同步 lastPublishedValue。
            lastPublishedValue = result
            text.wrappedValue = result
            let newCaret = i + (replacement as NSString).length
            textView.setSelectedRange(NSRange(location: newCaret, length: 0))
            textView.needsDisplay = true
            return true
        }

        /// Replace the in-progress `@token` at the caret. Returns true if
        /// it edited the buffer.
        func replaceCurrentAtToken(with replacement: String) -> Bool {
            let didReplace = replaceCurrentTriggerToken(trigger: 0x40, replacement: replacement)
            atMenuVisible.wrappedValue = false
            return didReplace
        }

        /// Replace the in-progress `$token` at the caret. Returns true if
        /// it edited the buffer.
        func replaceCurrentSkillToken(with replacement: String) -> Bool {
            let didReplace = replaceCurrentTriggerToken(trigger: 0x24, replacement: replacement)
            skillMenuVisible.wrappedValue = false
            return didReplace
        }

        /// Replaces the complete composer buffer and parks the caret at the
        /// end. Slash-command selection uses this to stage `/<command> ` for
        /// argument entry without losing focus or placing the caret at zero.
        func replaceComposerText(with replacement: String) -> Bool {
            guard let textView = activeTextView else { return false }
            textView.string = replacement
            lastPublishedValue = replacement
            text.wrappedValue = replacement
            let end = (replacement as NSString).length
            textView.setSelectedRange(NSRange(location: end, length: 0))
            textView.needsDisplay = true
            historyIndex = nil
            lastHistoryString = nil
            return true
        }

        /// Inserts content at the live caret rather than appending to the end
        /// of the SwiftUI binding. Protected-secret picker rows use this so a
        /// saved key lands exactly where the user was composing a command.
        func insertComposerTextAtSelection(_ insertion: String) -> Bool {
            guard let textView = activeTextView, !insertion.isEmpty else { return false }
            let source = textView.string as NSString
            let selected = textView.selectedRange()
            guard selected.location != NSNotFound,
                  NSMaxRange(selected) <= source.length else { return false }

            let hasLeadingBoundary = selected.location == 0
                || CharacterSet.whitespacesAndNewlines.contains(
                    UnicodeScalar(source.character(at: selected.location - 1)) ?? UnicodeScalar(32)
                )
            let selectionEnd = NSMaxRange(selected)
            let hasTrailingBoundary = selectionEnd == source.length
                || CharacterSet.whitespacesAndNewlines.contains(
                    UnicodeScalar(source.character(at: selectionEnd)) ?? UnicodeScalar(32)
                )
            let prefix = hasLeadingBoundary ? "" : " "
            let suffix = hasTrailingBoundary ? "" : " "
            let replacement = prefix + insertion + suffix
            let mutable = NSMutableString(string: source)
            mutable.replaceCharacters(in: selected, with: replacement)
            let result = mutable as String
            textView.string = result
            lastPublishedValue = result
            text.wrappedValue = result
            let caret = selected.location + (prefix + insertion).utf16.count
            textView.setSelectedRange(NSRange(location: caret, length: 0))
            textView.needsDisplay = true
            historyIndex = nil
            lastHistoryString = nil
            return true
        }
    }

    static func dismantleNSView(_ nsView: NSScrollView, coordinator: Coordinator) {}
}

final class ComposerNSTextView: NSTextView {
    fileprivate weak var coordinator: ComposerTextEditor.Coordinator?
    fileprivate var placeholder: String = "" {
        didSet {
            if placeholder != oldValue {
                needsDisplay = true
            }
        }
    }
    var inputSuggestion: String? {
        didSet {
            if inputSuggestion != oldValue {
                needsDisplay = true
            }
        }
    }

    fileprivate var slashCommandTokenRanges: ((String) -> [NSRange])?

    /// 回删落在命令词末尾时整个词一起删：命令词是一个整体，删成 `/no-sub`
    /// 就既不是命令也不是正文。
    override func deleteBackward(_ sender: Any?) {
        let selection = selectedRange()
        if selection.length == 0, !hasMarkedText(),
           let token = slashCommandTokenRanges?(string).first(where: { NSMaxRange($0) == selection.location }) {
            setSelectedRange(token)
        }
        super.deleteBackward(sender)
    }

    /// 此刻真正显示出来的建议：输入框为空、不在输入法组字中才算。
    var visibleInputSuggestion: String? {
        guard string.isEmpty, !hasMarkedText(),
              let inputSuggestion, !inputSuggestion.isEmpty else { return nil }
        return inputSuggestion
    }

    // A plain-text NSTextView (`isRichText = false`) only advertises text
    // flavors as readable, so AppKit DISABLES the `paste:` action — and
    // our `paste(_:)` override below never fires — whenever the pasteboard
    // holds ONLY an image and no string. That's exactly the common case:
    // a screenshot (Cmd+Shift+Ctrl+4), "Copy Image" from a browser with no
    // alt text, `screencapture -c`, Preview/Pixelmator copies, etc. The
    // user pressed Cmd+V and nothing happened because the keystroke was
    // swallowed before it ever reached us. Add the image flavors here so
    // the paste action stays enabled when an image is present; the override
    // then routes it into the image-attach pipeline.
    override var readablePasteboardTypes: [NSPasteboard.PasteboardType] {
        super.readablePasteboardTypes + [.png, .tiff]
    }

    /// 见 `ComposerDropSupport`:拖文件进来要变成附件,不是变成一行路径。
    fileprivate var onDropAttachments: ((NSPasteboard) -> Bool)?

    private func handlesDrop(_ sender: NSDraggingInfo) -> Bool {
        onDropAttachments != nil
            && ComposerDropSupport.shouldHandle(types: sender.draggingPasteboard.types ?? [])
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        handlesDrop(sender) ? .copy : super.draggingEntered(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        handlesDrop(sender) ? .copy : super.draggingUpdated(sender)
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        handlesDrop(sender) ? true : super.prepareForDragOperation(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard handlesDrop(sender), let onDropAttachments else {
            return super.performDragOperation(sender)
        }
        // 收下了就绝不调 super,否则路径还是会被插进缓冲区。
        return onDropAttachments(sender.draggingPasteboard)
    }

    override func draw(_ dirtyRect: NSRect) {
        refreshSecretTagAttributes()
        super.draw(dirtyRect)
        drawPlaceholderIfNeeded()
    }

    override func drawBackground(in dirtyRect: NSRect) {
        super.drawBackground(in: dirtyRect)
        guard let layoutManager,
              let textContainer else { return }
        let origin = textContainerOrigin
        for match in AgentSecretStore.placeholderMatches(in: string) {
            let rects = ComposerSecretTagLayout.highlightRects(
                forCharacterRange: match.range,
                layoutManager: layoutManager,
                textContainer: textContainer
            )
            for var rect in rects {
                rect.origin.x += origin.x
                rect.origin.y += origin.y
                rect = rect.insetBy(dx: -3, dy: -1)
                guard rect.intersects(dirtyRect) else { continue }
                NSColor.controlAccentColor.withAlphaComponent(0.13).setFill()
                NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5).fill()
                NSColor.controlAccentColor.withAlphaComponent(0.24).setStroke()
                let border = NSBezierPath(
                    roundedRect: rect.insetBy(dx: 0.5, dy: 0.5),
                    xRadius: 5,
                    yRadius: 5
                )
                border.lineWidth = 1
                border.stroke()
            }
        }
    }

    override func shouldChangeText(in affectedCharRange: NSRange, replacementString: String?) -> Bool {
        let matches = AgentSecretStore.placeholderMatches(in: string)
        let overlapping = matches.filter { match in
            if affectedCharRange.length == 0 {
                return affectedCharRange.location > match.range.location
                    && affectedCharRange.location < NSMaxRange(match.range)
            }
            return NSIntersectionRange(affectedCharRange, match.range).length > 0
        }
        guard !overlapping.isEmpty else {
            return super.shouldChangeText(in: affectedCharRange, replacementString: replacementString)
        }

        // A caret inside the pill cannot mutate its alias character-by-
        // character. Select the complete token so Backspace/Delete removes it
        // atomically and the picker can insert a replacement.
        if affectedCharRange.length == 0 {
            setSelectedRange(overlapping[0].range)
            NSSound.beep()
            return false
        }

        let expanded = overlapping.reduce(affectedCharRange) { partial, match in
            NSUnionRange(partial, match.range)
        }
        let replacement = replacementString ?? ""
        guard super.shouldChangeText(in: expanded, replacementString: replacement) else { return false }
        textStorage?.replaceCharacters(in: expanded, with: replacement)
        didChangeText()
        setSelectedRange(NSRange(location: expanded.location + replacement.utf16.count, length: 0))
        return false
    }

    /// Swap the input font when the chat body size changes. The secret-tag
    /// attributes are temporary layout-manager attributes carrying their own
    /// font, so they must be re-applied — otherwise `@` tags stay at the old
    /// size and sit visibly out of line with the text around them.
    func applyInputFont(ofSize size: CGFloat) {
        guard font?.pointSize != size else { return }
        font = NSFont.systemFont(ofSize: size)
        refreshSecretTagAttributes()
    }

    private func refreshSecretTagAttributes() {
        guard let layoutManager else { return }
        let fullRange = NSRange(location: 0, length: (string as NSString).length)
        layoutManager.removeTemporaryAttribute(.foregroundColor, forCharacterRange: fullRange)
        layoutManager.removeTemporaryAttribute(.font, forCharacterRange: fullRange)
        let tagColor = NSColor.controlAccentColor.blended(withFraction: 0.18, of: .labelColor)
            ?? NSColor.controlAccentColor
        // Derived from the live input size rather than a constant, so the tag
        // keeps its one-point-smaller relationship at every scale.
        let inputSize = font?.pointSize ?? AgentDesign.composerInputFontSize
        let tagFont = NSFont.systemFont(ofSize: max(1, inputSize - 1), weight: .medium)
        for match in AgentSecretStore.placeholderMatches(in: string) {
            layoutManager.addTemporaryAttribute(.foregroundColor, value: tagColor, forCharacterRange: match.range)
            layoutManager.addTemporaryAttribute(.font, value: tagFont, forCharacterRange: match.range)
        }
        // 认出的斜杠命令用深蓝色、稍粗，和正文区分开：一眼看得出哪些词会被
        // 当命令处理、不会作为正文发出去。
        if let ranges = slashCommandTokenRanges?(string), !ranges.isEmpty {
            let commandColor = NSColor.systemBlue.blended(withFraction: 0.3, of: .labelColor) ?? .systemBlue
            let commandFont = NSFont.systemFont(ofSize: inputSize, weight: .semibold)
            for range in ranges where NSMaxRange(range) <= fullRange.length {
                layoutManager.addTemporaryAttribute(.foregroundColor, value: commandColor, forCharacterRange: range)
                layoutManager.addTemporaryAttribute(.font, value: commandFont, forCharacterRange: range)
            }
        }
    }

    private func drawPlaceholderIfNeeded() {
        let suggestion = visibleInputSuggestion
        guard string.isEmpty, !hasMarkedText(), suggestion != nil || !placeholder.isEmpty else { return }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let textFont = font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let containerPadding = textContainer?.lineFragmentPadding ?? 0
        let origin = NSPoint(
            x: textContainerInset.width + containerPadding,
            y: textContainerInset.height
        )
        let rect = NSRect(
            x: origin.x,
            y: origin.y,
            width: max(0, bounds.width - origin.x - textContainerInset.width - containerPadding),
            height: ceil(textFont.ascender - textFont.descender + textFont.leading) + 2
        )
        guard let suggestion else {
            (placeholder as NSString).draw(
                in: rect,
                withAttributes: [
                    .font: textFont,
                    .foregroundColor: NSColor.placeholderTextColor,
                    .paragraphStyle: paragraph
                ]
            )
            return
        }
        let ghost = NSMutableAttributedString(
            string: suggestion,
            attributes: [
                .font: textFont,
                .foregroundColor: NSColor.placeholderTextColor,
                .paragraphStyle: paragraph
            ]
        )
        ghost.append(NSAttributedString(
            string: "  " + L10n.Composer.inputSuggestionAcceptHint,
            attributes: [
                .font: NSFont.systemFont(ofSize: max(1, textFont.pointSize - 2)),
                .foregroundColor: NSColor.tertiaryLabelColor,
                .paragraphStyle: paragraph
            ]
        ))
        ghost.draw(in: rect)
    }

    override func paste(_ sender: Any?) {
        let pasteboard = NSPasteboard.general
        // Use the shared helper instead of probing `.png`/`.tiff`
        // directly — many sources (Notes, Sketch, Figma, web browser
        // drag-out, Cmd+Shift+Ctrl+4 screen capture) advertise images
        // under `public.image` or an NSImage archive, which the
        // narrow check missed. Result: paste only worked for a
        // handful of apps. The helper also peeks via
        // `NSImage.canInit(with:)` to catch every variant AppKit
        // knows how to decode.
        if AgentImagePasteboardHelper.pasteboardHasImage(pasteboard) {
            coordinator?.onPasteImage()
            if let plain = pasteboard.string(forType: .string), !plain.isEmpty {
                if AgentTextAttachment.shouldCapturePaste(plain) {
                    coordinator?.onPasteText(plain)
                } else {
                    insertText(plain, replacementRange: selectedRange())
                }
            }
            return
        }
        // Non-image paste: force plain-text. The composer is a chat
        // input, not a rich editor — bringing in foreign fonts /
        // backgrounds from the source app (browser, terminal, Notes)
        // makes the bubble look broken and the next-turn payload bloat
        // with attributes the model can't read anyway.
        if let plain = pasteboard.string(forType: .string), !plain.isEmpty {
            if AgentTextAttachment.shouldCapturePaste(plain) {
                coordinator?.onPasteText(plain)
                return
            }
            insertText(plain, replacementRange: selectedRange())
            return
        }
        pasteAsPlainText(sender)
    }
}
