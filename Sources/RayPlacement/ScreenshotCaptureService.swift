import CoreGraphics
import Foundation
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers

enum ScreenshotCaptureTarget: Sendable {
    case display(CGDirectDisplayID)
    /// Rectangle in the selected display's local logical-point coordinates.
    case region(displayID: CGDirectDisplayID, rect: CGRect)
    case window(CGWindowID)
}

struct ScreenshotCaptureTargetInfo: Identifiable, Sendable {
    enum Kind: Sendable, Equatable { case display, window }
    let id: String
    let target: ScreenshotCaptureTarget
    let kind: Kind
    let title: String
    let bounds: CGRect
    let sourceApplication: String?
    let sourceBundleID: String?
}

struct ScreenshotCapturedImage: Sendable {
    let pngData: Data
    let pixelWidth: Int
    let pixelHeight: Int
    let metadata: ScreenshotMetadata
}

enum ScreenshotCaptureError: LocalizedError {
    case permissionRequired
    case unsupportedSystem
    case targetDisappeared
    case invalidRegion
    case failedToEncode
    case clipboardUnavailable

    var errorDescription: String? {
        switch self {
        case .permissionRequired:
            return "Enable Screen Recording for Lima in System Settings → Privacy & Security, then try again."
        case .unsupportedSystem:
            return "Screenshot capture requires macOS 14 or later."
        case .targetDisappeared:
            return "The selected display or window is no longer available."
        case .invalidRegion:
            return "Select a region inside one display."
        case .failedToEncode:
            return "The screenshot could not be encoded as PNG."
        case .clipboardUnavailable:
            return "The screenshot could not be copied to the clipboard."
        }
    }
}

/// ScreenCaptureKit capture engine. Enumeration and capture require Screen
/// Recording permission. NativeCapabilityRouter is the only AI entry point;
/// it requires exact-call review and a currently eligible selected target.
@MainActor
final class ScreenshotCaptureService {
    static let shared = ScreenshotCaptureService()

    var hasScreenRecordingPermission: Bool { CGPreflightScreenCaptureAccess() }

    /// Call only from the user's explicit permission action, never on Search input.
    func requestScreenRecordingPermission() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    func availableTargets() async throws -> [ScreenshotCaptureTargetInfo] {
        guard hasScreenRecordingPermission else { throw ScreenshotCaptureError.permissionRequired }
        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: true
        )
        let displays = content.displays.map { display in
            ScreenshotCaptureTargetInfo(
                id: "display:\(display.displayID)", target: .display(display.displayID), kind: .display,
                title: "Display \(display.displayID)", bounds: display.frame,
                sourceApplication: nil, sourceBundleID: nil
            )
        }
        let windows = content.windows
            .filter { $0.windowLayer == 0 && $0.frame.width > 0 && $0.frame.height > 0 }
            .map { window in
                ScreenshotCaptureTargetInfo(
                    id: "window:\(window.windowID)", target: .window(window.windowID), kind: .window,
                    title: window.title?.isEmpty == false ? window.title! : "Untitled Window",
                    bounds: window.frame,
                    sourceApplication: window.owningApplication?.applicationName,
                    sourceBundleID: window.owningApplication?.bundleIdentifier
                )
            }
        return displays + windows
    }

    func capture(_ target: ScreenshotCaptureTarget) async throws -> ScreenshotCapturedImage {
        guard hasScreenRecordingPermission else { throw ScreenshotCaptureError.permissionRequired }
        guard #available(macOS 14.0, *) else { throw ScreenshotCaptureError.unsupportedSystem }
        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: true
        )
        let filter: SCContentFilter
        let configuration = SCStreamConfiguration()
        configuration.showsCursor = false
        let metadata: ScreenshotMetadata
        switch target {
        case .display(let id):
            guard let display = content.displays.first(where: { $0.displayID == id }) else {
                throw ScreenshotCaptureError.targetDisappeared
            }
            filter = SCContentFilter(display: display, excludingWindows: [])
            configuration.width = CGDisplayPixelsWide(id)
            configuration.height = CGDisplayPixelsHigh(id)
            metadata = ScreenshotMetadata(captureKind: .display)
        case .region(let id, let rect):
            guard let display = content.displays.first(where: { $0.displayID == id }) else {
                throw ScreenshotCaptureError.targetDisappeared
            }
            guard ScreenshotCaptureGeometry.isValidLocalRegion(
                rect, displaySize: CGSize(width: display.width, height: display.height)
            ) else {
                throw ScreenshotCaptureError.invalidRegion
            }
            filter = SCContentFilter(display: display, excludingWindows: [])
            configuration.sourceRect = rect
            let scale = CGFloat(CGDisplayPixelsWide(id)) / CGFloat(display.width)
            let size = ScreenshotCaptureGeometry.pixelSize(for: rect.size, scale: scale)
            configuration.width = size.width
            configuration.height = size.height
            metadata = ScreenshotMetadata(captureKind: .region)
        case .window(let id):
            guard let window = content.windows.first(where: { $0.windowID == id }),
                  window.frame.width > 0, window.frame.height > 0 else {
                throw ScreenshotCaptureError.targetDisappeared
            }
            filter = SCContentFilter(desktopIndependentWindow: window)
            let size = ScreenshotCaptureGeometry.pixelSize(
                for: window.frame.size, scale: CGFloat(filter.pointPixelScale)
            )
            configuration.width = size.width
            configuration.height = size.height
            metadata = ScreenshotMetadata(
                captureKind: .window,
                sourceApplication: window.owningApplication?.applicationName,
                sourceBundleID: window.owningApplication?.bundleIdentifier,
                windowTitle: window.title
            )
        }
        guard configuration.width > 0, configuration.height > 0,
              Int64(configuration.width) * Int64(configuration.height) <= 80_000_000 else {
            throw ScreenshotCaptureError.invalidRegion
        }
        let image = try await SCScreenshotManager.captureImage(
            contentFilter: filter, configuration: configuration
        )
        let data = try Self.encodePNG(image)
        return ScreenshotCapturedImage(
            pngData: data, pixelWidth: image.width, pixelHeight: image.height,
            metadata: metadata
        )
    }

    private static func encodePNG(_ image: CGImage) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data, UTType.png.identifier as CFString, 1, nil
        ) else {
            throw ScreenshotCaptureError.failedToEncode
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw ScreenshotCaptureError.failedToEncode
        }
        return data as Data
    }
}

enum ScreenshotCaptureGeometry {
    static func isValidLocalRegion(_ rect: CGRect, displaySize: CGSize) -> Bool {
        guard rect.origin.x.isFinite, rect.origin.y.isFinite,
              rect.width.isFinite, rect.height.isFinite,
              displaySize.width.isFinite, displaySize.height.isFinite else { return false }
        return rect.minX >= 0 && rect.minY >= 0 &&
            rect.width >= 1 && rect.height >= 1 &&
            rect.maxX <= displaySize.width && rect.maxY <= displaySize.height
    }

    static func pixelSize(for points: CGSize, scale: CGFloat) -> (width: Int, height: Int) {
        guard points.width.isFinite, points.height.isFinite, scale.isFinite,
              points.width > 0, points.height > 0, scale > 0,
              points.width * scale <= 20_000,
              points.height * scale <= 20_000 else { return (0, 0) }
        return (Int(ceil(points.width * scale)), Int(ceil(points.height * scale)))
    }
}
