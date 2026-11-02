import Foundation

/// Extract the root NSString of the common little-endian attributed-body
/// envelope. No archived classes are instantiated and metadata is never text.
/// Unsupported envelopes remain unavailable rather than guessed or truncated.
enum MessagesBodyDecoder {
    static func decode(_ data: Data) -> String? {
        guard data.count <= 256 * 1_024 else { return nil }
        if data.starts(with: Data("bplist".utf8)) {
            guard let object = try? NSKeyedUnarchiver.unarchivedObject(
                ofClasses: [NSAttributedString.self, NSString.self], from: data) else { return nil }
            let text = (object as? NSAttributedString)?.string ?? (object as? String)
            return text.flatMap { $0.utf8.count <= 64 * 1_024 ? $0 : nil }
        }
        let bytes = [UInt8](data)
        let signature = [UInt8]([4, 11]) + Array("streamtyped".utf8)
        guard bytes.starts(with: signature), data.prefix(160).range(of: Data("NSAttributedString".utf8)) != nil,
              let name = data.prefix(192).range(of: Data([0x84, 8] + Array("NSString".utf8))) else { return nil }
        var cursor = name.upperBound
        // NSString version 1, superclass reference, then an unshared '+' value.
        guard cursor + 5 < bytes.count, bytes[cursor] == 1, bytes[cursor + 1] >= 0x92,
              Array(bytes[(cursor + 2)..<(cursor + 5)]) == [0x84, 1, 0x2b] else { return nil }
        cursor += 5
        let head = bytes[cursor]; cursor += 1
        let length: Int
        if head == 0x81 || head == 0x82 {
            let width = head == 0x81 ? 2 : 4
            guard cursor + width <= bytes.count else { return nil }
            var value: UInt32 = 0
            for index in 0..<width { value |= UInt32(bytes[cursor + index]) << (index * 8) }
            length = Int(value); cursor += width
        } else if !(0x80...0x91).contains(head) { length = Int(head) }
        else { return nil }
        guard length <= 64 * 1_024, length < bytes.count - cursor,
              bytes[cursor + length] == 0x86,
              let text = String(bytes: bytes[cursor..<(cursor + length)], encoding: .utf8),
              !text.unicodeScalars.contains(where: { $0.value == 0 }) else { return nil }
        return text
    }
}
