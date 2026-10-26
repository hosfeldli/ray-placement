import CoreGraphics
import SwiftUI

/// A single width contract for every persistent Workspace module. Modules receive
/// this through the SwiftUI environment instead of inventing their own breakpoints.
enum LimaWorkspaceSizeClass: Equatable, Sendable {
    case compact
    case regular
    case expanded

    static func classify(width: CGFloat) -> Self {
        if width < 520 { return .compact }
        if width <= 760 { return .regular }
        return .expanded
    }

    var moduleRailWidth: CGFloat {
        switch self {
        case .compact: 60
        case .regular: 60
        case .expanded: 208
        }
    }

    var contextSidebarWidth: CGFloat? {
        switch self {
        case .compact: nil
        case .regular: 188
        case .expanded: 232
        }
    }

    var contentPadding: CGFloat {
        switch self {
        case .compact: LimaSpacing.sm
        case .regular: LimaSpacing.md
        case .expanded: LimaSpacing.lg
        }
    }
}

/// Reserve the webpage before deciding whether the AI sidecar fits. The
/// chrome budget includes outer padding, inter-pane gaps, and rail insets.
struct LimaWorkspaceChromeLayout: Equatable {
    let showsSidecar: Bool
    let collapsesRail: Bool
    let sidecarWidth: CGFloat

    static func resolve(width: CGFloat, sidecarRequested: Bool, isDocked: Bool,
                        preferredSidecarWidth: CGFloat) -> Self {
        let showsSidecar = sidecarRequested && !isDocked && width >= 1_120
        let collapsesRail = width < (showsSidecar ? 1_380 : 940)
        // The expanded rail can reach 315 points with 140% text and Wide
        // presentation. Budget its maximum so resizing the sidecar never
        // silently steals the Browser's preferred 650-point minimum.
        let railBudget: CGFloat = collapsesRail ? 64 : 316
        let maximumSidecar = max(350, min(480, width - railBudget - 650 - 54))
        let sidecarWidth = min(max(preferredSidecarWidth, 350), maximumSidecar)
        return Self(showsSidecar: showsSidecar, collapsesRail: collapsesRail,
                    sidecarWidth: sidecarWidth)
    }
}

private struct LimaWorkspaceSizeClassKey: EnvironmentKey {
    // Full windows and Launcher popovers retain their existing wide layouts;
    // WorkspaceView explicitly injects the live side-panel class.
    static let defaultValue: LimaWorkspaceSizeClass = .expanded
}

extension EnvironmentValues {
    var limaWorkspaceSizeClass: LimaWorkspaceSizeClass {
        get { self[LimaWorkspaceSizeClassKey.self] }
        set { self[LimaWorkspaceSizeClassKey.self] = newValue }
    }
}
