import Foundation
import Darwin

/// Drain both pipes while the client is alive. Waiting for termination before
/// reading causes an indefinite deadlock as soon as either pipe fills.
public enum SQLClientProcess {
    public struct Output {
        public let stdout: Data
        public let stderr: Data
    }

    public struct Timeout: LocalizedError {
        public var errorDescription: String? { "The database client exceeded its time limit. Check the connection or reduce the discovery scope and retry." }
    }

    private final class Capture: @unchecked Sendable {
        let lock = NSLock()
        var stderr = Data()
        var timedOut = false
    }

    public static func run(_ process: Process, input: Data, timeout: TimeInterval = 120) throws -> Output {
        let stdout = Pipe(), stderr = Pipe(), stdin = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = stdin
        let capture = Capture()
        try process.run()
        let deadline = DispatchWorkItem {
            guard process.isRunning else { return }
            capture.lock.lock(); capture.timedOut = true; capture.lock.unlock()
            process.terminate()
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) {
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: deadline)
        defer { deadline.cancel() }
        let readers = DispatchGroup()
        readers.enter()
        DispatchQueue.global(qos: .utility).async {
            let data = stderr.fileHandleForReading.readDataToEndOfFile()
            capture.lock.lock(); capture.stderr = data; capture.lock.unlock()
            readers.leave()
        }
        // Writing input also runs concurrently: a large script must not block
        // draining the client's output.
        readers.enter()
        DispatchQueue.global(qos: .utility).async {
            try? stdin.fileHandleForWriting.write(contentsOf: input)
            try? stdin.fileHandleForWriting.close()
            readers.leave()
        }
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        readers.wait()
        capture.lock.lock(); defer { capture.lock.unlock() }
        if capture.timedOut { throw Timeout() }
        return Output(stdout: output, stderr: capture.stderr)
    }
}
