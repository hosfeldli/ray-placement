import SwiftUI

enum LimaMotion {
    static let quick = Animation.easeOut(duration: 0.14)
    static let standard = Animation.easeOut(duration: 0.18)
    static let panel = Animation.interactiveSpring(response: 0.26, dampingFraction: 0.88)
}

private struct LimaAnimationModifier<Value: Equatable>: ViewModifier {
    let animation: Animation
    let value: Value
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.animation(reduceMotion ? nil : animation, value: value)
    }
}

extension View {
    func limaAnimation<Value: Equatable>(_ animation: Animation, value: Value) -> some View {
        modifier(LimaAnimationModifier(animation: animation, value: value))
    }
}
