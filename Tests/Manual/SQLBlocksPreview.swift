// Isolated manual UI fixture: no app settings, passwords, or database connections.
import SwiftUI
import RayPlacementCore

@main struct SQLBlocksPreview: App {
    var body: some Scene { WindowGroup("SQL Blocks Preview") { PreviewContent() }.defaultSize(width: 880, height: 740) }
}

private struct PreviewContent: View {
    @State private var query: SQLVisualQuery = {
        var query = SQLVisualQuery(tables: ["OPS.ORDERS"])
        var blocks = SQLQueryBlocks()
        blocks.filters = [SQLFilterBlock(kind: .any, children: [SQLFilterBlock(field: "OPS.ORDERS.STATUS", value: "OPEN"), SQLFilterBlock(field: "OPS.ORDERS.TOTAL", comparison: .greater, valueType: .number, value: "100")])]
        query.blocks = blocks
        return query
    }()
    let tables = [SQLTable(schema: "OPS", name: "ORDERS", kind: "TABLE", columns: [SQLColumn(name: "STATUS", dataType: "VARCHAR", nullable: true, ordinal: 1), SQLColumn(name: "TOTAL", dataType: "NUMBER", nullable: true, ordinal: 2)])]
    var body: some View {
        HSplitView {
            SQLBlockCanvasEditor(query: $query, tables: tables, driver: .oracle).frame(minWidth: 430)
            ScrollView { Text(query.sql(for: .oracle)).font(.system(size: 12, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding() }.frame(minWidth: 250)
        }.padding(12).background(Color(white: 0.075)).preferredColorScheme(.dark)
    }
}
