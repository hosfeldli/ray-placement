import SwiftUI

/// Semantic typography recipes. `LimaFont` continues to own global text scaling;
/// these names keep workspace hierarchy consistent while preserving that behavior.
enum LimaTypography {
    static let windowTitle = LimaFont.system(size: 14.5, weight: .semibold)
    static let sectionTitle = LimaFont.system(size: 13, weight: .semibold)
    static let resultTitle = LimaFont.system(size: 13.5, weight: .medium)
    static let body = LimaFont.body
    static let secondary = LimaFont.system(size: 11.25)
    static let caption = LimaFont.caption
    static let shortcut = LimaFont.system(size: 10, weight: .medium, design: .rounded)
    static let technical = LimaFont.system(size: 12, design: .monospaced)
}
