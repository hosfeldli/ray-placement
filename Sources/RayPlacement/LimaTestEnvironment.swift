import Foundation

/// Runtime switches shared by UI previews, snapshot tests, and opt-in live AI checks.
/// Test mode never falls back to Lima's production persistence or credential namespaces.
enum LimaTestEnvironment {
    static let testModeVariable = "LIMA_TEST_MODE"
    static let liveAITestVariable = "LIMA_ALLOW_LIVE_AI_TESTS"
    static let testDataDirectoryVariable = "LIMA_TEST_DATA_DIRECTORY"

    static var isEnabled: Bool {
        isEnabled(environment: ProcessInfo.processInfo.environment)
    }

    static var allowsLiveAI: Bool {
        allowsLiveAI(environment: ProcessInfo.processInfo.environment)
    }

    static func isEnabled(environment: [String: String]) -> Bool {
        environment[testModeVariable] == "1"
    }

    static func allowsLiveAI(environment: [String: String]) -> Bool {
        isEnabled(environment: environment) && environment[liveAITestVariable] == "1"
    }

    /// A per-process root keeps preview and UI-test data separate by default. Supplying
    /// `LIMA_TEST_DATA_DIRECTORY` makes a fixture run reproducible without touching
    /// the normal Application Support directory.
    static let dataRoot: URL? = {
        let environment = ProcessInfo.processInfo.environment
        guard isEnabled(environment: environment) else { return nil }
        if let path = environment[testDataDirectoryVariable], !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return FileManager.default.temporaryDirectory
            .appendingPathComponent("LimaUITest", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }()

    static func storageURL(relativePath: String) -> URL? {
        dataRoot?.appendingPathComponent(relativePath)
    }

    static let userDefaults: UserDefaults = {
        guard isEnabled else { return .standard }
        let suite = "dev.liam.lima.test.\(ProcessInfo.processInfo.processIdentifier)"
        return UserDefaults(suiteName: suite) ?? .standard
    }()
}
