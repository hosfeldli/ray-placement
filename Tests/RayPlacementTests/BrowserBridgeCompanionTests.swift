import Foundation
import Testing
@testable import RayPlacement

private func withCompanionFixture(_ body: (URL) throws -> Void) throws {
    let root = URL(fileURLWithPath: "/private/tmp/lima-companion-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try body(root)
}

@Test func browserCompanionExportPreservesExactBytesAndSource() throws {
    try withCompanionFixture { root in
        // This fixture tests unchanged-byte copying and rejection behavior.
        let bytes = Data([0x50, 0x4b, 0, 0xff, 1, 2, 3])
        let source = BrowserBridgeCompanion.package(in: root)
        let destination = root.appendingPathComponent("download.xpi")
        try bytes.write(to: source)
        #expect(BrowserBridgeCompanion.isAvailable(in: root))
        #expect(throws: BrowserBridgeCompanion.ExportError.self) {
            try BrowserBridgeCompanion.export(from: root, to: destination) { _ in false }
        }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        try BrowserBridgeCompanion.export(from: root, to: destination) { candidate in
            candidate == source
        }
        #expect(try Data(contentsOf: destination) == bytes)
        #expect(try Data(contentsOf: source) == bytes)
        // An untrusted fixture cannot replace an existing destination.
        try Data("old destination".utf8).write(to: destination)
        #expect(throws: BrowserBridgeCompanion.ExportError.self) {
            try BrowserBridgeCompanion.export(from: root, to: destination) { _ in false }
        }
        #expect(try Data(contentsOf: destination) == Data("old destination".utf8))
    }
}

@Test func browserCompanionExportRejectsMalformedPackages() throws {
    try withCompanionFixture { root in
        let source = BrowserBridgeCompanion.package(in: root)
        try Data("not a zip".utf8).write(to: source)
        #expect(BrowserBridgeCompanion.isAvailable(in: root)) // Availability checks presence; export enforces package/signature validation.
        #expect(throws: BrowserBridgeCompanion.ExportError.self) {
            try BrowserBridgeCompanion.export(from: root, to: root.appendingPathComponent("invalid.xpi")) { _ in false }
        }
    }
}

@Test func browserCompanionNeverFallsBackToUnsignedPackage() throws {
    try withCompanionFixture { root in
        try Data("unsigned".utf8).write(to: root.appendingPathComponent("lima-browser-bridge-unsigned.xpi"))
        let destination = root.appendingPathComponent("download.xpi")
        #expect(!BrowserBridgeCompanion.isAvailable(in: root))
        #expect(throws: BrowserBridgeCompanion.ExportError.self) {
            try BrowserBridgeCompanion.export(from: root, to: destination) { _ in false }
        }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }
}

@Test func browserCompanionRejectsInvalidSizeSymlinkAndDestination() throws {
    try withCompanionFixture { root in
        let source = BrowserBridgeCompanion.package(in: root)
        try Data().write(to: source)
        #expect(!BrowserBridgeCompanion.isAvailable(in: root))
        try Data(repeating: 0, count: BrowserBridgeCompanion.maximumBytes + 1).write(to: source)
        #expect(!BrowserBridgeCompanion.isAvailable(in: root))
        try Data([1, 2, 3]).write(to: source)
        for destination in [source, root.appendingPathComponent("wrong.txt")] {
            #expect(throws: BrowserBridgeCompanion.ExportError.self) {
                try BrowserBridgeCompanion.export(from: root, to: destination)
            }
        }
        let alias = root.appendingPathComponent("alias.xpi")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: source)
        #expect(throws: BrowserBridgeCompanion.ExportError.self) {
            try BrowserBridgeCompanion.export(from: root, to: alias)
        }
        #expect(try Data(contentsOf: source) == Data([1, 2, 3]))
        try FileManager.default.removeItem(at: alias)
        try FileManager.default.moveItem(at: source, to: alias)
        try FileManager.default.createSymbolicLink(at: source, withDestinationURL: alias)
        #expect(!BrowserBridgeCompanion.isAvailable(in: root))
    }
}
