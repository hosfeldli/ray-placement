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
