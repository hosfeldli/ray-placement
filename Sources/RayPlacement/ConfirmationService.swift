import AppKit

@MainActor
enum LimaConfirmationService {
    enum Severity {
        case warning
        case critical
    }

    /// Presents the one native confirmation surface used by destructive Lima
    /// operations. Critical actions intentionally have no Return-key default;
    /// the user must deliberately click the action button, while Escape always
    /// activates Cancel.
    static func confirm(
        title: String,
        detail: String,
        confirmTitle: String,
        severity: Severity = .critical,
        deliberate: Bool = false
    ) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = severity == .critical ? .critical : .warning
        alert.messageText = title
        alert.informativeText = detail
        alert.addButton(withTitle: confirmTitle)
        alert.addButton(withTitle: "Cancel")

        let confirmButton = alert.buttons[0]
        let cancelButton = alert.buttons[1]
        cancelButton.keyEquivalent = "\u{1b}"

        if deliberate {
            // Do not let Return activate a destructive operation as soon as
            // the dialog opens. The button remains available for an explicit
            // mouse click or an intentional accessibility action.
            confirmButton.keyEquivalent = ""
            alert.window.defaultButtonCell = nil
        } else {
            confirmButton.keyEquivalent = "\r"
        }

        return alert.runModal() == .alertFirstButtonReturn
    }
}
