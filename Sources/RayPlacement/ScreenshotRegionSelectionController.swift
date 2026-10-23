import AppKit
import CoreGraphics

enum ScreenshotRegionSelectionGeometry {
    /// Overlay views use top-left local coordinates, matching the display-local
    /// logical-point rectangle expected by ScreenCaptureKit's sourceRect.
    static func localRect(from first: CGPoint, to second: CGPoint, in bounds: CGRect) -> CGRect? {
        guard [first.x, first.y, second.x, second.y,
               bounds.minX, bounds.minY, bounds.maxX, bounds.maxY].allSatisfy(\.isFinite),
              bounds.width > 0, bounds.height > 0 else { return nil }
        func clamp(_ point: CGPoint) -> CGPoint {
            CGPoint(x: min(max(point.x, bounds.minX), bounds.maxX),
                    y: min(max(point.y, bounds.minY), bounds.maxY))
        }
        let a = clamp(first)
        let b = clamp(second)
        let rect = CGRect(x: min(a.x, b.x), y: min(a.y, b.y),
                          width: abs(a.x - b.x), height: abs(a.y - b.y))
        return rect.width >= 2 && rect.height >= 2 ? rect : nil
    }
}

/// Explicit drag-selection UI. One transparent overlay covers each eligible
/// display; a drag is bounded to the display where it began. The overlays
/// disappear before any ScreenCaptureKit image request is made.
@MainActor
final class ScreenshotRegionSelectionController {
    private var panels: [ScreenshotRegionOverlayPanel] = []
    private var onSelect: ((ScreenshotCaptureTarget) -> Void)?
    private var onCancel: (() -> Void)?

    @discardableResult
    func present(displays: [ScreenshotCaptureTargetInfo],
                 onSelect: @escaping (ScreenshotCaptureTarget) -> Void,
                 onCancel: @escaping () -> Void) -> Bool {
        dismiss(notifyCancel: false)
        self.onSelect = onSelect
        self.onCancel = onCancel

        let displayIDs = Set(displays.compactMap { info -> CGDirectDisplayID? in
            guard case .display(let id) = info.target else { return nil }
            return id
        })
        guard !displayIDs.isEmpty else {
            dismiss(notifyCancel: true)
            return false
        }
        for screen in NSScreen.screens {
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                continue
            }
            let id = CGDirectDisplayID(number.uint32Value)
            guard displayIDs.contains(id) else { continue }
            let panel = ScreenshotRegionOverlayPanel(
                contentRect: screen.frame, styleMask: [.borderless],
                backing: .buffered, defer: false, screen: screen
            )
            panel.level = .screenSaver
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.isReleasedWhenClosed = false
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.hidesOnDeactivate = false
            let overlay = ScreenshotRegionOverlayView(
                frame: CGRect(origin: .zero, size: screen.frame.size),
                displayID: id,
                onSelect: { [weak self] target in self?.select(target) },
                onCancel: { [weak self] in self?.dismiss(notifyCancel: true) }
            )
            panel.contentView = overlay
            panels.append(panel)
        }
        guard !panels.isEmpty else {
            dismiss(notifyCancel: true)
            return false
        }
        for panel in panels { panel.orderFrontRegardless() }
        NSApp.activate(ignoringOtherApps: true)
        if let first = panels.first {
            first.makeKeyAndOrderFront(nil)
            first.makeFirstResponder(first.contentView)
        }
        NSCursor.crosshair.push()
        return true
    }

    private func select(_ target: ScreenshotCaptureTarget) {
        let callback = onSelect
        dismiss(notifyCancel: false)
        callback?(target)
    }

    func dismiss(notifyCancel: Bool) {
        let hadPanels = !panels.isEmpty
        for panel in panels { panel.orderOut(nil); panel.close() }
        panels.removeAll()
        if hadPanels { NSCursor.pop() }
        let callback = notifyCancel ? onCancel : nil
        onSelect = nil
        onCancel = nil
        callback?()
    }
}

private final class ScreenshotRegionOverlayPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

private final class ScreenshotRegionOverlayView: NSView {
    private let displayID: CGDirectDisplayID
    private let onSelect: (ScreenshotCaptureTarget) -> Void
    private let onCancel: () -> Void
    private var startPoint: CGPoint?
    private var endPoint: CGPoint?

    init(frame: CGRect, displayID: CGDirectDisplayID,
         onSelect: @escaping (ScreenshotCaptureTarget) -> Void,
         onCancel: @escaping () -> Void) {
        self.displayID = displayID
        self.onSelect = onSelect
        self.onCancel = onCancel
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.30).setFill()
        bounds.fill()
        if let startPoint, let endPoint,
           let rect = ScreenshotRegionSelectionGeometry.localRect(
                from: startPoint, to: endPoint, in: bounds
           ) {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current?.compositingOperation = .clear
            rect.fill()
            NSGraphicsContext.restoreGraphicsState()
            NSColor.white.setStroke()
            let outline = NSBezierPath(rect: rect)
            outline.lineWidth = 2
            outline.stroke()
        }
        let title = "Drag within one display to capture • Esc to cancel"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 16, weight: .semibold),
            .foregroundColor: NSColor.white
        ]
        let size = title.size(withAttributes: attributes)
        let label = CGRect(x: (bounds.width - size.width) / 2, y: 30,
                           width: size.width, height: size.height)
        NSColor.black.withAlphaComponent(0.65).setFill()
        label.insetBy(dx: -14, dy: -9).fill()
        title.draw(in: label, withAttributes: attributes)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeKey()
        window?.makeFirstResponder(self)
        startPoint = convert(event.locationInWindow, from: nil)
        endPoint = startPoint
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard startPoint != nil else { return }
        endPoint = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let startPoint else { return }
        let end = convert(event.locationInWindow, from: nil)
        self.startPoint = nil
        self.endPoint = nil
        needsDisplay = true
        guard let rect = ScreenshotRegionSelectionGeometry.localRect(
            from: startPoint, to: end, in: bounds
        ) else { return }
        onSelect(.region(displayID: displayID, rect: rect))
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onCancel() }
        else { super.keyDown(with: event) }
    }
}
