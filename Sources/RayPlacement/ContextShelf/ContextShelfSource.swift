import Foundation

struct ContextShelfSource: Codable, Equatable {
    enum SourceType: String, Codable {
        case application
        case clipboard
        case terminal
        case file
        case dictation
        case extensionOutput
        case note
        case lima
        case unknown
    }

    var type: SourceType
    var applicationName: String?
    var bundleIdentifier: String?
    var commandID: String?
    var extensionID: String?
    var noteID: UUID?
    var capturedAt: Date

    static func application(
        name: String?,
        bundleIdentifier: String?,
        capturedAt: Date = Date()
    ) -> ContextShelfSource {
        ContextShelfSource(
            type: .application,
            applicationName: name,
            bundleIdentifier: bundleIdentifier,
            commandID: nil,
            extensionID: nil,
            noteID: nil,
            capturedAt: capturedAt
        )
    }
}
