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
    // Two hours gives a full one-hour meeting a generous overrun buffer.
    public static let maximumDuration: TimeInterval = 2 * 60 * 60
    public static let appleSpeechSegmentDuration: TimeInterval = 45
    public static let localWhisperSegmentDuration: TimeInterval = 60
    public static let segmentDuration = appleSpeechSegmentDuration
    public static let recordingBytesPerSecond = 32_000

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
        return Int((boundedDuration * Double(recordingBytesPerSecond)).rounded(.up))
    }
}
