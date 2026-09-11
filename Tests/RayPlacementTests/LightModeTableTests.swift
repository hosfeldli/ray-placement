import AppKit
import Testing
@testable import RayPlacement

@MainActor
@Test func lightModeMarkdownTableRenderedAppearanceRegression() throws {
    let table = MarkdownTableData(
        headers: ["Header"],
        alignments: [.leading],
        rows: [["Body"], ["Hovered"], [""]]
    )
    let lightAppearance = NSAppearance(named: NSAppearance.Name.aqua)!
    let view = MarkdownNativeTableView(table: table)
    view.appearance = lightAppearance
    view.frame = NSRect(x: 0, y: 0, width: 420, height: view.preferredHeight)

    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 420, height: view.preferredHeight),
        styleMask: [.borderless],
        backing: .buffered,
        defer: false
    )
    window.appearance = lightAppearance
    window.contentView = view
    view.appearance = lightAppearance
    window.layoutIfNeeded()
    view.layoutSubtreeIfNeeded()
    view.debugRefreshAppearance()

    view.debugSetHoveredCell(row: 2, column: 0)
    #expect(view.debugFocusCell(row: 3, column: 0))
    view.layoutSubtreeIfNeeded()

    guard let image = view.debugRenderedBitmap() else {
        Issue.record("Could not render the Markdown table into a bitmap")
        return
    }

    let palette = NotesAppearancePalette(
        theme: SettingsStore.shared.notesVisualTheme,
        appearance: lightAppearance
    )
    let header = try #require(view.debugCellFrame(row: 0, column: 0))
    let body = try #require(view.debugCellFrame(row: 1, column: 0))
    let hovered = try #require(view.debugCellFrame(row: 2, column: 0))
    let focused = try #require(view.debugCellFrame(row: 3, column: 0))

    let actualHeader = try #require(view.debugPixel(in: image, at: header.midX, y: header.midY))
    let actualBody = try #require(view.debugPixel(in: image, at: body.maxX - 5, y: body.midY))
    let actualHovered = try #require(view.debugPixel(in: image, at: hovered.maxX - 5, y: hovered.midY))
    // The focused palette is applied to the active editor with the same opaque
    // composited result used by the table renderer.
    let actualFocused = try #require(view.debugPixel(in: image, at: focused.minX + 20, y: focused.midY))
    #expect(colorDistance(actualHeader, resolved(palette.tableHeader, appearance: lightAppearance)) < 0.12)
    #expect(colorDistance(actualBody, resolved(palette.background, appearance: lightAppearance)) < 0.12)
    #expect(colorDistance(actualHovered, resolved(palette.tableHover, appearance: lightAppearance)) < 0.12)
    let selectedOverlay = resolved(palette.tableSelectedCell, appearance: lightAppearance)
    let expectedFocused = composite(selectedOverlay, over: actualBody)
    #expect(colorDistance(actualFocused, expectedFocused) < 0.12)
    #expect(colorDistance(actualHeader, actualBody) > 0.005)
    #expect(colorDistance(actualHovered, actualBody) > 0.003)
    #expect(colorDistance(actualFocused, actualBody) > 0.003)

    window.contentView = nil
}

@MainActor
private func resolved(_ color: NSColor, appearance: NSAppearance) -> NSColor {
    NotesAppearancePalette.resolved(color, appearance: appearance)
        .usingColorSpace(.deviceRGB) ?? color.usingColorSpace(.deviceRGB) ?? .clear
}

private func colorDistance(_ lhs: NSColor, _ rhs: NSColor) -> CGFloat {
    let left = lhs.usingColorSpace(.deviceRGB) ?? lhs
    let right = rhs.usingColorSpace(.deviceRGB) ?? rhs
    return abs(left.redComponent - right.redComponent)
        + abs(left.greenComponent - right.greenComponent)
        + abs(left.blueComponent - right.blueComponent)
        + abs(left.alphaComponent - right.alphaComponent)
}

@MainActor
private func composite(_ foreground: NSColor, over background: NSColor) -> NSColor {
    let fg = foreground.usingColorSpace(.deviceRGB) ?? foreground
    let bg = background.usingColorSpace(.deviceRGB) ?? background
    let alpha = fg.alphaComponent
    let outputAlpha = alpha + bg.alphaComponent * (1 - alpha)
    guard outputAlpha > 0 else { return .clear }
    return NSColor(
        calibratedRed: (fg.redComponent * alpha + bg.redComponent * bg.alphaComponent * (1 - alpha)) / outputAlpha,
        green: (fg.greenComponent * alpha + bg.greenComponent * bg.alphaComponent * (1 - alpha)) / outputAlpha,
        blue: (fg.blueComponent * alpha + bg.blueComponent * bg.alphaComponent * (1 - alpha)) / outputAlpha,
        alpha: outputAlpha
    )
}
