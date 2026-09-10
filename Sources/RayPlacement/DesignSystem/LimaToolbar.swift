import SwiftUI

struct LimaToolbar: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, LimaSpacing.md)
            .frame(minHeight: LimaSpacing.toolbar)
            .background(LimaColors.raisedSurface.opacity(0.72))
            .overlay(alignment: .bottom) { Rectangle().fill(LimaColors.separator).frame(height: LimaDesign.hairlineWidth) }
    }
}

extension View {
    func limaNativeToolbar() -> some View { modifier(LimaToolbar()) }
}

struct GlassHairline: View {
    var body: some View {
        Rectangle()
            .fill(LimaDesign.separator)
            .frame(height: LimaDesign.hairlineWidth)
    }
}

struct LimaToolbarTitle: View {
    @ObservedObject private var settings = SettingsStore.shared
    let symbol: String
    let title: String
    let subtitle: String?

    init(symbol: String, title: String, subtitle: String? = nil) {
        self.symbol = symbol
        self.title = title
        self.subtitle = subtitle
    }

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: symbol)
                .limaFont(.system(size: 13, weight: .semibold))
                .foregroundStyle(settings.accentTheme.readablePrimary)
                .frame(width: LimaDesign.titleIconSize, height: LimaDesign.titleIconSize)
                .background(settings.accentTheme.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: LimaRadius.control, style: .continuous))
                .overlay { RoundedRectangle(cornerRadius: LimaRadius.control, style: .continuous).stroke(LimaDesign.controlBorder, lineWidth: LimaDesign.borderWidth) }
            VStack(alignment: .leading, spacing: subtitle == nil ? 0 : 1) {
                Text(title)
                    .limaFont(.system(size: 14.5, weight: .semibold, design: .rounded))
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .limaFont(.caption2)
                        .foregroundStyle(LimaColors.secondaryText)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .frame(maxWidth: 310, alignment: .leading)
            .layoutPriority(1)
            .help([title, subtitle].compactMap { $0 }.joined(separator: " — "))
        }
    }
}

private struct LimaToolbarModifier: ViewModifier {
    let depth: LiquidGlassDepth
    let accentOpacity: Double

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 12)
            .frame(minHeight: LimaDesign.toolbarHeight)
            .liquidGlass(cornerRadius: LimaDesign.standardCorner, depth: depth, accentOpacity: accentOpacity)
    }
}

extension View {
    func limaToolbar(depth: LiquidGlassDepth = .raised, accentOpacity: Double = 0.028) -> some View {
        modifier(LimaToolbarModifier(depth: depth, accentOpacity: accentOpacity))
    }
}
