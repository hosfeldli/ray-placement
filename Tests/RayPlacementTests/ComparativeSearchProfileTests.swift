import Foundation
import Testing
@testable import RayPlacement

/// Opt-in, version-neutral probe. Copy this file unchanged into the immutable
/// release worktree to compare the cost of typing on the MainActor.
@Test @MainActor func comparativeSearchTypingProfile() async {
    guard ProcessInfo.processInfo.environment["LIMA_RUN_PERFORMANCE_PROFILE"] == "1" else { return }

    let clock = ProcessInfo.processInfo
    var firstKeyMS: [Double] = []
    var resultMS: [Double] = []
    var warmKeyMS: [Double] = []

    for _ in 0..<12 {
        let model = LauncherViewModel(
            clipboard: ClipboardHistoryService(fixtures: []),
            scanApplications: false
        )
        let startedAt = clock.systemUptime
        model.query = "notes"
        firstKeyMS.append((clock.systemUptime - startedAt) * 1_000)

        for _ in 0..<1_000 where !model.results.contains(where: { $0.id == "builtin.notes" }) {
            try? await Task.sleep(for: .milliseconds(1))
        }
        resultMS.append((clock.systemUptime - startedAt) * 1_000)
        #expect(model.results.contains { $0.id == "builtin.notes" })

        for query in ["n", "no", "not", "note", "notes", "note", "not", "no", "n", ""] {
            let keyStartedAt = clock.systemUptime
            model.query = query
            warmKeyMS.append((clock.systemUptime - keyStartedAt) * 1_000)
        }
    }

    func percentile(_ samples: [Double], _ fraction: Double) -> String {
        let sorted = samples.sorted()
        let index = min(sorted.count - 1, Int(Double(sorted.count - 1) * fraction))
        return String(format: "%.3f", sorted[index])
    }
    print("LIMA_PROFILE_SEARCH firstKeyP50MS=\(percentile(firstKeyMS, 0.5)) firstKeyP95MS=\(percentile(firstKeyMS, 0.95)) resultP50MS=\(percentile(resultMS, 0.5)) resultP95MS=\(percentile(resultMS, 0.95)) warmKeyP50MS=\(percentile(warmKeyMS, 0.5)) warmKeyP95MS=\(percentile(warmKeyMS, 0.95))")
}

/// Synthetic source-volume probe: no user clipboard entries are read.
@Test @MainActor func comparativeSearchPopulatedCatalogProfile() async {
    guard ProcessInfo.processInfo.environment["LIMA_RUN_PERFORMANCE_PROFILE"] == "1" else { return }
    let entries = (0..<500).map { index in
        ClipboardEntry(text: "benchmarker synthetic clipboard item \(index) with searchable body")
    }
    let clock = ProcessInfo.processInfo
    var firstKeyMS: [Double] = []
    var resultMS: [Double] = []
    for _ in 0..<8 {
        let model = LauncherViewModel(
            clipboard: ClipboardHistoryService(fixtures: entries),
            scanApplications: false
        )
        let startedAt = clock.systemUptime
        model.query = "benchmarker"
        firstKeyMS.append((clock.systemUptime - startedAt) * 1_000)
        for _ in 0..<2_000 where !model.results.contains(where: { $0.id.hasPrefix("clipboard.") }) {
            try? await Task.sleep(for: .milliseconds(1))
        }
        resultMS.append((clock.systemUptime - startedAt) * 1_000)
        #expect(model.results.contains { $0.id.hasPrefix("clipboard.") })
    }
    func percentile(_ samples: [Double], _ fraction: Double) -> String {
        let sorted = samples.sorted()
        let index = min(sorted.count - 1, Int(Double(sorted.count - 1) * fraction))
        return String(format: "%.3f", sorted[index])
    }
    print("LIMA_PROFILE_SEARCH_POPULATED entries=500 firstKeyP50MS=\(percentile(firstKeyMS, 0.5)) firstKeyP95MS=\(percentile(firstKeyMS, 0.95)) resultP50MS=\(percentile(resultMS, 0.5)) resultP95MS=\(percentile(resultMS, 0.95))")
}
