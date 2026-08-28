//
//  AgentChatSelectionAction.swift
//  WillDeep
//
//  聊天区选中文字后弹出的动作气泡。
//
//  这一层从 AgentChatHistoryTextView 里搬出来，因为它现在有两个宿主：
//   - 结算后的会话正文，一整条 TextKit 大视图（气泡挂在视图内部，跟着内容滚）；
//   - 工种（子代理）的发言行，一行两行高的小文本视图（气泡挂到窗口内容视图上，
//     否则 28pt 的气泡装不进宿主的 bounds，也接不到点击）。
//
//  两处共用同一份条目：内置「添加到任务」永远第一位，插件经
//  `menus["chat.selection"]` 贡献的项按安装顺序接在后面。
//

import AppKit

enum AgentChatSelectionActionMetrics {
    static let cornerRadius: CGFloat = 8
    static let horizontalPadding: CGFloat = 9
    static let height: CGFloat = 28
    static let borderWidth: CGFloat = 0.5
    static let shadowRadius: CGFloat = 7
    static let shadowOffset = NSSize(width: 0, height: -2)
    static let lightShadowOpacity: Float = 0.16
    static let darkShadowOpacity: Float = 0.36
    /// 相邻两项之间的竖线。气泡是一条横排，没有分隔线时
    /// 「添加到任务 收藏 一句话记待办」会读成一句话，看不出是三项。
    static let separatorWidth: CGFloat = 1
    static let separatorHeight: CGFloat = 14
    /// 竖线两侧各留这么多，加上 item 自己的内边距，视觉上分隔线居中。
    static let itemSpacing: CGFloat = 3
    static let itemCornerRadius: CGFloat = 5
    static let itemHorizontalPadding: CGFloat = 5
    static let itemHeight: CGFloat = 22

    static func backgroundColor(isDark: Bool, isHovered: Bool) -> NSColor {
        if isDark {
            return NSColor(calibratedWhite: isHovered ? 0.22 : 0.16, alpha: 0.98)
        }
        return NSColor(calibratedWhite: isHovered ? 0.965 : 1, alpha: 0.98)
    }

    static func borderColor(isDark: Bool) -> NSColor {
        isDark
            ? NSColor.white.withAlphaComponent(0.16)
            : NSColor.black.withAlphaComponent(0.13)
    }

    static func separatorColor(isDark: Bool) -> NSColor {
        isDark
            ? NSColor.white.withAlphaComponent(0.18)
            : NSColor.black.withAlphaComponent(0.12)
    }

    /// 单项 hover 的底色。要盖在气泡底色之上仍看得出来，所以是半透明叠加，
    /// 而不是又一个不透明灰阶——后者在深浅两套外观里得各调一次才不脏。
    static func itemHoverBackgroundColor(isDark: Bool) -> NSColor {
        isDark
            ? NSColor.white.withAlphaComponent(0.14)
            : NSColor.black.withAlphaComponent(0.075)
    }
}

/// 右键菜单项带的载荷（NSMenuItem.representedObject 只能放对象/结构体值）。
final class AgentChatSelectionPluginMenuPayload: NSObject {
    let text: String
    let pluginID: AgentPluginID
    let commandID: AgentPluginCommandID

    init(text: String, pluginID: AgentPluginID, commandID: AgentPluginCommandID) {
        self.text = text
        self.pluginID = pluginID
        self.commandID = commandID
    }
}

/// 选区气泡里的一项：内置「添加到任务」，或插件经 `menus["chat.selection"]` 贡献的动作。
struct AgentChatSelectionActionItem {
    let title: String
    /// 插件项带上来源；内置项为 nil。
    let plugin: (pluginID: AgentPluginID, commandID: AgentPluginCommandID)?
}

/// 气泡与右键菜单共用的条目来源。两个入口列出来的动作必须一模一样，
/// 所以只有这一处在拼装。
enum AgentChatSelectionActionCatalog {
    /// 内置「添加到任务」打头，后面接插件贡献的项。
    static func items() -> [AgentChatSelectionActionItem] {
        let builtIn = AgentChatSelectionActionItem(title: L10n.AgentSelection.addToTask, plugin: nil)
        let pluginItems = AgentPluginRegistry.shared
            .menuCommands(at: AgentPluginMenuLocation.chatSelection)
            .map { resolved in
                AgentChatSelectionActionItem(
                    title: AgentPluginRegistry.shared.localizedString(
                        resolved.command.titleKey,
                        pluginID: resolved.pluginID
                    ),
                    plugin: (resolved.pluginID, resolved.command.id)
                )
            }
        return [builtIn] + pluginItems
    }

    /// 把同一批条目摆进右键菜单。内置项的 representedObject 是选中的原文，
    /// 插件项的是 `AgentChatSelectionPluginMenuPayload`。
    static func appendMenuItems(
        to menu: NSMenu,
        selectedText: String,
        target: AnyObject,
        builtInAction: Selector,
        pluginAction: Selector
    ) {
        for item in items() {
            let menuItem = NSMenuItem(
                title: item.title,
                action: item.plugin == nil ? builtInAction : pluginAction,
                keyEquivalent: ""
            )
            menuItem.target = target
            if let plugin = item.plugin {
                menuItem.representedObject = AgentChatSelectionPluginMenuPayload(
                    text: selectedText,
                    pluginID: plugin.pluginID,
                    commandID: plugin.commandID
                )
            } else {
                menuItem.representedObject = selectedText
            }
            menuItem.isEnabled = true
            menu.addItem(menuItem)
        }
    }
}

/// 气泡里两项之间的竖线。宽高按 metrics 固定，颜色跟随明暗外观。
private final class AgentChatSelectionActionSeparator: NSView {
    override var intrinsicContentSize: NSSize {
        NSSize(
            width: AgentChatSelectionActionMetrics.separatorWidth,
            height: AgentChatSelectionActionMetrics.separatorHeight
        )
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        AgentChatSelectionActionMetrics.separatorColor(isDark: isDark).setFill()
        bounds.fill()
    }
}

/// 气泡里的一项。NSButton 自己不给 hover 反馈，这里补一个圆角底色：
/// 分隔线只回答「有几项」，hover 才回答「现在指的是哪一项」。
private final class AgentChatSelectionActionButton: NSButton {
    private var hoverTrackingArea: NSTrackingArea?
    private var isHovered = false

    override var intrinsicContentSize: NSSize {
        var size = super.intrinsicContentSize
        size.width += AgentChatSelectionActionMetrics.itemHorizontalPadding * 2
        size.height = AgentChatSelectionActionMetrics.itemHeight
        return size
    }

    /// 执行中整条气泡会禁用。此时鼠标可能正停在某一项上，底色必须跟着撤掉，
    /// 否则那一项看起来还能点。
    override var isEnabled: Bool {
        didSet { applyHoverAppearance() }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyHoverAppearance()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyHoverAppearance()
    }

    override func updateTrackingAreas() {
        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
        }
        let trackingArea = NSTrackingArea(
            rect: .zero,
            options: [.activeInKeyWindow, .inVisibleRect, .mouseEnteredAndExited],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        hoverTrackingArea = trackingArea
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        applyHoverAppearance()
        super.mouseEntered(with: event)
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        applyHoverAppearance()
        super.mouseExited(with: event)
    }

    private func applyHoverAppearance() {
        wantsLayer = true
        layer?.cornerRadius = AgentChatSelectionActionMetrics.itemCornerRadius
        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let showsHover = isHovered && isEnabled
        layer?.backgroundColor = showsHover
            ? AgentChatSelectionActionMetrics.itemHoverBackgroundColor(isDark: isDark).cgColor
            : NSColor.clear.cgColor
    }
}

final class AgentChatSelectionActionView: NSView {
    private let stack: NSStackView
    private var buttons: [NSButton] = []
    private var separators: [NSView] = []
    private var items: [AgentChatSelectionActionItem] = []
    private var hoverTrackingArea: NSTrackingArea?
    private var isHovered = false
    /// 点了第几项（下标对应 items）。
    var onSelect: ((AgentChatSelectionActionItem) -> Void)?
    /// 异步动作执行期间与结果展示期间置 false：按钮点不动，整条气泡淡一档。
    var isInteractive = true {
        didSet {
            alphaValue = isInteractive ? 1 : 0.7
            buttons.forEach { $0.isEnabled = isInteractive }
        }
    }

    init(items: [AgentChatSelectionActionItem]) {
        stack = NSStackView()
        super.init(frame: .zero)

        wantsLayer = true
        layer?.cornerRadius = AgentChatSelectionActionMetrics.cornerRadius
        layer?.masksToBounds = false
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowRadius = AgentChatSelectionActionMetrics.shadowRadius
        layer?.shadowOffset = AgentChatSelectionActionMetrics.shadowOffset
        applyAppearance()

        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = AgentChatSelectionActionMetrics.itemSpacing
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(
                equalTo: leadingAnchor,
                constant: AgentChatSelectionActionMetrics.horizontalPadding
            ),
            stack.trailingAnchor.constraint(
                equalTo: trailingAnchor,
                constant: -AgentChatSelectionActionMetrics.horizontalPadding
            ),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        update(items: items)
    }

    /// 重建按钮：插件启停后条目会变，气泡复用同一个 view。
    func update(items: [AgentChatSelectionActionItem]) {
        guard items.map(\.title) != self.items.map(\.title) || buttons.isEmpty else {
            self.items = items
            return
        }
        self.items = items
        for view in buttons + separators {
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        buttons = []
        separators = []
        for (index, item) in items.enumerated() {
            if index > 0 {
                let separator = AgentChatSelectionActionSeparator()
                separator.translatesAutoresizingMaskIntoConstraints = false
                stack.addArrangedSubview(separator)
                NSLayoutConstraint.activate([
                    separator.widthAnchor.constraint(
                        equalToConstant: AgentChatSelectionActionMetrics.separatorWidth
                    ),
                    separator.heightAnchor.constraint(
                        equalToConstant: AgentChatSelectionActionMetrics.separatorHeight
                    ),
                ])
                separators.append(separator)
            }
            let button = AgentChatSelectionActionButton(
                title: item.title,
                target: self,
                action: #selector(selectAction(_:))
            )
            button.tag = index
            button.isBordered = false
            button.focusRingType = .none
            button.font = NSFont.systemFont(ofSize: 13, weight: .medium)
            button.contentTintColor = .labelColor
            button.isEnabled = isInteractive
            stack.addArrangedSubview(button)
            buttons.append(button)
        }
    }

    required init?(coder: NSCoder) {
        return nil
    }

    var preferredSize: NSSize {
        let buttonsWidth = buttons.reduce(CGFloat.zero) { total, button in
            total + ceil(button.intrinsicContentSize.width)
        }
        let separatorsWidth = CGFloat(separators.count) * AgentChatSelectionActionMetrics.separatorWidth
        let gaps = CGFloat(max(0, buttons.count + separators.count - 1)) * stack.spacing
        return NSSize(
            width: buttonsWidth + separatorsWidth + gaps
                + AgentChatSelectionActionMetrics.horizontalPadding * 2,
            height: AgentChatSelectionActionMetrics.height
        )
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyAppearance()
    }

    override func updateTrackingAreas() {
        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
        }
        let trackingArea = NSTrackingArea(
            rect: .zero,
            options: [.activeInKeyWindow, .inVisibleRect, .mouseEnteredAndExited],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        hoverTrackingArea = trackingArea
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        needsDisplay = true
        super.mouseEntered(with: event)
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        needsDisplay = true
        super.mouseExited(with: event)
    }

    override func layout() {
        super.layout()
        layer?.shadowPath = CGPath(
            roundedRect: bounds,
            cornerWidth: AgentChatSelectionActionMetrics.cornerRadius,
            cornerHeight: AgentChatSelectionActionMetrics.cornerRadius,
            transform: nil
        )
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let borderInset = AgentChatSelectionActionMetrics.borderWidth / 2
        let path = NSBezierPath(
            roundedRect: bounds.insetBy(dx: borderInset, dy: borderInset),
            xRadius: AgentChatSelectionActionMetrics.cornerRadius,
            yRadius: AgentChatSelectionActionMetrics.cornerRadius
        )
        AgentChatSelectionActionMetrics.backgroundColor(
            isDark: isDark,
            isHovered: isHovered
        ).setFill()
        path.fill()
        AgentChatSelectionActionMetrics.borderColor(isDark: isDark).setStroke()
        path.lineWidth = AgentChatSelectionActionMetrics.borderWidth
        path.stroke()
    }

    private func applyAppearance() {
        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        layer?.shadowOpacity = isDark
            ? AgentChatSelectionActionMetrics.darkShadowOpacity
            : AgentChatSelectionActionMetrics.lightShadowOpacity
        needsDisplay = true
    }

    @objc private func selectAction(_ sender: NSButton) {
        guard sender.tag >= 0, sender.tag < items.count else { return }
        onSelect?(items[sender.tag])
    }
}

/// 气泡的出场、定位、结果反馈与收起。宿主只需要提供「选区在我坐标系里的
/// 矩形」和两个回调，剩下的都在这里。
final class AgentChatSelectionActionPresenter {
    /// 气泡挂在谁身上。
    enum Placement {
        /// 挂在宿主视图自己身上。适合铺满整条会话的大文本视图：气泡跟着内容
        /// 一起滚，位置永远贴着选区。
        case insideOwner
        /// 挂到窗口的 contentView 上。工种发言那种只有一两行高的文本视图必须走
        /// 这条：28pt 的气泡放进去会溢出 bounds，而 AppKit 不会把 bounds 之外的
        /// 点击派给子视图——看得见、点不着。
        case windowContent
    }

    /// 同一时刻只留一个气泡。会话正文和每一条工种发言各有自己的文本视图，
    /// 它们的选区互不清除——不在这里让位，选完工种再选正文就会有两个气泡同时挂着。
    private static weak var visiblePresenter: AgentChatSelectionActionPresenter?

    var onAddSelectionToTask: ((String) -> Void)?
    var onSelectionPluginAction: (
        (String, AgentPluginID, AgentPluginCommandID, @escaping (Bool) -> Void) -> Void
    )?

    private unowned let owner: NSView
    private let placement: Placement
    private var actionView: AgentChatSelectionActionView?
    private var selectedText: String?
    /// 气泡出场时选区在 owner 坐标系里的矩形。插件动作回来要按新尺寸重摆一次。
    private var selectionRect: NSRect = .zero
    /// 每次气泡重新出现/收起都自增。异步的插件动作回来时拿它对一下，
    /// 确认自己反馈的还是当初那一次选区。
    private var revision: UInt64 = 0

    init(owner: NSView, placement: Placement) {
        self.owner = owner
        self.placement = placement
    }

    var isVisible: Bool {
        guard let actionView else { return false }
        return !actionView.isHidden && actionView.superview != nil
    }

    /// `selectionRect` 用 owner 自己的坐标系。
    func show(selectedText: String, selectionRect: NSRect) {
        guard let container = resolveContainer() else {
            dismiss()
            return
        }
        if let previous = Self.visiblePresenter, previous !== self {
            previous.dismiss()
        }
        Self.visiblePresenter = self
        let actionView = actionView ?? makeActionView()
        if actionView.superview !== container {
            actionView.removeFromSuperview()
            container.addSubview(actionView, positioned: .above, relativeTo: nil)
        }
        self.selectedText = selectedText
        self.selectionRect = selectionRect
        revision &+= 1
        actionView.update(items: AgentChatSelectionActionCatalog.items())
        actionView.isInteractive = true
        actionView.isHidden = false
        position(actionView, near: selectionRect, in: container)
    }

    func dismiss() {
        selectedText = nil
        revision &+= 1
        actionView?.isInteractive = true
        actionView?.isHidden = true
        if Self.visiblePresenter === self {
            Self.visiblePresenter = nil
        }
    }

    /// 宿主离场时把气泡一起摘掉：`windowContent` 摆法下气泡不是宿主的子视图，
    /// 宿主消失它不会跟着走。
    func detach() {
        dismiss()
        actionView?.removeFromSuperview()
        actionView = nil
    }

    private func resolveContainer() -> NSView? {
        switch placement {
        case .insideOwner:
            return owner
        case .windowContent:
            return owner.window?.contentView
        }
    }

    /// 定位：优先贴在选区上方，放不下时翻到下方，再夹进可视区。
    /// 执行插件动作后气泡内容会变（换成结果提示），要按新尺寸重新摆一次。
    private func position(
        _ actionView: AgentChatSelectionActionView,
        near selectionRect: NSRect,
        in container: NSView
    ) {
        let target = container === owner
            ? selectionRect
            : container.convert(selectionRect, from: owner)
        let size = actionView.preferredSize
        let visible = container.visibleRect.insetBy(dx: 8, dy: 8)
        let gap: CGFloat = 6
        let proposedAboveY = container.isFlipped
            ? target.minY - size.height - gap
            : target.maxY + gap
        let proposedBelowY = container.isFlipped
            ? target.maxY + gap
            : target.minY - size.height - gap
        let fitsAbove = proposedAboveY >= visible.minY
            && proposedAboveY + size.height <= visible.maxY
        let targetY = fitsAbove ? proposedAboveY : proposedBelowY
        let unclampedX = target.midX - size.width / 2
        let maxX = max(visible.minX, visible.maxX - size.width)
        let targetX = min(max(unclampedX, visible.minX), maxX)
        let maxY = max(visible.minY, visible.maxY - size.height)
        actionView.frame = NSRect(
            x: targetX,
            y: min(max(targetY, visible.minY), maxY),
            width: size.width,
            height: size.height
        )
    }

    private func makeActionView() -> AgentChatSelectionActionView {
        let actionView = AgentChatSelectionActionView(items: AgentChatSelectionActionCatalog.items())
        actionView.onSelect = { [weak self] item in
            guard let self, let selectedText = self.selectedText else { return }
            guard let plugin = item.plugin else {
                self.dismiss()
                self.onAddSelectionToTask?(selectedText)
                return
            }
            // 插件动作是异步的（命令执行器 → MCP 工具），先把气泡置灰留在原地，
            // 回来了再换成「✓ 收藏」并停一下——否则点完屏幕上什么都不会发生。
            let revision = self.revision
            actionView.isInteractive = false
            self.onSelectionPluginAction?(
                selectedText,
                plugin.pluginID,
                plugin.commandID
            ) { [weak self] succeeded in
                self?.showResult(title: item.title, succeeded: succeeded, revision: revision)
            }
        }
        self.actionView = actionView
        return actionView
    }

    /// 插件选区动作执行完的即时反馈：把气泡整条换成结果，停 1.1 秒再收起。
    /// `revision` 认的是「还是当初点的那一次选区」——期间用户改了选区或气泡
    /// 已经收起，这次回调就什么都不做，不去打扰新的选区。
    private func showResult(title: String, succeeded: Bool, revision: UInt64) {
        guard revision == self.revision,
              let actionView,
              !actionView.isHidden,
              let container = actionView.superview else {
            return
        }
        let marker = succeeded ? "✓" : "⚠︎"
        actionView.update(items: [AgentChatSelectionActionItem(title: "\(marker) \(title)", plugin: nil)])
        actionView.isInteractive = false
        position(actionView, near: selectionRect, in: container)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) { [weak self] in
            guard let self, revision == self.revision else { return }
            self.dismiss()
        }
    }
}
