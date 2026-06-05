//
//  MainWindowChrome.swift
//  Xedit
//
//  Window/keyboard plumbing split out of ContentView.swift in rc39.
//  All five types live here:
//
//    - `MainWindowKeyboardShortcutHandler` — global ⌘W close-tab
//      handler bound to the editor window only.
//    - `WindowChromeConfigurator` — collapses the system title bar
//      so the tab bar can sit at the very top, installs the
//      `ClearDividerSplitView` reclass, and binds a frame-autosave
//      name on first launch.
//    - `PaletteKeyboardHandler` — up/down/return/esc keys for any
//      list-style floating palette (Command Palette, Symbol Jump,
//      Quick Open, Go To Line).
//    - `FloatingPanelEscapeKeyHandler` — esc-only variant for panels
//      that don't need arrow-key navigation.
//    - `ClearDividerSplitView` + private NSView extensions — runtime
//      patching of NavigationSplitView's underlying NSSplitView to
//      hide the 1px hairline divider.
//

import SwiftUI
import AppKit

/// Local event monitor that translates ⌘W into "close current tab"
/// while the editor window is key. We can't use SwiftUI's
/// `.keyboardShortcut` for this because that competes with the system
/// "Close Window" shortcut — we want ⌘W to close a *tab*, not the
/// whole window, but only when a tab is open.
struct MainWindowKeyboardShortcutHandler: NSViewRepresentable {
    let hasActiveTab: Bool
    let onCloseTab: () -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        context.coordinator.view = view
        context.coordinator.installMonitor()
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.view = nsView
        context.coordinator.hasActiveTab = hasActiveTab
        context.coordinator.onCloseTab = onCloseTab
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.removeMonitor()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(hasActiveTab: hasActiveTab, onCloseTab: onCloseTab)
    }

    final class Coordinator {
        weak var view: NSView?
        var hasActiveTab: Bool
        var onCloseTab: () -> Void
        private var monitor: Any?

        init(hasActiveTab: Bool, onCloseTab: @escaping () -> Void) {
            self.hasActiveTab = hasActiveTab
            self.onCloseTab = onCloseTab
        }

        func installMonitor() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                self?.handle(event) ?? event
            }
        }

        func removeMonitor() {
            guard let monitor else { return }
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }

        private func handle(_ event: NSEvent) -> NSEvent? {
            guard let window = view?.window,
                  event.window === window,
                  hasActiveTab,
                  event.charactersIgnoringModifiers?.lowercased() == "w" else {
                return event
            }

            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let relevantModifiers = modifiers.intersection([.command, .option, .control, .shift])
            guard relevantModifiers == .command else {
                return event
            }

            onCloseTab()
            return nil
        }
    }
}

/// Collapses the system title-bar row so the tab bar sits at the very top of the
/// window instead of below a dead file-name strip. We hide the title text, make
/// the title bar transparent, and — crucially — turn on `.fullSizeContentView`
/// so the content area extends up through the title-bar height (otherwise that
/// ~28pt row keeps occupying space even with no title drawn). The traffic-light
/// buttons stay on top of the content because they live in their own layer.
struct WindowChromeConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        context.coordinator.attach(to: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.attach(to: nsView)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        private weak var view: NSView?
        private var retriesLeft = 30

        func attach(to view: NSView) {
            self.view = view
            retriesLeft = 30
            poll()
        }

        /// `view.window` is often still nil on the first runloop turn after the
        /// representable is created (the helper NSView hasn't been inserted into
        /// the window yet), and SwiftUI re-applies its own title-bar chrome a few
        /// turns later. Poll until we get a window, then keep configuring for a
        /// short while so our settings win over SwiftUI's late reset.
        private func poll() {
            guard retriesLeft > 0 else { return }
            retriesLeft -= 1
            if let window = view?.window {
                WindowChromeConfigurator.configure(window)
            }
            DispatchQueue.main.async { [weak self] in self?.poll() }
        }
    }

    /// One-shot bookkeeping so the autosave-name / first-launch resize
    /// logic only runs the first time we see each NSWindow — `poll()`
    /// re-enters `configure(_:)` every runloop turn for ~30 ticks and
    /// we don't want to keep stomping the user's manual resize.
    private static let frameAutosaveAppliedWindows = NSHashTable<NSWindow>.weakObjects()
    private static let mainWindowFrameAutosaveName = "VeilWriterMainWindow"
    /// AppKit refuses to bind the same autosave name to more than one
    /// window at a time (you get a runtime warning and the second binding
    /// is silently ignored), so we only attach `setFrameAutosaveName` to
    /// the very first window we see in this process. Subsequent windows
    /// (e.g. the URL-bound WindowGroup that opens when the user chooses
    /// another folder) still get the first-launch 80% resize but skip
    /// the persistence binding — AppKit cascades them off the first
    /// window's frame anyway, which is the behaviour users expect.
    private static var didBindFrameAutosaveName = false

    private static func configure(_ window: NSWindow) {
        if window.titleVisibility != .hidden { window.titleVisibility = .hidden }
        if !window.titlebarAppearsTransparent { window.titlebarAppearsTransparent = true }
        if !window.styleMask.contains(.fullSizeContentView) {
            window.styleMask.insert(.fullSizeContentView)
        }
        restoreStandardWindowButtons(in: window)
        window.titlebarSeparatorStyle = .none
        window.contentView?.superview?.hideTitlebarSeparatorViews()
        applyFrameAutosaveAndDefaultSize(window)

        // Hide the 1px divider NavigationSplitView's underlying NSSplitView draws
        // between the sidebar and the editor. There is no SwiftUI API for it, so
        // we find that NSSplitView and reclass it to a subclass whose
        // `dividerColor` is clear.
        if let contentView = window.contentView {
            for split in contentView.descendantSplitViews()
            where !(split is ClearDividerSplitView) {
                object_setClass(split, ClearDividerSplitView.self)
                split.needsDisplay = true
            }
            contentView.hideTitlebarSeparatorViews()
        }
    }

    /// Persist NSWindow frame across launches (SwiftUI's WindowGroup
    /// doesn't do this for us when there's no `defaultSize` / no scene
    /// storage), and on the very first launch — when nothing is yet
    /// persisted — size the window to ~80% of the current screen and
    /// center it. Both effects only fire the first time we see a given
    /// NSWindow; `poll()` keeps re-entering `configure(_:)` and we
    /// don't want to keep overriding the user's manual resize.
    private static func applyFrameAutosaveAndDefaultSize(_ window: NSWindow) {
        if frameAutosaveAppliedWindows.contains(window) { return }
        frameAutosaveAppliedWindows.add(window)

        let autosaveName = mainWindowFrameAutosaveName
        let defaultsKey = "NSWindow Frame \(autosaveName)"
        let hasPersistedFrame = UserDefaults.standard.string(forKey: defaultsKey) != nil

        // First launch (no persisted frame yet): start at 80% of the
        // active screen, centered. We pick the screen the window is
        // currently on; if that's nil, fall back to `.main`.
        if !hasPersistedFrame,
           let screen = window.screen ?? NSScreen.main {
            let visible = screen.visibleFrame
            let targetWidth = visible.width * 0.8
            let targetHeight = visible.height * 0.8
            let originX = visible.minX + (visible.width - targetWidth) / 2
            let originY = visible.minY + (visible.height - targetHeight) / 2
            let target = NSRect(x: originX, y: originY, width: targetWidth, height: targetHeight)
            window.setFrame(target, display: true)
        }

        // Bind the autosave AFTER the optional first-launch resize, so
        // that initial frame becomes the persisted baseline. On
        // subsequent launches AppKit reads the saved frame from
        // UserDefaults and applies it automatically. Only one window
        // per process can hold the binding — see the note on
        // `didBindFrameAutosaveName`.
        if !didBindFrameAutosaveName,
           window.frameAutosaveName != autosaveName {
            if window.setFrameAutosaveName(autosaveName) {
                didBindFrameAutosaveName = true
            }
        }
    }

    private static func restoreStandardWindowButtons(in window: NSWindow) {
        let buttons: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
        for buttonType in buttons {
            guard let button = window.standardWindowButton(buttonType) else { continue }
            button.isHidden = false
            button.alphaValue = 1
            button.superview?.isHidden = false
            button.superview?.alphaValue = 1
        }
    }
}

/// NSSplitView subclass that paints no visible divider line. Used to suppress the
/// hairline NavigationSplitView draws between the sidebar and the editor.
final class ClearDividerSplitView: NSSplitView {
    override var dividerColor: NSColor { .clear }
}

extension NSView {
    /// All `NSSplitView`s anywhere beneath this view (depth-first).
    func descendantSplitViews() -> [NSSplitView] {
        var result: [NSSplitView] = []
        if let split = self as? NSSplitView {
            result.append(split)
        }
        for subview in subviews {
            result.append(contentsOf: subview.descendantSplitViews())
        }
        return result
    }

    func hideTitlebarSeparatorViews() {
        let className = NSStringFromClass(type(of: self))
        if className.contains("Separator") || className.contains("TrackingSeparator") {
            isHidden = true
            alphaValue = 0
        }
        for subview in subviews {
            subview.hideTitlebarSeparatorViews()
        }
    }
}

/// Up/Down/Return/Esc key handling for any list-style floating palette.
/// Generic enough that the Command Palette, Symbol Jump, Quick Open, and
/// Go To Line panels all share it.
struct PaletteKeyboardHandler: NSViewRepresentable {
    let onMoveUp: () -> Void
    let onMoveDown: () -> Void
    let onSubmit: () -> Void
    let onCancel: () -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        context.coordinator.installMonitor()
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onMoveUp = onMoveUp
        context.coordinator.onMoveDown = onMoveDown
        context.coordinator.onSubmit = onSubmit
        context.coordinator.onCancel = onCancel
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.removeMonitor()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            onMoveUp: onMoveUp,
            onMoveDown: onMoveDown,
            onSubmit: onSubmit,
            onCancel: onCancel
        )
    }

    final class Coordinator {
        var onMoveUp: () -> Void
        var onMoveDown: () -> Void
        var onSubmit: () -> Void
        var onCancel: () -> Void
        private var monitor: Any?

        init(
            onMoveUp: @escaping () -> Void,
            onMoveDown: @escaping () -> Void,
            onSubmit: @escaping () -> Void,
            onCancel: @escaping () -> Void
        ) {
            self.onMoveUp = onMoveUp
            self.onMoveDown = onMoveDown
            self.onSubmit = onSubmit
            self.onCancel = onCancel
        }

        func installMonitor() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self else { return event }
                return self.handle(event)
            }
        }

        func removeMonitor() {
            guard let monitor else { return }
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }

        private func handle(_ event: NSEvent) -> NSEvent? {
            if event.keyCode == 53 {
                onCancel()
                return nil
            }

            switch event.specialKey {
            case .upArrow:
                onMoveUp()
                return nil
            case .downArrow:
                onMoveDown()
                return nil
            case .carriageReturn:
                onSubmit()
                return nil
            default:
                return event
            }
        }
    }
}

/// Esc-only key handler for floating panels that don't need
/// up/down/return navigation (the image preview hovering panel, for
/// example).
struct FloatingPanelEscapeKeyHandler: NSViewRepresentable {
    let onCancel: () -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        context.coordinator.view = view
        context.coordinator.installMonitor()
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.view = nsView
        context.coordinator.onCancel = onCancel
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.removeMonitor()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onCancel: onCancel)
    }

    final class Coordinator {
        weak var view: NSView?
        var onCancel: () -> Void
        private var monitor: Any?

        init(onCancel: @escaping () -> Void) {
            self.onCancel = onCancel
        }

        func installMonitor() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                self?.handle(event) ?? event
            }
        }

        func removeMonitor() {
            guard let monitor else { return }
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }

        private func handle(_ event: NSEvent) -> NSEvent? {
            guard event.keyCode == 53 else { return event }
            if let window = view?.window,
               let eventWindow = event.window,
               eventWindow !== window {
                return event
            }

            onCancel()
            return nil
        }
    }
}
