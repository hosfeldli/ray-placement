import CoreGraphics
import Foundation

public enum NotesDockEdge: String, Codable, CaseIterable, Sendable {
    case left
    case right
}

public enum NotesWindowLayout {
    public static let minimumDockWidth: CGFloat = 390
    public static let maximumDockWidth: CGFloat = 560

    public static func dockedFrame(
        edge: NotesDockEdge,
        visibleFrame: CGRect,
        preferredWidth: CGFloat
    ) -> CGRect {
        let maximumWidth = min(maximumDockWidth, visibleFrame.width)
        let minimumWidth = min(minimumDockWidth, maximumWidth)
        let width = min(max(preferredWidth, minimumWidth), maximumWidth)
        let x = edge == .left ? visibleFrame.minX : visibleFrame.maxX - width
        return CGRect(x: x, y: visibleFrame.minY, width: width, height: visibleFrame.height)
    }

    public static func clampedWorkspaceFrame(_ frame: CGRect, visibleFrame: CGRect) -> CGRect {
        let minimumWidth = min(800, visibleFrame.width)
        let minimumHeight = min(500, visibleFrame.height)
        let width = min(max(frame.width, minimumWidth), visibleFrame.width)
        let height = min(max(frame.height, minimumHeight), visibleFrame.height)
        let x = min(max(frame.minX, visibleFrame.minX), visibleFrame.maxX - width)
        let y = min(max(frame.minY, visibleFrame.minY), visibleFrame.maxY - height)
        return CGRect(x: x, y: y, width: width, height: height)
    }
}
