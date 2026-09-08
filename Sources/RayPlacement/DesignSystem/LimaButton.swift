import SwiftUI

struct LimaNativeButtonStyle: ButtonStyle {
    var prominent = false
    var destructive = false
    var compact = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let tint = destructive ? LimaColors.danger : LimaColors.accent
        configuration.label
            .limaFont(compact ? .system(size: 11, weight: .semibold) : .system(size: 12, weight: .semibold))
            .foregroundStyle(prominent || destructive ? Color.white : LimaColors.primaryText)
            .padding(.horizontal, compact ? 9 : 12)
            .frame(minHeight: compact ? LimaSpacing.compactControl : LimaSpacing.control)
            .background {
                RoundedRectangle(cornerRadius: LimaRadius.control, style: .continuous)
                    .fill(prominent ? tint : (destructive ? tint : LimaColors.raisedSurface))
            }
            .overlay {
                RoundedRectangle(cornerRadius: LimaRadius.control, style: .continuous)
                    .strokeBorder(prominent || destructive ? tint.opacity(0.72) : LimaColors.border, lineWidth: LimaDesign.borderWidth)
            }
            .opacity(isEnabled ? 1 : 0.45)
            .brightness(configuration.isPressed ? -0.04 : 0)
            .animation(LimaMotion.quick, value: configuration.isPressed)
    }
}

struct LimaShortcutBadge: View {
    let text: String

    var body: some View {
        Text(text)
            .limaFont(.system(size: 10, weight: .medium, design: .rounded))
            .foregroundStyle(LimaColors.secondaryText)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(LimaColors.recessedSurface.opacity(0.72), in: RoundedRectangle(cornerRadius: LimaRadius.small, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: LimaRadius.small, style: .continuous)
                    .strokeBorder(LimaColors.border, lineWidth: LimaDesign.borderWidth)
            }
            .accessibilityLabel("Keyboard shortcut \(text)")
    }
}

struct LiquidGlassIconButtonStyle: ButtonStyle {
    var size: CGFloat = 30
    var prominent = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(width: size, height: size)
            .foregroundStyle(prominent ? Color.white : LimaDesign.primaryText)
            .background {
                RoundedRectangle(cornerRadius: LimaRadius.control, style: .continuous)
                    .fill(prominent ? AnyShapeStyle(LimaColors.accent) : AnyShapeStyle(LimaDesign.controlFill))
            }
            .overlay {
                RoundedRectangle(cornerRadius: LimaRadius.control, style: .continuous)
                    .strokeBorder(LimaDesign.controlBorder, lineWidth: prominent ? LimaDesign.focusWidth : LimaDesign.borderWidth)
            }
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .offset(y: configuration.isPressed ? 0.5 : 0)
            .brightness(configuration.isPressed ? -0.03 : 0)
            .opacity(isEnabled ? 1 : LimaDesign.disabledOpacity)
            .limaAnimation(LimaDesign.spring(0.20), value: configuration.isPressed)
    }
}

struct LimaToolbarIconButtonStyle: ButtonStyle {
    var tint: Color = .primary
    var size: CGFloat = LimaDesign.iconButtonSize
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .limaFont(.system(size: 11.5, weight: .semibold))
            .foregroundStyle(configuration.isPressed ? tint : LimaDesign.primaryText)
            .frame(width: size, height: size)
            .background(configuration.isPressed ? LimaDesign.controlHoverFill : LimaDesign.controlFill, in: RoundedRectangle(cornerRadius: LimaRadius.small, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: LimaRadius.small, style: .continuous)
                    .stroke(configuration.isPressed ? tint.opacity(0.42) : LimaDesign.controlBorder, lineWidth: LimaDesign.borderWidth)
            }
            .brightness(configuration.isPressed ? -0.04 : 0)
            .opacity(isEnabled ? 1 : LimaDesign.disabledOpacity)
            .limaAnimation(LimaDesign.spring(0.18), value: configuration.isPressed)
    }
}

struct LimaToolbarTextButtonStyle: ButtonStyle {
    var prominent = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .limaFont(.system(size: 11.5, weight: .semibold))
            .foregroundStyle(prominent ? Color.white : LimaDesign.primaryText)
            .padding(.horizontal, 10)
            .frame(minHeight: LimaDesign.compactControlHeight)
            .background {
                RoundedRectangle(cornerRadius: LimaRadius.control, style: .continuous)
                    .fill(prominent ? LimaColors.accent : (configuration.isPressed ? LimaDesign.controlHoverFill : LimaDesign.controlFill))
            }
            .overlay {
                RoundedRectangle(cornerRadius: LimaRadius.control, style: .continuous)
                    .stroke(LimaDesign.controlBorder, lineWidth: LimaDesign.borderWidth)
            }
            .brightness(configuration.isPressed ? -0.04 : 0)
            .opacity(isEnabled ? 1 : LimaDesign.disabledOpacity)
            .limaAnimation(LimaDesign.spring(0.18), value: configuration.isPressed)
    }
}

struct LimaButtonStyle: ButtonStyle {
    var prominent = false
    var compact = false
    var destructive = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: compact ? LimaRadius.small : LimaRadius.control, style: .continuous)
        let accent = destructive ? LimaDesign.danger : LimaColors.accent
        configuration.label
            .limaFont(.system(size: compact ? 10.5 : 11.5, weight: .semibold))
            .foregroundStyle(prominent || destructive ? Color.white : LimaDesign.primaryText)
            .padding(.horizontal, compact ? 8 : 10)
            .frame(minHeight: compact ? LimaDesign.compactControlHeight : LimaDesign.controlHeight)
            .background {
                shape.fill(prominent ? LimaColors.accent : (destructive ? accent.opacity(0.84) : LimaDesign.controlFill))
            }
            .overlay {
                shape.strokeBorder(prominent || destructive ? accent.opacity(0.72) : LimaDesign.controlBorder, lineWidth: LimaDesign.borderWidth)
            }
            .brightness(configuration.isPressed ? -0.045 : 0)
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .opacity(isEnabled ? 1 : LimaDesign.disabledOpacity)
            .limaAnimation(LimaDesign.spring(0.18), value: configuration.isPressed)
    }
}

private struct LimaInputSurfaceModifier: ViewModifier {
    let height: CGFloat
    let monospaced: Bool

    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .limaFont(monospaced ? .system(size: 12, design: .monospaced) : .subheadline)
            .padding(.horizontal, 9)
            .frame(minHeight: height)
            .background(LimaDesign.controlFill, in: RoundedRectangle(cornerRadius: LimaRadius.control, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: LimaRadius.control, style: .continuous).stroke(LimaDesign.controlBorder, lineWidth: LimaDesign.borderWidth) }
    }
}

private struct LimaEditorSurfaceModifier: ViewModifier {
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        content
            .scrollContentBackground(.hidden)
            .padding(8)
            .background(LimaDesign.editorFill, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).stroke(LimaDesign.controlBorder, lineWidth: LimaDesign.borderWidth) }
    }
}

extension View {
    func limaButton(prominent: Bool = false, compact: Bool = false, destructive: Bool = false) -> some View {
        buttonStyle(LimaButtonStyle(prominent: prominent, compact: compact, destructive: destructive))
    }

    func limaInputSurface(height: CGFloat = LimaDesign.controlHeight, monospaced: Bool = false) -> some View {
        modifier(LimaInputSurfaceModifier(height: height, monospaced: monospaced))
    }

    func limaEditorSurface(cornerRadius: CGFloat = LimaDesign.compactCorner) -> some View {
        modifier(LimaEditorSurfaceModifier(cornerRadius: cornerRadius))
    }
}
