import Foundation
import RayPlacementCore
import SwiftUI

enum LimaOnboardingStep: Int, CaseIterable, Codable {
    case welcome
    case audio
    case mail
    case aiAccess
    case browser
    case noteDemo
    case versionHistory
    case finish

    var title: String {
        switch self {
        case .welcome: return "Welcome to the New Lima"
        case .audio: return "Discover Sound Output"
        case .mail: return "Explore Apple Mail"
        case .aiAccess: return "Choose AI Tool Access"
        case .browser: return "Control Browser Access"
        case .noteDemo: return "Review Cross-App Tasks"
        case .versionHistory: return "Find Release Notes"
        case .finish: return "You're Ready"
        }
    }

    var message: String {
        switch self {
        case .welcome:
            return "The dedicated Workflows feature has been retired. Search, AI, Notes, Extensions, and task tools remain available in a simpler workspace."
        case .audio:
            return "Use the real Sound Output control below, or the speaker icon when the Activity Shelf is visible. No output changes unless you select one."
        case .mail:
            return "Choose which Apple Mail accounts Lima may read. Drafting and sending are separate controls; this tour neither reads Mail nor sends a message."
        case .aiAccess:
            return "Choose which Lima tools AI can use. Mail, Notes, Reminders, Contacts, and screenshots retain their own access boundaries; changing Tool Access does not grant Browser control."
        case .browser:
            return "Browser AI Control is separate from Tool Access. Choose a permission level here, then grant a tab in Browser. Pause AI on a tab whenever you need to take over."
        case .noteDemo:
            return "Review Mail action items before saving an editable Note. Creating linked Reminders is a separate, explicit action after the Note is saved. This example is synthetic."
        case .versionHistory:
            return "Open Version History here to revisit offline release notes for installed versions."
        case .finish:
            return "You can return to Version History at any time. Lima is ready to use without completing this tour."
        }
    }

    var targetID: String? {
        switch self {
        case .audio: return "audio"
        case .mail: return "mail"
        case .aiAccess: return "ai"
        case .browser: return "browser"
        case .versionHistory: return "history"
        default: return nil
        }
    }
}

struct LimaOnboardingProgress: Codable, Equatable {
    let installedVersion: String
    let installedBuild: String
    let onboardingID: String
    let firstShownAt: Date
    var lastCompletedStep: Int
    var completed: Bool
    var skipped: Bool
    var lastDismissedAt: Date?
}

private struct LimaOnboardingSnapshot: Codable {
    var progress: [LimaOnboardingProgress]
}

@MainActor
final class OnboardingCoordinator: ObservableObject {
    static let shared = OnboardingCoordinator()

    @Published private(set) var activeManifest: LimaReleaseManifest?
    @Published private(set) var step: LimaOnboardingStep = .welcome
    @Published private(set) var storageError: String?

    private var progress: [LimaOnboardingProgress] = []
    private let fileURL: URL
    private let files = PrivateFileStore()

    var isActive: Bool { activeManifest != nil }

    init(fileURL: URL = ApplicationPaths.updates.appendingPathComponent("onboarding-state.json")) {
        self.fileURL = fileURL
        let loaded = files.loadJSON(LimaOnboardingSnapshot.self, from: fileURL)
        switch loaded.result.state {
        case .missing: break
        case .loaded: progress = loaded.value?.progress ?? []
        case .corrupt, .unreadable:
            storageError = loaded.result.errorDescription ?? "Onboarding state could not be read."
        }
    }

    func progressFor(version: String, build: String, onboardingID: String) -> LimaOnboardingProgress? {
        progress.first {
            $0.installedVersion == version
                && $0.installedBuild == build
                && $0.onboardingID == onboardingID
        }
    }

    /// Only a manifest activated by the verified installer receipt reaches
    /// this entry point. A shown but dismissed tour is not reopened at launch.
    @discardableResult
    func startIfNeeded(_ manifest: LimaReleaseManifest, at date: Date = Date()) -> Bool {
        guard manifest.isValid, manifest.requiresOnboarding,
              let build = manifest.build, let id = manifest.onboardingID,
              progressFor(version: manifest.version, build: build, onboardingID: id) == nil,
              storageError == nil else { return false }
        let shown = LimaOnboardingProgress(
            installedVersion: manifest.version,
            installedBuild: build,
            onboardingID: id,
            firstShownAt: date,
            lastCompletedStep: -1,
            completed: false,
            skipped: false,
            lastDismissedAt: nil
        )
        guard save(progress + [shown]) else { return false }
        activeManifest = manifest
        step = .welcome
        return true
    }

    @discardableResult
    func replay(_ manifest: LimaReleaseManifest) -> Bool {
        guard manifest.isValid, manifest.requiresOnboarding, manifest.build != nil,
              storageError == nil else { return false }
        activeManifest = manifest
        step = .welcome
        return true
    }

    func next(at date: Date = Date()) {
        guard let manifest = activeManifest else { return }
        if step == .finish { complete(at: date); return }
        updateProgress(for: manifest) {
            $0.lastCompletedStep = max($0.lastCompletedStep, step.rawValue)
        }
        step = LimaOnboardingStep(rawValue: step.rawValue + 1) ?? .finish
    }

    func back() {
        guard isActive else { return }
        step = LimaOnboardingStep(rawValue: max(0, step.rawValue - 1)) ?? .welcome
    }

    func dismiss(at date: Date = Date()) {
        guard let manifest = activeManifest else { return }
        updateProgress(for: manifest) {
            $0.skipped = true
            $0.lastDismissedAt = date
        }
        activeManifest = nil
    }

    func complete(at date: Date = Date()) {
        guard let manifest = activeManifest else { return }
        updateProgress(for: manifest) {
            $0.completed = true
            $0.lastCompletedStep = LimaOnboardingStep.finish.rawValue
            $0.lastDismissedAt = date
        }
        activeManifest = nil
    }

    private func updateProgress(for manifest: LimaReleaseManifest, change: (inout LimaOnboardingProgress) -> Void) {
        guard let build = manifest.build, let id = manifest.onboardingID,
              let index = progress.firstIndex(where: {
                  $0.installedVersion == manifest.version
                      && $0.installedBuild == build
                      && $0.onboardingID == id
              }) else { return }
        var next = progress
        change(&next[index])
        _ = save(next)
    }

    private func save(_ next: [LimaOnboardingProgress]) -> Bool {
        guard storageError == nil else { return false }
        do {
            try files.write(LimaOnboardingSnapshot(progress: Array(next.suffix(80))), to: fileURL)
            progress = Array(next.suffix(80))
            return true
        } catch {
            storageError = error.localizedDescription
            return false
        }
    }
}

private struct LimaOnboardingTargetPreference: PreferenceKey {
    static var defaultValue: [String: Anchor<CGRect>] = [:]
    static func reduce(value: inout [String: Anchor<CGRect>], nextValue: () -> [String: Anchor<CGRect>]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

extension View {
    func limaOnboardingTarget(_ id: String) -> some View {
        anchorPreference(key: LimaOnboardingTargetPreference.self, value: .bounds) { [id: $0] }
    }

    func limaOnboardingOverlay(coordinator: OnboardingCoordinator) -> some View {
        overlayPreferenceValue(LimaOnboardingTargetPreference.self) { anchors in
            GeometryReader { proxy in
                if coordinator.isActive {
                    LimaOnboardingSpotlight(
                        coordinator: coordinator,
                        target: coordinator.step.targetID.flatMap { anchors[$0].map { proxy[$0] } },
                        availableSize: proxy.size
                    )
                }
            }
        }
    }
}

private struct LimaOnboardingSpotlight: View {
    @ObservedObject var coordinator: OnboardingCoordinator
    let target: CGRect?
    let availableSize: CGSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var ownsFocus: Bool

    private var visibleTarget: CGRect? {
        guard let target, target.width > 0, target.height > 0,
              target.intersects(CGRect(origin: .zero, size: availableSize)) else { return nil }
        return target
    }

    private var cardCenter: CGPoint {
        guard let target = visibleTarget else {
            return CGPoint(x: availableSize.width / 2, y: availableSize.height / 2)
        }
        let x = min(max(target.midX, 195), max(195, availableSize.width - 195))
        let below = target.maxY + 146
        let y = below < availableSize.height - 30 ? below : max(150, target.minY - 146)
        return CGPoint(x: x, y: y)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black.opacity(0.20)
                .allowsHitTesting(false)
            if let target = visibleTarget {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(SettingsStore.shared.accentTheme.readablePrimary, lineWidth: 2)
                    .frame(width: target.width + 10, height: target.height + 10)
                    .position(x: target.midX, y: target.midY)
                    .allowsHitTesting(false)
            }
            card
                .position(cardCenter)
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: coordinator.step)
        .onExitCommand { coordinator.dismiss() }
        .onMoveCommand { direction in
            guard ownsFocus else { return }
            switch direction {
            case .left: coordinator.back()
            case .right: coordinator.next()
            default: break
            }
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("STEP \(coordinator.step.rawValue + 1) OF \(LimaOnboardingStep.allCases.count)")
                .limaFont(.caption2.weight(.semibold))
                .foregroundStyle(LimaTheme.textTertiary)
            Text(coordinator.step.title)
                .limaFont(.headline)
            Text(coordinator.step.message)
                .limaFont(.callout)
                .foregroundStyle(LimaTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if coordinator.step == .noteDemo {
                VStack(alignment: .leading, spacing: 5) {
                    Text("DEMONSTRATION · SYNTHETIC")
                        .limaFont(.caption2.weight(.semibold))
                    Text("Message: Please confirm the shipment window and send the revised ETA.")
                        .limaFont(.caption)
                    Text("Note: ☐ Confirm shipment window  ☐ Share revised ETA")
                        .limaFont(.caption)
                    Text("Optional next step: review and create linked Reminders.")
                        .limaFont(.caption)
                }
                .padding(9)
                .background(LimaTheme.surfaceSecondary, in: RoundedRectangle(cornerRadius: 8))
            }
            if coordinator.step.targetID != nil && visibleTarget == nil {
                Text("Scroll to the highlighted setting, or continue with the tour.")
                    .limaFont(.caption)
                    .foregroundStyle(LimaTheme.textTertiary)
            }
            HStack(spacing: 9) {
                Button("Skip Tour") { coordinator.dismiss() }
                    .buttonStyle(.borderless)
                Spacer()
                Button("Back") { coordinator.back() }
                    .disabled(coordinator.step == .welcome)
                Button(coordinator.step == .finish ? "Start Using Lima" : "Next") {
                    coordinator.next()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(17)
        .frame(width: 360, alignment: .leading)
        .background(LimaTheme.surfaceRaised, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(LimaTheme.borderSubtle, lineWidth: 1))
        .shadow(color: .black.opacity(0.18), radius: 16, y: 5)
        .focusable()
        .focused($ownsFocus)
        .onAppear { ownsFocus = true }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Lima introductory tour")
    }
}
