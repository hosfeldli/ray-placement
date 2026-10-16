import Foundation
import Testing
@testable import RayPlacement

@Test func markdownASTBuildsSemanticBlocksOffMain() async {
    let source = """
    # Summary

    A **bold** line with a [link](https://example.com).

    - first
    - second

    | Name | Value |
    | --- | --- |
    | One | Two |

    > A quote

    ```swift
    let value = 1
    ```
    """
    let tree = await LimaMarkdownRenderService.shared.renderTree(for: source)
    #expect(tree.source == source)
    #expect(tree.blocks.contains { if case .heading(1, _) = $0 { true } else { false } })
    #expect(tree.blocks.contains { if case .list(ordered: false, _, let items) = $0 { items.count == 2 } else { false } })
    #expect(tree.blocks.contains { if case .table(let headers, let rows) = $0 { headers.count == 2 && rows.count == 1 } else { false } })
    #expect(tree.blocks.contains { if case .quote = $0 { true } else { false } })
    #expect(tree.blocks.contains { if case .code(let language, let text) = $0 { language == "swift" && text.contains("let value = 1") } else { false } })
}

@Test func malformedMarkdownKeepsVisibleText() async {
    let source = "# Header\n\nAn **unclosed paragraph and `code"
    let tree = await LimaMarkdownRenderService.shared.renderTree(for: source)
    #expect(!tree.blocks.isEmpty)
    let visible = tree.blocks.map { block -> String in
        switch block {
        case .paragraph(let text), .heading(_, let text), .quote(let text):
            return String(text.characters)
        case .list(_, _, let items):
            return items.map { String($0.characters) }.joined(separator: " ")
        case .code(_, let text), .literal(let text):
            return text
        case .table(let headers, let rows):
            return (headers + rows.flatMap { $0 }).map { String($0.characters) }.joined(separator: " ")
        case .rule:
            return ""
        }
    }.joined(separator: " ")
    #expect(visible.contains("unclosed paragraph"))
    #expect(visible.contains("code"))
}
