import AppKit
import Foundation
import SwiftTerm

/// A real pseudo-terminal owned by an AI Workspace session. SwiftTerm renders
/// the same bytes the AI can read, and both user keyboard input and AI writes go
/// to this one process. The coordinator retains the view while the session is
/// alive, even when the Terminal workspace is not currently visible.
final class AIWorkspacePTYTerminalView: LocalProcessTerminalView {
    var onOutput: ((Data) -> Void)?
    var onExit: ((Int32?) -> Void)?

    override func dataReceived(slice: ArraySlice<UInt8>) {
        super.dataReceived(slice: slice)
        let chunk = Data(slice)
        DispatchQueue.main.async { [weak self] in
            self?.onOutput?(chunk)
        }
    }

    override func processTerminated(_ source: LocalProcess, exitCode: Int32?) {
        super.processTerminated(source, exitCode: exitCode)
        DispatchQueue.main.async { [weak self] in
            self?.onExit?(exitCode)
        }
    }
}
