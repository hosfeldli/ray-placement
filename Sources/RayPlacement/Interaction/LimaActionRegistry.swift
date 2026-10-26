import Foundation
import RayPlacementCore

/// Resolves the actions a Search object can actually perform. Callers supply
/// current capabilities so the same ordered descriptors can be presented by
/// the keyboard action panel or a native context menu.
@MainActor
enum LimaActionRegistry {
    struct Capabilities {
        var objectExists = true
        var canOpenInCode = false
        var canAttachFileToAI = false
        var runningApplicationPID: Int32?
        var canEditAlias = false
        var isFavorite = false
        var contextActions: [LauncherItemAction] = []
    }

    static func actions(for item: LauncherItem, capabilities: Capabilities) -> [LauncherItemAction] {
        switch item.action {
        case .fileAction(let url, _), .openFile(let url), .revealFile(let url):
            return fileActions(for: url, capabilities: capabilities)
        case .launchApplication(let url):
            return applicationActions(for: item, url: url, capabilities: capabilities)
        default:
            return generalActions(for: item, capabilities: capabilities)
        }
    }

    static func fileActions(for url: URL, capabilities: Capabilities) -> [LauncherItemAction] {
        let fileAction: (String, String, String, LauncherActionRole, LauncherFileAction) -> LauncherItemAction = {
            id, title, symbol, role, operation in
            LauncherItemAction(id: id, title: title, symbol: symbol, shortcut: nil,
                               role: role, action: .fileAction(url, operation))
        }

        // A stale Spotlight hit must not advertise Open, Preview, or AI reads.
        guard capabilities.objectExists else {
            return [fileAction("copy-path", "Copy Path", "doc.on.doc", .primary, .copyPath)]
        }
        var actions = [
            fileAction("open", "Open", "arrow.up.forward.app", .primary, .open),
            fileAction("quick-look", "Quick Look", "eye", .secondary, .quickLook),
            fileAction("reveal", "Reveal in Finder", "finder", .secondary, .reveal),
            fileAction("copy-path", "Copy Path", "doc.on.doc", .secondary, .copyPath),
            fileAction("terminal", "Open Terminal Here", "terminal", .secondary, .openTerminalHere)
        ]
        if capabilities.canOpenInCode {
            actions.append(fileAction("code", "Open in Code", "chevron.left.forwardslash.chevron.right",
                                      .secondary, .openInCode))
        }
        if capabilities.canAttachFileToAI {
            actions.append(fileAction("describe-ai", "Describe with AI…", "text.magnifyingglass",
                                      .secondary, .describeWithAI))
            actions.append(fileAction("ask-ai", "Ask AI About File…", "sparkles",
                                      .secondary, .askAIAboutFile))
        }
        actions.append(fileAction("shelf", "Add to Shelf", "tray.and.arrow.down", .secondary, .addToShelf))
        actions.append(fileAction("note", "Append to Note", "note.text.badge.plus", .secondary, .sendToNote))
        return actions
    }

    private static func applicationActions(
        for item: LauncherItem, url: URL, capabilities: Capabilities
    ) -> [LauncherItemAction] {
        var actions: [LauncherItemAction] = []
        if capabilities.objectExists {
            actions.append(LauncherItemAction(id: "open", title: "Open", symbol: "arrow.up.forward.app",
                                              shortcut: nil, role: .primary, action: item.action))
            actions.append(LauncherItemAction(id: "reveal", title: "Reveal in Finder", symbol: "finder",
                                              shortcut: nil, role: .secondary, action: .revealFile(url)))
        }
        actions.append(LauncherItemAction(id: "copy-path", title: "Copy Path", symbol: "doc.on.doc",
                                          shortcut: nil, role: actions.isEmpty ? .primary : .secondary,
                                          action: .copyText(url.path)))
        if let pid = capabilities.runningApplicationPID {
            actions.append(LauncherItemAction(id: "hide", title: "Hide", symbol: "eye.slash",
                                              shortcut: nil, role: .secondary,
                                              action: .applicationOperation(operation: "hide",
                                                                            processIdentifier: pid, name: item.title)))
            actions.append(LauncherItemAction(id: "quit", title: "Quit", symbol: "xmark.circle",
                                              shortcut: nil, role: .destructive,
                                              action: .applicationOperation(operation: "quit",
                                                                            processIdentifier: pid, name: item.title)))
            actions.append(LauncherItemAction(id: "force-quit", title: "Force Quit",
                                              symbol: "exclamationmark.octagon", shortcut: nil,
                                              role: .destructive,
                                              action: .applicationOperation(operation: "forceQuit",
                                                                            processIdentifier: pid, name: item.title)))
        }
        actions.append(favoriteAction(for: item.id, isFavorite: capabilities.isFavorite))
        return actions
    }

    private static func generalActions(
        for item: LauncherItem, capabilities: Capabilities
    ) -> [LauncherItemAction] {
        var actions = [LauncherItemAction(id: "run", title: LauncherSearchDesign.primaryTitle(for: item),
                                          symbol: "play.fill", shortcut: "↩", role: .primary,
                                          action: item.action)]
        if let expression = item.keywords.first {
            let rawValue: Double?
            if item.id.hasPrefix("calculator.") {
                rawValue = try? Calculator.evaluate(expression)
            } else if item.id.hasPrefix("conversion.") {
                rawValue = SearchMeasurementConversion.convert(expression)?.rawValue
            } else {
                rawValue = nil
            }
            if let rawValue {
                actions.append(LauncherItemAction(id: "copy-raw", title: "Copy Raw Number", symbol: "number",
                                                  shortcut: nil, role: .secondary,
                                                  action: .copyText(String(rawValue))))
                actions.append(LauncherItemAction(id: "copy-expression", title: "Copy Expression",
                                                  symbol: "doc.on.doc", shortcut: nil, role: .secondary,
                                                  action: .copyText(expression)))
            }
        }
        actions.append(contentsOf: capabilities.contextActions)
        if capabilities.canEditAlias {
            actions.append(LauncherItemAction(id: "add-alias", title: "Add Alias…",
                                              symbol: "text.badge.plus", shortcut: nil,
                                              role: .secondary, action: .editAlias(item.id)))
        }
        actions.append(favoriteAction(for: item.id, isFavorite: capabilities.isFavorite))
        actions.append(LauncherItemAction(id: "forget", title: "Forget Ranking",
                                          symbol: "clock.badge.xmark", shortcut: nil,
                                          role: .destructive, action: .forgetRanking(item.id)))
        return actions
    }

    private static func favoriteAction(for id: String, isFavorite: Bool) -> LauncherItemAction {
        LauncherItemAction(id: "favorite",
                           title: isFavorite ? "Unpin from Top" : "Pin to Top",
                           symbol: isFavorite ? "pin.slash" : "pin",
                           shortcut: nil, role: .secondary, action: .toggleFavorite(id))
    }
}
