import AppKit
import Combine
import Foundation

/// The timeout behavior of a transient launcher surface. This is deliberately
/// separate from extension execution budgets in `PerformanceScale`.
enum LauncherSurfaceTimeoutPolicy: Equatable, Sendable {
    case global
    case never
    case custom(TimeInterval)

    @MainActor
    func timeout(using settings: SettingsStore) -> TimeInterval? {
        switch self {
        case .global:
            return settings.launcherSurfaceTimeout > 0 ? settings.launcherSurfaceTimeout : nil
        case .never:
            return nil
        case .custom(let value):
            return value > 0 ? value : nil
        }
    }
}

enum LauncherSurfaceKind: String, Codable, CaseIterable, Sendable {
    case form
    case picker
    case generator
    case inspector
    case live
    case textEditor
    case results
    case terminal
}

enum LauncherSurfaceReopeningPolicy: String, Codable, CaseIterable, Sendable {
    case root
    case resume
    case resumeIfPinned
}

/// Metadata for a transient surface’s one obvious next step. Execution remains
/// with the owning controller so descriptors stay value-safe and restorable.
struct LimaPrimaryAction: Equatable, Sendable {
    let title: String
    let symbol: String?
    let isEnabled: Bool

    init(title: String, symbol: String? = nil, isEnabled: Bool = true) {
        self.title = title
        self.symbol = symbol
        self.isEnabled = isEnabled
    }
}

/// Return advances a transient flow unless a multiline editor owns the key.
/// Search fields and single-line form fields remain eligible for the primary
/// action; AppKit represents those with a field editor NSTextView.
enum LimaProgressiveEnter {
    enum Action: Equatable, Sendable {
        case performPrimaryAction
        case passthrough
    }

    static func action(
        isReturnKey: Bool,
        hasNonPrimaryModifiers: Bool,
        isEditingMultilineText: Bool
    ) -> Action {
        guard isReturnKey, !hasNonPrimaryModifiers, !isEditingMultilineText else {
            return .passthrough
        }
        return .performPrimaryAction
    }

    static func action(for event: NSEvent, firstResponder: NSResponder?) -> Action {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let hasNonPrimaryModifiers = !modifiers
            .intersection([.command, .control, .option, .shift])
            .isEmpty
        let isEditingMultilineText: Bool
        if let textView = firstResponder as? NSTextView {
            isEditingMultilineText = textView.isEditable && !textView.isFieldEditor
        } else {
            isEditingMultilineText = false
        }
        return action(
            isReturnKey: event.keyCode == 36 || event.keyCode == 76,
            hasNonPrimaryModifiers: hasNonPrimaryModifiers,
            isEditingMultilineText: isEditingMultilineText
        )
    }
}

struct LauncherSurfaceDescriptor: Equatable, Sendable {
    let id: String
    let title: String
    let kind: LauncherSurfaceKind
    let preferredSize: CGSize
    let timeoutPolicy: LauncherSurfaceTimeoutPolicy
    let canPopOut: Bool
    let preservesState: Bool
    let reopeningPolicy: LauncherSurfaceReopeningPolicy
    let handler: LauncherSurfaceHandlerKey
    let primaryAction: LimaPrimaryAction?
    let supportsCopy: Bool
    let supportsSearch: Bool

    init(
        id: String,
        title: String,
        kind: LauncherSurfaceKind,
        preferredSize: CGSize = CGSize(width: 680, height: 520),
        timeoutPolicy: LauncherSurfaceTimeoutPolicy = .global,
        canPopOut: Bool = false,
        preservesState: Bool = true,
        reopeningPolicy: LauncherSurfaceReopeningPolicy = .root,
        handler: LauncherSurfaceHandlerKey = .generic,
        primaryAction: LimaPrimaryAction? = nil,
        primaryActionTitle: String? = nil,
        supportsCopy: Bool = false,
        supportsSearch: Bool = true
    ) {
        self.id = id
        self.title = title
        self.kind = kind
        self.preferredSize = preferredSize
        self.timeoutPolicy = timeoutPolicy
        self.canPopOut = canPopOut
        self.preservesState = preservesState
        self.reopeningPolicy = reopeningPolicy
        self.handler = handler
        self.primaryAction = primaryAction ?? primaryActionTitle.map { LimaPrimaryAction(title: $0) }
        self.supportsCopy = supportsCopy
        self.supportsSearch = supportsSearch
    }
}

protocol LauncherSurface {
    var id: String { get }
    var title: String { get }
    var preferredSize: CGSize { get }
    var timeoutPolicy: LauncherSurfaceTimeoutPolicy { get }
    var canPopOut: Bool { get }
    var preservesState: Bool { get }
    var primaryAction: LimaPrimaryAction? { get }
    var supportsCopy: Bool { get }
    var supportsSearch: Bool { get }
}

extension LauncherSurface {
    var primaryActionTitle: String? { primaryAction?.title }
}

extension LauncherSurfaceDescriptor: LauncherSurface {}

struct LauncherSurfaceSession: Identifiable, Equatable, Sendable {
    let id: String
    let surface: LauncherSurfaceDescriptor
    let openedAt: Date
    var lastInteractionAt: Date
    var isPinned: Bool

    init(surface: LauncherSurfaceDescriptor, openedAt: Date = Date(), isPinned: Bool = false) {
        self.id = surface.id
        self.surface = surface
        self.openedAt = openedAt
        self.lastInteractionAt = openedAt
        self.isPinned = isPinned
    }
}

/// Safe, deliberately small value set for transient surface restoration.
/// Secrets and arbitrary reference types cannot enter this cache.
enum SurfaceStateValue: Codable, Equatable, Sendable {
    case string(String)
    case integer(Int)
    case double(Double)
    case boolean(Bool)
    case strings([String])
}

/// Safe-to-restore state for a surface. Values are persisted so returning to a
/// tool after hiding/reopening Lima behaves consistently, while sensitive keys
/// are rejected before they can reach UserDefaults.
@MainActor
final class SurfaceStateCache: ObservableObject {
    static let shared = SurfaceStateCache()
    private static let defaultsKey = "launcher.surfaceStateCache"

    private let defaults = LimaTestEnvironment.userDefaults
    private var values: [String: [String: SurfaceStateValue]] = [:]

    private init() {
        guard let data = defaults.data(forKey: Self.defaultsKey),
              let decoded = try? JSONDecoder().decode([String: [String: SurfaceStateValue]].self, from: data) else {
            return
        }
        values = decoded.reduce(into: [:]) { result, surface in
            result[surface.key] = surface.value.filter { !Self.isSensitiveKey($0.key) }
        }
    }

    func set(_ value: SurfaceStateValue?, for surfaceID: String, key: String) {
        guard !Self.isSensitiveKey(key) else { return }
        if let value {
            values[surfaceID, default: [:]][key] = value
        } else {
            values[surfaceID, default: [:]].removeValue(forKey: key)
        }
        persist()
    }

    func value(for surfaceID: String, key: String) -> SurfaceStateValue? {
        values[surfaceID]?[key]
    }

    func string(for surfaceID: String, key: String) -> String? {
        guard case .string(let value) = value(for: surfaceID, key: key) else { return nil }
        return value
    }

    func remove(surfaceID: String) {
        values.removeValue(forKey: surfaceID)
        persist()
    }

    func removeAll() {
        values.removeAll()
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(values) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }

    private static func isSensitiveKey(_ key: String) -> Bool {
        let normalized = key
            .lowercased()
            .replacingOccurrences(of: "_", with: "-")
            .replacingOccurrences(of: " ", with: "-")
        return ["password", "secret", "token", "api-key", "apikey", "credential", "secure"]
            .contains { normalized.contains($0) }
    }
}

@MainActor
final class LauncherSurfaceSessionController: ObservableObject {
    @Published private(set) var lastInteractionAt = Date()
    @Published private(set) var secondsRemaining: TimeInterval?
    @Published private(set) var isSuspended = false
    @Published private(set) var isPinned = false

    private weak var viewModel: LauncherViewModel?
    private var timeoutTask: Task<Void, Never>?
    private var currentMode: LauncherMode = .root
    private var currentPolicy: LauncherSurfaceTimeoutPolicy = .global
    private var currentSessionID: String?
    private var suspensionCounts: [String: Int] = [:]

    init(viewModel: LauncherViewModel? = nil) {
        self.viewModel = viewModel
    }

    deinit {
        timeoutTask?.cancel()
    }

    func bind(to viewModel: LauncherViewModel) {
        self.viewModel = viewModel
    }

    func interactionOccurred() {
        lastInteractionAt = Date()
        viewModel?.recordSurfaceInteraction(at: lastInteractionAt)
        restartTimeout()
    }

    func surfaceChanged(to mode: LauncherMode) {
        currentMode = mode
        currentSessionID = mode.surfaceDescriptor?.id
        currentPolicy = mode.surfaceDescriptor?.timeoutPolicy ?? .global
        isPinned = mode.isPinnedSurface
        lastInteractionAt = Date()
        restartTimeout()
    }

    func setPinned(_ pinned: Bool) {
        isPinned = pinned
        restartTimeout()
    }

    /// Suspend by reason so independent active operations cannot resume the
    /// timer while another operation is still holding the surface open.
    func suspendTimeout(for reason: String = "default") {
        suspensionCounts[reason, default: 0] += 1
        isSuspended = !suspensionCounts.isEmpty
        timeoutTask?.cancel()
        timeoutTask = nil
        secondsRemaining = nil
    }

    func resumeTimeout(for reason: String = "default") {
        if let count = suspensionCounts[reason] {
            if count <= 1 {
                suspensionCounts.removeValue(forKey: reason)
            } else {
                suspensionCounts[reason] = count - 1
            }
        }
        isSuspended = !suspensionCounts.isEmpty
        restartTimeout()
    }

    func cancelTimeout() {
        timeoutTask?.cancel()
        timeoutTask = nil
        secondsRemaining = nil
    }

    private func restartTimeout() {
        timeoutTask?.cancel()
        timeoutTask = nil
        guard !isSuspended,
              !isPinned,
              currentMode != .root,
              let timeout = currentPolicy.timeout(using: SettingsStore.shared),
              timeout > 0 else {
            secondsRemaining = nil
            return
        }

        let sessionID = currentSessionID
        let deadline = Date().addingTimeInterval(timeout)
        secondsRemaining = timeout
        timeoutTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                let remaining = deadline.timeIntervalSinceNow
                if remaining <= 0 { break }
                self.secondsRemaining = remaining
                do {
                    try await Task.sleep(for: .milliseconds(250))
                } catch {
                    return
                }
            }
            guard !Task.isCancelled else { return }
            self.secondsRemaining = 0
            guard !self.isSuspended,
                  !self.isPinned,
                  self.currentMode != .root,
                  self.currentSessionID == sessionID else { return }
            self.returnToRootIfEligible()
        }
    }

    private func returnToRootIfEligible() {
        guard let viewModel, viewModel.mode != .root else { return }
        viewModel.enter(.root)
        viewModel.focusSearch()
        secondsRemaining = nil
    }
}

@MainActor
extension LauncherMode {
    var surfaceSession: LauncherSurfaceSession? {
        guard case .surface(let session) = self else { return nil }
        return session
    }

    var isPinnedSurface: Bool {
        switch self {
        case .surface(let session): return session.isPinned
        case .extensionSurface(let session): return session.isPinned
        default: return false
        }
    }

    var surfaceDescriptor: LauncherSurfaceDescriptor? {
        switch self {
        case .surface(let session):
            return session.surface
        case .extensionSurface(let session):
            return LauncherSurfaceDescriptor(
                id: session.id,
                title: session.title,
                kind: session.kind.surfaceKind,
                preferredSize: CGSize(width: 680, height: session.preferredHeight),
                timeoutPolicy: session.timeoutPolicy,
                canPopOut: session.canPopOut,
                preservesState: session.remembersState
            )
        case .terminal:
            return LauncherSurfaceDescriptor(
                id: "terminal",
                title: "Terminal",
                kind: .terminal,
                preferredSize: CGSize(width: 920, height: 620),
                timeoutPolicy: SettingsStore.shared.terminalUsesLauncherTimeout ? .global : .never,
                canPopOut: false,
                preservesState: true,
                reopeningPolicy: .resume
            )
        case .files:
            return LauncherSurfaceDescriptor(id: "files", title: "Search Files", kind: .results, preferredSize: CGSize(width: 680, height: 452))
        case .clipboard:
            return LauncherSurfaceDescriptor(id: "clipboard", title: "Clipboard History", kind: .results, preferredSize: CGSize(width: 680, height: 452))
        case .history:
            return LauncherSurfaceDescriptor(id: "history", title: "Command History", kind: .results, preferredSize: CGSize(width: 680, height: 452))
        case .picker(let picker):
            let descriptor: (String, String, LauncherSurfaceKind) = {
                switch picker {
                case .emoji: return ("emoji", "Emoji Picker", .picker)
                case .applications: return ("applications", "Applications", .picker)
                case .displays: return ("displays", "Displays", .picker)
                case .timezone: return ("timezone", "Timezone Converter", .picker)
                }
            }()
            return LauncherSurfaceDescriptor(id: descriptor.0, title: descriptor.1, kind: descriptor.2, preferredSize: CGSize(width: 680, height: 452))
        case .writingReview:
            return LauncherSurfaceDescriptor(id: "writing-review", title: "Writing Review", kind: .textEditor, preferredSize: CGSize(width: 680, height: 600))
        case .output(let title, _, _):
            return LauncherSurfaceDescriptor(id: "output.\(title)", title: title, kind: .live, preferredSize: CGSize(width: 680, height: 540))
        case .contextShelf:
            // Shelf contents are persistent working memory and should not be
            // silently discarded by the transient launcher timeout.
            return LauncherSurfaceDescriptor(id: "context-shelf", title: "Context Shelf", kind: .results, preferredSize: CGSize(width: 680, height: 520), timeoutPolicy: .never, reopeningPolicy: .resumeIfPinned)
        case .root:
            return nil
        }
    }
}

private extension ExtensionSurfaceKind {
    var surfaceKind: LauncherSurfaceKind {
        switch self {
        case .form: return .form
        case .generator: return .generator
        case .picker: return .picker
        case .textTool: return .textEditor
        case .liveOutput: return .live
        }
    }
}
