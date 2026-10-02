import SwiftUI

/// Content-width breakpoints, measured after the global navigation rail.
/// Do not squeeze an editor to preserve an optional inspector.
enum LimaWorkspaceMetrics {
    static let inspectorWidth: CGFloat = 260
    static let minimumEditorWidth: CGFloat = 420
    static func sidebarWidth(contentWidth: CGFloat, preferred: CGFloat?) -> CGFloat {
        guard let preferred, contentWidth >= preferred + minimumEditorWidth + 16 else { return 0 }
        return preferred
    }

    static func showsInspector(contentWidth: CGFloat, sidebarWidth: CGFloat = 0) -> Bool {
        contentWidth >= sidebarWidth + minimumEditorWidth + inspectorWidth + 32
    }
}

struct LimaFeatureIcon: View {
    let symbol: String
    var tint: AppAccentTheme = .blue
    var size: CGFloat = 42

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.46, weight: .semibold))
            .foregroundStyle(tint.onGradient)
            .frame(width: size, height: size)
            .background(tint.gradient, in: RoundedRectangle(cornerRadius: size * 0.27, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
                    .strokeBorder(.white.opacity(0.18), lineWidth: 0.5)
            }
            .accessibilityHidden(true)
    }
}

struct LimaWorkspaceCard<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) { self.content = content() }

    var body: some View {
        content
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(LimaTheme.surfaceRaised, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(LimaTheme.borderSubtle, lineWidth: LimaDesign.hairlineWidth)
                    .allowsHitTesting(false)
            }
    }
}

struct LimaWorkspaceHeading: View {
    let title: String
    let subtitle: String
    let symbol: String
    var tint: AppAccentTheme = .blue

    var body: some View {
        HStack(spacing: 13) {
            LimaFeatureIcon(symbol: symbol, tint: tint, size: 46)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).limaFont(.system(size: 23, weight: .bold))
                    .foregroundStyle(LimaTheme.textPrimary)
                Text(subtitle).limaFont(.callout)
                    .foregroundStyle(LimaTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct LimaWorkspaceSearchField: View {
    let placeholder: String
    @Binding var text: String
    var submit: () -> Void = {}

    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(LimaTheme.textSecondary)
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .limaFont(.system(size: 15))
                .onSubmit(submit)
                .accessibilityLabel(placeholder)
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(LimaTheme.textTertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
                .help("Clear search")
            }
        }
        .padding(.horizontal, 15)
        .frame(height: 48)
        .background(LimaTheme.fieldBackground, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(LimaTheme.borderSubtle, lineWidth: LimaDesign.hairlineWidth)
                .allowsHitTesting(false)
        }
    }
}

struct LimaWorkspaceActionRow: View {
    let title: String
    let detail: String
    let symbol: String
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(LimaTheme.accentInk)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).limaFont(.callout.weight(.medium))
                        .foregroundStyle(LimaTheme.textPrimary)
                    if !detail.isEmpty {
                        Text(detail).limaFont(.caption)
                            .foregroundStyle(LimaTheme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(LimaTheme.textTertiary)
            }
            .padding(10)
            .frame(maxWidth: .infinity, minHeight: 42, alignment: .leading)
            .background(hovered ? LimaTheme.surfaceSelected : LimaTheme.surfacePrimary,
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}

struct LimaWorkspaceBadge: View {
    let title: String
    var symbol: String? = nil

    var body: some View {
        HStack(spacing: 5) {
            if let symbol { Image(systemName: symbol) }
            Text(title)
        }
        .limaFont(.caption.weight(.medium))
        .foregroundStyle(LimaTheme.accentInk)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(LimaTheme.accentSoft, in: Capsule())
    }
}

extension LimaWorkspaceModule {
    var featureTint: AppAccentTheme {
        switch self {
        case .home, .ai, .context: .violet
        case .notes: .orange
        case .grammar: .green
        case .dictation: .rose
        case .extensions: .cyan
        case .clipboard: .mint
        case .terminal: .graphite
        case .formatter: .blue
        }
    }
}
