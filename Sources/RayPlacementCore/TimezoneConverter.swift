import Foundation

public struct TimezoneConversion: Equatable, Sendable {
    public let instant: Date
    public let sourceTime: String
    public let sourceDate: String
    public let destinationTime: String
    public let destinationDate: String
    public let destinationZone: String

    public init(
        instant: Date,
        sourceTime: String,
        sourceDate: String,
        destinationTime: String,
        destinationDate: String,
        destinationZone: String
    ) {
        self.instant = instant
        self.sourceTime = sourceTime
        self.sourceDate = sourceDate
        self.destinationTime = destinationTime
        self.destinationDate = destinationDate
        self.destinationZone = destinationZone
    }
}

public enum TimezoneConverter {
    public static func convert(
        _ input: String,
        from sourceIdentifier: String,
        to destinationIdentifier: String,
        now: Date = Date()
    ) -> TimezoneConversion? {
        guard let source = TimeZone(identifier: sourceIdentifier),
              let destination = TimeZone(identifier: destinationIdentifier) else { return nil }

        let clean = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return nil }
        let instant: Date
        if clean.caseInsensitiveCompare("now") == .orderedSame {
            instant = now
        } else if let fullDate = parseFullDate(clean, timeZone: source) {
            instant = fullDate
        } else if let time = parseTime(clean, timeZone: source) {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = source
            var components = calendar.dateComponents([.year, .month, .day], from: now)
            let timeComponents = calendar.dateComponents([.hour, .minute, .second], from: time)
            components.hour = timeComponents.hour
            components.minute = timeComponents.minute
            components.second = timeComponents.second
            guard let combined = calendar.date(from: components) else { return nil }
            instant = combined
        } else {
            return nil
        }

        return TimezoneConversion(
            instant: instant,
            sourceTime: format(instant, pattern: "h:mm a", timeZone: source),
            sourceDate: format(instant, pattern: "EEEE, MMM d", timeZone: source),
            destinationTime: format(instant, pattern: "h:mm a", timeZone: destination),
            destinationDate: format(instant, pattern: "EEEE, MMM d", timeZone: destination),
            destinationZone: destination.abbreviation(for: instant) ?? destination.identifier
        )
    }

    private static func parseFullDate(_ input: String, timeZone: TimeZone) -> Date? {
        let formats = [
            "yyyy-MM-dd h:mm a", "yyyy-MM-dd HH:mm", "MMM d, yyyy h:mm a",
            "MMMM d, yyyy h:mm a", "MMM d yyyy h:mm a", "M/d/yyyy h:mm a",
            "M/d/yyyy HH:mm"
        ]
        return formats.lazy.compactMap { parse(input, pattern: $0, timeZone: timeZone) }.first
    }

    private static func parseTime(_ input: String, timeZone: TimeZone) -> Date? {
        let formats = ["h:mm a", "h a", "h:mma", "ha", "HH:mm", "HHmm"]
        return formats.lazy.compactMap { parse(input, pattern: $0, timeZone: timeZone) }.first
    }

    private static func parse(_ input: String, pattern: String, timeZone: TimeZone) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = pattern
        formatter.isLenient = false
        return formatter.date(from: input.uppercased())
    }

    private static func format(_ date: Date, pattern: String, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = pattern
        return formatter.string(from: date)
    }
}
