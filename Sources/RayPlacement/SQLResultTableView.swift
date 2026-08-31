import AppKit
import RayPlacementCore
import SwiftUI

/// A view-based NSTableView keeps large Oracle result sets responsive: AppKit
/// creates only the rows currently on screen instead of a SwiftUI cell for every
/// value. Column filters are also evaluated away from the main thread.
struct SQLResultTableView: NSViewRepresentable {
    let result: SQLResultSet
    let revision: Int

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasHorizontalScroller = true
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = true
        scroll.backgroundColor = NSColor(calibratedWhite: 0.035, alpha: 0.5)

        let table = NSTableView()
        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        table.rowHeight = 23
        table.intercellSpacing = NSSize(width: 1, height: 1)
        table.gridStyleMask = [.solidVerticalGridLineMask]
        table.gridColor = NSColor.white.withAlphaComponent(0.055)
        table.usesAlternatingRowBackgroundColors = true
        table.columnAutoresizingStyle = .noColumnAutoresizing
        table.allowsMultipleSelection = true
        table.allowsColumnReordering = true
        table.allowsColumnResizing = true
        table.headerView = SQLResultFilterHeaderView(tableView: table, coordinator: context.coordinator)
        scroll.documentView = table
        context.coordinator.tableView = table
        context.coordinator.update(result: result, revision: revision)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.update(result: result, revision: revision)
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
        weak var tableView: NSTableView?
        private var result = SQLResultSet()
        private var visibleRows: [Int]?
        private var filters: [Int: String] = [:]
        private var loadedRevision = -1
        private var filterRevision = 0
        private var filterWorkItem: DispatchWorkItem?

        func update(result: SQLResultSet, revision: Int) {
            guard revision != loadedRevision else { return }
            filterWorkItem?.cancel()
            filterRevision += 1
            loadedRevision = revision
            self.result = result
            filters = [:]
            visibleRows = nil
            rebuildColumns()
            tableView?.reloadData()
        }

        func numberOfRows(in tableView: NSTableView) -> Int { visibleRows?.count ?? result.rows.count }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let tableColumn,
                  let column = Int(tableColumn.identifier.rawValue),
                  result.columns.indices.contains(column) else { return nil }
            let identifier = NSUserInterfaceItemIdentifier("SQLResultValue")
            let field: NSTextField
            if let reused = tableView.makeView(withIdentifier: identifier, owner: nil) as? NSTextField {
                field = reused
            } else {
                field = NSTextField(labelWithString: "")
                field.identifier = identifier
                field.isSelectable = true
                field.lineBreakMode = .byTruncatingTail
                field.font = .monospacedSystemFont(ofSize: 10.5, weight: .regular)
                field.textColor = .labelColor
            }
            let sourceRow = visibleRows?[safe: row] ?? row
            field.stringValue = result.rows[safe: sourceRow]?[safe: column] ?? ""
            field.toolTip = field.stringValue
            return field
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField,
                  let index = Int(field.identifier?.rawValue ?? "") else { return }
            let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if value.isEmpty { filters.removeValue(forKey: index) } else { filters[index] = value }
            scheduleFilter()
        }

        private func rebuildColumns() {
            guard let tableView else { return }
            tableView.tableColumns.forEach(tableView.removeTableColumn)
            for (index, name) in result.columns.enumerated() {
                let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(String(index)))
                column.title = ""
                column.minWidth = 112
                column.maxWidth = 520
                column.width = estimatedWidth(column: index, name: name)
                column.resizingMask = .userResizingMask
                tableView.addTableColumn(column)
            }
            (tableView.headerView as? SQLResultFilterHeaderView)?.rebuild(columns: result.columns)
        }

        private func estimatedWidth(column: Int, name: String) -> CGFloat {
            let samples = result.rows.prefix(80).compactMap { $0[safe: column] }
            let longest = samples.reduce(name.count) { max($0, min(52, $1.count)) }
            return min(420, max(140, CGFloat(longest) * 7.1 + 20))
        }

        private func scheduleFilter() {
            filterWorkItem?.cancel()
            filterRevision += 1
            let revision = filterRevision
            let rows = result.rows
            let activeFilters = filters
            guard !activeFilters.isEmpty else {
                visibleRows = nil
                tableView?.reloadData()
                return
            }
            let work = DispatchWorkItem { [weak self] in
                let matches = SQLResultFilter.matchingRowIndices(rows: rows, filters: activeFilters)
                DispatchQueue.main.async {
                    guard self?.filterRevision == revision else { return }
                    self?.visibleRows = matches
                    self?.tableView?.reloadData()
                }
            }
            filterWorkItem = work
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.16, execute: work)
        }
    }
}

@MainActor
private final class SQLResultFilterHeaderView: NSTableHeaderView {
    private weak var filterCoordinator: SQLResultTableView.Coordinator?
    private var labels: [NSTextField] = []
    private var filters: [NSSearchField] = []

    init(tableView: NSTableView, coordinator: SQLResultTableView.Coordinator) {
        self.filterCoordinator = coordinator
        super.init(frame: NSRect(x: 0, y: 0, width: 0, height: 51))
        self.tableView = tableView
    }

    required init?(coder: NSCoder) { nil }

    func rebuild(columns: [String]) {
        labels.forEach { $0.removeFromSuperview() }
        filters.forEach { $0.removeFromSuperview() }
        labels = columns.enumerated().map { index, name in
            let label = NSTextField(labelWithString: name)
            label.font = .monospacedSystemFont(ofSize: 10, weight: .semibold)
            label.textColor = .systemCyan
            label.lineBreakMode = .byTruncatingTail
            label.toolTip = name
            addSubview(label)
            let filter = NSSearchField()
            filter.identifier = NSUserInterfaceItemIdentifier(String(index))
            filter.placeholderString = "Filter"
            filter.font = .systemFont(ofSize: 10)
            filter.delegate = filterCoordinator
            filter.sendsSearchStringImmediately = true
            filter.controlSize = .small
            filters.append(filter)
            addSubview(filter)
            return label
        }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        guard let tableView else { return }
        frame.size.height = 51
        for index in tableView.tableColumns.indices where labels.indices.contains(index) && filters.indices.contains(index) {
            let rect = tableView.rect(ofColumn: index).insetBy(dx: 5, dy: 0)
            labels[index].frame = NSRect(x: rect.minX, y: 29, width: rect.width, height: 16)
            filters[index].frame = NSRect(x: rect.minX, y: 3, width: rect.width, height: 23)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(calibratedWhite: 0.07, alpha: 0.98).setFill()
        dirtyRect.fill()
        NSColor.white.withAlphaComponent(0.08).setStroke()
        let line = NSBezierPath()
        line.move(to: NSPoint(x: dirtyRect.minX, y: 0.5))
        line.line(to: NSPoint(x: dirtyRect.maxX, y: 0.5))
        line.stroke()
    }
}

private extension Collection {
    subscript(safe index: Index) -> Element? { indices.contains(index) ? self[index] : nil }
}
