import AppKit
import RayPlacementCore

@MainActor
final class MarkdownTableData {
    var headers: [String]
    var alignments: [MarkdownTableAlignment]
    var rows: [[String]]

    init(
        headers: [String],
        alignments: [MarkdownTableAlignment],
        rows: [[String]]
    ) {
        let columnCount = max(1, headers.count)
        self.headers = Self.normalized(headers, count: columnCount, defaultValue: "Column")
        self.alignments = Self.normalized(alignments, count: columnCount, defaultValue: .leading)
        self.rows = rows.isEmpty
            ? [Array(repeating: "", count: columnCount)]
            : rows.map { Self.normalized($0, count: columnCount, defaultValue: "") }
    }

    var columnCount: Int { headers.count }

    var markdown: String {
        var lines = [markdownRow(headers)]
        lines.append("| " + alignments.map(Self.delimiter).joined(separator: " | ") + " |")
        lines.append(contentsOf: rows.map(markdownRow))
        return lines.joined(separator: "\n")
    }

    func addRow() {
        rows.append(Array(repeating: "", count: columnCount))
    }

    func removeLastRow() {
        guard rows.count > 1 else { return }
        rows.removeLast()
    }

    func addColumn() {
        headers.append("Column \(columnCount + 1)")
        alignments.append(.leading)
        for index in rows.indices { rows[index].append("") }
    }

    func removeLastColumn() {
        guard columnCount > 1 else { return }
        headers.removeLast()
        alignments.removeLast()
        for index in rows.indices { rows[index].removeLast() }
    }

    private func markdownRow(_ cells: [String]) -> String {
        "| " + cells.map(Self.escaped).joined(separator: " | ") + " |"
    }

    private static func escaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "|", with: "\\|")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    private static func delimiter(_ alignment: MarkdownTableAlignment) -> String {
        switch alignment {
        case .leading: return ":---"
        case .center: return ":---:"
        case .trailing: return "---:"
        }
    }

    private static func normalized<T>(_ values: [T], count: Int, defaultValue: T) -> [T] {
        if values.count == count { return values }
        if values.count > count { return Array(values.prefix(count)) }
        return values + Array(repeating: defaultValue, count: count - values.count)
    }
}

@MainActor
final class MarkdownTableAttachment: NSTextAttachment {
    static let fileType = "dev.liam.rayplacement.markdown-table"

    let table: MarkdownTableData
    var onChange: (() -> Void)?
    var onDelete: (() -> Void)?

    init(table: MarkdownTableData) {
        self.table = table
        super.init(data: Data([0]), ofType: Self.fileType)
        allowsTextAttachmentView = false
        image = NSImage(size: NSSize(width: 1, height: 1))
    }

    required init?(coder: NSCoder) {
        table = MarkdownTableData(
            headers: ["Column 1", "Column 2"],
            alignments: [.leading, .leading],
            rows: [["", ""]]
        )
        super.init(coder: coder)
        allowsTextAttachmentView = false
        image = NSImage(size: NSSize(width: 1, height: 1))
    }

    override func attachmentBounds(
        for attributes: [NSAttributedString.Key: Any],
        location: any NSTextLocation,
        textContainer: NSTextContainer?,
        proposedLineFragment: CGRect,
        position: CGPoint
    ) -> CGRect {
        let availableWidth = proposedLineFragment.width.isFinite && proposedLineFragment.width > 220
            ? proposedLineFragment.width
            : 520
        let height = 44 + CGFloat(1 + table.rows.count) * 35
        return CGRect(x: 0, y: 0, width: max(260, availableWidth), height: height)
    }

    override func attachmentBounds(
        for textContainer: NSTextContainer?,
        proposedLineFragment lineFragment: NSRect,
        glyphPosition position: NSPoint,
        characterIndex: Int
    ) -> NSRect {
        let availableWidth = lineFragment.width.isFinite && lineFragment.width > 220
            ? lineFragment.width
            : 520
        let height = 44 + CGFloat(1 + table.rows.count) * 35
        return NSRect(x: 0, y: 0, width: max(260, availableWidth), height: height)
    }
}

@MainActor
final class MarkdownNativeTableView: NSView, NSTextFieldDelegate {
    private let table: MarkdownTableData
    private let toolbar = NSStackView()
    private var gridView: NSGridView?
    private var fields: [MarkdownTableField] = []
    private var isSizingColumns = false

    var onChange: (() -> Void)?
    var onDelete: (() -> Void)?
    var onSizeChange: (() -> Void)?

    var preferredHeight: CGFloat {
        44 + CGFloat(1 + table.rows.count) * 35
    }

    init(table: MarkdownTableData) {
        self.table = table
        super.init(frame: NSRect(x: 0, y: 0, width: 560, height: 150))
        translatesAutoresizingMaskIntoConstraints = true
        wantsLayer = true
        layer?.cornerRadius = 11
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.62).cgColor
        layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.72).cgColor
        layer?.masksToBounds = true
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Editable table")
        configureToolbar()
        rebuildGrid()
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        guard !isSizingColumns,
              let gridView,
              gridView.numberOfColumns > 0 else { return }
        isSizingColumns = true
        let separators = CGFloat(max(0, gridView.numberOfColumns - 1)) * gridView.columnSpacing
        let width = floor(max(72, gridView.bounds.width - separators) / CGFloat(gridView.numberOfColumns))
        for column in 0..<gridView.numberOfColumns {
            gridView.column(at: column).width = width
        }
        isSizingColumns = false
    }

    private func configureToolbar() {
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        toolbar.orientation = .horizontal
        toolbar.alignment = .centerY
        toolbar.spacing = 6

        let icon = NSImageView(image: NSImage(
            systemSymbolName: "tablecells",
            accessibilityDescription: nil
        ) ?? NSImage())
        icon.contentTintColor = .controlAccentColor
        icon.setContentHuggingPriority(.required, for: .horizontal)

        let title = NSTextField(labelWithString: "Table")
        title.font = .systemFont(ofSize: 12, weight: .semibold)
        title.textColor = .secondaryLabelColor

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let addRow = makeButton(title: "+ Row", action: #selector(addRow))
        addRow.setAccessibilityLabel("Add table row")
        let addColumn = makeButton(title: "+ Column", action: #selector(addColumn))
        addColumn.setAccessibilityLabel("Add table column")

        let more = NSButton(
            image: NSImage(systemSymbolName: "ellipsis", accessibilityDescription: "Table actions") ?? NSImage(),
            target: self,
            action: #selector(showActions(_:))
        )
        more.isBordered = false
        more.imagePosition = .imageOnly
        more.setAccessibilityLabel("Table actions")

        for item in [icon, title, spacer, addRow, addColumn, more] {
            toolbar.addArrangedSubview(item)
        }
        addSubview(toolbar)
        NSLayoutConstraint.activate([
            toolbar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 11),
            toolbar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            toolbar.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            toolbar.heightAnchor.constraint(equalToConstant: 28)
        ])
    }

    private func makeButton(title: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .recessed
        button.controlSize = .small
        button.font = .systemFont(ofSize: 11, weight: .medium)
        return button
    }

    private func rebuildGrid(focus coordinate: CellCoordinate? = nil) {
        gridView?.removeFromSuperview()
        fields.removeAll(keepingCapacity: true)

        var visualRows: [[NSView]] = []
        visualRows.append(table.headers.enumerated().map { column, value in
            cellView(value: value, coordinate: .header(column), header: true, alternate: false)
        })
        for (row, values) in table.rows.enumerated() {
            visualRows.append(values.enumerated().map { column, value in
                cellView(value: value, coordinate: .body(row, column), header: false, alternate: row.isMultiple(of: 2))
            })
        }

        let grid = NSGridView(views: visualRows)
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.rowSpacing = 1
        grid.columnSpacing = 1
        grid.xPlacement = .fill
        grid.yPlacement = .fill
        grid.wantsLayer = true
        grid.layer?.backgroundColor = NSColor.separatorColor.withAlphaComponent(0.52).cgColor
        for row in 0..<grid.numberOfRows { grid.row(at: row).height = 34 }
        for column in 0..<grid.numberOfColumns { grid.column(at: column).xPlacement = .fill }

        addSubview(grid)
        NSLayoutConstraint.activate([
            grid.leadingAnchor.constraint(equalTo: leadingAnchor),
            grid.trailingAnchor.constraint(equalTo: trailingAnchor),
            grid.topAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: 4),
            grid.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        gridView = grid

        if let coordinate {
            DispatchQueue.main.async { [weak self] in
                guard let self,
                      let field = self.fields.first(where: { $0.coordinate == coordinate }) else { return }
                self.window?.makeFirstResponder(field)
                field.currentEditor()?.selectAll(nil)
            }
        }
    }

    private func cellView(
        value: String,
        coordinate: CellCoordinate,
        header: Bool,
        alternate: Bool
    ) -> NSView {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = header
            ? NSColor.controlAccentColor.withAlphaComponent(0.14).cgColor
            : NSColor.textBackgroundColor.withAlphaComponent(alternate ? 0.56 : 0.76).cgColor

        let field = MarkdownTableField(string: value)
        field.coordinate = coordinate
        field.delegate = self
        field.translatesAutoresizingMaskIntoConstraints = false
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 13.5, weight: header ? .semibold : .regular)
        field.textColor = .labelColor
        field.placeholderString = header ? "Column" : "Add value"
        field.lineBreakMode = .byTruncatingTail
        field.setAccessibilityLabel(coordinate.accessibilityLabel)

        container.addSubview(field)
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 10),
            field.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -9),
            field.centerYAnchor.constraint(equalTo: container.centerYAnchor)
        ])
        fields.append(field)
        return container
    }

    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? MarkdownTableField else { return }
        switch field.coordinate {
        case .header(let column):
            table.headers[column] = field.stringValue
        case .body(let row, let column):
            table.rows[row][column] = field.stringValue
        }
        onChange?()
    }

    func control(
        _ control: NSControl,
        textView: NSTextView,
        doCommandBy commandSelector: Selector
    ) -> Bool {
        guard let field = control as? MarkdownTableField else { return false }
        if commandSelector == #selector(NSResponder.insertTab(_:)) {
            move(from: field, forward: true)
            return true
        }
        if commandSelector == #selector(NSResponder.insertBacktab(_:)) {
            move(from: field, forward: false)
            return true
        }
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            moveDown(from: field)
            return true
        }
        return false
    }

    private func move(from field: MarkdownTableField, forward: Bool) {
        guard let index = fields.firstIndex(where: { $0 === field }) else { return }
        let targetIndex = index + (forward ? 1 : -1)
        if targetIndex >= fields.count {
            table.addRow()
            let coordinate = CellCoordinate.body(table.rows.count - 1, 0)
            rebuildGrid(focus: coordinate)
            onChange?()
            onSizeChange?()
        } else if targetIndex >= 0 {
            window?.makeFirstResponder(fields[targetIndex])
            fields[targetIndex].currentEditor()?.selectAll(nil)
        }
    }

    private func moveDown(from field: MarkdownTableField) {
        let column = field.coordinate.column
        let nextCoordinate: CellCoordinate
        switch field.coordinate {
        case .header:
            nextCoordinate = .body(0, column)
        case .body(let row, _):
            if row + 1 >= table.rows.count {
                table.addRow()
                rebuildGrid(focus: .body(row + 1, column))
                onChange?()
                onSizeChange?()
                return
            }
            nextCoordinate = .body(row + 1, column)
        }
        if let next = fields.first(where: { $0.coordinate == nextCoordinate }) {
            window?.makeFirstResponder(next)
            next.currentEditor()?.selectAll(nil)
        }
    }

    @objc private func addRow() {
        table.addRow()
        rebuildGrid(focus: .body(table.rows.count - 1, 0))
        onChange?()
        onSizeChange?()
    }

    @objc private func addColumn() {
        table.addColumn()
        rebuildGrid(focus: .header(table.columnCount - 1))
        onChange?()
        onSizeChange?()
    }

    @objc private func showActions(_ sender: NSButton) {
        let menu = NSMenu(title: "Table Actions")
        let removeRow = NSMenuItem(title: "Remove Last Row", action: #selector(removeLastRow), keyEquivalent: "")
        removeRow.target = self
        removeRow.isEnabled = table.rows.count > 1
        menu.addItem(removeRow)
        let removeColumn = NSMenuItem(title: "Remove Last Column", action: #selector(removeLastColumn), keyEquivalent: "")
        removeColumn.target = self
        removeColumn.isEnabled = table.columnCount > 1
        menu.addItem(removeColumn)
        menu.addItem(.separator())
        let delete = NSMenuItem(title: "Delete Table", action: #selector(deleteTable), keyEquivalent: "")
        delete.target = self
        menu.addItem(delete)
        menu.popUp(positioning: nil, at: NSPoint(x: sender.bounds.minX, y: sender.bounds.minY), in: sender)
    }

    @objc private func removeLastRow() {
        table.removeLastRow()
        rebuildGrid()
        onChange?()
        onSizeChange?()
    }

    @objc private func removeLastColumn() {
        table.removeLastColumn()
        rebuildGrid()
        onChange?()
        onSizeChange?()
    }

    @objc private func deleteTable() {
        onDelete?()
    }
}

private enum CellCoordinate: Equatable {
    case header(Int)
    case body(Int, Int)

    var column: Int {
        switch self {
        case .header(let column): return column
        case .body(_, let column): return column
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .header(let column): return "Table header, column \(column + 1)"
        case .body(let row, let column): return "Table row \(row + 1), column \(column + 1)"
        }
    }
}

private final class MarkdownTableField: NSTextField {
    var coordinate: CellCoordinate = .header(0)
}

@MainActor
enum MarkdownTableDocumentCodec {
    private struct Line {
        var fullRange: NSRange
        var contentRange: NSRange
        var text: String
    }

    private struct Region {
        var range: NSRange
        var table: MarkdownTableData
    }

    static func attributedString(
        from markdown: String,
        onTableChange: @escaping () -> Void,
        onTableDelete: @escaping (MarkdownTableAttachment) -> Void
    ) -> NSAttributedString {
        let source = markdown as NSString
        let output = NSMutableAttributedString()
        var cursor = 0
        for region in tableRegions(in: markdown) {
            if region.range.location > cursor {
                output.append(NSAttributedString(string: source.substring(
                    with: NSRange(location: cursor, length: region.range.location - cursor)
                )))
            }
            let attachment = MarkdownTableAttachment(table: region.table)
            attachment.onChange = onTableChange
            attachment.onDelete = { [weak attachment] in
                guard let attachment else { return }
                onTableDelete(attachment)
            }
            output.append(NSAttributedString(attachment: attachment))
            cursor = NSMaxRange(region.range)
        }
        if cursor < source.length {
            output.append(NSAttributedString(string: source.substring(
                with: NSRange(location: cursor, length: source.length - cursor)
            )))
        }
        return output
    }

    static func markdown(from attributedString: NSAttributedString) -> String {
        let source = attributedString.string as NSString
        var markdown = ""
        var cursor = 0
        while cursor < attributedString.length {
            var range = NSRange(location: 0, length: 0)
            let attachment = attributedString.attribute(
                .attachment,
                at: cursor,
                effectiveRange: &range
            ) as? MarkdownTableAttachment
            if let attachment {
                markdown += attachment.table.markdown
                cursor = NSMaxRange(range)
            } else {
                let next = NSMaxRange(range)
                markdown += source.substring(with: NSRange(location: cursor, length: next - cursor))
                cursor = next
            }
        }
        return markdown
    }

    private static func tableRegions(in markdown: String) -> [Region] {
        let source = markdown as NSString
        guard source.length > 0 else { return [] }
        var lines: [Line] = []
        var cursor = 0
        while cursor < source.length {
            let fullRange = source.lineRange(for: NSRange(location: cursor, length: 0))
            var contentLength = fullRange.length
            while contentLength > 0 {
                let character = source.character(at: fullRange.location + contentLength - 1)
                if character == 10 || character == 13 { contentLength -= 1 } else { break }
            }
            let contentRange = NSRange(location: fullRange.location, length: contentLength)
            lines.append(Line(
                fullRange: fullRange,
                contentRange: contentRange,
                text: source.substring(with: contentRange)
            ))
            cursor = NSMaxRange(fullRange)
        }

        var regions: [Region] = []
        var index = 0
        var insideCode = false
        while index < lines.count {
            let trimmed = lines[index].text.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                insideCode.toggle()
                index += 1
                continue
            }
            guard !insideCode,
                  index + 1 < lines.count,
                  let header = tableHeader(
                    headerLine: lines[index].text,
                    delimiterLine: lines[index + 1].text
                  ) else {
                index += 1
                continue
            }

            var rows: [[String]] = []
            var end = index + 2
            while end < lines.count {
                let candidate = lines[end].text
                guard !candidate.trimmingCharacters(in: .whitespaces).isEmpty,
                      candidate.contains("|") else { break }
                var cells = tableCells(from: candidate)
                guard !cells.isEmpty else { break }
                cells = normalized(cells, count: header.headers.count, defaultValue: "")
                rows.append(cells)
                end += 1
            }
            let finalLine = lines[max(index + 1, end - 1)]
            let range = NSRange(
                location: lines[index].contentRange.location,
                length: NSMaxRange(finalLine.contentRange) - lines[index].contentRange.location
            )
            regions.append(Region(
                range: range,
                table: MarkdownTableData(
                    headers: header.headers,
                    alignments: header.alignments,
                    rows: rows
                )
            ))
            index = end
        }
        return regions
    }

    private static func tableHeader(
        headerLine: String,
        delimiterLine: String
    ) -> (headers: [String], alignments: [MarkdownTableAlignment])? {
        guard headerLine.contains("|"), delimiterLine.contains("|") else { return nil }
        let headers = tableCells(from: headerLine)
        let delimiters = tableCells(from: delimiterLine)
        guard !headers.isEmpty, headers.count == delimiters.count else { return nil }
        var alignments: [MarkdownTableAlignment] = []
        for raw in delimiters {
            let delimiter = raw.trimmingCharacters(in: .whitespaces)
            let dashes = delimiter.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
            guard dashes.count >= 3, dashes.allSatisfy({ $0 == "-" }) else { return nil }
            if delimiter.hasPrefix(":") && delimiter.hasSuffix(":") {
                alignments.append(.center)
            } else if delimiter.hasSuffix(":") {
                alignments.append(.trailing)
            } else {
                alignments.append(.leading)
            }
        }
        return (headers, alignments)
    }

    private static func tableCells(from line: String) -> [String] {
        var source = line.trimmingCharacters(in: .whitespaces)[...]
        if source.first == "|" { source = source.dropFirst() }
        if source.last == "|" { source = source.dropLast() }
        var cells: [String] = []
        var current = ""
        var escaped = false
        for character in source {
            if escaped {
                current.append(character)
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "|" {
                cells.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(character)
            }
        }
        if escaped { current.append("\\") }
        cells.append(current.trimmingCharacters(in: .whitespaces))
        return cells
    }

    private static func normalized<T>(_ values: [T], count: Int, defaultValue: T) -> [T] {
        if values.count > count { return Array(values.prefix(count)) }
        return values + Array(repeating: defaultValue, count: count - values.count)
    }
}
