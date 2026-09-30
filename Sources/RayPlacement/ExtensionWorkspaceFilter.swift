import Foundation

enum ExtensionWorkspaceFilter: String, CaseIterable, Identifiable {
    case all = "All", enabled = "Enabled", disabled = "Disabled", builtIn = "Built-in", local = "User packages"
    var id: String { rawValue }

    func includes(enabled: Bool, bundled: Bool) -> Bool {
        switch self {
        case .all: true
        case .enabled: enabled
        case .disabled: !enabled
        case .builtIn: bundled
        case .local: !bundled
        }
    }

    static func matches(query: String, name: String, id: String, commandTitles: [String]) -> Bool {
        let text = ([name, id] + commandTitles).joined(separator: " ")
        return query.split(whereSeparator: { $0.isWhitespace }).allSatisfy {
            text.localizedCaseInsensitiveContains(String($0))
        }
    }
}
