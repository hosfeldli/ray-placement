import Foundation

public struct ExtensionManifest: Codable, Sendable {
    public enum Trust: String, Codable, Sendable { case bundled, builtIn, userInstalled, unsigned }
    public enum Provenance: String, Codable, Sendable { case bundled, userInstalled, unsigned }
    public enum Capability: String, Codable, CaseIterable, Sendable {
        case network
        case shell
        case filesystem
        case clipboard
        case selectedText
        case accessibility
        case processControl
        case systemControl
        case externalExecution
    }

    public var schemaVersion: Int
    public var id: String
    public var name: String
    public var version: String?
    public var description: String?
    public var pack: String?
    public var category: String?
    public var bundled: Bool
    public var provenance: Provenance
    public var commands: [ExtensionCommand]
    public var capabilities: Set<Capability>
    public var trust: Trust

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, id, name, version, description, pack, category, bundled, provenance, commands, capabilities, trust
    }

    public init(
        schemaVersion: Int = 2,
        id: String,
        name: String,
        version: String? = nil,
        description: String? = nil,
        pack: String? = nil,
        category: String? = nil,
        bundled: Bool = false,
        provenance: Provenance = .unsigned,
        commands: [ExtensionCommand],
        capabilities: Set<Capability> = [],
        trust: Trust = .unsigned
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.name = name
        self.version = version
        self.description = description
        self.pack = pack
        self.category = category
        self.bundled = bundled
        self.provenance = provenance
        self.commands = commands
        self.capabilities = capabilities
        self.trust = trust
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        version = try container.decodeIfPresent(String.self, forKey: .version)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        pack = try container.decodeIfPresent(String.self, forKey: .pack)
        category = try container.decodeIfPresent(String.self, forKey: .category)
        bundled = try container.decodeIfPresent(Bool.self, forKey: .bundled) ?? false
        provenance = try container.decodeIfPresent(Provenance.self, forKey: .provenance)
            ?? (bundled ? .bundled : .unsigned)
        commands = try container.decodeIfPresent([ExtensionCommand].self, forKey: .commands) ?? []
        capabilities = try container.decodeIfPresent(Set<Capability>.self, forKey: .capabilities) ?? []
        trust = try container.decodeIfPresent(Trust.self, forKey: .trust)
            ?? (bundled ? .bundled : .unsigned)
    }
}

public struct ExtensionApprovalRecord: Codable, Hashable, Sendable {
    public var extensionID: String
    public var manifestHash: String
    public var capabilities: Set<ExtensionManifest.Capability>
    public var approvedAt: Date

    public init(extensionID: String, manifestHash: String, capabilities: Set<ExtensionManifest.Capability>, approvedAt: Date = Date()) {
        self.extensionID = extensionID
        self.manifestHash = manifestHash
        self.capabilities = capabilities
        self.approvedAt = approvedAt
    }
}

public enum ExtensionApprovalStore {
    private static let key = "lima.extensionApprovals"

    public static func records() -> [String: ExtensionApprovalRecord] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([String: ExtensionApprovalRecord].self, from: data) else { return [:] }
        return decoded
    }

    public static func record(for extensionID: String) -> ExtensionApprovalRecord? {
        records()[extensionID]
    }

    public static func approve(extensionID: String, manifestHash: String, capabilities: Set<ExtensionManifest.Capability>) {
        var current = records()
        current[extensionID] = ExtensionApprovalRecord(extensionID: extensionID, manifestHash: manifestHash, capabilities: capabilities)
        guard let data = try? JSONEncoder().encode(current) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    public static func revoke(extensionID: String) {
        var current = records()
        current.removeValue(forKey: extensionID)
        guard let data = try? JSONEncoder().encode(current) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}

public struct ExtensionCommand: Codable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var subtitle: String?
    public var keywords: [String]?
    public var icon: String?
    public var hotkey: String?
    public var runInBackground: Bool?
    public var action: ExtensionAction

    public init(id: String, title: String, subtitle: String? = nil, keywords: [String]? = nil, icon: String? = nil, hotkey: String? = nil, runInBackground: Bool? = nil, action: ExtensionAction) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.keywords = keywords
        self.icon = icon
        self.hotkey = hotkey
        self.runInBackground = runInBackground
        self.action = action
    }
}

public struct ExtensionAction: Codable, Sendable {
    public enum ActionType: String, Codable, Sendable {
        case application
        case clipboard
        case file
        case form
        case picker
        case shell
        case system
        case url
        case window
        case workspace
    }

    public var type: ActionType
    public var value: String
    public var operation: String?
    public var target: String?
    public var confirmation: Bool?
    public var parameters: [String: String]?
    public var arguments: [String]?
    public var workingDirectory: String?
    public var form: ExtensionFormDefinition?
    public var chain: [ExtensionAction]?

    private enum CodingKeys: String, CodingKey {
        case type, value, operation, target, confirmation, parameters, arguments, workingDirectory, form, chain
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decode(ActionType.self, forKey: .type)
        value = try container.decodeIfPresent(String.self, forKey: .value) ?? ""
        operation = try container.decodeIfPresent(String.self, forKey: .operation)
        target = try container.decodeIfPresent(String.self, forKey: .target)
        confirmation = try container.decodeIfPresent(Bool.self, forKey: .confirmation)
        parameters = try container.decodeIfPresent([String: String].self, forKey: .parameters)
        arguments = try container.decodeIfPresent([String].self, forKey: .arguments)
        workingDirectory = try container.decodeIfPresent(String.self, forKey: .workingDirectory)
        form = try container.decodeIfPresent(ExtensionFormDefinition.self, forKey: .form)
        chain = try container.decodeIfPresent([ExtensionAction].self, forKey: .chain)
    }

    public init(
        type: ActionType,
        value: String = "",
        operation: String? = nil,
        target: String? = nil,
        confirmation: Bool? = nil,
        parameters: [String: String]? = nil,
        arguments: [String]? = nil,
        workingDirectory: String? = nil,
        form: ExtensionFormDefinition? = nil,
        chain: [ExtensionAction]? = nil
    ) {
        self.type = type
        self.value = value
        self.operation = operation
        self.target = target
        self.confirmation = confirmation
        self.parameters = parameters
        self.arguments = arguments
        self.workingDirectory = workingDirectory
        self.form = form
        self.chain = chain
    }

    public var inferredCapabilities: Set<ExtensionManifest.Capability> {
        var capabilities: Set<ExtensionManifest.Capability>
        switch type {
        case .url:
            capabilities = [.network]
        case .file:
            capabilities = [.filesystem]
        case .application:
            capabilities = [.processControl]
        case .shell:
            capabilities = [.shell, .filesystem]
        case .clipboard:
            capabilities = (operation ?? "copy") == "copy" ? [.clipboard] : [.clipboard, .accessibility]
        case .picker:
            switch operation {
            case "emoji": capabilities = [.clipboard, .accessibility]
            case "application": capabilities = [.processControl]
            case "display": capabilities = [.accessibility]
            case "file": capabilities = [.filesystem]
            default: capabilities = []
            }
        case .system:
            capabilities = [.systemControl]
        case .window:
            capabilities = [.accessibility]
        case .workspace:
            switch operation {
            case "writingReview": capabilities = [.selectedText, .clipboard, .accessibility]
            case "focusedFileLauncher": capabilities = [.filesystem]
            default: capabilities = []
            }
        case .form:
            capabilities = [.shell, .filesystem]
        }
        for nested in chain ?? [] {
            capabilities.formUnion(nested.inferredCapabilities)
        }
        return capabilities
    }

    public static let maximumNativeChainLength = 8

    public enum ChainValidationError: Error, Equatable, Sendable {
        case tooManyActions
        case unsupportedAction(ActionType)
    }

    public static func validateNativeChain(_ actions: [ExtensionAction]) throws {
        guard actions.count <= maximumNativeChainLength else { throw ChainValidationError.tooManyActions }
        for action in actions {
            guard action.chain == nil else {
                throw ChainValidationError.unsupportedAction(action.type)
            }
            guard ![.shell, .form, .url, .file, .picker, .workspace].contains(action.type) else {
                throw ChainValidationError.unsupportedAction(action.type)
            }
        }
    }
}

public struct ExtensionFormDefinition: Codable, Sendable {
    public var title: String?
    public var submitLabel: String?
    public var fields: [ExtensionFormField]
    public var execution: ExtensionFormExecution

    public init(title: String? = nil, submitLabel: String? = nil, fields: [ExtensionFormField], execution: ExtensionFormExecution) {
        self.title = title
        self.submitLabel = submitLabel
        self.fields = fields
        self.execution = execution
    }
}

public struct ExtensionFormField: Codable, Identifiable, Sendable {
    public enum FieldType: String, Codable, Sendable {
        case text, secure, multiline, number, toggle, picker, file, directory, date, slider, keyValue
    }

    public var id: String
    public var label: String
    public var type: FieldType
    public var placeholder: String?
    public var defaultValue: String?
    public var options: [String]?
    public var required: Bool?
    public var section: String?
    public var helpText: String?
    public var minimum: Double?
    public var maximum: Double?
    public var visibleWhen: ExtensionFieldVisibility?

    public init(id: String, label: String, type: FieldType, placeholder: String? = nil, defaultValue: String? = nil, options: [String]? = nil, required: Bool? = nil, section: String? = nil, helpText: String? = nil, minimum: Double? = nil, maximum: Double? = nil, visibleWhen: ExtensionFieldVisibility? = nil) {
        self.id = id
        self.label = label
        self.type = type
        self.placeholder = placeholder
        self.defaultValue = defaultValue
        self.options = options
        self.required = required
        self.section = section
        self.helpText = helpText
        self.minimum = minimum
        self.maximum = maximum
        self.visibleWhen = visibleWhen
    }
}

public struct ExtensionFieldVisibility: Codable, Sendable {
    public var field: String
    public var equals: String?
    public var notEquals: String?

    public init(field: String, equals: String? = nil, notEquals: String? = nil) {
        self.field = field
        self.equals = equals
        self.notEquals = notEquals
    }
}

public struct ExtensionFormExecution: Codable, Sendable {
    public enum ExecutionType: String, Codable, Sendable { case shell }

    public var type: ExecutionType
    public var executable: String?
    public var arguments: [String]?
    public var workingDirectory: String?
    public var timeoutSeconds: Int?

    public init(type: ExecutionType, executable: String? = nil, arguments: [String]? = nil, workingDirectory: String? = nil, timeoutSeconds: Int? = nil) {
        self.type = type
        self.executable = executable
        self.arguments = arguments
        self.workingDirectory = workingDirectory
        self.timeoutSeconds = timeoutSeconds
    }
}

public enum ExtensionTemplate {
    public static func render(_ template: String, values: [String: String]) -> String {
        values.reduce(template) { partial, pair in
            partial.replacingOccurrences(of: "{{\(pair.key)}}", with: pair.value)
        }
    }
}

public enum ExtensionBundleUpdatePolicy {
    /// Returns true only when a shipped pack is newer than a bundled installed
    /// copy. User-owned folders are never eligible for automatic replacement.
    public static func shouldUpdate(
        shippedVersion: String?,
        installedVersion: String?,
        destinationIsBundled: Bool
    ) -> Bool {
        guard destinationIsBundled, let shippedVersion else { return false }
        guard let installedVersion else { return true }
        guard shippedVersion != installedVersion else { return false }
        guard let shipped = SemanticVersion(shippedVersion),
              let installed = SemanticVersion(installedVersion) else {
            // A changed but non-semantic bundled version is safer to refresh
            // than to leave an installed copy permanently stale.
            return true
        }
        return shipped > installed
    }
}

public struct LoadedExtensionCommand: Sendable {
    public var extensionID: String
    public var extensionName: String
    public var directory: URL
    public var command: ExtensionCommand
    public var capabilities: Set<ExtensionManifest.Capability>
    public var trust: ExtensionManifest.Trust
    public var pack: String?
    public var category: String?
    public var bundled: Bool
    public var version: String?

    public init(extensionID: String, extensionName: String, directory: URL, command: ExtensionCommand, capabilities: Set<ExtensionManifest.Capability> = [], trust: ExtensionManifest.Trust = .unsigned, pack: String? = nil, category: String? = nil, bundled: Bool = false, version: String? = nil) {
        self.extensionID = extensionID
        self.extensionName = extensionName
        self.directory = directory
        self.command = command
        self.capabilities = capabilities
        self.trust = trust
        self.pack = pack
        self.category = category
        self.bundled = bundled
        self.version = version
    }

    /// Stable preferences identity for a pack. User extensions without pack
    /// metadata fall back to their extension ID, preserving older settings.
    public var settingsPackKey: String {
        let source = bundled || trust == .bundled || trust == .builtIn
            ? "bundled"
            : trust.rawValue
        guard let packName = pack?.trimmingCharacters(in: .whitespacesAndNewlines), !packName.isEmpty else {
            return "extension:\(extensionID)"
        }
        let categoryName = category?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return "\(source)|\(packName)|\(categoryName)"
    }

    public var provenanceLabel: String {
        bundled || trust == .bundled || trust == .builtIn
            ? "Built-in by Lima"
            : "User extension"
    }
}
