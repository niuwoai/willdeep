//
//  EditorView.swift
//  WillDeep
//
//  Created by rocky on 2026/5/27.
//

import SwiftUI
import AppKit

/// An NSViewRepresentable that wraps NSTextView inside an NSScrollView
/// for native macOS text editing performance within a SwiftUI view hierarchy.
///
/// Supports syntax highlighting, line numbers, editor font settings, color
/// themes, and current-line focus highlighting.
struct EditorView: NSViewRepresentable {
    @Binding var text: String

    /// The language to use for syntax highlighting. `nil` disables highlighting.
    var language: Language?
    var detectedLanguage: Language?
    var syntaxHighlightingSelection: SyntaxHighlightingSelection = .automatic

    /// User-configurable editor appearance.
    var settings: EditorSettings

    /// Identity of the active tab. The single shared NSTextView is reused across
    /// tabs; this lets the coordinator save the outgoing tab's cursor/scroll and
    /// restore the incoming tab's, so switching tabs returns to where you were.
    var activeTabID: UUID?

    /// Explicit render token used when SwiftUI keeps the same NSTextView alive
    /// across tab activation changes.
    var renderRevision = 0

    /// Explicit highlight token used after file load completes.
    var highlightRevision = 0

    /// A one-shot line navigation request from the inspector/minimap.
    var navigationRequest: EditorNavigationRequest?

    /// A one-shot exact cursor placement request after programmatic editor edits.
    var textSelectionRequest: EditorTextSelectionRequest?

    /// Lines whose current content differs from the last saved content.
    var changedLineNumbers: Set<Int> = []

    /// Ranges matching the current find query.
    var searchRanges: [NSRange] = []

    /// The active find match, shown more prominently than the rest.
    var activeSearchRange: NSRange?

    /// Language-server diagnostics rendered as editor underlines.
    var diagnosticIssues: [EditorDiagnosticIssue] = []

    /// Language-server document highlights for the symbol under the caret.
    var documentHighlightSpans: [EditorDocumentHighlightSpan] = []

    /// Language-server semantic tokens rendered over regex fallback colors.
    var semanticTokenSpans: [EditorSemanticTokenSpan] = []

    /// Language-server inlay hints rendered as virtual overlay text.
    var inlayHintSpans: [EditorInlayHintSpan] = []

    /// Language-server document links rendered as clickable semantic links.
    var documentLinkSpans: [EditorDocumentLinkSpan] = []

    /// Language-server folding ranges rendered in the gutter when available.
    var languageServiceFoldingGuides: [ScopeGuide] = []
    var languageServiceFoldingIsAuthoritative = false

    /// Immediate, constant-time dirty-state hook. This must stay cheap so the
    /// native text view can paint the just-entered glyph without waiting for
    /// language-service or document-analysis work.
    var onImmediateEdit: (() -> Void)?

    /// Debounced edit hook for document analysis and other auxiliary work.
    var onEdit: (() -> Void)?

    /// Called when the caret or selection moves so the status bar can stay current.
    var onSelectionChange: ((Int, Int, Int, Int, String, Int) -> Void)?

    /// Called when the user picks a syntax highlighting mode from the editor menu.
    var onSyntaxHighlightingChange: ((SyntaxHighlightingSelection) -> Void)?

    /// Called from the editor context menu to stage the current text selection
    /// as Agent conversation context without immediately sending it.
    var onAddSelectionToAgentConversation: ((AgentEditorSelectionContext) -> Void)?

    /// Called from the editor context menu to reveal the side Agent panel and
    /// stage the current text selection as context for a question.
    var onAskSelectionInAgentPanel: ((AgentEditorSelectionContext) -> Void)?

    /// Called when the user asks to jump to the project-local definition of a
    /// symbol under the cursor.
    var onGoToDefinition: ((EditorDefinitionRequest) -> Void)?

    /// Called when the user asks to jump to the language-server declaration.
    var onGoToDeclaration: ((EditorDeclarationRequest) -> Void)?

    /// Called when the user asks to jump to the language-server type definition.
    var onGoToTypeDefinition: ((EditorTypeDefinitionRequest) -> Void)?

    /// Called when the user asks to jump to the language-server implementation.
    var onGoToImplementation: ((EditorImplementationRequest) -> Void)?

    /// Called when the user asks for language-server references.
    var onFindReferences: ((EditorReferenceRequest) -> Void)?

    /// Called when the user asks for language-server call hierarchy.
    var onShowCallHierarchy: ((EditorCallHierarchyRequest) -> Void)?

    /// Called when the user asks the language server to rename a symbol.
    var onRenameSymbol: ((EditorRenameRequest) -> Void)?

    /// Called when the user asks the language server to format the document.
    var onFormatDocument: (() -> Void)?

    /// Called when the user asks the language server to format the current selection.
    var onFormatSelection: ((EditorRangeFormattingRequest) -> Void)?

    /// Called when the user asks for language-server hover information.
    var onShowHoverInfo: ((EditorHoverRequest) -> Void)?

    /// Called when the user asks for language-server completions.
    var onShowCompletions: ((EditorCompletionRequest) -> Void)?

    /// Called when the user asks for language-server signature help.
    var onShowSignatureHelp: ((EditorSignatureHelpRequest) -> Void)?

    /// Called when the user asks for language-server code actions.
    var onShowCodeActions: ((EditorCodeActionRequest) -> Void)?

    /// Called when the user asks the language server for a semantic selection expansion.
    var onExpandSelection: ((EditorSelectionRangeRequest) -> Void)?

    /// Called when the user command-clicks a language-server document link.
    var onOpenDocumentLink: ((EditorDocumentLinkSpan) -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        let textView = WillDeepTextView()

        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        // Default NSScrollView border is `.bezelBorder`, which draws a hairline
        // along the top edge — it peeked out above the gutter ruler as a stray
        // line sitting just over line "1". Drop it.
        scrollView.borderType = .noBorder
        scrollView.autoresizingMask = [.width, .height]
        scrollView.contentView.postsBoundsChangedNotifications = true

        // Keep user editing and pasteboard import strictly plain-text. Syntax
        // highlighting still uses programmatic text-storage attributes; AppKit
        // does not require rich-text editing to render those attributes.
        textView.isEditable = true
        textView.importsGraphics = false
        textView.configureCodeEditingBehavior()
        textView.allowsUndo = true
        textView.textContainerInset = NSSize(width: 12, height: 8)
        textView.textContainer?.lineFragmentPadding = 0
        configureTextViewGeometry(textView, in: scrollView)
        textView.delegate = context.coordinator
        textView.layoutManager?.delegate = context.coordinator
        // NOTE: non-contiguous layout was tried here to speed up tab switching,
        // but it made window re-activation (clicking the Dock icon) janky and
        // amplified fold invalidation cost. The tab-switch win actually came from
        // not forcing a full-document ensureLayout on switch (see
        // `preserveViewport` below), so we keep the default contiguous layout.
        textView.syntaxHighlightingSelection = syntaxHighlightingSelection
        textView.detectedLanguage = detectedLanguage
        textView.scopeGuideLanguage = language
        textView.inlayHintSpans = inlayHintSpans
        textView.documentLinkSpans = documentLinkSpans
        textView.languageServiceFoldingGuides = languageServiceFoldingGuides
        textView.languageServiceFoldingIsAuthoritative = languageServiceFoldingIsAuthoritative
        textView.onSyntaxHighlightingChange = { [weak coordinator = context.coordinator] selection in
            coordinator?.parent.onSyntaxHighlightingChange?(selection)
        }
        textView.onAddSelectionToAgentConversation = { [weak coordinator = context.coordinator] selection in
            coordinator?.parent.onAddSelectionToAgentConversation?(selection)
        }
        textView.onAskSelectionInAgentPanel = { [weak coordinator = context.coordinator] selection in
            coordinator?.parent.onAskSelectionInAgentPanel?(selection)
        }
        textView.onGoToDefinition = { [weak coordinator = context.coordinator] request in
            coordinator?.parent.onGoToDefinition?(request)
        }
        textView.onGoToDeclaration = { [weak coordinator = context.coordinator] request in
            coordinator?.parent.onGoToDeclaration?(request)
        }
        textView.onGoToTypeDefinition = { [weak coordinator = context.coordinator] request in
            coordinator?.parent.onGoToTypeDefinition?(request)
        }
        textView.onGoToImplementation = { [weak coordinator = context.coordinator] request in
            coordinator?.parent.onGoToImplementation?(request)
        }
        textView.onFindReferences = { [weak coordinator = context.coordinator] request in
            coordinator?.parent.onFindReferences?(request)
        }
        textView.onShowCallHierarchy = { [weak coordinator = context.coordinator] request in
            coordinator?.parent.onShowCallHierarchy?(request)
        }
        textView.onRenameSymbol = { [weak coordinator = context.coordinator] request in
            coordinator?.parent.onRenameSymbol?(request)
        }
        textView.onFormatDocument = { [weak coordinator = context.coordinator] in
            coordinator?.parent.onFormatDocument?()
        }
        textView.onFormatSelection = { [weak coordinator = context.coordinator] request in
            coordinator?.parent.onFormatSelection?(request)
        }
        textView.onShowHoverInfo = { [weak coordinator = context.coordinator] request in
            coordinator?.parent.onShowHoverInfo?(request)
        }
        textView.onShowCompletions = { [weak coordinator = context.coordinator] request in
            coordinator?.parent.onShowCompletions?(request)
        }
        textView.onShowSignatureHelp = { [weak coordinator = context.coordinator] request in
            coordinator?.parent.onShowSignatureHelp?(request)
        }
        textView.onShowCodeActions = { [weak coordinator = context.coordinator] request in
            coordinator?.parent.onShowCodeActions?(request)
        }
        textView.onExpandSelection = { [weak coordinator = context.coordinator] request in
            coordinator?.parent.onExpandSelection?(request)
        }
        textView.onOpenDocumentLink = { [weak coordinator = context.coordinator] link in
            coordinator?.parent.onOpenDocumentLink?(link)
        }

        let ruler = LineNumberRulerView(scrollView: scrollView, textView: textView)
        scrollView.verticalRulerView = ruler

        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.visibleRectDidChange),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )

        context.coordinator.applyAppearance(to: textView, in: scrollView)
        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = nsView.documentView as? WillDeepTextView else { return }

        context.coordinator.parent = self
        // NSTextView owns the marked-text buffer while a CJK input method is
        // composing. Any SwiftUI-driven appearance/text/highlight refresh in
        // that window can rewrite text storage or selection and prematurely
        // commit the raw pinyin. The commit emits another update/textDidChange,
        // so defer all representable updates until AppKit ends composition.
        guard !textView.hasMarkedText() else { return }
        configureTextViewGeometry(textView, in: nsView)

        let langChanged = context.coordinator.currentLanguage != language
        let settingsChanged = context.coordinator.currentSettings != settings
        let renderRevisionChanged = context.coordinator.currentRenderRevision != renderRevision
        let highlightRevisionChanged = context.coordinator.currentHighlightRevision != highlightRevision
        let navigationChanged = context.coordinator.currentNavigationRequest != navigationRequest
        let textSelectionChanged = context.coordinator.currentTextSelectionRequest != textSelectionRequest
        let searchChanged = context.coordinator.currentSearchRanges != searchRanges
            || context.coordinator.currentActiveSearchRange != activeSearchRange
        let diagnosticsChanged = context.coordinator.currentDiagnosticIssues != diagnosticIssues
        let documentHighlightsChanged = context.coordinator.currentDocumentHighlightSpans != documentHighlightSpans
        let semanticTokensChanged = context.coordinator.currentSemanticTokenSpans != semanticTokenSpans
        let inlayHintsChanged = context.coordinator.currentInlayHintSpans != inlayHintSpans
        let documentLinksChanged = context.coordinator.currentDocumentLinkSpans != documentLinkSpans
        let languageServiceFoldingChanged = context.coordinator.currentLanguageServiceFoldingGuides != languageServiceFoldingGuides
            || context.coordinator.currentLanguageServiceFoldingIsAuthoritative != languageServiceFoldingIsAuthoritative
        context.coordinator.currentLanguage = language
        context.coordinator.currentSettings = settings
        context.coordinator.currentRenderRevision = renderRevision
        context.coordinator.currentHighlightRevision = highlightRevision
        context.coordinator.currentNavigationRequest = navigationRequest
        context.coordinator.currentTextSelectionRequest = textSelectionRequest
        context.coordinator.currentSearchRanges = searchRanges
        context.coordinator.currentActiveSearchRange = activeSearchRange
        context.coordinator.currentDiagnosticIssues = diagnosticIssues
        context.coordinator.currentDocumentHighlightSpans = documentHighlightSpans
        context.coordinator.currentSemanticTokenSpans = semanticTokenSpans
        context.coordinator.currentInlayHintSpans = inlayHintSpans
        context.coordinator.currentDocumentLinkSpans = documentLinkSpans
        context.coordinator.currentLanguageServiceFoldingGuides = languageServiceFoldingGuides
        context.coordinator.currentLanguageServiceFoldingIsAuthoritative = languageServiceFoldingIsAuthoritative
        textView.layoutManager?.delegate = context.coordinator
        textView.syntaxHighlightingSelection = syntaxHighlightingSelection
        textView.detectedLanguage = detectedLanguage
        textView.scopeGuideLanguage = language
        if inlayHintsChanged {
            textView.inlayHintSpans = inlayHintSpans
            textView.needsDisplay = true
        }
        if documentLinksChanged {
            textView.documentLinkSpans = documentLinkSpans
        }
        if languageServiceFoldingChanged {
            textView.languageServiceFoldingGuides = languageServiceFoldingGuides
            textView.languageServiceFoldingIsAuthoritative = languageServiceFoldingIsAuthoritative
            textView.clearFoldedScopes()
            nsView.verticalRulerView?.needsDisplay = true
        }
        textView.onSyntaxHighlightingChange = { [weak coordinator = context.coordinator] selection in
            coordinator?.parent.onSyntaxHighlightingChange?(selection)
        }
        textView.onAddSelectionToAgentConversation = { [weak coordinator = context.coordinator] selection in
            coordinator?.parent.onAddSelectionToAgentConversation?(selection)
        }
        textView.onAskSelectionInAgentPanel = { [weak coordinator = context.coordinator] selection in
            coordinator?.parent.onAskSelectionInAgentPanel?(selection)
        }
        textView.onGoToDefinition = { [weak coordinator = context.coordinator] request in
            coordinator?.parent.onGoToDefinition?(request)
        }
        textView.onGoToDeclaration = { [weak coordinator = context.coordinator] request in
            coordinator?.parent.onGoToDeclaration?(request)
        }
        textView.onGoToTypeDefinition = { [weak coordinator = context.coordinator] request in
            coordinator?.parent.onGoToTypeDefinition?(request)
        }
        textView.onGoToImplementation = { [weak coordinator = context.coordinator] request in
            coordinator?.parent.onGoToImplementation?(request)
        }
        textView.onFindReferences = { [weak coordinator = context.coordinator] request in
            coordinator?.parent.onFindReferences?(request)
        }
        textView.onShowCallHierarchy = { [weak coordinator = context.coordinator] request in
            coordinator?.parent.onShowCallHierarchy?(request)
        }
        textView.onRenameSymbol = { [weak coordinator = context.coordinator] request in
            coordinator?.parent.onRenameSymbol?(request)
        }
        textView.onFormatDocument = { [weak coordinator = context.coordinator] in
            coordinator?.parent.onFormatDocument?()
        }
        textView.onFormatSelection = { [weak coordinator = context.coordinator] request in
            coordinator?.parent.onFormatSelection?(request)
        }
        textView.onShowHoverInfo = { [weak coordinator = context.coordinator] request in
            coordinator?.parent.onShowHoverInfo?(request)
        }
        textView.onShowCompletions = { [weak coordinator = context.coordinator] request in
            coordinator?.parent.onShowCompletions?(request)
        }
        textView.onShowSignatureHelp = { [weak coordinator = context.coordinator] request in
            coordinator?.parent.onShowSignatureHelp?(request)
        }
        textView.onShowCodeActions = { [weak coordinator = context.coordinator] request in
            coordinator?.parent.onShowCodeActions?(request)
        }
        textView.onExpandSelection = { [weak coordinator = context.coordinator] request in
            coordinator?.parent.onExpandSelection?(request)
        }
        textView.onOpenDocumentLink = { [weak coordinator = context.coordinator] link in
            coordinator?.parent.onOpenDocumentLink?(link)
        }
        // `applyAppearance` sets a dozen NSTextView properties (font, theme,
        // typingAttributes, paragraph style) and re-tiles the line-number ruler
        // — non-trivial on large files. SwiftUI re-fires `updateNSView` on every
        // window re-activation; running it then when nothing has actually
        // changed was a big slice of the reactivation lag. Skip the heavy parts
        // when settings/language/render haven't changed, but always push the
        // cheap, edit-driven changedLineNumbers update to the ruler.
        if settingsChanged || langChanged || renderRevisionChanged {
            context.coordinator.applyAppearance(to: textView, in: nsView)
        } else if let ruler = nsView.verticalRulerView as? LineNumberRulerView,
                  ruler.changedLineNumbers != changedLineNumbers {
            ruler.changedLineNumbers = changedLineNumbers
            ruler.needsDisplay = true
        }

        // A tab switch arrives as a changed activeTabID plus new content. Save the
        // outgoing tab's cursor/scroll before the content is replaced.
        let tabSwitched = context.coordinator.beginTabTransitionIfNeeded(to: activeTabID, in: textView)

        // Detect programmatic text changes (file load, not user typing).
        if textView.string != text || langChanged || settingsChanged || renderRevisionChanged || highlightRevisionChanged || semanticTokensChanged {
            textView.clearFoldedScopes()
            context.coordinator.suppressDirtyFlag = true
            context.coordinator.applyText(text, to: textView)
            context.coordinator.suppressDirtyFlag = false
        } else if searchChanged {
            context.coordinator.applySearchHighlights(to: textView)
        }
        if diagnosticsChanged || documentHighlightsChanged || documentLinksChanged || searchChanged || highlightRevisionChanged || renderRevisionChanged || settingsChanged || langChanged {
            context.coordinator.applyDiagnosticHighlights(to: textView)
        }

        // Restore the incoming tab's cursor/scroll after its content is in place.
        if tabSwitched {
            context.coordinator.finishTabTransition(to: activeTabID, in: textView)
        }

        if navigationChanged, let navigationRequest {
            context.coordinator.navigate(toLine: navigationRequest.line, in: textView)
        }
        if textSelectionChanged, let textSelectionRequest {
            context.coordinator.select(range: textSelectionRequest.range, in: textView)
        }
    }

    private func configureTextViewGeometry(_ textView: WillDeepTextView, in scrollView: NSScrollView) {
        textView.minSize = NSSize(width: 0, height: scrollView.contentSize.height)
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.containerSize = NSSize(
            width: max(1, scrollView.contentSize.width),
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainer?.widthTracksTextView = true
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, NSLayoutManagerDelegate, NSTextViewDelegate {
        var parent: EditorView

        /// When `true`, `textDidChange` will skip calling `onEdit` —
        /// used during programmatic text changes in `updateNSView`.
        var suppressDirtyFlag = false

        /// Tracks the current language so we can detect changes.
        var currentLanguage: Language?

        /// Tracks the current settings so we can refresh text attributes.
        var currentSettings: EditorSettings

        var currentRenderRevision: Int
        var currentHighlightRevision: Int
        var currentNavigationRequest: EditorNavigationRequest?
        var currentTextSelectionRequest: EditorTextSelectionRequest?
        var currentSearchRanges: [NSRange]
        var currentActiveSearchRange: NSRange?
        var currentDiagnosticIssues: [EditorDiagnosticIssue]
        var currentDocumentHighlightSpans: [EditorDocumentHighlightSpan]
        var currentSemanticTokenSpans: [EditorSemanticTokenSpan]
        var currentInlayHintSpans: [EditorInlayHintSpan]
        var currentDocumentLinkSpans: [EditorDocumentLinkSpan]
        var currentLanguageServiceFoldingGuides: [ScopeGuide]
        var currentLanguageServiceFoldingIsAuthoritative: Bool

        /// Debounced highlight work item.
        private var highlightWorkItem: DispatchWorkItem?
        private var highlightGeneration = 0

        /// Non-rendering editor work is intentionally kept off the immediate
        /// NSTextView edit callback. AppKit can paint the inserted glyph as
        /// soon as `textDidChange` returns; folding, CJK attribute repair,
        /// LSP scheduling, cursor publication, and gutter refresh are safely
        /// coalesced across a short typing burst.
        private var postInputWorkItem: DispatchWorkItem?
        private weak var pendingInputTextView: WillDeepTextView?
        private var pendingInputChangedText = false
        private var pendingInputMarksDocumentDirty = false
        private static let postInputDelay: TimeInterval = 0.05

        // MARK: Viewport highlighting (large files)

        /// Files at or above this UTF-16 length highlight only the visible range
        /// (plus a margin) instead of the whole document, so opening and scrolling
        /// huge files stays responsive. Smaller files keep the simple full-file
        /// async path.
        private static let viewportHighlightThreshold = 100_000

        /// Characters of overscan added on each side of the visible range before
        /// highlighting, snapped to line boundaries. A generous margin lets most
        /// multi-line tokens (block comments, multi-line strings) resolve and
        /// pre-warms scrolling so highlight rarely "pops" in.
        private static let viewportHighlightMargin = 8_000

        /// Bootstrap enough layout after a fresh text-storage swap that older
        /// AppKit builds have a concrete first viewport even before SwiftUI has
        /// delivered a non-zero visible rect.
        private static let initialLayoutCharacterLimit = 20_000
        private static let publishedSelectionTextLimit = 6_000

        /// Debounced viewport re-highlight on scroll.
        private var viewportHighlightWorkItem: DispatchWorkItem?

        /// Character ranges already highlighted for the current document, so a
        /// scroll only highlights newly-revealed regions. Reset when the document
        /// or language changes.
        private var highlightedRanges = IndexSet()

        /// `true` while the current document uses viewport highlighting.
        private var usesViewportHighlighting = false

        // MARK: Per-tab cursor/scroll restoration

        /// Saved caret location and top-of-viewport character index per tab, so
        /// switching tabs returns to where the user left off instead of jumping to
        /// the top. Storing a character index (not a pixel offset) lets us restore
        /// with local layout only.
        private var tabEditingState: [UUID: (cursorLocation: Int, topCharIndex: Int)] = [:]

        /// The tab whose content is currently shown, to detect switches.
        private var currentTabID: UUID?

        init(_ parent: EditorView) {
            self.parent = parent
            self.currentLanguage = parent.language
            self.currentSettings = parent.settings
            self.currentRenderRevision = parent.renderRevision
            self.currentHighlightRevision = parent.highlightRevision
            self.currentNavigationRequest = parent.navigationRequest
            self.currentTextSelectionRequest = parent.textSelectionRequest
            self.currentSearchRanges = parent.searchRanges
            self.currentActiveSearchRange = parent.activeSearchRange
            self.currentDiagnosticIssues = parent.diagnosticIssues
            self.currentDocumentHighlightSpans = parent.documentHighlightSpans
            self.currentSemanticTokenSpans = parent.semanticTokenSpans
            self.currentInlayHintSpans = parent.inlayHintSpans
            self.currentDocumentLinkSpans = parent.documentLinkSpans
            self.currentLanguageServiceFoldingGuides = parent.languageServiceFoldingGuides
            self.currentLanguageServiceFoldingIsAuthoritative = parent.languageServiceFoldingIsAuthoritative
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? WillDeepTextView else { return }
            // Marked text is AppKit-owned provisional input, not document
            // content yet. Publishing it to SwiftUI or scheduling a whole
            // text-storage replacement cancels the IME candidate session and
            // leaves raw pinyin in the editor. Invalidate any highlight already
            // in flight; the committed textDidChange will run the normal path.
            guard !textView.hasMarkedText() else {
                cancelPendingHighlightForIMEComposition()
                return
            }
            // Keep the document model current synchronously so Save/Save As
            // can never miss the newest keystroke. Everything that does not
            // affect that correctness contract is deferred below, allowing
            // AppKit to return to glyph display immediately.
            parent.text = textView.string
            if !suppressDirtyFlag {
                parent.onImmediateEdit?()
            }
            // Publishing into SwiftUI can invalidate this representable in the
            // same run-loop turn. Refresh the native insertion point before
            // yielding so the caret rectangle follows the newly inserted
            // glyph instead of waiting for the debounced chrome pass.
            textView.updateInsertionPointStateAndRestartTimer(true)
            schedulePostInputWork(
                for: textView,
                textChanged: true,
                marksDocumentDirty: !suppressDirtyFlag
            )
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? WillDeepTextView else { return }
            textView.invalidateCurrentLineHighlight()
            guard !textView.hasMarkedText() else { return }
            schedulePostInputWork(
                for: textView,
                textChanged: false,
                marksDocumentDirty: false
            )
        }

        private func schedulePostInputWork(
            for textView: WillDeepTextView,
            textChanged: Bool,
            marksDocumentDirty: Bool
        ) {
            if let pendingInputTextView, pendingInputTextView !== textView {
                performPendingInputWork()
            }
            pendingInputTextView = textView
            pendingInputChangedText = pendingInputChangedText || textChanged
            pendingInputMarksDocumentDirty = pendingInputMarksDocumentDirty || marksDocumentDirty
            postInputWorkItem?.cancel()
            let workItem = DispatchWorkItem { [weak self] in
                self?.performPendingInputWork()
            }
            postInputWorkItem = workItem
            DispatchQueue.main.asyncAfter(
                deadline: .now() + Self.postInputDelay,
                execute: workItem
            )
        }

        private func performPendingInputWork() {
            postInputWorkItem?.cancel()
            postInputWorkItem = nil
            guard let textView = pendingInputTextView else {
                pendingInputChangedText = false
                pendingInputMarksDocumentDirty = false
                return
            }
            let textChanged = pendingInputChangedText
            let marksDocumentDirty = pendingInputMarksDocumentDirty
            pendingInputTextView = nil
            pendingInputChangedText = false
            pendingInputMarksDocumentDirty = false

            if textChanged {
                textView.invalidateFoldableGuidesCache()
                textView.clearFoldedScopes()
                applyLiveEditorCJKFallbackFonts(to: textView)
                if marksDocumentDirty {
                    parent.onEdit?()
                }
                scheduleHighlight(textView: textView)
            }
            publishCursorPosition(for: textView)
            applyBracketHighlight(to: textView)
            refreshEditorChrome(for: textView, redrawTextView: false)
        }

        private func cancelPendingHighlightForIMEComposition() {
            highlightWorkItem?.cancel()
            viewportHighlightWorkItem?.cancel()
            postInputWorkItem?.cancel()
            postInputWorkItem = nil
            pendingInputTextView = nil
            pendingInputChangedText = false
            pendingInputMarksDocumentDirty = false
            highlightGeneration += 1
        }

        @objc func visibleRectDidChange(_ notification: Notification) {
            guard let clipView = notification.object as? NSClipView,
                  let scrollView = clipView.enclosingScrollView,
                  let textView = scrollView.documentView as? WillDeepTextView else {
                return
            }
            refreshEditorChrome(for: textView)

            // Extend viewport highlighting into newly-revealed regions of a large
            // file (debounced so a fling-scroll doesn't queue many passes).
            guard usesViewportHighlighting, let lang = currentLanguage else { return }
            viewportHighlightWorkItem?.cancel()
            let settings = parent.settings
            let workItem = DispatchWorkItem { [weak self, weak textView] in
                guard let self = self, let textView = textView else { return }
                self.highlightVisibleRange(in: textView, language: lang, settings: settings)
            }
            viewportHighlightWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: workItem)
        }

        func layoutManager(
            _ layoutManager: NSLayoutManager,
            shouldSetLineFragmentRect lineFragmentRect: UnsafeMutablePointer<NSRect>,
            lineFragmentUsedRect: UnsafeMutablePointer<NSRect>,
            baselineOffset: UnsafeMutablePointer<CGFloat>,
            in textContainer: NSTextContainer,
            forGlyphRange glyphRange: NSRange
        ) -> Bool {
            guard let textView = textContainer.textView as? WillDeepTextView,
                  textView.isFoldedGlyphRange(glyphRange, layoutManager: layoutManager) else {
                return true
            }

            lineFragmentRect.pointee.size.height = 0
            lineFragmentUsedRect.pointee.size.height = 0
            lineFragmentUsedRect.pointee.size.width = 0
            baselineOffset.pointee = 0
            return true
        }

        func applyAppearance(to textView: WillDeepTextView, in scrollView: NSScrollView) {
            let theme = parent.settings.theme
            let font = parent.settings.editorFont()
            let paragraphStyle = parent.settings.editorParagraphStyle()
            let surfaceOpacity = parent.settings.editorGlassEnabled ? CGFloat(parent.settings.editorSurfaceOpacity) : 1
            let editorBackgroundColor = theme.backgroundColor.withAlphaComponent(surfaceOpacity)

            scrollView.drawsBackground = !parent.settings.editorGlassEnabled
            scrollView.backgroundColor = editorBackgroundColor
            scrollView.rulersVisible = parent.settings.showsLineNumbers
            scrollView.hasVerticalRuler = parent.settings.showsLineNumbers

            textView.font = font
            textView.drawsBackground = true
            textView.backgroundColor = editorBackgroundColor
            textView.insertionPointColor = theme.insertionPointColor
            textView.selectedTextAttributes = WillDeepTextView.codeSelectionTextAttributes
            textView.currentLineColor = theme.currentLineBackgroundColor
            textView.foldedPlaceholderColor = theme.gutterTextColor
            textView.foldedPlaceholderBackgroundColor = theme.gutterTextColor.withAlphaComponent(0.12)
            textView.showsCurrentLineHighlight = parent.settings.highlightsCurrentLine
            textView.defaultParagraphStyle = paragraphStyle
            textView.typingAttributes = [
                .font: font,
                .foregroundColor: theme.foregroundColor,
                .paragraphStyle: paragraphStyle,
            ]

            if let ruler = scrollView.verticalRulerView as? LineNumberRulerView {
                ruler.settings = parent.settings
                ruler.theme = theme
                let fontChanged = ruler.font != font
                ruler.font = font
                ruler.changedLineNumbers = parent.changedLineNumbers
                ruler.needsDisplay = true
                // `requiredThickness` scans the document to count lines, and
                // `tile()` re-lays out the scroll view — both costly on large
                // files. Only recompute when something that can actually change
                // the thickness changed (font size or the line count itself).
                // `lineCount()` is now cached by length so this stays cheap.
                if fontChanged || ruler.thicknessNeedsRefresh() {
                    ruler.invalidateRuleThickness()
                }
            }
            textView.needsDisplay = true
        }

        func applyText(_ newText: String, to textView: WillDeepTextView) {
            highlightGeneration += 1
            let generation = highlightGeneration
            textView.invalidateFoldableGuidesCache()
            highlightedRanges.removeAll()
            viewportHighlightWorkItem?.cancel()

            // Show plain text immediately so the file appears the instant it
            // loads — never block the main thread on a full-file regex pass.
            // Syntax highlighting is applied asynchronously afterwards.
            let plain = NSMutableAttributedString(
                string: newText,
                attributes: [
                    .font: parent.settings.editorFont(),
                    .foregroundColor: parent.settings.theme.foregroundColor,
                    .paragraphStyle: parent.settings.editorParagraphStyle(),
                ]
            )
            SyntaxHighlighter.applyEditorCJKFallbackFonts(
                to: plain,
                source: newText,
                defaultFont: parent.settings.editorFont()
            )
            // Fresh content: don't preserve/restore a viewport (no full-document
            // layout). Scroll is restored separately on tab switch; a freshly
            // opened file starts at the top.
            replaceTextStorage(in: textView, with: plain, preserveViewport: false)

            guard let lang = currentLanguage, !newText.isEmpty else {
                usesViewportHighlighting = false
                return
            }

            let settings = parent.settings

            // Large files highlight only the visible range (plus a margin) and
            // extend on scroll; small files highlight the whole document once.
            if (newText as NSString).length >= Self.viewportHighlightThreshold {
                usesViewportHighlighting = true
                highlightVisibleRange(in: textView, language: lang, settings: settings)
                return
            }

            usesViewportHighlighting = false
            SyntaxHighlighter.highlight(
                newText,
                language: lang,
                theme: settings.theme,
                font: settings.editorFont(),
                semanticTokenSpans: currentSemanticTokenSpans
            ) { [weak self, weak textView] highlighted in
                guard let self = self, let textView = textView else { return }
                guard self.highlightGeneration == generation else { return }
                self.replaceTextStorage(in: textView, with: highlighted)
            }
        }

        /// Highlight the currently-visible character range (expanded to line
        /// boundaries with an overscan margin) for a large document, applying the
        /// result in place so layout and scroll position are preserved. Skips
        /// regions already highlighted.
        private func highlightVisibleRange(
            in textView: WillDeepTextView,
            language: Language,
            settings: EditorSettings
        ) {
            guard let target = visibleHighlightRange(in: textView) else { return }

            // Only the not-yet-highlighted portion needs work; bail if covered.
            var pending = IndexSet(integersIn: target.location..<(target.location + target.length))
            pending.subtract(highlightedRanges)
            guard !pending.isEmpty else { return }

            let source = textView.string
            let theme = settings.theme
            let font = settings.editorFont()
            let semanticTokenSpans = currentSemanticTokenSpans
            highlightGeneration += 1
            let generation = highlightGeneration

            DispatchQueue.global(qos: .userInitiated).async { [weak self, weak textView] in
                let spans = SyntaxHighlighter.computeSpans(
                    in: source,
                    range: target,
                    language: language,
                    theme: theme,
                    font: font,
                    semanticTokenSpans: semanticTokenSpans
                )
                DispatchQueue.main.async {
                    guard let self = self, let textView = textView else { return }
                    guard self.highlightGeneration == generation,
                          let textStorage = textView.textStorage,
                          textView.string == source else { return }
                    SyntaxHighlighter.applySpans(spans, to: textStorage, clearing: target, theme: theme)
                    self.highlightedRanges.insert(integersIn: target.location..<(target.location + target.length))
                }
            }
        }

        /// The visible character range expanded to line boundaries plus an
        /// overscan margin, clamped to the document. `nil` if nothing is laid out.
        private func visibleHighlightRange(in textView: WillDeepTextView) -> NSRange? {
            guard let layoutManager = textView.layoutManager,
                  let container = textView.textContainer else { return nil }

            let visibleRect = textView.visibleRect
            let glyphRange = layoutManager.glyphRange(forBoundingRect: visibleRect, in: container)
            let charRange = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)

            let nsString = textView.string as NSString
            let length = nsString.length
            guard length > 0 else { return nil }

            let lower = max(0, charRange.location - Self.viewportHighlightMargin)
            let upper = min(length, charRange.location + charRange.length + Self.viewportHighlightMargin)
            // Snap to line boundaries so multi-line tokens aren't clipped mid-line.
            let lineStart = nsString.lineRange(for: NSRange(location: lower, length: 0)).location
            let lineEndRange = nsString.lineRange(for: NSRange(location: min(upper, length - 1), length: 0))
            let lineEnd = min(length, lineEndRange.location + lineEndRange.length)
            guard lineEnd > lineStart else { return nil }
            return NSRange(location: lineStart, length: lineEnd - lineStart)
        }

        /// Replace the whole text storage.
        ///
        /// - Parameter preserveViewport: when `true` (a re-highlight of the
        ///   *same* document), the current top-of-viewport line is captured and
        ///   restored so the highlight swap doesn't yank the scroll position —
        ///   which requires forcing full-document glyph layout. When `false` (a
        ///   fresh load / tab switch, where the content is entirely new and the
        ///   caller restores scroll separately), that anchor work is skipped, so
        ///   the editor shows the new text without a synchronous full-document
        ///   layout pass — the difference between an instant switch and a 1-2s
        ///   stall on a large file.
        private func replaceTextStorage(
            in textView: WillDeepTextView,
            with attributed: NSAttributedString,
            preserveViewport: Bool = true
        ) {
            let selected = preserveViewport ? textView.selectedRanges : nil
            let topAnchor = preserveViewport ? topVisibleAnchor(in: textView) : nil

            textView.textStorage?.setAttributedString(attributed)
            if let textStorage = textView.textStorage, textStorage.length > 0 {
                textStorage.addAttribute(
                    .paragraphStyle,
                    value: parent.settings.editorParagraphStyle(),
                    range: NSRange(location: 0, length: textStorage.length)
                )
            }
            refreshVisibleTextLayout(for: textView)
            applySearchHighlights(to: textView, scrollToActiveMatch: false)
            applyDiagnosticHighlights(to: textView)
            if let selected {
                textView.selectedRanges = selected
            }

            if preserveViewport {
                restoreTopVisibleAnchor(topAnchor, in: textView)
            }
            refreshEditorChrome(for: textView)
        }

        private var highlightedDiagnosticRanges: [NSRange] = []
        private var highlightedDocumentHighlightRanges: [NSRange] = []
        private var highlightedDocumentLinkRanges: [NSRange] = []

        func applyDiagnosticHighlights(to textView: WillDeepTextView) {
            guard let layoutManager = textView.layoutManager else { return }
            let length = (textView.string as NSString).length

            for range in highlightedDiagnosticRanges where NSMaxRange(range) <= length {
                layoutManager.removeTemporaryAttribute(.underlineStyle, forCharacterRange: range)
                layoutManager.removeTemporaryAttribute(.underlineColor, forCharacterRange: range)
                layoutManager.removeTemporaryAttribute(.backgroundColor, forCharacterRange: range)
            }
            for range in highlightedDocumentHighlightRanges where NSMaxRange(range) <= length {
                layoutManager.removeTemporaryAttribute(.backgroundColor, forCharacterRange: range)
            }
            for range in highlightedDocumentLinkRanges where NSMaxRange(range) <= length {
                layoutManager.removeTemporaryAttribute(.underlineStyle, forCharacterRange: range)
                layoutManager.removeTemporaryAttribute(.underlineColor, forCharacterRange: range)
                layoutManager.removeTemporaryAttribute(.foregroundColor, forCharacterRange: range)
            }
            highlightedDiagnosticRanges = []
            highlightedDocumentHighlightRanges = []
            highlightedDocumentLinkRanges = []

            for span in currentDocumentHighlightSpans where NSMaxRange(span.range) <= length {
                layoutManager.addTemporaryAttribute(
                    .backgroundColor,
                    value: documentHighlightColor(for: span.kind),
                    forCharacterRange: span.range
                )
                highlightedDocumentHighlightRanges.append(span.range)
            }

            for link in currentDocumentLinkSpans where NSMaxRange(link.range) <= length {
                layoutManager.addTemporaryAttribute(
                    .underlineStyle,
                    value: NSUnderlineStyle.single.rawValue,
                    forCharacterRange: link.range
                )
                layoutManager.addTemporaryAttribute(
                    .underlineColor,
                    value: NSColor.linkColor,
                    forCharacterRange: link.range
                )
                layoutManager.addTemporaryAttribute(
                    .foregroundColor,
                    value: NSColor.linkColor,
                    forCharacterRange: link.range
                )
                highlightedDocumentLinkRanges.append(link.range)
            }

            for issue in currentDiagnosticIssues where NSMaxRange(issue.range) <= length {
                let color = diagnosticColor(for: issue.severity)
                layoutManager.addTemporaryAttribute(
                    .underlineStyle,
                    value: NSUnderlineStyle.single.rawValue,
                    forCharacterRange: issue.range
                )
                layoutManager.addTemporaryAttribute(
                    .underlineColor,
                    value: color,
                    forCharacterRange: issue.range
                )
                layoutManager.addTemporaryAttribute(
                    .backgroundColor,
                    value: color.withAlphaComponent(0.10),
                    forCharacterRange: issue.range
                )
                highlightedDiagnosticRanges.append(issue.range)
            }

            refreshEditorChrome(for: textView)
        }

        private func documentHighlightColor(for kind: Int?) -> NSColor {
            switch kind {
            case 3:
                return NSColor.systemOrange.withAlphaComponent(0.16)
            case 2:
                return NSColor.controlAccentColor.withAlphaComponent(0.14)
            default:
                return NSColor.selectedTextBackgroundColor.withAlphaComponent(0.32)
            }
        }

        private func diagnosticColor(for severity: EditorDiagnosticIssue.Severity) -> NSColor {
            switch severity {
            case .error:
                return .systemRed
            case .warning:
                return .systemOrange
            case .information:
                return .systemBlue
            case .hint:
                return .systemGray
            }
        }

        private func refreshVisibleTextLayout(for textView: WillDeepTextView) {
            guard let layoutManager = textView.layoutManager,
                  let textContainer = textView.textContainer else {
                textView.needsDisplay = true
                textView.enclosingScrollView?.contentView.needsDisplay = true
                return
            }

            let visibleRect = textView.visibleRect
            if visibleRect.width > 0, visibleRect.height > 0 {
                layoutManager.ensureLayout(forBoundingRect: visibleRect, in: textContainer)
            } else if let length = textView.textStorage?.length, length > 0 {
                let characterRange = NSRange(location: 0, length: min(length, Self.initialLayoutCharacterLimit))
                let glyphRange = layoutManager.glyphRange(
                    forCharacterRange: characterRange,
                    actualCharacterRange: nil
                )
                layoutManager.ensureLayout(forGlyphRange: glyphRange)
            }
            textView.needsDisplay = true
            textView.enclosingScrollView?.contentView.needsDisplay = true
        }

        /// A scroll anchor: the character at the top of the viewport plus the
        /// distance its line's top sits above the viewport top. Restoring both
        /// reproduces a partially-scrolled top line exactly.
        private struct ScrollAnchor {
            let characterIndex: Int
            /// `viewportTopY - lineTopY` in text-view coordinates (>= 0 when the
            /// line's top has scrolled above the viewport edge).
            let offsetWithinLine: CGFloat
        }

        private func topVisibleAnchor(in textView: WillDeepTextView) -> ScrollAnchor? {
            guard let layoutManager = textView.layoutManager,
                  let textContainer = textView.textContainer,
                  textView.enclosingScrollView != nil else {
                return nil
            }
            let visibleRect = textView.visibleRect
            guard visibleRect.height > 0 else { return nil }

            // Probe a point just inside the top of the viewport, in text-container
            // coordinates.
            let probeY = visibleRect.minY - textView.textContainerOrigin.y + 1
            let probe = NSPoint(x: textView.textContainerOrigin.x, y: probeY)
            let glyphIndex = layoutManager.glyphIndex(for: probe, in: textContainer)
            let characterIndex = layoutManager.characterIndexForGlyph(at: glyphIndex)

            var lineGlyphRange = NSRange(location: 0, length: 0)
            let lineRect = layoutManager.lineFragmentRect(
                forGlyphAt: glyphIndex,
                effectiveRange: &lineGlyphRange,
                withoutAdditionalLayout: true
            )
            let lineTopY = lineRect.minY + textView.textContainerOrigin.y
            return ScrollAnchor(
                characterIndex: characterIndex,
                offsetWithinLine: visibleRect.minY - lineTopY
            )
        }

        /// Scrolls so the anchored line is restored to the same sub-pixel position
        /// it held before the text storage was replaced, after forcing layout so
        /// the document height is correct.
        private func restoreTopVisibleAnchor(_ anchor: ScrollAnchor?, in textView: WillDeepTextView) {
            guard let anchor,
                  let layoutManager = textView.layoutManager,
                  let textContainer = textView.textContainer,
                  let clipView = textView.enclosingScrollView?.contentView else {
                return
            }

            let length = (textView.string as NSString).length
            let safeAnchor = min(max(0, anchor.characterIndex), max(0, length))

            // Force full glyph layout so both the anchor's line rect and the
            // document height are valid; otherwise the clamp below uses a stale
            // (collapsed) height and lands the viewport too high.
            layoutManager.ensureLayout(for: textContainer)

            let glyphIndex = layoutManager.glyphIndexForCharacter(at: safeAnchor)
            var lineGlyphRange = NSRange(location: 0, length: 0)
            let lineRect = layoutManager.lineFragmentRect(
                forGlyphAt: glyphIndex,
                effectiveRange: &lineGlyphRange
            )

            let documentHeight = layoutManager.usedRect(for: textContainer).height
                + textView.textContainerInset.height * 2
            let lineTopY = lineRect.minY + textView.textContainerOrigin.y
            // Re-apply the original within-line offset so a top line that was only
            // half-visible stays half-visible instead of snapping flush to the top.
            let targetY = lineTopY + anchor.offsetWithinLine
            let maxY = max(0, documentHeight - clipView.bounds.height)
            let clampedY = min(max(0, targetY), maxY)
            clipView.setBoundsOrigin(NSPoint(x: clipView.bounds.origin.x, y: clampedY))
            textView.enclosingScrollView?.reflectScrolledClipView(clipView)
        }

        func applySearchHighlights(to textView: WillDeepTextView, scrollToActiveMatch: Bool = true) {
            guard let textStorage = textView.textStorage else { return }

            let fullRange = NSRange(location: 0, length: textStorage.length)
            textStorage.removeAttribute(.backgroundColor, range: fullRange)
            textStorage.removeAttribute(.underlineStyle, range: fullRange)

            let passiveColor = NSColor.systemYellow.withAlphaComponent(0.28)
            let activeColor = NSColor.systemYellow.withAlphaComponent(0.58)
            for range in currentSearchRanges where NSMaxRange(range) <= textStorage.length {
                textStorage.addAttribute(.backgroundColor, value: passiveColor, range: range)
            }

            if let activeRange = currentActiveSearchRange,
               NSMaxRange(activeRange) <= textStorage.length {
                textStorage.addAttributes(
                    [
                        .backgroundColor: activeColor,
                        .underlineStyle: NSUnderlineStyle.single.rawValue,
                    ],
                    range: activeRange
                )
                if scrollToActiveMatch {
                    textView.scrollRangeToVisible(activeRange)
                }
            }

            refreshEditorChrome(for: textView)
        }

        private func refreshEditorChrome(for textView: WillDeepTextView, redrawTextView: Bool = true) {
            // Only re-apply folding when scopes are actually folded. Applying it
            // unconditionally forced a full-document glyph/layout invalidation on
            // every caret move, which produced severe arrow-key lag.
            textView.refreshFoldedScopesIfNeeded()
            if redrawTextView {
                textView.needsDisplay = true
            }
            (textView.enclosingScrollView?.verticalRulerView as? LineNumberRulerView)?.needsDisplay = true
        }

        /// Detect a tab switch. If the active tab changed, save the outgoing tab's
        /// caret and scroll offset (read live from the text view) and return
        /// `true` so the caller restores the incoming tab afterwards. Returns
        /// `false` when this is the same tab (an edit/setting change, not a
        /// switch), where state must be left untouched.
        func beginTabTransitionIfNeeded(to newTabID: UUID?, in textView: WillDeepTextView) -> Bool {
            guard newTabID != currentTabID else { return false }

            if let outgoing = currentTabID {
                tabEditingState[outgoing] = (
                    cursorLocation: textView.selectedRange().location,
                    topCharIndex: topVisibleCharacterIndex(in: textView)
                )
            }
            currentTabID = newTabID
            return true
        }

        /// Restore the incoming tab's caret and scroll position so the saved
        /// top-of-viewport line sits at the *top* of the viewport. Verified by
        /// instrumented measurement on a 8000-line file: scrolling to line
        /// 6596 lands actualLine=6596 (drift = 0), vs ~ -123 lines pre-fix.
        ///
        /// Naive `scrollRangeToVisible` only guarantees the target is on screen
        /// — it would leave the saved line at the bottom, drifting the view by
        /// ~one screenful upward (the "6600 -> 6300 lines" jump). And a line
        /// fragment's Y depends on every fragment above it: without ensuring
        /// layout from 0 to the target, the rect comes from partial layout and
        /// lands hundreds of lines off.
        func finishTabTransition(to newTabID: UUID?, in textView: WillDeepTextView) {
            guard let newTabID, let saved = tabEditingState[newTabID] else { return }

            let length = (textView.string as NSString).length
            let location = max(0, min(saved.cursorLocation, length))
            textView.setSelectedRange(NSRange(location: location, length: 0))

            guard let layoutManager = textView.layoutManager,
                  let clipView = textView.enclosingScrollView?.contentView else {
                return
            }

            let topIndex = max(0, min(saved.topCharIndex, max(0, length - 1)))
            // Lay out the entire document. We must lay out from 0 through the
            // target so the line fragment Y for the saved row is exact (Y
            // depends on every fragment above it), and we must include the
            // content *below* the target up to the bottom of the viewport so
            // AppKit knows the document height — otherwise it clamps the new
            // scroll origin against a not-yet-extended content size and pulls
            // the viewport up by a few lines (the "cursor at 928, bottom was
            // 932 but came back 927" symptom when the cursor sat near the
            // viewport's bottom edge). Laying out the whole document removes
            // both failure modes; the cost is a one-time pass per tab switch
            // and dominated by the fragment-Y requirement anyway.
            layoutManager.ensureLayout(forCharacterRange: NSRange(location: 0, length: length))
            let glyphIndex = layoutManager.glyphIndexForCharacter(at: topIndex)
            let lineRect = layoutManager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: nil)
            let targetY = max(0, lineRect.minY + textView.textContainerOrigin.y)
            clipView.setBoundsOrigin(NSPoint(x: clipView.bounds.origin.x, y: targetY))
            textView.enclosingScrollView?.reflectScrolledClipView(clipView)
        }

        /// Character index at the top edge of the current viewport (lazy layout
        /// safe — only queries the visible rect).
        private func topVisibleCharacterIndex(in textView: WillDeepTextView) -> Int {
            guard let layoutManager = textView.layoutManager,
                  let container = textView.textContainer else { return 0 }
            let visibleRect = textView.visibleRect
            let glyphRange = layoutManager.glyphRange(forBoundingRect: visibleRect, in: container)
            return layoutManager.characterIndexForGlyph(at: glyphRange.location)
        }

        func navigate(toLine line: Int, in textView: WillDeepTextView) {
            let range = Self.rangeForLine(line, in: textView.string)
            textView.window?.makeFirstResponder(textView)
            textView.setSelectedRange(NSRange(location: range.location, length: 0))
            textView.scrollRangeToVisible(range)
            publishCursorPosition(for: textView)
            applyBracketHighlight(to: textView)
            refreshEditorChrome(for: textView)

            // Ensure the jumped-to region is highlighted in a large file even if
            // the scroll didn't cross a bounds-change threshold.
            if usesViewportHighlighting, let lang = currentLanguage {
                highlightVisibleRange(in: textView, language: lang, settings: parent.settings)
            }
        }

        func select(range: NSRange, in textView: WillDeepTextView) {
            let length = (textView.string as NSString).length
            let safeLocation = min(max(0, range.location), length)
            let safeEnd = min(max(safeLocation, NSMaxRange(range)), length)
            let safeRange = NSRange(location: safeLocation, length: safeEnd - safeLocation)
            textView.window?.makeFirstResponder(textView)
            textView.setSelectedRange(safeRange)
            textView.scrollRangeToVisible(safeRange)
            publishCursorPosition(for: textView)
            applyBracketHighlight(to: textView)
            refreshEditorChrome(for: textView)
        }

        static func rangeForLine(_ line: Int, in text: String) -> NSRange {
            guard line > 1, !text.isEmpty else {
                return NSRange(location: 0, length: 0)
            }

            let nsText = text as NSString
            var lineStart = 0
            var lineEnd = 0
            var contentsEnd = 0
            var currentLine = 1

            while lineStart < nsText.length {
                nsText.getLineStart(
                    &lineStart,
                    end: &lineEnd,
                    contentsEnd: &contentsEnd,
                    for: NSRange(location: lineStart, length: 0)
                )

                if currentLine == line {
                    return NSRange(location: lineStart, length: max(0, contentsEnd - lineStart))
                }

                currentLine += 1
                lineStart = lineEnd
            }

            return NSRange(location: nsText.length, length: 0)
        }

        private func publishCursorPosition(for textView: WillDeepTextView) {
            let selectedRange = textView.selectedRange()
            let content = textView.string
            let position = Self.lineAndColumn(for: selectedRange.location, in: content)
            let selectedLines = Self.selectedLineCount(for: selectedRange, in: content)
            let selectedText = Self.selectedText(
                for: selectedRange,
                in: content,
                maxLength: Self.publishedSelectionTextLimit
            )
            parent.onSelectionChange?(
                position.line,
                position.column,
                selectedRange.length,
                selectedLines,
                selectedText,
                selectedRange.location
            )
        }

        /// The two single-character ranges currently carrying the bracket-match
        /// highlight, so we can clear exactly those instead of sweeping the whole
        /// document's temporary attributes on every caret move.
        private var highlightedBracketRanges: [NSRange] = []
        private static let bracketMatchScanLimit = 120_000

        private func applyBracketHighlight(to textView: WillDeepTextView) {
            guard let layoutManager = textView.layoutManager else { return }
            let length = (textView.string as NSString).length

            for range in highlightedBracketRanges where NSMaxRange(range) <= length {
                layoutManager.removeTemporaryAttribute(.backgroundColor, forCharacterRange: range)
            }
            highlightedBracketRanges = []

            guard let match = Self.matchingBracketRanges(
                around: textView.selectedRange().location,
                in: textView.string
            ) else {
                return
            }

            let color = NSColor.selectedTextBackgroundColor.withAlphaComponent(0.55)
            layoutManager.addTemporaryAttribute(.backgroundColor, value: color, forCharacterRange: match.opening)
            layoutManager.addTemporaryAttribute(.backgroundColor, value: color, forCharacterRange: match.closing)
            highlightedBracketRanges = [match.opening, match.closing]
        }

        static func matchingBracketRanges(around location: Int, in text: String) -> (opening: NSRange, closing: NSRange)? {
            let nsText = text as NSString
            guard nsText.length > 1 else { return nil }

            let candidates = [
                min(max(0, location - 1), nsText.length - 1),
                min(max(0, location), nsText.length - 1),
            ]

            for index in candidates {
                guard let bracket = BracketPair(character: nsText.character(at: index)) else {
                    continue
                }

                if bracket.isOpening,
                   let match = findClosingBracket(from: index, pair: bracket, in: nsText) {
                    return (NSRange(location: index, length: 1), NSRange(location: match, length: 1))
                }

                if !bracket.isOpening,
                   let match = findOpeningBracket(from: index, pair: bracket, in: nsText) {
                    return (NSRange(location: match, length: 1), NSRange(location: index, length: 1))
                }
            }

            return nil
        }

        private static func findClosingBracket(from index: Int, pair: BracketPair, in text: NSString) -> Int? {
            var depth = 0
            guard index + 1 < text.length else { return nil }
            let upperBound = min(text.length, index + bracketMatchScanLimit)
            for cursor in index..<upperBound {
                let character = text.character(at: cursor)
                if character == pair.opening {
                    depth += 1
                } else if character == pair.closing {
                    depth -= 1
                    if depth == 0 {
                        return cursor
                    }
                }
            }
            return nil
        }

        private static func findOpeningBracket(from index: Int, pair: BracketPair, in text: NSString) -> Int? {
            var depth = 0
            guard index > 0 else { return nil }
            let lowerBound = max(0, index - bracketMatchScanLimit)
            for cursor in stride(from: index, through: lowerBound, by: -1) {
                let character = text.character(at: cursor)
                if character == pair.closing {
                    depth += 1
                } else if character == pair.opening {
                    depth -= 1
                    if depth == 0 {
                        return cursor
                    }
                }
            }
            return nil
        }

        static func lineAndColumn(for location: Int, in text: String) -> (line: Int, column: Int) {
            guard !text.isEmpty else { return (1, 1) }

            let nsText = text as NSString
            let boundedLocation = min(max(0, location), nsText.length)
            var lineStart = 0
            var lineEnd = 0
            var contentsEnd = 0
            nsText.getLineStart(
                &lineStart,
                end: &lineEnd,
                contentsEnd: &contentsEnd,
                for: NSRange(location: boundedLocation, length: 0)
            )

            let line = lineNumber(forLineStart: lineStart, in: nsText)
            return (line, boundedLocation - lineStart + 1)
        }

        static func selectedLineCount(for range: NSRange, in text: String) -> Int {
            guard range.length > 0 else { return 0 }
            let nsText = text as NSString
            let boundedLocation = min(max(0, range.location), nsText.length)
            let boundedEnd = min(max(boundedLocation, NSMaxRange(range)), nsText.length)
            guard boundedEnd > boundedLocation else { return 0 }
            return newlineCount(in: nsText, from: boundedLocation, to: boundedEnd) + 1
        }

        static func selectedText(for range: NSRange, in text: String, maxLength: Int? = nil) -> String {
            guard range.length > 0 else { return "" }
            let nsText = text as NSString
            let boundedLocation = min(max(0, range.location), nsText.length)
            let boundedEnd = min(max(boundedLocation, NSMaxRange(range)), nsText.length)
            guard boundedEnd > boundedLocation else { return "" }
            let length = boundedEnd - boundedLocation
            let cappedLength = maxLength.map { min(length, max(0, $0)) } ?? length
            guard cappedLength > 0 else { return "" }
            return nsText.substring(with: NSRange(location: boundedLocation, length: cappedLength))
        }

        private static func lineNumber(forLineStart lineStart: Int, in text: NSString) -> Int {
            let boundedLineStart = min(max(0, lineStart), text.length)
            guard boundedLineStart > 0 else { return 1 }

            var currentLocation = 0
            var line = 1
            var currentLineStart = 0
            var lineEnd = 0
            var contentsEnd = 0

            while currentLocation < boundedLineStart {
                text.getLineStart(
                    &currentLineStart,
                    end: &lineEnd,
                    contentsEnd: &contentsEnd,
                    for: NSRange(location: currentLocation, length: 0)
                )
                guard lineEnd > currentLocation else { break }
                line += 1
                currentLocation = lineEnd
            }

            return line
        }

        private static func newlineCount(in text: NSString, from: Int, to: Int) -> Int {
            let lower = min(max(0, from), text.length)
            let upper = min(max(lower, to), text.length)
            guard lower < upper else { return 0 }

            var count = 0
            var searchRange = NSRange(location: lower, length: upper - lower)
            while searchRange.length > 0 {
                let found = text.rangeOfCharacter(from: .newlines, options: [], range: searchRange)
                if found.location == NSNotFound { break }
                count += 1
                let nextLocation = NSMaxRange(found)
                guard nextLocation < upper else { break }
                searchRange = NSRange(location: nextLocation, length: upper - nextLocation)
            }
            return count
        }

        // MARK: - Debounced Highlighting

        private func applyLiveEditorCJKFallbackFonts(to textView: WillDeepTextView) {
            guard let textStorage = textView.textStorage, textStorage.length > 0 else {
                return
            }

            let source = textView.string
            let nsSource = source as NSString
            let fullRange = NSRange(location: 0, length: textStorage.length)
            let targetRange: NSRange
            // Per-keystroke, only re-apply CJK fallback fonts to the line(s) the
            // edit touched, never the whole document. Earlier this used
            // `fullRange` for files < 100KB, which meant every keypress in a
            // several-thousand-character CJK file re-scanned and re-attributed
            // the entire text on the main thread — the primary source of typing
            // lag (and why CJK typing felt heavier than ASCII). The insertion
            // point sits at the just-committed edit, so its line range covers the
            // characters that need fallback fonts; a debounced full highlight
            // (`scheduleHighlight`) still corrects anything outside this window.
            if let visibleRange = visibleHighlightRange(in: textView) {
                let editedLineRange = nsSource.lineRange(for: NSIntersectionRange(textView.selectedRange(), fullRange))
                // On large files stay within the viewport; on small ones the
                // edited line is enough and far cheaper than the viewport.
                targetRange = textStorage.length < Self.viewportHighlightThreshold
                    ? editedLineRange
                    : NSIntersectionRange(visibleRange, fullRange)
            } else {
                targetRange = nsSource.lineRange(for: NSIntersectionRange(textView.selectedRange(), fullRange))
            }

            SyntaxHighlighter.applyLiveEditorCJKFallbackFonts(
                in: textView,
                defaultFont: parent.settings.editorFont(),
                range: targetRange
            )
        }

        /// Schedules a debounced re-highlight of the current document content.
        /// The highlight runs on a background queue and results are applied on
        /// the main thread, preserving cursor/selection position.
        private func scheduleHighlight(textView: WillDeepTextView) {
            guard let lang = currentLanguage else { return }

            highlightWorkItem?.cancel()
            highlightGeneration += 1
            let generation = highlightGeneration

            let settings = parent.settings

            // Large files: after an edit, character offsets shifted, so drop the
            // highlighted-range bookkeeping and re-highlight just the visible
            // range (debounced). Avoids re-running the full-file regex per
            // keystroke on a huge document.
            if usesViewportHighlighting {
                let workItem = DispatchWorkItem { [weak self, weak textView] in
                    guard let self = self, let textView = textView else { return }
                    self.highlightedRanges.removeAll()
                    self.highlightVisibleRange(in: textView, language: lang, settings: settings)
                }
                highlightWorkItem = workItem
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: workItem)
                return
            }

            let workItem = DispatchWorkItem { [weak self, weak textView] in
                guard let self = self, let textView = textView, self.currentLanguage != nil else { return }

                let latestText = textView.string
                guard !latestText.isEmpty else { return }

                SyntaxHighlighter.highlight(
                    latestText,
                    language: lang,
                    theme: settings.theme,
                    font: settings.editorFont(),
                    semanticTokenSpans: self.currentSemanticTokenSpans
                ) { [weak self, weak textView] highlighted in
                    guard let self = self, let textView = textView else { return }
                    guard self.highlightGeneration == generation else { return }
                    self.replaceTextStorage(in: textView, with: highlighted)
                }
            }

            highlightWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: workItem)
        }
    }
}
