import SwiftUI

struct LimaStatusView: View {
    let title: String
    let detail: String?
    let symbol: String
    let tint: Color

    var body: some View {
        HStack(spacing: LimaSpacing.sm) {
            Image(systemName: symbol).foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).limaFont(.system(size: 11.5, weight: .semibold))
                if let detail, !detail.isEmpty { Text(detail).limaFont(.caption).foregroundStyle(LimaColors.secondaryText) }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, LimaSpacing.md)
        .padding(.vertical, LimaSpacing.sm)
        .limaNativeSurface(fill: tint.opacity(0.08), radius: LimaRadius.control, border: tint.opacity(0.22))
        .accessibilityElement(children: .combine)
    }
}

struct LimaStatusLine: View {
    let text: String
    let symbol: String
    let tint: Color
    let detail: String?
    let compact: Bool

    init(_ text: String, symbol: String = "circle.fill", tint: Color = .primary, detail: String? = nil, compact: Bool = false) {
        self.text = text; self.symbol = symbol; self.tint = tint; self.detail = detail; self.compact = compact
    }

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: symbol).limaFont(.system(size: 9, weight: .bold)).foregroundStyle(tint)
            Text(text).limaFont(.system(size: 10.5, weight: .medium)).foregroundStyle(LimaColors.secondaryText).lineLimit(1)
            if let detail, !detail.isEmpty { Text(detail).limaFont(.system(size: 9.5, weight: .medium, design: .monospaced)).foregroundStyle(LimaColors.tertiaryText).lineLimit(1) }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, compact ? 7 : 10)
        .frame(minHeight: compact ? LimaDesign.compactStatusHeight : LimaDesign.statusHeight)
        .background(LimaDesign.recessedFill, in: RoundedRectangle(cornerRadius: LimaRadius.control, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: LimaRadius.control, style: .continuous).stroke(LimaDesign.separator, lineWidth: LimaDesign.borderWidth) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(text)
    }
}

struct LimaSectionLabel: View {
    let title: String
    let detail: String?

    init(_ title: String, detail: String? = nil) { self.title = title; self.detail = detail }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Text(title.uppercased()).limaFont(.system(size: 9.5, weight: .bold, design: .rounded)).tracking(0.85).foregroundStyle(LimaColors.secondaryText)
            if let detail, !detail.isEmpty { Text(detail).limaFont(.caption2).foregroundStyle(LimaColors.tertiaryText).lineLimit(1) }
            Spacer(minLength: 0)
        }
    }
}

struct LimaBadge: View {
    let text: String
    let symbol: String?
    let tint: Color

    init(_ text: String, symbol: String? = nil, tint: Color = .primary) { self.text = text; self.symbol = symbol; self.tint = tint }

    var body: some View {
        HStack(spacing: 5) {
            if let symbol { Image(systemName: symbol).limaFont(.system(size: 8.5, weight: .bold)) }
            Text(text).limaFont(.system(size: 8.5, weight: .bold, design: .rounded)).tracking(0.55)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: LimaRadius.small, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: LimaRadius.small, style: .continuous).stroke(tint.opacity(0.24), lineWidth: LimaDesign.borderWidth) }
        .accessibilityElement(children: .combine)
    }
}
