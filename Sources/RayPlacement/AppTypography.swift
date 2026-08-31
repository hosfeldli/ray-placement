import AppKit
import RayPlacementCore
import SwiftUI

/// A separate publisher keeps text sizing independent from unrelated settings.
final class AppTypography: ObservableObject {
    static let shared = AppTypography()
    @Published var scale: Double {
        didSet {
            let valid = InterfaceTextScale.normalized(scale)
            if scale != valid { scale = valid }
            UserDefaults.standard.set(valid, forKey: "interfaceTextScale")
        }
    }
    private init() {
        scale = InterfaceTextScale.normalized(UserDefaults.standard.double(forKey: "interfaceTextScale"))
    }
    static func size(_ base: CGFloat) -> CGFloat { base * shared.scale }
}

/// Font recipes are resolved inside a small observing modifier, so changing the
/// preference never recreates a window, resets a query, or restarts its shell.
struct LimaFont {
    fileprivate var resolve: (CGFloat) -> Font
    static func system(size: CGFloat, weight: Font.Weight = .regular, design: Font.Design = .default) -> Self {
        Self { .system(size: size * $0, weight: weight, design: design) }
    }
    static let largeTitle = system(size: 34)
    static let title = system(size: 28)
    static let title2 = system(size: 22)
    static let title3 = system(size: 20)
    static let headline = system(size: 13, weight: .bold)
    static let subheadline = system(size: 12)
    static let body = system(size: 13)
    static let callout = system(size: 12)
    static let caption = system(size: 11)
    static let caption2 = system(size: 10)
    func weight(_ value: Font.Weight) -> Self { Self { resolve($0).weight(value) } }
    func bold() -> Self { weight(.bold) }
    func italic() -> Self { Self { resolve($0).italic() } }
    func monospaced() -> Self { Self { resolve($0).monospaced() } }
    func monospacedDigit() -> Self { Self { resolve($0).monospacedDigit() } }
}

private struct LimaFontModifier: ViewModifier {
    @ObservedObject private var typography = AppTypography.shared
    let recipe: LimaFont
    func body(content: Content) -> some View {
        content.font(recipe.resolve(typography.scale))
    }
}

extension View {
    func limaFont(_ recipe: LimaFont) -> some View { modifier(LimaFontModifier(recipe: recipe)) }
}

struct LimaTypographyRoot<Content: View>: View {
    let content: Content
    var body: some View { content.limaFont(.body) }
}

struct InterfaceTextSizeControl: View {
    @ObservedObject private var typography = AppTypography.shared
    var body: some View {
        HStack {
            Text("Text size")
            Slider(value: $typography.scale, in: 0.85...1.4, step: 0.05)
                .accessibilityLabel("App-wide text size")
            Text("\(Int((typography.scale * 100).rounded()))%")
                .monospacedDigit().frame(width: 46, alignment: .trailing)
            Button("Reset") { typography.scale = 1 }.disabled(typography.scale == 1)
        }
    }
}
