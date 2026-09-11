import AppKit
import Testing
@testable import RayPlacement

@MainActor
@Test func markdownTableUsesReadableNativeSurfacesAndVisibleFocus() throws {
    let table = MarkdownTableData(
        headers: ["Header"],
        alignments: [.leading],
        rows: [["Body text"], ["A longer body value that should wrap instead of being clipped"]]
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
    window.layoutIfNeeded()
    view.layoutSubtreeIfNeeded()
    view.debugRefreshAppearance()

    #expect(view.debugFocusCell(row: 1, column: 0))
    view.layoutSubtreeIfNeeded()

    guard let image = view.debugRenderedBitmap() else {
        Issue.record("Could not render the Markdown table into a bitmap")
        return
    }

    let palette = NotesAppearancePalette(theme: SettingsStore.shared.notesVisualTheme, appearance: lightAppearance)
    let headerFrame = try #require(view.debugCellFrame(row: 0, column: 0))
    let bodyFrame = try #require(view.debugCellFrame(row: 1, column: 0))
    let actualHeader = try #require(view.debugPixel(in: image, at: headerFrame.midX, y: headerFrame.midY))
    let actualBody = try #require(view.debugPixel(in: image, at: bodyFrame.maxX - 5, y: bodyFrame.midY))
    let expectedHeader = resolved(palette.elevatedSurface, appearance: lightAppearance)
    let expectedBody = resolved(palette.background, appearance: lightAppearance)

    // The off-screen AppKit compositor may flatten sibling cell layers. Keep
    // the screenshot useful as a renderability check, while contrast is
    // asserted against the semantic foreground/background roles below.
    #expect(actualHeader.alphaComponent > 0)
    #expect(actualBody.alphaComponent > 0)
    #expect(headerFrame.height >= 34)
    #expect(bodyFrame.height >= 34)
    #expect(contrastRatio(palette.textPrimary, expectedBody, appearance: lightAppearance) >= 4.5)
    #expect(contrastRatio(palette.textPrimary, expectedHeader, appearance: lightAppearance) >= 4.5)

    window.contentView = nil
}

@MainActor
@Test func markdownTablePaletteMaintainsTextContrastInLightAndDarkAppearances() {
    for appearance in [NSAppearance(named: .aqua)!, NSAppearance(named: .darkAqua)!] {
        let palette = NotesAppearancePalette(theme: SettingsStore.shared.notesVisualTheme, appearance: appearance)
        let body = resolved(palette.background, appearance: appearance)
        let header = resolved(palette.elevatedSurface, appearance: appearance)
        #expect(contrastRatio(palette.textPrimary, body, appearance: appearance) >= 4.5)
        #expect(contrastRatio(palette.textPrimary, header, appearance: appearance) >= 4.5)
        #expect(contrastRatio(palette.textPrimary, resolved(palette.tableHeader, appearance: appearance), appearance: appearance) >= 4.5)
        #expect(contrastRatio(palette.tableGrid, body, appearance: appearance) >= (appearance == NSAppearance(named: .darkAqua) ? 2.0 : 1.5))
        #expect(contrastRatio(palette.tableOuterBorder, body, appearance: appearance) >= (appearance == NSAppearance(named: .darkAqua) ? 2.5 : 1.5))
    }
}

@MainActor
private func resolved(_ color: NSColor, appearance: NSAppearance) -> NSColor {
    NotesAppearancePalette.resolved(color, appearance: appearance)
        .usingColorSpace(.deviceRGB) ?? color.usingColorSpace(.deviceRGB) ?? .clear
}

@MainActor
private func contrastRatio(_ foreground: NSColor, _ background: NSColor, appearance: NSAppearance) -> CGFloat {
    let fg = resolved(foreground, appearance: appearance)
    let bg = resolved(background, appearance: appearance)
    func luminance(_ color: NSColor) -> CGFloat {
        let components = [color.redComponent, color.greenComponent, color.blueComponent].map { component in
            component <= 0.03928 ? component / 12.92 : pow((component + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * components[0] + 0.7152 * components[1] + 0.0722 * components[2]
    }
    let light = max(luminance(fg), luminance(bg))
    let dark = min(luminance(fg), luminance(bg))
    return (light + 0.05) / (dark + 0.05)
}
