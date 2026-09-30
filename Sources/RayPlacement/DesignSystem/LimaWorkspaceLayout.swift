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
        case .compact: 44
        case .regular: 46
        case .expanded: 184
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
