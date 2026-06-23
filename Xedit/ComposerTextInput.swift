//
//  ComposerTextInput.swift
//  WillDeep
//
//  NSTextView-backed composer input + coordinator, split out of
//  AgentModeComposerView.swift in rc42. Two pieces:
//   - `ComposerTextEditor` (NSViewRepresentable): the SwiftUI bridge.
//     Wires Return-submits, ↑/↓ history cycling, Cmd+V image intercept,
//     and the "/" and "@" popover state bindings owned by ComposerCard.
//   - `ComposerNSTextView` (NSTextView subclass): force-plain-text paste,
//     image-pasteboard detection via `AgentImagePasteboardHelper`.
//
//  The coordinator owns the history cursor (savedDraft + historyIndex)
//  and the @-token query derivation — both are stateful enough to need
//  a class rather than living inside the SwiftUI struct.
//

import AppKit
import SwiftUI

struct ComposerTextEditor: NSViewRepresentable {
    @Binding var text: String
    let onSubmit: () -> Void
    let onPasteImage: () -> Void
    let onPasteText: (String) -> Void
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
    /// Same shape as the slash palette, used for the "@" skill picker.
    @Binding var atMenuVisible: Bool
    @Binding var atMenuSelection: Int
    let atMenuItemCount: () -> Int
    let onAtCommit: () -> Bool
    let onAtCancel: () -> Void
    /// Notifies the composer card that the @ token in the buffer has
    /// changed (e.g. user kept typing letters after `@`), so the popover
    /// can re-filter its entries.
    let onAtQueryChange: (String?) -> Void
    /// Holder the parent passes in so it can hand the coordinator
    /// pointer back to SwiftUI menu callbacks (used by the @-token
    /// replacement helper). Filled in inside `makeCoordinator`.
    let coordinatorRef: ComposerCoordinatorRef

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
            atMenuVisible: $atMenuVisible,
            atMenuSelection: $atMenuSelection,
            atMenuItemCount: atMenuItemCount,
            onAtCommit: onAtCommit,
            onAtCancel: onAtCancel,
            onAtQueryChange: onAtQueryChange
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
        textView.font = NSFont.systemFont(ofSize: 13)
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isEditable = true
        textView.isSelectable = true
        textView.autoresizingMask = [.width]
        textView.textContainerInset = NSSize(width: 0, height: 2)
        textView.string = text
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
        guard let textView = nsView.documentView as? NSTextView else { return }
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
        var atMenuVisible: Binding<Bool>
        var atMenuSelection: Binding<Int>
        let atMenuItemCount: () -> Int
        let onAtCommit: () -> Bool
        let onAtCancel: () -> Void
        let onAtQueryChange: (String?) -> Void

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
            atMenuVisible: Binding<Bool>,
            atMenuSelection: Binding<Int>,
            atMenuItemCount: @escaping () -> Int,
            onAtCommit: @escaping () -> Bool,
            onAtCancel: @escaping () -> Void,
            onAtQueryChange: @escaping (String?) -> Void
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
            self.atMenuVisible = atMenuVisible
            self.atMenuSelection = atMenuSelection
            self.atMenuItemCount = atMenuItemCount
            self.onAtCommit = onAtCommit
            self.onAtCancel = onAtCancel
            self.onAtQueryChange = onAtQueryChange
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
            // slash + @ visibility.
            if newValue != lastHistoryString {
                historyIndex = nil
                lastHistoryString = nil
            }
            updateSlashMenuVisibility(for: newValue)
            updateAtMenuVisibility(for: textView)
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

            // @ skill picker takes priority over submit while it's open,
            // but defers caret motion (↑/↓) ONLY when the menu actually
            // has items to step through — keeps multi-line composition
            // unaffected when there are no skill matches.
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
                    if onAtCommit() { return true }
                case #selector(NSResponder.cancelOperation(_:)):
                    onAtCancel()
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
        }

        private func updateSlashMenuVisibility(for newValue: String) {
            // Show the palette only when the buffer starts with "/" and
            // has no embedded newline yet. A trailing space ends the
            // command name and dismisses the menu.
            let trimmed = newValue.trimmingCharacters(in: .whitespaces)
            let shouldShow = newValue.hasPrefix("/")
                && !newValue.contains("\n")
                && !trimmed.isEmpty
            if slashMenuVisible.wrappedValue != shouldShow {
                slashMenuVisible.wrappedValue = shouldShow
                if shouldShow {
                    slashMenuSelection.wrappedValue = 0
                }
            }
        }

        /// Looks at the caret position and decides whether the user is
        /// inside an `@token` (counting backwards from the caret to the
        /// nearest `@`, stopping at whitespace/newline/another `@`).
        /// Returns the substring after `@` so the popover can filter.
        fileprivate func currentAtQuery(in textView: NSTextView) -> String? {
            let nsString = textView.string as NSString
            let caret = textView.selectedRange().location
            guard caret > 0, caret <= nsString.length else { return nil }
            var i = caret - 1
            while i >= 0 {
                let ch = nsString.character(at: i)
                let scalar = UnicodeScalar(ch)
                if ch == 0x40 { // '@'
                    // Require that '@' sits at the start of the buffer
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

        /// Replace the in-progress `@token` at the caret with the chosen
        /// skill's identifier (kept around for transparency — actual
        /// skill content gets spliced in at send time) and dismiss the
        /// popover. Returns true if it edited the buffer.
        func replaceCurrentAtToken(with replacement: String) -> Bool {
            guard let textView = activeTextView else { return false }
            let nsString = textView.string as NSString
            let caret = textView.selectedRange().location
            guard caret > 0, caret <= nsString.length else { return false }
            var i = caret - 1
            while i >= 0 {
                let ch = nsString.character(at: i)
                if ch == 0x40 { break }
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
            atMenuVisible.wrappedValue = false
            return true
        }
    }

    static func dismantleNSView(_ nsView: NSScrollView, coordinator: Coordinator) {}
}

fileprivate final class ComposerNSTextView: NSTextView {
    fileprivate weak var coordinator: ComposerTextEditor.Coordinator?

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
