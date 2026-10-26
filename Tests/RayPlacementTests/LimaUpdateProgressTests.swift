import Testing
@testable import RayPlacement

@Test func updateProgressUsesOnlyMeasuredDownloadBytes() {
    let half = LimaUpdateProgressPresentation.measuredDownloadFraction(
        canCancelDownload: true, downloadedBytes: 50, totalBytes: 100
    )
    #expect(half == 0.5)
    #expect(LimaUpdateProgressPresentation.measuredDownloadFraction(
        canCancelDownload: true, downloadedBytes: 300, totalBytes: 100
    ) == 1)
    #expect(LimaUpdateProgressPresentation.measuredDownloadFraction(
        canCancelDownload: true, downloadedBytes: -5, totalBytes: 100
    ) == 0)
}

@Test func updateProgressIsIndeterminateOutsideDownload() {
    #expect(LimaUpdateProgressPresentation.measuredDownloadFraction(
        canCancelDownload: false, downloadedBytes: 50, totalBytes: 100
    ) == nil)
    #expect(LimaUpdateProgressPresentation.measuredDownloadFraction(
        canCancelDownload: true, downloadedBytes: 50, totalBytes: 0
    ) == nil)
}
