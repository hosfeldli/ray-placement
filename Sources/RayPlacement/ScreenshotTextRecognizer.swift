import Foundation
import ImageIO
import Vision

/// Optional, local-only OCR for user-saved Screenshot History captures.
/// The image is downsampled before Vision processing and text never leaves Lima.
enum ScreenshotTextRecognizer {
    static func recognize(_ data: Data) throws -> String? {
        try recognize(data, fast: false)
    }

    static func recognizeQuickly(_ data: Data) throws -> String? {
        // Fast recognition is ideal for selection-sized text. Retry accurately
        // only when Vision finds nothing, retaining support for small type.
        if let text = try recognize(data, fast: true) { return text }
        return try recognize(data, fast: false)
    }

    private static func recognize(_ data: Data, fast: Bool) throws -> String? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: fast ? 2560 : 4096
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = fast ? .fast : .accurate
        request.usesLanguageCorrection = !fast
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let text = String(lines.joined(separator: "\n").prefix(20_000))
        return text.isEmpty ? nil : text
    }
}
