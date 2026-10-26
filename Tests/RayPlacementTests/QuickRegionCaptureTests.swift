import AppKit
import Foundation
import Testing
@testable import RayPlacement

@Test func quickRegionImageBypassesOCRAndKeepsPixelsPrivate() throws {
    let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x01])
    let payload = try QuickRegionCapturePayload.prepare(kind: .image, pngData: png) { _ in
        Issue.record("Image capture must not invoke OCR")
        return "unexpected"
    }
    #expect(payload == .image(png))
}

@Test func textReaderTrimsLocalOCRAndRejectsEmptyResults() throws {
    let data = Data("fixture".utf8)
    let payload = try QuickRegionCapturePayload.prepare(kind: .text, pngData: data) { input in
        #expect(input == data)
        return "  Warehouse 42\n  "
    }
    #expect(payload == .text("Warehouse 42"))
    do {
        _ = try QuickRegionCapturePayload.prepare(kind: .text, pngData: data) { _ in "  \n " }
        Issue.record("Expected empty OCR text to leave the clipboard unchanged")
    } catch QuickRegionCaptureError.noText {
        // Expected.
    }
}

@Test func quickRegionRejectsCaptureAfterUnrelatedAppTakesFocus() {
    #expect(QuickRegionCaptureFocus.permitsCapture(
        frontmostProcessID: 100, limaProcessID: 100, sourceProcessID: 200
    ))
    #expect(QuickRegionCaptureFocus.permitsCapture(
        frontmostProcessID: 200, limaProcessID: 100, sourceProcessID: 200
    ))
    #expect(!QuickRegionCaptureFocus.permitsCapture(
        frontmostProcessID: 300, limaProcessID: 100, sourceProcessID: 200
    ))
    #expect(!QuickRegionCaptureFocus.permitsCapture(
        frontmostProcessID: nil, limaProcessID: 100, sourceProcessID: 200
    ))
    #expect(!QuickRegionCaptureFocus.permitsCapture(
        frontmostProcessID: 200, limaProcessID: 100, sourceProcessID: nil
    ))
}

@Test func screenshotContextRejectsTransientTakeover() {
    var state = ScreenshotCaptureContextState(
        limaProcessID: 100, sourceProcessID: 200, clipboardChangeCount: 5
    )
    state.observeActivation(200)
    #expect(state.permitsCompletion(frontmostProcessID: 100, clipboardChangeCount: 5))
    state.observeActivation(300)
    state.observeActivation(100)
    #expect(!state.permitsCompletion(frontmostProcessID: 100, clipboardChangeCount: 5))
    #expect(!state.permitsCompletion(frontmostProcessID: 200, clipboardChangeCount: 5))
}

@Test func screenshotContextPreservesNewClipboardContentsAndRejectsDisplayChanges() {
    var state = ScreenshotCaptureContextState(
        limaProcessID: 100, sourceProcessID: nil, clipboardChangeCount: 5
    )
    #expect(state.permitsCompletion(frontmostProcessID: 100, clipboardChangeCount: 5))
    #expect(!state.permitsCompletion(frontmostProcessID: 100, clipboardChangeCount: 6))
    #expect(!state.permitsCompletion(frontmostProcessID: nil, clipboardChangeCount: 5))
    state.invalidate()
    #expect(!state.permitsCompletion(frontmostProcessID: 100, clipboardChangeCount: 5))
}

@Test func quickRegionInstructionsMatchSelectedOperation() {
    #expect(QuickRegionCaptureKind.image.selectionInstruction.contains("copy an image"))
    #expect(QuickRegionCaptureKind.text.selectionInstruction.contains("read text"))
}

@Test @MainActor func screenshotStudioPreflightRestoresUIWithoutStartingCapture() throws {
    try #require(LimaTestEnvironment.isEnabled)
    let defaults = LimaTestEnvironment.userDefaults
    let destinationKey = "lima.screenshot.destination"
    let bookmarkKey = "lima.screenshot.saveFolderBookmark"
    let previousDestination = defaults.object(forKey: destinationKey)
    let previousBookmark = defaults.object(forKey: bookmarkKey)
    defer {
        defaults.set(previousDestination, forKey: destinationKey)
        defaults.set(previousBookmark, forKey: bookmarkKey)
    }
    defaults.removeObject(forKey: bookmarkKey)

    for destination in ScreenshotDestination.allCases {
        defaults.set(destination.rawValue, forKey: destinationKey)
        let model = ScreenshotStudioModel()
        var completions: [Bool] = []
        model.capture(
            .region(displayID: 1, rect: CGRect(x: 0, y: 0, width: 100, height: 100)),
            beforeCapture: { Issue.record("Rejected capture must not begin") },
            captureAllowed: {
                Issue.record("Preflight must not request screen capture")
                return false
            },
            afterCapture: { completions.append($0) },
            onTakeover: { Issue.record("Preflight failure is not user takeover") }
        )
        #expect(completions == [false])
        #expect(!model.isWorking)
        if destination.includesFile {
            #expect(model.message == ScreenshotFileDestination.DestinationError.folderUnavailable.localizedDescription)
        } else {
            #expect(model.message?.contains("library is not ready") == true)
        }
    }
}

@Test @MainActor func textReaderRecognizesFixtureWithLocalVision() async throws {
    let bitmap = try #require(NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: 1000, pixelsHigh: 180,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
        isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0
    ))
    let context = try #require(NSGraphicsContext(bitmapImageRep: bitmap))
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    NSColor.white.setFill()
    NSRect(x: 0, y: 0, width: 1000, height: 180).fill()
    ("Warehouse 42" as NSString).draw(
        at: NSPoint(x: 40, y: 50),
        withAttributes: [
            .font: NSFont.systemFont(ofSize: 60),
            .foregroundColor: NSColor.black
        ]
    )
    NSGraphicsContext.restoreGraphicsState()
    let png = try #require(bitmap.representation(using: .png, properties: [:]))
    let payload = try await Task.detached(priority: .userInitiated) {
        try QuickRegionCapturePayload.prepare(kind: .text, pngData: png)
    }.value
    guard case .text(let text) = payload else {
        Issue.record("Text Reader must return text, not image data")
        return
    }
    #expect(text.contains("Warehouse 42"))
    let pasteboard = NSPasteboard.withUniqueName()
    defer { pasteboard.releaseGlobally() }
    #expect(payload.copy(to: pasteboard))
    #expect(pasteboard.string(forType: .string) == text)
    #expect(pasteboard.data(forType: .png) == nil)
}

@Test @MainActor func quickRegionCopiesOnlyTheRequestedRepresentation() throws {
    let pasteboard = NSPasteboard.withUniqueName()
    defer { pasteboard.releaseGlobally() }

    let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x01])
    #expect(QuickRegionCapturePayload.image(png).copy(to: pasteboard))
    #expect(pasteboard.data(forType: .png) == png)
    #expect(pasteboard.string(forType: .string) == nil)

    #expect(QuickRegionCapturePayload.text("Local OCR only").copy(to: pasteboard))
    #expect(pasteboard.string(forType: .string) == "Local OCR only")
    #expect(pasteboard.data(forType: .png) == nil)

    #expect(!QuickRegionCapturePayload.image(Data("invalid".utf8)).copy(to: pasteboard))
    #expect(pasteboard.string(forType: .string) == "Local OCR only")
}
