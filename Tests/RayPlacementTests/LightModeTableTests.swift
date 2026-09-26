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
    let focusedCellHasIndicator = view.debugCellHasVisibleFocusIndicator(row: 1, column: 0)
    let paddedCellAreaIsEditable = view.debugCellFieldCoversPoint(
        row: 1,
        column: 0,
        at: CGPoint(x: bodyFrame.midX, y: bodyFrame.minY + 4)
    )
    let clickReachesEditableField = view.debugHitTestTargetsEditableField(
        at: CGPoint(x: bodyFrame.midX, y: bodyFrame.midY)
    )

    // Keep a real interaction affordance in the table: a click just inside
    // the cell edge must reach its NSTextField, and the selected cell's border
    // must be visible in the rendered layer output.
    #expect(actualHeader.alphaComponent > 0)
    #expect(actualBody.alphaComponent > 0)
    #expect(paddedCellAreaIsEditable)
    #expect(clickReachesEditableField)
    #expect(focusedCellHasIndicator)
    #expect(headerFrame.height >= 34)
    #expect(bodyFrame.height >= 34)
    #expect(contrastRatio(palette.textPrimary, expectedBody, appearance: lightAppearance) >= 4.5)
    #expect(contrastRatio(palette.textPrimary, expectedHeader, appearance: lightAppearance) >= 4.5)

    window.contentView = nil
}

@MainActor
@Test func markdownTableTabAndReturnCommandsMoveBetweenEditableCells() {
    let table = MarkdownTableData(
        headers: ["Task", "Owner"],
        alignments: [.leading, .leading],
        rows: [["Review table", "Liam"], ["Verify dictation", "Morgan"]]
    )
    let view = MarkdownNativeTableView(table: table)
    view.frame = NSRect(x: 0, y: 0, width: 520, height: view.preferredHeight)
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 520, height: view.preferredHeight),
        styleMask: [.borderless],
        backing: .buffered,
        defer: false
    )
    window.contentView = view
    window.layoutIfNeeded()
    view.layoutSubtreeIfNeeded()

    #expect(view.debugFocusCell(row: 1, column: 0))
    #expect(view.debugDispatchCellCommand(#selector(NSResponder.insertTab(_:)), row: 1, column: 0))
    #expect(view.debugCellIsFocused(row: 1, column: 1))

    #expect(view.debugDispatchCellCommand(#selector(NSResponder.insertBacktab(_:)), row: 1, column: 1))
    #expect(view.debugCellIsFocused(row: 1, column: 0))

    #expect(view.debugDispatchCellCommand(#selector(NSResponder.insertNewline(_:)), row: 1, column: 0))
    #expect(view.debugCellIsFocused(row: 2, column: 0))

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

@Test @MainActor func markdownTableFieldEditorTypingSelectionAndTabularPaste() async throws {
    let table = MarkdownTableData(headers: ["Task", "Owner"], alignments: [.leading, .leading],
                                  rows: [["Original", "Liam"]])
    let view = MarkdownNativeTableView(table: table)
    view.frame = NSRect(x: 0, y: 0, width: 520, height: view.preferredHeight)
    let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = view
    defer { window.makeFirstResponder(nil); window.contentView = nil }
    window.layoutIfNeeded()
    view.layoutSubtreeIfNeeded()
    var changes = 0
    view.onChange = { changes += 1 }

    #expect(view.debugFocusCell(row: 1, column: 0))
    let editor = try #require(window.firstResponder as? NSTextView)
    editor.selectAll(nil)
    let selection = try #require(editor.selectedTextAttributes[.backgroundColor] as? NSColor)
    #expect(selection.alphaComponent > 0) // Selection must not be invisible.
    editor.insertText("Typed | value", replacementRange: editor.selectedRange())
    #expect(table.rows[0][0] == "Typed | value")
    #expect(changes > 0)
    #expect(table.markdown.contains("Typed \\| value"))

    // Use a private pasteboard; never read or replace the user's clipboard.
    let pasteboard = NSPasteboard.withUniqueName()
    defer { pasteboard.releaseGlobally() }
    pasteboard.setString("One\tTwo\tThree\nFour\tFive\tSix", forType: .string)
    #expect(editor.readSelection(from: pasteboard, type: .string))
    for _ in 0..<10 { await Task.yield() }
    #expect(table.columnCount == 3)
    #expect(table.rows == [["One", "Two", "Three"], ["Four", "Five", "Six"]])
    #expect(view.debugCellIsFocused(row: 1, column: 0))
    let focusedEditor = try #require(window.firstResponder as? NSTextView)
    focusedEditor.doCommand(by: #selector(NSResponder.insertTab(_:)))
    #expect(view.debugCellIsFocused(row: 1, column: 1))
    #expect(view.subviews.filter { $0 is NSScrollView }.count == 1)
    let secondEditor = try #require(window.firstResponder as? NSTextView)
    #expect(secondEditor.readSelection(from: pasteboard, type: .string))
    for _ in 0..<10 { await Task.yield() }
    #expect(view.subviews.filter { $0 is NSScrollView }.count == 1)
    #expect(table.rows[0][0] == "One")
    #expect(table.rows[0][1] == "One")
    #expect(table.columnCount == 4)
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
