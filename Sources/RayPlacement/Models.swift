import AppKit
import Foundation
import RayPlacementCore
import RayPlacementWriting

enum LauncherOutputState: Equatable {
    case running(canCancel: Bool)
    case success
    case error
}

enum PickerSurface: Equatable {
    case emoji
    case applications(operation: String)
    case displays(operation: String)
    case timezone
}

enum LauncherMode: Equatable {
    case root
    case files
    case picker(PickerSurface)
    case clipboard
    case history
    case terminal
    case writingReview(WritingReview)
    case output(title: String, text: String, state: LauncherOutputState)

    var title: String? {
        switch self {
        case .root: return nil
        case .files: return "Search Files"
        case .picker(.timezone): return "Timezone Converter"
        case .picker(.applications): return "Applications"
        case .picker(.displays): return "Displays"
        case .picker(.emoji): return "Emoji Picker"
        case .clipboard: return "Clipboard History"
        case .history: return "Command History"
        case .terminal: return "Terminal"
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
    case leftThird
    case centerThird
    case rightThird
    case leftTwoThirds
    case rightTwoThirds
    case topLeftQuarter
    case topRightQuarter
    case bottomLeftQuarter
    case bottomRightQuarter
    case restorePrevious
    case nextDisplay
    case previousDisplay
    case mainDisplay

    var title: String {
        switch self {
        case .leftHalf: return "Left Half"
        case .rightHalf: return "Right Half"
        case .topHalf: return "Top Half"
        case .bottomHalf: return "Bottom Half"
        case .maximize: return "Maximize"
        case .center: return "Center"
        case .leftThird: return "Left Third"
        case .centerThird: return "Center Third"
        case .rightThird: return "Right Third"
        case .leftTwoThirds: return "Left Two Thirds"
        case .rightTwoThirds: return "Right Two Thirds"
        case .topLeftQuarter: return "Top Left Quarter"
        case .topRightQuarter: return "Top Right Quarter"
        case .bottomLeftQuarter: return "Bottom Left Quarter"
        case .bottomRightQuarter: return "Bottom Right Quarter"
        case .restorePrevious: return "Restore Previous Position"
        case .nextDisplay: return "Next Display"
        case .previousDisplay: return "Previous Display"
        case .mainDisplay: return "Main Display"
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
        case .leftThird, .leftTwoThirds: return "rectangle.lefthalf.inset.filled"
        case .centerThird: return "rectangle.center.inset.filled"
        case .rightThird, .rightTwoThirds: return "rectangle.righthalf.inset.filled"
        case .topLeftQuarter: return "rectangle.topthird.inset.filled"
        case .topRightQuarter: return "rectangle.topthird.inset.filled"
        case .bottomLeftQuarter: return "rectangle.bottomthird.inset.filled"
        case .bottomRightQuarter: return "rectangle.bottomthird.inset.filled"
        case .restorePrevious: return "arrow.uturn.backward"
        case .nextDisplay: return "rectangle.on.rectangle"
        case .previousDisplay: return "rectangle.on.rectangle"
        case .mainDisplay: return "display.2"
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
    case openPermissionCenter
    case exportDiagnostics
    case openWorkflows
    case openSettings
    case openDeveloperGrammarSettings
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
    case applicationOperation(operation: String, processIdentifier: Int32, name: String)
    case displayOperation(operation: String, displayIdentifier: CGDirectDisplayID, name: String)
    case enterMode(LauncherMode)
    case extensionCommand(LoadedExtensionCommand)
    case universalSearch(LimaSearchResult)
    case workflow(UUID)
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
    let extensionID: String?
    let manifestHash: String?
    let capabilities: Set<ExtensionManifest.Capability>?

    init(file: String, message: String, extensionID: String? = nil, manifestHash: String? = nil, capabilities: Set<ExtensionManifest.Capability>? = nil) {
        self.file = file
        self.message = message
        self.extensionID = extensionID
        self.manifestHash = manifestHash
        self.capabilities = capabilities
    }
}

extension LoadedExtensionCommand {
    var capabilitySummary: String { capabilities.map(\.rawValue).sorted().joined(separator: ", ") }
    var trustLabel: String { trust.rawValue }
}

extension Notification.Name {
    static let rayPlacementShortcutChanged = Notification.Name("RayPlacementShortcutChanged")
    static let rayPlacementActionShortcutsChanged = Notification.Name("RayPlacementActionShortcutsChanged")
    static let rayPlacementAccentChanged = Notification.Name("RayPlacementAccentChanged")
    static let rayPlacementAppearanceChanged = Notification.Name("RayPlacementAppearanceChanged")
    static let rayPlacementClipboardSettingsChanged = Notification.Name("RayPlacementClipboardSettingsChanged")
    static let rayPlacementExtensionsReloadRequested = Notification.Name("RayPlacementExtensionsReloadRequested")
    static let rayPlacementExtensionShortcutsChanged = Notification.Name("RayPlacementExtensionShortcutsChanged")
    static let rayPlacementCommandProfilesChanged = Notification.Name("RayPlacementCommandProfilesChanged")
}
