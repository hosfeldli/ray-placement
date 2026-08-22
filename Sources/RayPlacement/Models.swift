import AppKit
import Foundation
import RayPlacementCore
import RayPlacementWriting

enum LauncherMode: Equatable {
    case root
    case files
    case vscodePicker
    case clipboard
    case writingReview(WritingReview)
    case output(title: String, text: String, isError: Bool)

    var title: String? {
        switch self {
        case .root: return nil
        case .files: return "Search Files"
        case .vscodePicker: return "Open in VS Code"
        case .clipboard: return "Clipboard History"
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
    case openSettings
    case quit
}

enum LauncherAction {
    case launchApplication(URL)
    case openFile(URL)
    case revealFile(URL)
    case openInVSCode(URL)
    case openURL(URL)
    case copyText(String)
    case pasteText(String)
    case replaceSelectedText(String)
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
    static let rayPlacementClipboardSettingsChanged = Notification.Name("RayPlacementClipboardSettingsChanged")
    static let rayPlacementExtensionsReloadRequested = Notification.Name("RayPlacementExtensionsReloadRequested")
    static let rayPlacementExtensionShortcutsChanged = Notification.Name("RayPlacementExtensionShortcutsChanged")
}
