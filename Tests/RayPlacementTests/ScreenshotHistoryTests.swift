import AppKit
import Foundation
import Testing
@testable import RayPlacement

private func screenshotFixturePNG() throws -> Data {
    let bitmap = try #require(NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: 8, pixelsHigh: 6,
        bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0
    ))
    bitmap.setColor(NSColor(calibratedRed: 0.1, green: 0.3, blue: 0.8, alpha: 1), atX: 1, y: 1)
    return try #require(bitmap.representation(using: .png, properties: [:]))
}

private func screenshotFixtureJPEG() throws -> Data {
    let bitmap = try #require(NSBitmapImageRep(data: screenshotFixturePNG()))
    return try #require(bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.8]))
}

@Test func screenshotHistoryPersistsPrivateImagesAndSearchableMetadata() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("LimaScreenshotHistoryTests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let data = try screenshotFixturePNG()
    let store = try ScreenshotHistoryStore(rootURL: root)
    let imported = try await store.importImage(
        data, format: .png,
        metadata: ScreenshotMetadata(
            captureKind: .window,
            sourceApplication: "Safari",
            sourceBundleID: "com.apple.Safari",
            windowTitle: "Quarterly Dashboard"
        )
    )
    #expect(imported.pixelWidth == 8)
    #expect(imported.pixelHeight == 6)
    #expect(imported.category == .browser)
    #expect(imported.imageURL.path.hasPrefix(root.appendingPathComponent("Images").path))
    #expect(imported.thumbnailURL != nil)
    #expect(try Data(contentsOf: imported.imageURL) == data)
    #expect((try await store.search("Safari Dashboard")).map(\.id) == [imported.id])
    #expect((try await store.search("unrelated")).isEmpty)

    try await store.setTags(["report", "chart"], for: imported.id)
    try await store.setRecognizedText("Warehouse allocation 2026", for: imported.id)
    #expect((try await store.search("warehouse allocation")).map(\.id) == [imported.id])
    try await store.setPinned(true, for: imported.id)
    let reopened = try ScreenshotHistoryStore(rootURL: root)
    let persisted = try #require(try await reopened.record(id: imported.id))
    #expect(persisted.tags == ["chart", "report"])
    #expect(persisted.recognizedText == "Warehouse allocation 2026")
    #expect(persisted.isPinned)
    #expect((try await reopened.search("chart")).map(\.id) == [imported.id])
    #expect((try await reopened.imageData(for: imported.id)).0 == data)

    try await reopened.delete(id: imported.id)
    #expect(try await reopened.record(id: imported.id) == nil)
    #expect(!FileManager.default.fileExists(atPath: imported.imageURL.path))
    if let thumbnailURL = imported.thumbnailURL {
        #expect(!FileManager.default.fileExists(atPath: thumbnailURL.path))
    }
}

@Test @MainActor func screenshotOCRTextAppearsAsIndividualCentralSearchResult() async throws {
    let store = try ScreenshotHistoryStore()
    let capture = try await store.importImage(
        screenshotFixturePNG(), format: .png,
        metadata: ScreenshotMetadata(captureKind: .window, sourceApplication: "Fixture App")
    )
    defer { Task { try? await store.delete(id: capture.id) } }
    try await store.setRecognizedText("DistinctiveWarehouseMarker", for: capture.id)
    let matches = await UniversalSearchCoordinator.shared.search("screenshots:DistinctiveWarehouseMarker")
    let matching = matches.first(where: { $0.id == "screenshot:\(capture.id.uuidString)" })
    #expect(matching?.kind == .screenshot)
    #expect(matching?.subtitle.contains("DistinctiveWarehouseMarker") == false)
    #expect(UniversalSearchCoordinator.parse("screenshots:chart").prefix == "screenshot")
}

@Test func screenshotHistoryRejectsInvalidImagesAndRetainsPinnedCaptures() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("LimaScreenshotHistoryTests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try ScreenshotHistoryStore(rootURL: root)
    do {
        _ = try await store.importImage(
            Data("not an image".utf8), format: .png,
            metadata: ScreenshotMetadata(captureKind: .region)
        )
        Issue.record("Expected invalid image rejection")
    } catch ScreenshotHistoryError.invalidImage {
        // Expected.
    }
    #expect((try await store.recent()).isEmpty)

    let old = try await store.importImage(
        screenshotFixturePNG(), format: .png,
        metadata: ScreenshotMetadata(captureKind: .region),
        at: Date().addingTimeInterval(-2 * 24 * 60 * 60)
    )
    try await store.setPinned(true, for: old.id)
    let removable = try await store.importImage(
        screenshotFixturePNG(), format: .png,
        metadata: ScreenshotMetadata(captureKind: .display),
        at: Date().addingTimeInterval(-2 * 24 * 60 * 60)
    )
    try await store.setRetention(.init(maximumBytes: 100_000, maximumAge: 24 * 60 * 60))
    #expect(try await store.record(id: old.id) != nil)
    #expect(try await store.record(id: removable.id) == nil)
}

@Test func screenshotCaptureGeometryRejectsCrossDisplayAndPreservesRetinaSize() {
    let display = CGSize(width: 1440, height: 900)
    #expect(ScreenshotCaptureGeometry.isValidLocalRegion(
        CGRect(x: 100, y: 200, width: 400, height: 300), displaySize: display
    ))
    #expect(!ScreenshotCaptureGeometry.isValidLocalRegion(
        CGRect(x: 1400, y: 200, width: 100, height: 300), displaySize: display
    ))
    #expect(!ScreenshotCaptureGeometry.isValidLocalRegion(
        CGRect(x: -1, y: 0, width: 100, height: 100), displaySize: display
    ))
    #expect(!ScreenshotCaptureGeometry.isValidLocalRegion(
        CGRect(x: 0, y: 0, width: CGFloat.nan, height: 100), displaySize: display
    ))
    let pixels = ScreenshotCaptureGeometry.pixelSize(
        for: CGSize(width: 400.5, height: 300.5), scale: 2
    )
    #expect(pixels.width == 801)
    #expect(pixels.height == 601)
}

@Test func screenshotRegionDragNormalizesAndClampsWithinItsDisplay() {
    let display = CGRect(x: 0, y: 0, width: 1440, height: 900)
    #expect(ScreenshotRegionSelectionGeometry.localRect(
        from: CGPoint(x: 500, y: 400), to: CGPoint(x: 100, y: 200), in: display
    ) == CGRect(x: 100, y: 200, width: 400, height: 200))
    #expect(ScreenshotRegionSelectionGeometry.localRect(
        from: CGPoint(x: 1400, y: 850), to: CGPoint(x: 1500, y: 1000), in: display
    ) == CGRect(x: 1400, y: 850, width: 40, height: 50))
    #expect(ScreenshotRegionSelectionGeometry.localRect(
        from: CGPoint(x: 100, y: 100), to: CGPoint(x: 101, y: 101), in: display
    ) == nil)
    #expect(ScreenshotRegionSelectionGeometry.localRect(
        from: CGPoint(x: CGFloat.nan, y: 0), to: .zero, in: display
    ) == nil)
}

@Test @MainActor func screenshotClipboardConvertsJPEGToPNGImageBytes() throws {
    let jpeg = try screenshotFixtureJPEG()
    let pasteboard = NSPasteboard(name: NSPasteboard.Name("LimaScreenshotJPEGClipboard-\(UUID().uuidString)"))
    defer { pasteboard.releaseGlobally() }
    #expect(ScreenshotClipboard.copy(jpeg, format: .jpeg, to: pasteboard))
    let png = try #require(pasteboard.data(forType: .png))
    #expect(png.starts(with: [0x89, 0x50, 0x4E, 0x47]))
    #expect(pasteboard.string(forType: .string) == nil)
}

@Test @MainActor func screenshotClipboardPublishesPNGBytesNotFileText() throws {
    let data = try screenshotFixturePNG()
    let pasteboard = NSPasteboard(name: NSPasteboard.Name("LimaScreenshotClipboard-\(UUID().uuidString)"))
    defer { pasteboard.releaseGlobally() }
    #expect(ScreenshotClipboard.copyPNG(data, to: pasteboard))
    #expect(pasteboard.data(forType: .png) == data)
    #expect(pasteboard.string(forType: .string) == nil)
    #expect(!ScreenshotClipboard.copyPNG(Data("not png".utf8), to: pasteboard))
}

@Test func screenshotDestinationModesAreExplicitAndBookmarkedFileIsJPEG() throws {
    #expect(ScreenshotDestination.clipboard.includesClipboard)
    #expect(!ScreenshotDestination.clipboard.includesHistory)
    #expect(ScreenshotDestination.fileAndHistory.includesFile)
    #expect(ScreenshotDestination.fileAndHistory.includesHistory)
    #expect(!ScreenshotDestination.fileAndHistory.includesClipboard)
    #expect(ScreenshotDestination.all.includesClipboard)
    #expect(ScreenshotDestination.all.includesFile)
    #expect(ScreenshotDestination.all.includesHistory)

    let folder = FileManager.default.temporaryDirectory
        .appendingPathComponent("LimaScreenshotDestinationTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let bookmark = try ScreenshotFileDestination.bookmark(for: folder)
    let saved = try ScreenshotFileDestination.save(
        screenshotFixturePNG(), format: .jpeg, bookmark: bookmark
    )
    #expect(saved.deletingLastPathComponent().resolvingSymlinksInPath() == folder.resolvingSymlinksInPath())
    #expect(saved.pathExtension == "jpg")
    #expect(try Data(contentsOf: saved).starts(with: [0xFF, 0xD8]))
}

@Test func screenshotExportConvertsFormatsAndRejectsMismatchedData() throws {
    let png = try screenshotFixturePNG()
    let jpeg = try ScreenshotImageExport.data(
        png, sourceFormat: .png, destinationFormat: .jpeg
    )
    #expect(jpeg.starts(with: [0xFF, 0xD8]))
    #expect(try #require(NSBitmapImageRep(data: jpeg)).pixelsWide == 8)
    let roundTrip = try ScreenshotImageExport.data(
        jpeg, sourceFormat: .jpeg, destinationFormat: .png
    )
    #expect(roundTrip.starts(with: [0x89, 0x50, 0x4E, 0x47]))
    #expect(try #require(NSBitmapImageRep(data: roundTrip)).pixelsHigh == 6)
    #expect(try ScreenshotImageExport.data(
        png, sourceFormat: .png, destinationFormat: .png
    ) == png)
    do {
        _ = try ScreenshotImageExport.data(
            Data("not an image".utf8), sourceFormat: .png, destinationFormat: .jpeg
        )
        Issue.record("Expected invalid image rejection")
    } catch ScreenshotImageExport.ExportError.invalidImage {
        // Expected.
    }
}
