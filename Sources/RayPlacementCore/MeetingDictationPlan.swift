import Foundation

public struct MeetingDictationSegment: Equatable, Sendable {
    public let start: TimeInterval
    public let duration: TimeInterval

    public init(start: TimeInterval, duration: TimeInterval) {
        self.start = start
        self.duration = duration
    }
}

public enum MeetingDictationPlan {
    public static let maximumDuration: TimeInterval = 60 * 60
    public static let segmentDuration: TimeInterval = 45
    public static let recordingBitRate = 32_000

    public static func segments(for duration: TimeInterval) -> [MeetingDictationSegment] {
        let boundedDuration = min(max(duration, 0), maximumDuration)
        guard boundedDuration > 0 else { return [] }
        let count = Int(ceil(boundedDuration / segmentDuration))
        return (0..<count).map { index in
            let start = Double(index) * segmentDuration
            return MeetingDictationSegment(
                start: start,
                duration: min(segmentDuration, boundedDuration - start)
            )
        }
    }

    public static func estimatedEncodedByteCount(for duration: TimeInterval) -> Int {
        let boundedDuration = min(max(duration, 0), maximumDuration)
        return Int((boundedDuration * Double(recordingBitRate) / 8).rounded(.up))
    }
}
