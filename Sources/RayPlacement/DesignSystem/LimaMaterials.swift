import AppKit
import SwiftUI

/// Material is used only at the major-surface level. Child rows and controls
/// should use opaque semantic fills so scrolling remains inexpensive and clear.
struct LimaMaterialBackground: View {
    let material: NSVisualEffectView.Material
    let reduceTransparency: Bool

    var body: some View {
        Group {
            if reduceTransparency {
                LimaColors.windowBackground
            } else {
                VisualEffectView(material: material, blendingMode: .behindWindow)
            }
        }
    }
}
