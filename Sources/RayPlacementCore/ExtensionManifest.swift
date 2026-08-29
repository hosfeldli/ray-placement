import Foundation

public struct ExtensionManifest: Codable, Sendable {
    public var schemaVersion: Int
    public var id: String
    public var name: String
    public var version: String?
    public var description: String?
    public var commands: [ExtensionCommand]

    public init(schemaVersion: Int = 1, id: String, name: String, version: String? = nil, description: String? = nil, commands: [ExtensionCommand]) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.name = name
        self.version = version
        self.description = description
        self.commands = commands
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
        case url
        case file
        case application
        case shell
        case copy
        case paste
        case pastePlainText
        case checkWriting
        case openFocusedFileLauncher
        case convertTimezones
        case forceQuitApplications
        case forceQuitAllApplications
        case openFormatterWorkspace
        case openEmojiPicker
        case openPasswordGenerator
        case openExtensionDevelopment
        case form
    }

    public var type: ActionType
    public var value: String
    public var arguments: [String]?
    public var workingDirectory: String?
    public var form: ExtensionFormDefinition?

    public init(type: ActionType, value: String, arguments: [String]? = nil, workingDirectory: String? = nil, form: ExtensionFormDefinition? = nil) {
        self.type = type
        self.value = value
        self.arguments = arguments
        self.workingDirectory = workingDirectory
        self.form = form
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
    public enum ExecutionType: String, Codable, Sendable {
        case httpRequest
        case shell
    }

    public var type: ExecutionType
    public var method: String?
    public var url: String?
    public var headers: [String: String]?
    public var body: String?
    public var executable: String?
    public var arguments: [String]?
    public var workingDirectory: String?
    public var timeoutSeconds: Int?

    public init(type: ExecutionType, method: String? = nil, url: String? = nil, headers: [String: String]? = nil, body: String? = nil, executable: String? = nil, arguments: [String]? = nil, workingDirectory: String? = nil, timeoutSeconds: Int? = nil) {
        self.type = type
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
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

public struct LoadedExtensionCommand: Sendable {
    public var extensionID: String
    public var extensionName: String
    public var directory: URL
    public var command: ExtensionCommand

    public init(extensionID: String, extensionName: String, directory: URL, command: ExtensionCommand) {
        self.extensionID = extensionID
        self.extensionName = extensionName
        self.directory = directory
        self.command = command
    }
}
