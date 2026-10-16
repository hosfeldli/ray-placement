import Foundation
import Markdown

/// Immutable presentation data. Parsing and inline style construction happen on
/// the service actor; SwiftUI only builds views from these values.
struct LimaMarkdownRenderTree: Sendable {
    enum Block: Sendable {
        case paragraph(AttributedString)
        case heading(Int, AttributedString)
        case list(ordered: Bool, start: Int, items: [AttributedString])
        case quote(AttributedString)
        case code(language: String, text: String)
        case table(headers: [AttributedString], rows: [[AttributedString]])
        case rule
        case literal(String)
    }

    let source: String
    let blocks: [Block]
}

actor LimaMarkdownRenderService {
    static let shared = LimaMarkdownRenderService()

    private final class Entry {
        let tree: LimaMarkdownRenderTree
        init(_ tree: LimaMarkdownRenderTree) { self.tree = tree }
    }

    private let cache: NSCache<NSString, Entry> = {
        let cache = NSCache<NSString, Entry>()
        cache.countLimit = 64
        cache.totalCostLimit = 12 * 1_024 * 1_024
        return cache
    }()

    func renderTree(for source: String) -> LimaMarkdownRenderTree {
        let key = source as NSString
        if let cached = cache.object(forKey: key), cached.tree.source == source {
            return cached.tree
        }

        let document = Document(parsing: source)
        var blocks: [LimaMarkdownRenderTree.Block] = []
        for node in document.children {
            blocks.append(contentsOf: Self.convert(node))
        }
        // CommonMark accepts most malformed input. Still render the original
        // literal if no block survived conversion instead of showing blank UI.
        if blocks.isEmpty { blocks = [.literal(source)] }
        let tree = LimaMarkdownRenderTree(source: source, blocks: blocks)
        cache.setObject(Entry(tree), forKey: key, cost: max(1, min(source.utf8.count * 3, 12 * 1_024 * 1_024)))
        return tree
    }

    private static func convert(_ node: Markup) -> [LimaMarkdownRenderTree.Block] {
        if let heading = node as? Heading {
            return [.heading(heading.level, styled(inlineMarkdown(heading)))]
        }
        if let paragraph = node as? Paragraph {
            return [.paragraph(styled(inlineMarkdown(paragraph)))]
        }
        if let list = node as? OrderedList {
            let items = list.children.map { styled(inlineMarkdown($0)) }
            return [.list(ordered: true, start: Int(list.startIndex), items: items)]
        }
        if let list = node as? UnorderedList {
            let items = list.children.map { styled(inlineMarkdown($0)) }
            return [.list(ordered: false, start: 1, items: items)]
        }
        if let quote = node as? BlockQuote {
            return [.quote(styled(inlineMarkdown(quote)))]
        }
        if let code = node as? CodeBlock {
            return [.code(language: code.language ?? "", text: code.code)]
        }
        if let table = node as? Table {
            let headers = table.head.children.map { styled(inlineMarkdown($0)) }
            let rows = table.body.children.map { row in
                row.children.map { styled(inlineMarkdown($0)) }
            }
            return [.table(headers: headers, rows: rows)]
        }
        if node is ThematicBreak { return [.rule] }

        let children = Array(node.children)
        if !children.isEmpty {
            let converted = children.flatMap(convert)
            if !converted.isEmpty { return converted }
        }
        return [.literal(node.format())]
    }

    private static func inlineMarkdown(_ node: Markup) -> String {
        let parts = node.children.map { child -> String in
            if child is Paragraph { return inlineMarkdown(child) }
            if child is LineBreak || child is SoftBreak { return "\n" }
            if child is OrderedList || child is UnorderedList { return "\n" + child.format() }
            return child.format()
        }
        return parts.joined().trimmingCharacters(in: .newlines)
    }

    private static func styled(_ markdown: String) -> AttributedString {
        (try? AttributedString(markdown: markdown, options: .init(interpretedSyntax: .full)))
            ?? AttributedString(markdown)
    }
}
