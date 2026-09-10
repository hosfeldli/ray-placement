import SwiftUI

struct LimaListRow<Leading: View, Content: View, Trailing: View>: View {
    let selected: Bool
    let leading: Leading
    let content: Content
    let trailing: Trailing

    init(
        selected: Bool = false,
        @ViewBuilder leading: () -> Leading,
        @ViewBuilder content: () -> Content,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.selected = selected
        self.leading = leading()
        self.content = content()
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: LimaSpacing.md) {
            leading
            content
                .frame(maxWidth: .infinity, alignment: .leading)
            trailing
        }
        .padding(.horizontal, LimaSpacing.md)
        .frame(minHeight: LimaSpacing.listRow)
        .limaSelection(selected)
        .contentShape(Rectangle())
    }
}
