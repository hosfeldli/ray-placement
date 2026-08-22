import Foundation

final class FileSearchService {
    private let queue = DispatchQueue(label: "dev.rayplacement.filesearch", qos: .userInitiated)
    private let lock = NSLock()
    private var process: Process?
    private var generation = 0

    func search(_ query: String, completion: @escaping ([URL]) -> Void) {
        lock.lock()
        generation += 1
        let requestGeneration = generation
        if let process, process.isRunning { process.terminate() }
        lock.unlock()

        let cleanQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanQuery.isEmpty else {
            completion([])
            return
        }

        queue.async { [weak self] in
            guard let self else { return }
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
            task.arguments = ["-name", cleanQuery]
            let output = Pipe()
            task.standardOutput = output
            task.standardError = FileHandle.nullDevice

            do {
                try task.run()

                // Publish only a launched Process. Calling terminate() before run()
                // raises an Objective-C exception rather than a catchable Swift error.
                self.lock.lock()
                guard requestGeneration == self.generation else {
                    self.lock.unlock()
                    task.terminate()
                    _ = output.fileHandleForReading.readDataToEndOfFile()
                    task.waitUntilExit()
                    return
                }
                self.process = task
                self.lock.unlock()

                let handle = output.fileHandleForReading
                var data = Data()
                let byteLimit = 2_000_000
                while let chunk = try handle.read(upToCount: 65_536), !chunk.isEmpty {
                    let remaining = byteLimit - data.count
                    if remaining > 0 { data.append(chunk.prefix(remaining)) }
                    if data.count >= byteLimit {
                        task.terminate()
                        break
                    }
                }
                task.waitUntilExit()
                let paths = String(decoding: data, as: UTF8.self)
                    .split(separator: "\n", omittingEmptySubsequences: true)
                    .prefix(80)
                    .map { URL(fileURLWithPath: String($0)) }

                self.lock.lock()
                let isCurrent = requestGeneration == self.generation
                if isCurrent { self.process = nil }
                self.lock.unlock()
                if isCurrent { DispatchQueue.main.async { completion(paths) } }
            } catch {
                self.lock.lock()
                let isCurrent = requestGeneration == self.generation
                if isCurrent { self.process = nil }
                self.lock.unlock()
                if isCurrent { DispatchQueue.main.async { completion([]) } }
            }
        }
    }

    func cancel() {
        lock.lock()
        generation += 1
        if let process, process.isRunning { process.terminate() }
        process = nil
        lock.unlock()
    }
}
