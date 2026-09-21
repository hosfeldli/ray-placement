import AppKit
import Foundation
import Combine
import RayPlacementCore

// MARK: - Universal context and Use With…

enum LimaContextKind: String, Codable, CaseIterable, Sendable {
    case text, file, note, terminalOutput, shelfItem, clipboard, application, url
}

struct LimaContextValue: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let kind: LimaContextKind
    let title: String
    let value: String
    let sourceApplication: String?

    init(id: UUID = UUID(), kind: LimaContextKind, title: String, value: String, sourceApplication: String? = nil) {
        self.id = id; self.kind = kind; self.title = title; self.value = value; self.sourceApplication = sourceApplication
    }
}

struct LimaUseWithAction: Identifiable {
    let id: String
    let title: String
    let symbol: String
    let acceptedKinds: Set<LimaContextKind>
    let action: LauncherAction

    func supports(_ context: LimaContextValue) -> Bool { acceptedKinds.contains(context.kind) }
}

@MainActor
final class LimaCompatibilityRegistry {
    static let shared = LimaCompatibilityRegistry()
    private init() {}

    func actions(for context: LimaContextValue) -> [LimaUseWithAction] {
        var result: [LimaUseWithAction] = []
        if [.text, .clipboard, .shelfItem, .terminalOutput].contains(context.kind) {
            result += [
                LimaUseWithAction(id: "proofread", title: "Proofread", symbol: "text.badge.checkmark", acceptedKinds: [.text, .clipboard, .shelfItem, .terminalOutput], action: .checkSelectedText),
                LimaUseWithAction(id: "copy", title: "Copy", symbol: "doc.on.doc", acceptedKinds: Set(LimaContextKind.allCases), action: .copyText(context.value)),
                LimaUseWithAction(id: "note", title: "Create Note", symbol: "note.text.badge.plus", acceptedKinds: [.text, .clipboard, .shelfItem, .terminalOutput], action: .saveSelectionToQuickNote(context.value))
            ]
        }
        if [.text, .clipboard, .shelfItem, .file, .url, .terminalOutput].contains(context.kind) {
            result.append(LimaUseWithAction(id: "shelf", title: "Add to Shelf", symbol: "tray.and.arrow.down", acceptedKinds: Set(LimaContextKind.allCases), action: .system(.addSelectionToShelf)))
        }
        if [.file, .url, .application].contains(context.kind) {
            result.append(LimaUseWithAction(id: "terminal", title: "Use with Terminal", symbol: "terminal", acceptedKinds: [.file, .url, .application], action: .system(.openTerminal)))
        }
        return result
    }
}

// MARK: - Typed outputs

enum ExtensionOutputPayload: @unchecked Sendable {
    case text(String?)
    case native(ExtensionAction)
    case nativeChain([ExtensionAction])
}

struct ExtensionExecutionOutput: Identifiable, @unchecked Sendable {
    let id: UUID
    let title: String
    let value: String
    let descriptor: ExtensionOutputDescriptor
    let sourceCommandID: String
    let createdAt: Date
    let payload: ExtensionOutputPayload

    init(
        id: UUID = UUID(),
        title: String,
        value: String = "",
        descriptor: ExtensionOutputDescriptor = ExtensionOutputDescriptor(kind: .text),
        sourceCommandID: String,
        createdAt: Date = Date(),
        payload: ExtensionOutputPayload = .text(nil)
    ) {
        self.id = id
        self.title = title
        self.value = value
        self.descriptor = descriptor
        self.sourceCommandID = sourceCommandID
        self.createdAt = createdAt
        self.payload = payload
    }

    static func text(for command: LoadedExtensionCommand, value: String?) -> ExtensionExecutionOutput {
        ExtensionExecutionOutput(
            title: command.command.title,
            value: value ?? "",
            descriptor: command.command.output ?? ExtensionOutputDescriptor(kind: .text),
            sourceCommandID: command.command.id,
            payload: .text(value)
        )
    }

    static func native(for command: LoadedExtensionCommand, action: ExtensionAction) -> ExtensionExecutionOutput {
        ExtensionExecutionOutput(title: command.command.title, descriptor: command.command.output ?? ExtensionOutputDescriptor(kind: .status), sourceCommandID: command.command.id, payload: .native(action))
    }

    static func nativeChain(for command: LoadedExtensionCommand, actions: [ExtensionAction]) -> ExtensionExecutionOutput {
        ExtensionExecutionOutput(title: command.command.title, descriptor: command.command.output ?? ExtensionOutputDescriptor(kind: .status), sourceCommandID: command.command.id, payload: .nativeChain(actions))
    }

    var canCopy: Bool { descriptor.copyable ?? true }
    var canPaste: Bool { descriptor.pasteable ?? true }
    var canSaveToShelf: Bool { descriptor.shelfEligible == true }
    var canSaveToNotes: Bool { descriptor.notesEligible == true }
    var isPersistable: Bool { canSaveToShelf || canSaveToNotes }
}

@MainActor
final class ExtensionOutputStore: ObservableObject {
    static let shared = ExtensionOutputStore()
    @Published private(set) var outputs: [ExtensionExecutionOutput] = []
    private init() {}

    func record(_ output: ExtensionExecutionOutput) {
        guard !output.value.isEmpty else { return }
        outputs.insert(output, at: 0)
        if outputs.count > 40 { outputs.removeLast(outputs.count - 40) }
    }
    func clear() { outputs.removeAll() }
}

// MARK: - Surface registry

enum LauncherSurfaceHandlerKey: String, Codable, Sendable {
    case generic
    case formatter
    case permissions
    case extensionStore
    case workflows
    case extensionDevelopment
    case grammarDebugger
    case aiChat
}

enum ExtensionSurfaceHandlerKey: String, Codable, Sendable {
    case generic
    case form
    case generator
    case passwordGenerator
}

@MainActor
final class LimaSurfaceRegistry {
    static let shared = LimaSurfaceRegistry()
    private init() {}

    func descriptor(
        id: String,
        title: String,
        kind: LauncherSurfaceKind,
        handler: LauncherSurfaceHandlerKey = .generic,
        preferredHeight: CGFloat = 520,
        canPopOut: Bool = false,
        primaryActionTitle: String? = nil,
        supportsCopy: Bool = false,
        supportsSearch: Bool = true
    ) -> LauncherSurfaceDescriptor {
        LauncherSurfaceDescriptor(id: id, title: title, kind: kind, preferredSize: CGSize(width: 680, height: preferredHeight), canPopOut: canPopOut, preservesState: true, handler: handler, primaryActionTitle: primaryActionTitle, supportsCopy: supportsCopy, supportsSearch: supportsSearch)
    }
}

// MARK: - Chaining and macros

enum LimaMacroFailurePolicy: String, Codable, CaseIterable, Sendable {
    case stop
    case continueOnFailure
}

struct LimaActionStep: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var commandID: String
    var title: String
    var parameters: [String: String]

    init(id: UUID = UUID(), commandID: String, title: String, parameters: [String: String] = [:]) {
        self.id = id; self.commandID = commandID; self.title = title; self.parameters = parameters
    }
}

struct LimaActionChain: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var name: String
    var steps: [LimaActionStep]
    var shortcut: String?
    var failurePolicy: LimaMacroFailurePolicy

    init(id: UUID = UUID(), name: String, steps: [LimaActionStep] = [], shortcut: String? = nil, failurePolicy: LimaMacroFailurePolicy = .stop) {
        self.id = id; self.name = name; self.steps = steps; self.shortcut = shortcut; self.failurePolicy = failurePolicy
    }

    private enum CodingKeys: String, CodingKey { case id, name, steps, shortcut, failurePolicy }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        steps = try c.decode([LimaActionStep].self, forKey: .steps)
        shortcut = try c.decodeIfPresent(String.self, forKey: .shortcut)
        failurePolicy = try c.decodeIfPresent(LimaMacroFailurePolicy.self, forKey: .failurePolicy) ?? .stop
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id); try c.encode(name, forKey: .name); try c.encode(steps, forKey: .steps)
        try c.encodeIfPresent(shortcut, forKey: .shortcut); try c.encode(failurePolicy, forKey: .failurePolicy)
    }
}

@MainActor
final class LimaMacroStore: ObservableObject {
    static let shared = LimaMacroStore()
    @Published private(set) var chains: [LimaActionChain] = []
    private let key = "lima.actionChains"
    private init() { reload() }

    func reload() {
        guard let data = UserDefaults.standard.data(forKey: key), let values = try? JSONDecoder().decode([LimaActionChain].self, from: data) else { return }
        chains = values
    }
    func save(_ chain: LimaActionChain) {
        if let index = chains.firstIndex(where: { $0.id == chain.id }) { chains[index] = chain } else { chains.append(chain) }
        persist()
    }
    func remove(_ chain: LimaActionChain) { chains.removeAll { $0.id == chain.id }; persist() }
    private func persist() { UserDefaults.standard.set(try? JSONEncoder().encode(chains), forKey: key) }
}

// MARK: - Unified index and latency diagnostics

struct LauncherLatencySample: Identifiable, Codable, Sendable {
    let id: UUID
    let operation: String
    let milliseconds: Double
    let budget: Double
    let recordedAt: Date
    var withinBudget: Bool { milliseconds <= budget }
}

@MainActor
final class LauncherPerformanceDiagnostics: ObservableObject {
    static let shared = LauncherPerformanceDiagnostics()
    @Published private(set) var samples: [LauncherLatencySample] = []
    private init() {}
    func measure<T>(_ operation: String, budget: Double, _ work: () throws -> T) rethrows -> T {
        let start = DispatchTime.now().uptimeNanoseconds
        defer {
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
            samples.append(LauncherLatencySample(id: UUID(), operation: operation, milliseconds: elapsed, budget: budget, recordedAt: Date()))
            if samples.count > 200 { samples.removeFirst(samples.count - 200) }
        }
        return try work()
    }
    func record(operation: String, budget: Double, milliseconds: Double) {
        samples.append(LauncherLatencySample(id: UUID(), operation: operation, milliseconds: milliseconds, budget: budget, recordedAt: Date()))
        if samples.count > 200 { samples.removeFirst(samples.count - 200) }
    }
    func mark(_ operation: String, startedAt: UInt64, budget: Double) {
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - startedAt) / 1_000_000
        record(operation: operation, budget: budget, milliseconds: elapsed)
    }
    func clear() { samples.removeAll() }
}

struct LauncherSearchIndexEntry: Identifiable {
    let id: String
    let title: String
    let searchableText: String
    let item: LauncherItem
}

@MainActor
final class LauncherSearchIndex {
    private(set) var entries: [LauncherSearchIndexEntry] = []
    func rebuild(items: [LauncherItem]) {
        entries = items.map { LauncherSearchIndexEntry(id: $0.id, title: $0.title, searchableText: $0.searchableText, item: $0) }
    }
    func search(_ query: String) -> [LauncherItem] {
        let clean = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return entries.map(\.item) }
        return entries.compactMap { entry in FuzzyMatcher.score(entry.searchableText, query: clean) == nil ? nil : entry.item }
    }
}
