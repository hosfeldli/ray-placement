import SwiftUI

@MainActor
struct ClipboardWorkspaceView: View {
    @ObservedObject var service: ClipboardHistoryService
    let openSettings: () -> Void

    @ObservedObject private var settings = SettingsStore.shared
    @State private var query = ""
    @State private var confirmClear = false

    private var visibleEntries: [ClipboardEntry] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return service.entries
            .filter { term.isEmpty || $0.text.localizedCaseInsensitiveContains(term) }
            .sorted {
                if $0.pinned != $1.pinned { return $0.pinned }
                return $0.capturedAt > $1.capturedAt
            }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Clipboard History")
                        .limaFont(.title3.weight(.semibold))
                        .foregroundStyle(LimaTheme.textPrimary)
                    Text("Private local text history. Concealed and one-time clips are ignored.")
                        .limaFont(.caption)
                        .foregroundStyle(LimaTheme.textSecondary)
                }
                Spacer()
                Toggle("Remember copied text", isOn: $settings.clipboardEnabled)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .help("Store eligible text copied on this Mac")
                if !service.entries.isEmpty {
                    Button("Clear History", role: .destructive) { confirmClear = true }
                        .buttonStyle(.borderless)
                }
            }
            .padding(.horizontal, 18)
            .frame(minHeight: 58)
            .background(LimaTheme.surfacePrimary)

            GlassHairline()

            HStack(spacing: 9) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(LimaTheme.textSecondary)
                TextField("Search clipboard history", text: $query)
                    .textFieldStyle(.plain)
                    .limaFont(.body)
                    .accessibilityLabel("Search clipboard history")
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain)
                        .foregroundStyle(LimaTheme.textTertiary)
                        .help("Clear search")
                }
                Text("\(visibleEntries.count) items")
                    .limaFont(.caption.monospacedDigit())
                    .foregroundStyle(LimaTheme.textTertiary)
            }
            .padding(.horizontal, 12)
            .frame(height: 38)
            .background(LimaTheme.fieldBackground, in: RoundedRectangle(cornerRadius: LimaRadius.control, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: LimaRadius.control, style: .continuous).stroke(LimaTheme.borderSubtle, lineWidth: LimaDesign.hairlineWidth))
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            if let error = service.lastError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .limaFont(.caption)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 18)
                    .padding(.bottom, 8)
            }

            if visibleEntries.isEmpty {
                VStack(spacing: 9) {
                    Image(systemName: query.isEmpty ? "clipboard" : "magnifyingglass")
                        .font(.system(size: 22, weight: .medium))
                        .foregroundStyle(LimaTheme.textTertiary)
                    Text(query.isEmpty ? (settings.clipboardEnabled ? "Clipboard is empty" : "History is paused") : "No matching clips")
                        .limaFont(.callout.weight(.semibold))
                        .foregroundStyle(LimaTheme.textPrimary)
                    Text(emptyDescription)
                        .limaFont(.caption)
                        .foregroundStyle(LimaTheme.textSecondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 320)
                    if !settings.clipboardEnabled && query.isEmpty {
                        Button("Open Clipboard Settings", action: openSettings)
                            .buttonStyle(.bordered)
                            .padding(.top, 2)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(24)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(visibleEntries) { entry in
                            entryCard(entry)
                        }
                    }
                    .padding(14)
                }
                .background(LimaTheme.surfacePrimary)
            }

            HStack(spacing: 6) {
                Image(systemName: settings.clipboardEnabled ? "checkmark.shield" : "pause.circle")
                Text(settings.clipboardEnabled
                     ? "Stored only on this Mac · \(settings.clipboardLimit) item limit"
                     : "Capture paused · existing history is preserved")
                Spacer()
            }
            .limaFont(.caption2)
            .foregroundStyle(LimaTheme.textTertiary)
            .padding(.horizontal, 16)
            .frame(height: 26)
            .background(LimaTheme.surfaceSecondary)
        }
        .background(LimaTheme.surfacePrimary)
        .alert("Clear clipboard history?", isPresented: $confirmClear) {
            Button("Cancel", role: .cancel) {}
            Button("Clear History", role: .destructive) { service.clear() }
        } message: {
            Text("This permanently removes all saved clipboard entries from this Mac.")
        }
        .accessibilityIdentifier("lima-clipboard-workspace")
    }

    private var emptyDescription: String {
        if !query.isEmpty { return "Try another word or phrase." }
        if settings.clipboardEnabled { return "Copy text in an app to add it here. Lima keeps this history on this Mac." }
        return "Turn on Remember copied text to capture future clips. Your existing history remains saved."
    }

    private func entryCard(_ entry: ClipboardEntry) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                Text(entry.text)
                    .limaFont(.body.monospaced())
                    .foregroundStyle(LimaTheme.textPrimary)
                    .lineLimit(4)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button {
                    service.copy(entry.text)
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Copy this clip to the system clipboard")
            }
            HStack(spacing: 8) {
                if entry.pinned {
                    Label("Pinned", systemImage: "pin.fill")
                        .foregroundStyle(LimaTheme.accentInk)
                }
                Text(entry.capturedAt, style: .relative)
                    .foregroundStyle(LimaTheme.textTertiary)
                Spacer()
                Menu {
                    Button(entry.pinned ? "Unpin" : "Pin", systemImage: entry.pinned ? "pin.slash" : "pin") {
                        service.togglePinned(entry.id)
                    }
                    Button("Remove", systemImage: "trash", role: .destructive) {
                        service.remove(entry.id)
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .frame(width: 24, height: 22)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .help("Clipboard item actions")
            }
            .limaFont(.caption2)
        }
        .padding(12)
        .background(LimaTheme.surfaceRaised, in: RoundedRectangle(cornerRadius: LimaRadius.card, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: LimaRadius.card, style: .continuous).stroke(LimaTheme.borderSubtle, lineWidth: LimaDesign.hairlineWidth))
    }
}
