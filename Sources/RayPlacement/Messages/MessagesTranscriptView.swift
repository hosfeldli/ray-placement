import SwiftUI

struct MessagesTranscriptView: View {
    let messages: [MessagesMessage]
    var selectedMessageGUID: String? = nil
    @State private var positioned = false
    private var chronological: [MessagesMessage] { messages.sorted { $0.sentAt < $1.sentAt } }

    var body: some View {
        ScrollViewReader { reader in
            ZStack(alignment: .bottomTrailing) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        if messages.isEmpty {
                            Label("No messages in this history window", systemImage: "bubble.left.and.bubble.right")
                                .foregroundStyle(LimaTheme.textSecondary).padding(.vertical, 30)
                        }
                        ForEach(chronological) { message in
                            HStack(alignment: .bottom, spacing: 20) {
                                if message.isFromMe { Spacer(minLength: 40) }
                                VStack(alignment: .leading, spacing: 5) {
                                    HStack(spacing: 10) {
                                        Text(message.isFromMe ? "You" : (message.senderAddress ?? "Unknown sender"))
                                            .fontWeight(.medium).lineLimit(1)
                                        Text(message.sentAt.formatted(date: .abbreviated, time: .shortened))
                                            .foregroundStyle(LimaTheme.textSecondary).font(.caption2)
                                    }
                                    Text(message.text ?? "This message's text is unavailable or uses an unsupported format.")
                                        .textSelection(.enabled)
                                        .foregroundStyle(message.text == nil ? LimaTheme.textSecondary : LimaTheme.textPrimary)
                                    if message.guid == selectedMessageGUID {
                                        Label("Selected result", systemImage: "magnifyingglass").font(.caption2).foregroundStyle(LimaTheme.accentInk)
                                    }
                                }
                                .padding(12)
                                .background(message.isFromMe ? LimaTheme.accentSoft : LimaTheme.surfaceSecondary,
                                    in: RoundedRectangle(cornerRadius: 13))
                                .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(
                                    message.guid == selectedMessageGUID ? LimaTheme.accentInk : .clear, lineWidth: 1))
                                if !message.isFromMe { Spacer(minLength: 40) }
                            }
                            .id(message.guid)
                        }
                    }.padding(.bottom, 42)
                }
                if let latest = chronological.last {
                    Button { reader.scrollTo(latest.guid, anchor: .bottom) } label: {
                        Label("Latest", systemImage: "arrow.down")
                    }.buttonStyle(.bordered).controlSize(.small)
                }
            }
            .onChange(of: messages.map(\.guid)) { _ in
                guard !positioned, let target = selectedMessageGUID ?? chronological.last?.guid else { return }
                positioned = true
                reader.scrollTo(target, anchor: .center)
            }
        }
        .limaFont(.callout)
        .accessibilityIdentifier("messages-conversation-transcript")
    }
}
