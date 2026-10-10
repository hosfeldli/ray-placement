import Foundation

/// Stable semantic identifiers shared by Accessibility, XCUITest, and QA tooling.
/// Keep these compact: the QA inspector projects visible controls rather than
/// exposing the raw macOS accessibility tree.
enum LimaQAIdentifiers {
    enum Launcher {
        static let searchField = "launcher.searchField"
        static let results = "launcher.results"
        static let result = "launcher.result"
        static let selectedResult = "launcher.result.selected"
    }

    enum Workspace {
        static let sidebar = "workspace.sidebar"
        static let searchField = "workspace.searchField"

        static func module(_ module: LimaWorkspaceModule) -> String {
            "workspace.module.\(module.rawValue)"
        }
    }

    enum Notes {
        static let list = "notes.list"
        static let search = "notes.search"
        static let editor = "notes.editor"
        static let new = "notes.new"
    }

    enum AI {
        static let composer = "ai.composer"
        static let send = "ai.send"
        static let stop = "ai.stop"
        static let activity = "ai.activity"
        static let subagentActivity = "ai.activity.subagent"
    }

    enum Context {
        static let search = "context.search"
        static let list = "context.list"
    }

    enum Settings {
        static let browserBridge = "settings.browserBridge"
    }

    static var knownIdentifiers: Set<String> {
        var values: Set<String> = [
            Launcher.searchField, Launcher.results, Launcher.result, Launcher.selectedResult,
            Workspace.sidebar, Workspace.searchField,
            Notes.list, Notes.search, Notes.editor, Notes.new,
            AI.composer, AI.send, AI.stop, AI.activity, AI.subagentActivity,
            Context.search, Context.list,
            Settings.browserBridge
        ]
        values.formUnion(LimaWorkspaceModule.allCases.map(Workspace.module))
        return values
    }

    static let textEntryIdentifiers: Set<String> = [
        Launcher.searchField, Workspace.searchField, Notes.search, Notes.editor, AI.composer, Context.search
    ]
}
