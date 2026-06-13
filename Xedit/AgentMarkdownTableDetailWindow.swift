//
//  AgentMarkdownTableDetailWindow.swift
//  WillDeep
//
//  Opens a Markdown table from the lightweight transcript renderer in
//  a separate AppKit table window. The chat pane keeps its low-memory
//  TextKit fallback; only an explicit click creates NSTableView cells.
//

import AppKit

final class AgentMarkdownTablePayload: NSObject {
    let headers: [String]
    let rows: [[String]]

    var columnCount: Int {
        max(headers.count, rows.map(\.count).max() ?? 0)
    }

    init(headers: [String], rows: [[String]]) {
        self.headers = headers
        self.rows = rows
        super.init()
    }

    func title(forColumn index: Int) -> String {
        if index < headers.count, !headers[index].isEmpty {
            return headers[index]
        }
        return String(
            localized: "agent.markdown-table.column-title",
            defaultValue: "Column \(index + 1)"
        )
    }

    func value(row: Int, column: Int) -> String {
        guard row >= 0, row < rows.count else { return "" }
        let cells = rows[row]
        guard column >= 0, column < cells.count else { return "" }
        return cells[column]
    }
}

@MainActor
enum AgentMarkdownTableDetailWindowRegistry {
    private static var controllers: Set<AgentMarkdownTableDetailWindowController> = []

    static func open(payload: AgentMarkdownTablePayload) {
        let controller = AgentMarkdownTableDetailWindowController(payload: payload) {
            controllers.remove($0)
        }
        controllers.insert(controller)
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }
}

@MainActor
private final class AgentMarkdownTableDetailWindowController: NSWindowController, NSWindowDelegate {
    private let release: (AgentMarkdownTableDetailWindowController) -> Void
    private let tableDataSource: AgentMarkdownTableDetailDataSource

    init(payload: AgentMarkdownTablePayload, release: @escaping (AgentMarkdownTableDetailWindowController) -> Void) {
        self.release = release
        self.tableDataSource = AgentMarkdownTableDetailDataSource(payload: payload)

        let tableView = NSTableView()
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.gridStyleMask = [.solidHorizontalGridLineMask, .solidVerticalGridLineMask]
        tableView.columnAutoresizingStyle = .noColumnAutoresizing
        tableView.rowHeight = 28
        tableView.headerView = NSTableHeaderView()
        tableView.dataSource = tableDataSource
        tableView.delegate = tableDataSource

        for columnIndex in 0..<payload.columnCount {
            let identifier = NSUserInterfaceItemIdentifier("column-\(columnIndex)")
            let column = NSTableColumn(identifier: identifier)
            column.title = payload.title(forColumn: columnIndex)
            column.minWidth = 96
            column.width = tableDataSource.preferredWidth(forColumn: columnIndex)
            column.maxWidth = 640
            tableView.addTableColumn(column)
        }

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = false
        scrollView.borderType = .noBorder
        scrollView.documentView = tableView

        let caption = NSTextField(labelWithString: String(
            localized: "agent.markdown-table.detail-caption",
            defaultValue: "\(payload.rows.count) rows · \(payload.columnCount) columns"
        ))
        caption.font = .systemFont(ofSize: 12, weight: .medium)
        caption.textColor = .secondaryLabelColor

        let container = NSStackView(views: [caption, scrollView])
        container.orientation = .vertical
        container.alignment = .leading
        container.spacing = 10
        container.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.widthAnchor.constraint(greaterThanOrEqualToConstant: 760).isActive = true
        scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 420).isActive = true

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 840, height: 520),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = String(localized: "agent.markdown-table.window-title", defaultValue: "Markdown Table")
        window.contentView = container
        window.center()

        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) {
        return nil
    }

    func windowWillClose(_ notification: Notification) {
        release(self)
    }
}

@MainActor
private final class AgentMarkdownTableDetailDataSource: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private let payload: AgentMarkdownTablePayload

    init(payload: AgentMarkdownTablePayload) {
        self.payload = payload
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        payload.rows.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard
            let tableColumn,
            let columnIndex = tableView.tableColumns.firstIndex(of: tableColumn)
        else {
            return nil
        }

        let identifier = NSUserInterfaceItemIdentifier("cell-\(columnIndex)")
        let field = (tableView.makeView(withIdentifier: identifier, owner: self) as? NSTextField)
            ?? NSTextField(wrappingLabelWithString: "")
        field.identifier = identifier
        field.stringValue = payload.value(row: row, column: columnIndex)
        field.font = .systemFont(ofSize: 13)
        field.textColor = .labelColor
        field.lineBreakMode = .byTruncatingTail
        field.maximumNumberOfLines = 2
        field.allowsDefaultTighteningForTruncation = true
        return field
    }

    func preferredWidth(forColumn column: Int) -> CGFloat {
        let headerWidth = AgentMarkdownTableFormatter.displayWidth(of: payload.title(forColumn: column))
        let bodyWidth = payload.rows
            .map { column < $0.count ? AgentMarkdownTableFormatter.displayWidth(of: $0[column]) : 0 }
            .max() ?? 0
        let width = CGFloat(max(headerWidth, bodyWidth)) * 8.5 + 40
        return min(640, max(120, width))
    }
}
