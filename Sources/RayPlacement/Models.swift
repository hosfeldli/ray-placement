import AppKit
import Foundation
import RayPlacementCore
import RayPlacementWriting

enum LauncherOutputState: Equatable {
    case running(canCancel: Bool)
    case success
    case error
}

enum LauncherMode: Equatable {
    case root
    case files
    case timezoneConverter
    case forceQuitPicker
    case emojiPicker
    case clipboard
    case history
    case writingReview(WritingReview)
    case output(title: String, text: String, state: LauncherOutputState)

    var title: String? {
        switch self {
        case .root: return nil
        case .files: return "Search Files"
        case .timezoneConverter: return "Timezone Converter"
        case .forceQuitPicker: return "Force Quit"
        case .emojiPicker: return "Emoji Picker"
        case .clipboard: return "Clipboard History"
        case .history: return "Command History"
        case .writingReview: return "Writing Review"
        case .output(let title, _, _): return title
        }
    }
}

enum LauncherIcon: Hashable {
    case system(String)
    case application(URL)
    case file(URL)
    case text(String)
}

enum WindowLayout: String, CaseIterable {
    case leftHalf
    case rightHalf
    case topHalf
    case bottomHalf
    case maximize
    case center

    var title: String {
        switch self {
        case .leftHalf: return "Left Half"
        case .rightHalf: return "Right Half"
        case .topHalf: return "Top Half"
        case .bottomHalf: return "Bottom Half"
        case .maximize: return "Maximize"
        case .center: return "Center"
        }
    }

    var symbol: String {
        switch self {
        case .leftHalf: return "rectangle.lefthalf.inset.filled"
        case .rightHalf: return "rectangle.righthalf.inset.filled"
        case .topHalf: return "rectangle.tophalf.inset.filled"
        case .bottomHalf: return "rectangle.bottomhalf.inset.filled"
        case .maximize: return "rectangle.inset.filled"
        case .center: return "rectangle.center.inset.filled"
        }
    }
}

enum SystemAction {
    case lockScreen
    case sleep
    case startScreenSaver
    case openExtensionsFolder
    case reloadExtensions
    case clearClipboardHistory
    case openNotes
    case openQuickNote
    case toggleNoteDictation
    case openTerminal
    case openSQLWorkspace
    case openEndpointTester
    case openFocusedFileLauncher
    case openPasswordGenerator
    case openFormatter
    case openExtensionGuide
    case openSettings
    case quit
}

enum LauncherAction {
    case launchApplication(URL)
    case openFile(URL)
    case revealFile(URL)
    case openURL(URL)
    case copyText(String)
    case pasteText(String)
    case replaceSelectedText(String)
    case saveSelectionToQuickNote(String)
    case checkSelectedText
    case forceQuitApplication(processIdentifier: Int32, name: String)
    case enterMode(LauncherMode)
    case extensionCommand(LoadedExtensionCommand)
    case window(WindowLayout)
    case system(SystemAction)
    case noOp
}

struct LauncherItem: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let icon: LauncherIcon
    let keywords: [String]
    let action: LauncherAction
    var shortcut: String?
    var accessory: String?

    var searchableText: String {
        ([title, subtitle] + keywords).joined(separator: " ")
    }
}

struct ApplicationRecord: Identifiable, Hashable {
    let url: URL
    let name: String
    let bundleIdentifier: String?

    var id: String { url.path }
}

struct TimezoneOption: Identifiable, Hashable {
    let id: String
    let title: String

    var city: String {
        id.split(separator: "/").last.map(String.init)?.replacingOccurrences(of: "_", with: " ") ?? id
    }
}

struct ClipboardEntry: Codable, Identifiable, Hashable {
    let id: UUID
    let text: String
    let capturedAt: Date
    var pinned: Bool

    init(id: UUID = UUID(), text: String, capturedAt: Date = Date(), pinned: Bool = false) {
        self.id = id
        self.text = text
        self.capturedAt = capturedAt
        self.pinned = pinned
    }
}

struct ExtensionIssue: Identifiable, Hashable {
    let id = UUID()
    let file: String
    let message: String
}

extension Notification.Name {
    static let rayPlacementShortcutChanged = Notification.Name("RayPlacementShortcutChanged")
    static let rayPlacementActionShortcutsChanged = Notification.Name("RayPlacementActionShortcutsChanged")
    static let rayPlacementAccentChanged = Notification.Name("RayPlacementAccentChanged")
    static let rayPlacementClipboardSettingsChanged = Notification.Name("RayPlacementClipboardSettingsChanged")
    static let rayPlacementExtensionsReloadRequested = Notification.Name("RayPlacementExtensionsReloadRequested")
    static let rayPlacementExtensionShortcutsChanged = Notification.Name("RayPlacementExtensionShortcutsChanged")
}
