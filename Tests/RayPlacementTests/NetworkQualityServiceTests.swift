import Foundation
import Testing
@testable import RayPlacement

@Test func networkQualitySummaryParsesMeasuredValuesAndUnits() throws {
    let started = Date(timeIntervalSince1970: 1_800_000_000)
    let id = UUID()
    let summary = """
    ==== SUMMARY ====
    Upload capacity: 42.75 Mbps
    Download capacity: 1.21 Gbps
    Upload flows: 12
    Download flows: 12
    Responsiveness: High (1240 RPM)
    Idle Latency: 18.5 milliseconds
    Interface: Wi-Fi
    """
    let result = try #require(NetworkQualitySummaryParser.parse(
        summary, id: id, startedAt: started, durationSeconds: 14.2
    ))
    #expect(result.id == id)
    #expect(result.downloadMbps == 1210)
    #expect(result.uploadMbps == 42.75)
    #expect(result.idleLatencyMilliseconds == 18.5)
    #expect(result.responsiveness == "High (1240 RPM)")
    #expect(result.interfaceName == "Wi-Fi")
    #expect(result.method == "macOS networkQuality")
}

@Test func networkQualitySummaryRejectsUnrecognizedOrPartialOutput() {
    let now = Date()
    #expect(NetworkQualitySummaryParser.parse(
        "networkQuality: command unavailable", id: UUID(), startedAt: now,
        durationSeconds: 0
    ) == nil)
    #expect(NetworkQualitySummaryParser.parse(
        "Upload capacity: 20 Mbps", id: UUID(), startedAt: now,
        durationSeconds: 1
    ) == nil)
    let kilobitSummary = "Download capacity: 950 Kbps\nUpload capacity: 500 Kbps"
    let parsed = NetworkQualitySummaryParser.parse(
        kilobitSummary, id: UUID(), startedAt: now, durationSeconds: 1
    )
    #expect(parsed?.downloadMbps == 0.95)
    #expect(parsed?.uploadMbps == 0.5)
}

@Test @MainActor func networkQualityDoesNotStartWhenBackendIsMissing() {
    let service = NetworkQualityService(
        executableURL: URL(fileURLWithPath: "/definitely/missing/networkQuality"),
        historyURL: FileManager.default.temporaryDirectory.appendingPathComponent(
            "LimaNetworkQualityTests-\(UUID().uuidString).json"
        )
    )
    do {
        _ = try service.start()
        Issue.record("An unavailable networkQuality backend must not start")
    } catch NetworkQualityService.QualityError.unavailable {
        #expect(service.phase == .idle)
        #expect(service.activeRunID == nil)
    } catch {
        Issue.record("Unexpected error: \(error)")
    }
}
