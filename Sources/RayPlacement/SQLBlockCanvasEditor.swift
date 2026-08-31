import SwiftUI
import UniformTypeIdentifiers
import RayPlacementCore

/// Typed blocks remain the source of truth; the SQL preview is derived, never hidden.
struct SQLBlockCanvasEditor: View {
    @Binding var query: SQLVisualQuery
    var tables: [SQLTable]
    var driver: SQLDatabaseDriver
    var schemaRevision: Int = 0
    @State private var pendingRemoval: String?
    @State private var columns: [String] = []
    @State private var tableNames: [String] = []
    @State private var dropTargeted = false

    private var blocks: Binding<SQLQueryBlocks> {
        Binding(get: { query.blocks ?? SQLQueryBlocks() }, set: { query.blocks = $0 })
    }
    private func refreshSuggestions() {
        let selected = Set(query.tables + (query.blocks?.joins.map(\.table) ?? []))
        columns = tables.filter { selected.contains($0.qualifiedName) }.flatMap { table in table.columns.map { "\(table.qualifiedName).\($0.name)" } }.sorted()
    }
    private func refreshSchemaSuggestions() {
        tableNames = tables.map(\.qualifiedName).sorted()
        refreshSuggestions()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 91), spacing: 5)], alignment: .leading, spacing: 5) {
                    ForEach(["Select", "Join", "Filter", "Group", "Aggregate", "Having", "Sort"], id: \.self) { kind in
                        Button { add(kind) } label: {
                            HStack(spacing: 4) { Image(systemName: paletteIcon(kind)).foregroundStyle(color(kind)); Text(paletteTitle(kind)); Spacer(minLength: 0); Image(systemName: "plus").limaFont(.system(size: 8)) }
                                .limaFont(.system(size: 10, weight: .medium)).padding(.horizontal, 7).frame(height: 27)
                        }
                            .buttonStyle(.plain)
                            .background(Color.white.opacity(0.045), in: SQLSocketShape())
                            .onDrag { NSItemProvider(object: "lima-block:\(kind)" as NSString) }
                            .help("Add a \(kind.lowercased()) block. You can also drag it into the flow.")
                    }
                }.padding(.vertical, 2)
            ScrollView {
                VStack(alignment: .leading, spacing: 7) {
                    sourceBlock
                    selectBlock
                    joinBlocks
                    if !blocks.wrappedValue.filters.isEmpty {
                        block("FILTER", color: .orange) {
                            SQLFilterListEditor(filters: blocks.filters, columns: columns)
                        }
                    }
                    if !blocks.wrappedValue.groupBy.isEmpty {
                        block("GROUP BY", color: .purple) { stringRows(blocks.groupBy, placeholder: "Grouping column") }
                    }
                    aggregateBlocks
                    if !blocks.wrappedValue.having.isEmpty {
                        block("HAVING", color: .orange) {
                            SQLFilterListEditor(filters: blocks.having, columns: columns + ["COUNT(*)", "SUM(column)", "AVG(column)"])
                        }
                    }
                    sortBlocks
                    block("LIMIT", color: .cyan) {
                        HStack {
                            TextField("250", value: $query.limit, formatter: Self.integerFormatter).frame(width: 85)
                            Text("rows").foregroundStyle(.secondary)
                            Spacer()
                        }
                    }
                }.padding(3)
            }
            .frame(minHeight: 185, maxHeight: .infinity)
        }
        .padding(4)
        .background(dropTargeted ? Color.teal.opacity(0.10) : .clear, in: SQLSocketShape())
        .overlay(SQLSocketShape().stroke(dropTargeted ? Color.teal.opacity(0.8) : .clear, style: StrokeStyle(lineWidth: 1.2, dash: [5, 4])).allowsHitTesting(false))
        .onDrop(of: [.plainText], isTargeted: $dropTargeted, perform: acceptDrop)
        .limaFont(.system(size: 11))
        .textFieldStyle(.roundedBorder)
        .controlSize(.small)
        .onAppear(perform: refreshSchemaSuggestions)
        .onChange(of: schemaRevision) { _ in refreshSchemaSuggestions() }
        .onChange(of: query.tables + (query.blocks?.joins.map(\.table) ?? [])) { _ in refreshSuggestions() }
        .alert("Remove source table?", isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } })) {
            Button("Cancel", role: .cancel) { pendingRemoval = nil }
            Button("Remove and reset blocks", role: .destructive) { if let table = pendingRemoval { remove(table) }; pendingRemoval = nil }
        } message: { Text("This removes the source and resets query blocks to avoid stale references. Other source tables remain.") }
    }

    private static let integerFormatter: NumberFormatter = {
        let formatter = NumberFormatter(); formatter.numberStyle = .none; formatter.usesGroupingSeparator = false; return formatter
    }()

    private func acceptDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let text = object as? String else { return }
            DispatchQueue.main.async {
                if text.hasPrefix("lima-block:") { add(String(text.dropFirst("lima-block:".count))) }
                else if tables.contains(where: { $0.qualifiedName == text }), !query.tables.contains(text) { query.tables.append(text) }
            }
        }
        return true
    }

    private var sourceBlock: some View {
        block("FROM", color: .blue) {
            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array(query.tables.enumerated()), id: \.element) { index, table in
                    HStack {
                        Text(index == 0 ? "Start" : (blocks.wrappedValue.joins.contains { $0.table == table } ? "Joined" : "Cross")).foregroundStyle(.secondary).frame(width: 40, alignment: .leading)
                        Text(table).limaFont(.system(size: 11, design: .monospaced)).lineLimit(1).help(table)
                        Spacer()
                        Button { pendingRemoval = table } label: { Image(systemName: "xmark") }.buttonStyle(.borderless).help("Remove table and reset query blocks")
                    }
                }
                Menu("Add table…") {
                    ForEach(tables) { table in
                        Button(table.qualifiedName) { if !query.tables.contains(table.qualifiedName) { query.tables.append(table.qualifiedName) } }
                    }
                }.frame(maxWidth: 220, alignment: .leading).help("Choose any discovered table, or drag a table anywhere onto the workspace.")
            }
        }
    }

    private var selectBlock: some View {
        block("SELECT", color: .blue) {
            VStack(alignment: .leading, spacing: 5) {
                Toggle("Distinct rows", isOn: blocks.distinct).toggleStyle(.checkbox)
                if blocks.wrappedValue.columns.isEmpty {
                    Text(blocks.wrappedValue.aggregates.isEmpty && blocks.wrappedValue.groupBy.isEmpty ? "All columns from the starting table" : "Grouping columns + summaries").foregroundStyle(.secondary)
                }
                stringRows(blocks.columns, placeholder: "Column / expression")
            }
        }
    }

    private var joinBlocks: some View {
        ForEach(blocks.joins) { $join in
            block("JOIN", color: .teal) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Picker("Type", selection: $join.style) { ForEach(SQLJoinBlock.Style.allCases, id: \.self) { Text($0.rawValue).tag($0) } }.labelsHidden().frame(width: 100)
                        SQLExpressionField(placeholder: "Joined table", text: $join.table, suggestions: tableNames)
                        Button { blocks.wrappedValue.joins.removeAll { $0.id == join.id } } label: { Image(systemName: "xmark") }.buttonStyle(.borderless).help("Remove join")
                    }
                    Text(joinDescription(join.style)).limaFont(.system(size: 10)).foregroundStyle(.secondary)
                    if join.style != .cross { SQLFilterNodeEditor(node: $join.condition, columns: columns) }
                }
            }
            .modifier(SQLReorderBlocks(items: blocks.joins, id: join.id, category: "join"))
        }
    }

    private var aggregateBlocks: some View {
        ForEach(blocks.aggregates) { $aggregate in
            block("AGGREGATE", color: .purple) {
                VStack(spacing: 5) {
                    HStack {
                        Picker("Function", selection: $aggregate.function) { ForEach(SQLAggregateBlock.Function.allCases, id: \.self) { Text($0.rawValue).tag($0) } }.labelsHidden().frame(width: 94)
                        SQLExpressionField(placeholder: "Column", text: $aggregate.field, suggestions: ["*"] + columns)
                        Button { blocks.wrappedValue.aggregates.removeAll { $0.id == aggregate.id } } label: { Image(systemName: "xmark") }.buttonStyle(.borderless).help("Remove aggregate")
                    }
                    HStack {
                        Toggle("Distinct", isOn: $aggregate.distinct).toggleStyle(.checkbox)
                        TextField("Result name (optional)", text: $aggregate.alias)
                    }
                }
            }
            .modifier(SQLReorderBlocks(items: blocks.aggregates, id: aggregate.id, category: "aggregate"))
        }
    }

    private var sortBlocks: some View {
        ForEach(blocks.sorts) { $sort in
            block("SORT", color: .cyan) {
                HStack {
                    SQLExpressionField(placeholder: "Column / aggregate", text: $sort.field, suggestions: columns)
                    Picker("Direction", selection: $sort.descending) { Text("ASC").tag(false); Text("DESC").tag(true) }.labelsHidden().frame(width: 76)
                    Button { blocks.wrappedValue.sorts.removeAll { $0.id == sort.id } } label: { Image(systemName: "xmark") }.buttonStyle(.borderless).help("Remove sort")
                }
            }
            .modifier(SQLReorderBlocks(items: blocks.sorts, id: sort.id, category: "sort"))
        }
    }

    private func stringRows(_ values: Binding<[String]>, placeholder: String) -> some View {
        VStack(spacing: 5) {
            ForEach(values.wrappedValue.indices, id: \.self) { index in
                HStack {
                    SQLExpressionField(placeholder: placeholder, text: Binding(get: { values.wrappedValue.indices.contains(index) ? values.wrappedValue[index] : "" }, set: { if values.wrappedValue.indices.contains(index) { values.wrappedValue[index] = $0 } }), suggestions: columns)
                    Button { values.wrappedValue.remove(at: index) } label: { Image(systemName: "xmark") }.buttonStyle(.borderless).help("Remove column")
                }
            }
        }
    }

    private func block<Content: View>(_ title: String, color: Color, @ViewBuilder content: @escaping () -> Content) -> some View {
        SQLQueryStepCard(clause: title, color: color, content: content)
    }

    private func paletteTitle(_ kind: String) -> String {
        switch kind { case "Select": return "Columns"; case "Aggregate": return "Summarize"; case "Having": return "Totals filter"; default: return kind }
    }
    private func paletteIcon(_ kind: String) -> String {
        switch kind { case "Select": return "list.bullet.rectangle"; case "Join": return "link"; case "Filter", "Having": return "line.3.horizontal.decrease"; case "Group": return "square.stack.3d.up"; case "Aggregate": return "sum"; default: return "arrow.up.arrow.down" }
    }
    private func joinDescription(_ style: SQLJoinBlock.Style) -> String {
        switch style {
        case .inner: return "Keep rows that match on both sides."
        case .left: return "Keep every row on the left, plus matching rows on the right."
        case .right: return "Keep every row on the right, plus matching rows on the left."
        case .full: return driver == .mysql ? "Not supported by MySQL. Use a UNION in Free SQL." : "Keep rows from both sides, including unmatched rows."
        case .cross: return "Every combination of rows. Large tables can produce very large results."
        }
    }

    private func color(_ kind: String) -> Color {
        switch kind { case "Join": return .teal; case "Filter", "Having": return .orange; case "Aggregate", "Group": return .purple; case "Sort": return .cyan; default: return .blue }
    }

    private func add(_ kind: String) {
        switch kind {
        case "Select": blocks.wrappedValue.columns.append("")
        case "Join": blocks.wrappedValue.joins.append(SQLJoinBlock())
        case "Filter": blocks.wrappedValue.filters.append(SQLFilterBlock())
        case "Group": blocks.wrappedValue.groupBy.append("")
        case "Aggregate": blocks.wrappedValue.aggregates.append(SQLAggregateBlock())
        case "Having": blocks.wrappedValue.having.append(SQLFilterBlock())
        case "Sort": blocks.wrappedValue.sorts.append(SQLSortBlock())
        default: break
        }
    }

    private func remove(_ table: String) {
        query.tables.removeAll { $0 == table }
        query.projections.removeAll { $0.hasPrefix(table + ".") }
        query.joins.removeAll { $0.fromTable == table || $0.toTable == table }
        // Do not leave invisible conditions referencing a removed source.
        query.blocks = SQLQueryBlocks()
    }
}

private struct SQLQueryStepCard<Content: View>: View {
    var clause: String
    var color: Color
    @ViewBuilder var content: () -> Content
    @State private var expanded = true
    @State private var showingHelp = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var meaning: (String, String) {
        switch clause {
        case "FROM": return ("Source tables", "Choose where the rows come from. Additional tables without a join condition create a cross join.")
        case "SELECT": return ("Choose columns", "Pick the columns returned in the result. Distinct removes duplicate result rows.")
        case "JOIN": return ("Connect tables", "Combine tables using matching columns. Conditions can be grouped with AND, OR, and NOT.")
        case "FILTER": return ("Filter rows", "WHERE runs before grouping. Separate top-level conditions must all match; use an OR group for alternatives.")
        case "GROUP BY": return ("Group rows", "Rows with the same values become one group. Every non-summary result column must be included here.")
        case "AGGREGATE": return ("Summarize", "Calculate COUNT, SUM, AVG, MIN, or MAX for each group, or for the entire result when no grouping is set.")
        case "HAVING": return ("Filter summaries", "HAVING runs after grouping. Use it for conditions such as COUNT(*) > 10.")
        case "SORT": return ("Order results", "Sort ascending or descending. Drag sort blocks to change their priority.")
        default: return ("Limit results", "Cap the number of rows returned. Add a sort for a predictable first page.")
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Button {
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.12)) { expanded.toggle() }
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: expanded ? "chevron.down" : "chevron.right").limaFont(.system(size: 8, weight: .bold)).foregroundStyle(color)
                        Text(meaning.0).limaFont(.system(size: 11, weight: .semibold))
                        Spacer(minLength: 3)
                        Text(clause == "FILTER" ? "WHERE" : clause).limaFont(.system(size: 8.5, weight: .medium, design: .monospaced)).foregroundStyle(color)
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain).help(expanded ? "Collapse this block" : "Expand this block")
                Button { showingHelp.toggle() } label: { Image(systemName: "info.circle").limaFont(.system(size: 10)).foregroundStyle(.secondary) }
                    .buttonStyle(.plain).accessibilityLabel("About \(meaning.0)")
                    .popover(isPresented: $showingHelp) { Text(meaning.1).limaFont(.system(size: 12)).padding(12).frame(width: 265) }
            }.padding(.horizontal, 10).frame(height: 33)
            if expanded {
                content().padding(.horizontal, 10).padding(.bottom, 10)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(white: 0.095), in: SQLSocketShape())
        .overlay(alignment: .leading) { Rectangle().fill(color.opacity(0.8)).frame(width: 2).padding(.vertical, 10).allowsHitTesting(false) }
        .overlay(SQLSocketShape().stroke(color.opacity(0.22), lineWidth: 0.7).allowsHitTesting(false))
    }
}

private struct SQLSocketShape: Shape {
    func path(in rect: CGRect) -> Path {
        let width = rect.width, height = rect.height
        return Path { p in
            p.move(to: CGPoint(x: 0, y: 4)); p.addLine(to: CGPoint(x: 4, y: 0))
            p.addLine(to: CGPoint(x: 18, y: 0)); p.addLine(to: CGPoint(x: 22, y: 4)); p.addLine(to: CGPoint(x: 40, y: 4)); p.addLine(to: CGPoint(x: 44, y: 0))
            p.addLine(to: CGPoint(x: width - 4, y: 0)); p.addLine(to: CGPoint(x: width, y: 4)); p.addLine(to: CGPoint(x: width, y: height - 4)); p.addLine(to: CGPoint(x: width - 4, y: height))
            p.addLine(to: CGPoint(x: 44, y: height)); p.addLine(to: CGPoint(x: 40, y: height - 4)); p.addLine(to: CGPoint(x: 22, y: height - 4)); p.addLine(to: CGPoint(x: 18, y: height)); p.addLine(to: CGPoint(x: 4, y: height)); p.addLine(to: CGPoint(x: 0, y: height - 4)); p.closeSubpath()
        }
    }
    func strokeBorderless(_ color: Color) -> some View { stroke(color, lineWidth: 0.7) }
}

private struct SQLExpressionField: View {
    var placeholder: String
    @Binding var text: String
    var suggestions: [String]
    var body: some View {
        HStack(spacing: 3) {
            TextField(placeholder, text: $text).limaFont(.system(size: 10.5, design: .monospaced))
            if !suggestions.isEmpty {
                Menu {
                    ForEach(suggestions.filter { text.isEmpty || $0.localizedCaseInsensitiveContains(text) }, id: \.self) { item in Button(item) { text = item } }
                } label: { Image(systemName: "list.bullet") }.menuStyle(.borderlessButton).frame(width: 19).help("Choose from schema")
            }
        }
    }
}

private struct SQLReorderBlocks<Item: Identifiable>: ViewModifier where Item.ID == UUID {
    @Binding var items: [Item]
    var id: UUID
    var category: String
    private var dragType: UTType { UTType(exportedAs: "dev.liam.lima.sql-reorder-\(category)") }
    func body(content: Content) -> some View {
        content
            .onDrag {
                let provider = NSItemProvider()
                provider.registerDataRepresentation(forTypeIdentifier: dragType.identifier, visibility: .ownProcess) { completion in completion(Data(id.uuidString.utf8), nil); return nil }
                return provider
            }
            .onDrop(of: [dragType], isTargeted: nil) { providers in
                providers.first?.loadDataRepresentation(forTypeIdentifier: dragType.identifier) { data, _ in
                    guard let data, let text = String(data: data, encoding: .utf8), let source = UUID(uuidString: text) else { return }
                    DispatchQueue.main.async {
                        guard let from = items.firstIndex(where: { $0.id == source }), let to = items.firstIndex(where: { $0.id == id }) else { return }
                        items.insert(items.remove(at: from), at: to)
                    }
                }
                return !providers.isEmpty
            }
    }
}

private struct SQLFilterListEditor: View {
    @Binding var filters: [SQLFilterBlock]
    var columns: [String]
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach($filters) { $filter in
                HStack(alignment: .top, spacing: 5) {
                    SQLFilterNodeEditor(node: $filter, columns: columns)
                    VStack(spacing: 8) {
                        Button { filters.removeAll { $0.id == filter.id } } label: { Image(systemName: "xmark") }.help("Remove condition")
                        Button {
                            if let index = filters.firstIndex(where: { $0.id == filter.id }), index > 0 { filters.swapAt(index, index - 1) }
                        } label: { Image(systemName: "arrow.up") }.help("Move condition up")
                    }.buttonStyle(.borderless)
                }
                .padding(7).background(Color.white.opacity(0.035), in: SQLSocketShape())
                .modifier(SQLReorderBlocks(items: $filters, id: filter.id, category: "filter"))
            }
        }
    }
}

private struct SQLFilterNodeEditor: View {
    @Binding var node: SQLFilterBlock
    var columns: [String]
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Picker("Condition type", selection: $node.kind) { ForEach(SQLFilterBlock.Kind.allCases, id: \.self) { Text(kindTitle($0)).tag($0) } }.labelsHidden().frame(width: 163)
            if node.kind == .condition {
                HStack {
                    SQLExpressionField(placeholder: "Column / expression", text: $node.field, suggestions: columns)
                    Picker("Comparison", selection: $node.comparison) { ForEach(SQLFilterBlock.Comparison.allCases, id: \.self) { Text($0.rawValue).tag($0) } }.labelsHidden().frame(width: 110)
                }
                if node.comparison != .isNull && node.comparison != .notNull {
                    HStack(alignment: .top) {
                        Picker("Value type", selection: $node.valueType) { ForEach(SQLFilterBlock.ValueType.allCases, id: \.self) { Text($0.rawValue).tag($0) } }.labelsHidden().frame(width: 112)
                        if node.comparison == .inside || node.comparison == .outside {
                            TextField("One value per line", text: $node.value, axis: .vertical).lineLimit(2...5)
                        } else {
                            SQLExpressionField(placeholder: "Value", text: $node.value, suggestions: node.valueType == .expression ? columns : [])
                        }
                    }
                    if node.comparison == .between { TextField("Upper value", text: $node.upperValue) }
                }
            } else if node.kind == .expression {
                TextField("SQL condition, e.g. EXISTS (SELECT …)", text: $node.field, axis: .vertical).lineLimit(1...4)
            } else {
                // Type erasure breaks SwiftUI's recursive view type, not the data model.
                AnyView(SQLFilterListEditor(filters: $node.children, columns: columns)).padding(.leading, 8)
                Menu("Add to \(node.kind.rawValue)…") {
                    Button("Condition") { node.children.append(SQLFilterBlock()) }
                    Button("AND group") { node.children.append(SQLFilterBlock(kind: .all, children: [SQLFilterBlock()])) }
                    Button("OR group") { node.children.append(SQLFilterBlock(kind: .any, children: [SQLFilterBlock()])) }
                    Button("NOT group") { node.children.append(SQLFilterBlock(kind: .not, children: [SQLFilterBlock()])) }
                }.frame(width: 130)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func kindTitle(_ kind: SQLFilterBlock.Kind) -> String {
        switch kind { case .condition: return "Compare a value"; case .all: return "Match all · AND"; case .any: return "Match any · OR"; case .not: return "Exclude · NOT"; case .expression: return "Custom SQL condition" }
    }
}
