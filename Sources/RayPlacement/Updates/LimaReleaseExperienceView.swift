import AppKit
import SwiftUI

struct LimaReleaseNotesView: View {
    let manifest: LimaReleaseManifest

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(manifest.title)
                .limaFont(.title2.weight(.semibold))
                .foregroundStyle(LimaTheme.textPrimary)
            Text(manifest.summary)
                .limaFont(.body)
                .foregroundStyle(LimaTheme.textSecondary)
            if !manifest.highlights.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Highlights")
                        .limaFont(.headline)
                        .foregroundStyle(LimaTheme.textPrimary)
                    ForEach(manifest.highlights) { highlight in
                        Label(highlight.title, systemImage: "checkmark.circle")
                            .limaFont(.callout)
                            .foregroundStyle(LimaTheme.textSecondary)
                    }
                }
            }
            if manifest.sections.isEmpty {
                Text("Detailed notes are not available for this release.")
                    .limaFont(.callout)
                    .foregroundStyle(LimaTheme.textSecondary)
            }
            ForEach(manifest.sections) { section in
                VStack(alignment: .leading, spacing: 8) {
                    Text(section.category.title)
                        .limaFont(.headline)
                        .foregroundStyle(LimaTheme.textPrimary)
                    LimaMarkdownDocumentView(markdown: section.markdown)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let details = manifest.technicalDetails, !details.isEmpty {
                DisclosureGroup("View Technical Details") {
                    LimaMarkdownDocumentView(markdown: details)
                        .padding(.top, 8)
                }
            }
            if let url = manifest.releaseURL, LimaReleaseNotesParser.isAllowedReleaseURL(url) {
                Button("Open Published Release") { NSWorkspace.shared.open(url) }
                    .buttonStyle(.link)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct LimaVersionHistoryView: View {
    @ObservedObject private var history = LimaReleaseHistoryStore.shared
    @ObservedObject private var onboarding = OnboardingCoordinator.shared
    let currentVersion: String
    let currentBuild: String

    var body: some View {
        DisclosureGroup("Version History") {
            VStack(alignment: .leading, spacing: 12) {
                Text("Installed: Lima \(currentVersion) · Build \(currentBuild)")
                    .limaFont(.callout.weight(.medium))
                if let current = history.notesForInstalled(version: currentVersion, build: currentBuild) {
                    DisclosureGroup("Release Notes for \(currentVersion)") {
                        LimaReleaseNotesView(manifest: current)
                            .padding(.top, 8)
                    }
                    if current.requiresOnboarding {
                        Button("Replay Introductory Tour") { _ = onboarding.replay(current) }
                    }
                } else {
                    Text("Offline notes for this installed build are not yet available.")
                        .limaFont(.caption)
                        .foregroundStyle(LimaTheme.textSecondary)
                }
                ForEach(history.installed.filter {
                    $0.manifest.version != currentVersion || $0.manifest.build != currentBuild
                }) { record in
                    DisclosureGroup("Lima \(record.manifest.version) · Build \(record.manifest.build ?? "—")") {
                        LimaReleaseNotesView(manifest: record.manifest)
                            .padding(.top, 8)
                    }
                }
                if let pending = history.pending, pending.version != currentVersion {
                    Text("Release notes saved for pending update \(pending.version).")
                        .limaFont(.caption)
                        .foregroundStyle(LimaTheme.textSecondary)
                }
                if let error = history.storageError {
                    Text("Version history could not be loaded: \(error)")
                        .limaFont(.caption)
                        .foregroundStyle(LimaTheme.textSecondary)
                }
            }
            .padding(.top, 8)
        }
        .accessibilityLabel("Version History")
    }
}

@MainActor
final class LimaUpdatePresentationController {
    private var window: NSWindow?

    func present(release: UpdateService.Release, manifest: LimaReleaseManifest, install: @escaping () -> Void) {
        window?.close()
        let view = LimaUpdateAvailableView(
            release: release,
            manifest: manifest,
            install: { [weak self] in
                self?.window?.close()
                self?.window = nil
                install()
            },
            dismiss: { [weak self] in
                self?.window?.close()
                self?.window = nil
            }
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 660, height: 460),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Lima Update Available"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: view)
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window
    }
}

struct LimaUpdateAvailableView: View {
    let release: UpdateService.Release
    let manifest: LimaReleaseManifest
    let install: () -> Void
    let dismiss: () -> Void
    @State private var showFullNotes = false

    private var sizeText: String? {
        guard SparkleMigrationBoundary.activeBackend == .legacy,
              let size = release.updateAsset?.size, size > 0 else { return nil }
        return ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "arrow.down.app")
                    .font(.system(size: 29, weight: .light))
                    .foregroundStyle(LimaTheme.textPrimary)
                    .frame(width: 42, height: 42)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Lima Update Available")
                        .limaFont(.title2.weight(.semibold))
                    Text("Version \(release.versionText) · \(manifest.importance == .major ? "Major update" : "Published update")")
                        .limaFont(.callout)
                        .foregroundStyle(LimaTheme.textSecondary)
                }
                Spacer()
            }
            .padding(22)

            Rectangle().fill(LimaTheme.borderSubtle).frame(height: 1)

            ScrollView {
                VStack(alignment: .leading, spacing: 15) {
                    Text(manifest.summary)
                        .limaFont(.body)
                    if !manifest.highlights.isEmpty {
                        ForEach(manifest.highlights) { item in
                            Label(item.title, systemImage: "checkmark.circle")
                                .limaFont(.callout)
                                .foregroundStyle(LimaTheme.textPrimary)
                        }
                    }
                    if manifest.sections.contains(where: { $0.category == .removedFeatures }) {
                        Label("This update removes a feature. Review the release notes before installing.",
                              systemImage: "info.circle")
                            .limaFont(.callout)
                            .foregroundStyle(LimaTheme.textSecondary)
                    }
                    if manifest.sections.contains(where: { $0.category == .securityAndCompatibility }) {
                        Label("Security or compatibility information is included in the release notes.",
                              systemImage: "shield")
                            .limaFont(.callout)
                            .foregroundStyle(LimaTheme.textSecondary)
                    }
                    if manifest.requiresOnboarding {
                        Label("An optional introductory tour will be available after this update is installed.",
                              systemImage: "sparkles.rectangle.stack")
                            .limaFont(.callout)
                            .foregroundStyle(LimaTheme.textSecondary)
                    }
                    if SparkleMigrationBoundary.activeBackend == .sparkle {
                        Text("Continue to the signed updater to review and install this release.")
                            .limaFont(.caption)
                            .foregroundStyle(LimaTheme.textTertiary)
                    }
                    if let sizeText {
                        Text("Update size: \(sizeText)")
                            .limaFont(.caption)
                            .foregroundStyle(LimaTheme.textTertiary)
                    }
                    if showFullNotes {
                        Rectangle().fill(LimaTheme.borderSubtle).frame(height: 1)
                        LimaReleaseNotesView(manifest: manifest)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(22)
            }

            Rectangle().fill(LimaTheme.borderSubtle).frame(height: 1)
            HStack {
                Button(showFullNotes ? "Hide Full Release Notes" : "View Full Release Notes") {
                    showFullNotes.toggle()
                }
                .buttonStyle(.borderless)
                Spacer()
                Button("Later", action: dismiss)
                Button(SparkleMigrationBoundary.activeBackend == .sparkle ? "Continue to Signed Updater" : "Install Update", action: install)
                    .buttonStyle(.borderedProminent)
                    .disabled(SparkleMigrationBoundary.activeBackend == .legacy && release.updateAsset == nil)
            }
            .padding(18)
        }
        .frame(minWidth: 620, minHeight: 420)
        .background(LimaTheme.surfacePrimary)
        .tint(SettingsStore.shared.accentTheme.readablePrimary)
        .accessibilityElement(children: .contain)
    }
}
