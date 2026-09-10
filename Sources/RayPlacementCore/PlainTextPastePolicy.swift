import Foundation

/// Normalizes text selected from a pasteboard without touching Unicode scalars.
/// In particular, emoji sequences, variation selectors, joiners, and skin-tone
/// modifiers remain byte-for-byte equivalent after the line-ending conversion.
public enum PlainTextPastePolicy {
    public static func normalize(_ text: String?) -> String? {
        guard let text, !text.isEmpty else { return nil }
        return text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }
}
