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
    public var action: ExtensionAction

    public init(id: String, title: String, subtitle: String? = nil, keywords: [String]? = nil, icon: String? = nil, hotkey: String? = nil, action: ExtensionAction) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.keywords = keywords
        self.icon = icon
        self.hotkey = hotkey
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
        case openInVSCode
        case convertTimezones
        case forceQuitApplications
        case forceQuitAllApplications
        case openFormatterWorkspace
    }

    public var type: ActionType
    public var value: String
    public var arguments: [String]?
    public var workingDirectory: String?

    public init(type: ActionType, value: String, arguments: [String]? = nil, workingDirectory: String? = nil) {
        self.type = type
        self.value = value
        self.arguments = arguments
        self.workingDirectory = workingDirectory
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
