import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Pure image conversion used only after a user chooses an export destination.
/// The Screenshot History store remains private; this type does not write files
/// or grant AI/extensions access to saved captures.
enum ScreenshotImageExport {
    enum ExportError: LocalizedError {
        case invalidImage
        case encodingFailed

        var errorDescription: String? {
            switch self {
            case .invalidImage: return "The saved screenshot can no longer be read as an image."
            case .encodingFailed: return "The screenshot could not be exported in that format."
            }
        }
    }

    static func data(_ sourceData: Data,
                     sourceFormat: ScreenshotImageFormat,
                     destinationFormat: ScreenshotImageFormat) throws -> Data {
        guard let source = CGImageSourceCreateWithData(sourceData as CFData, nil),
              CGImageSourceGetType(source) as String? == sourceFormat.typeIdentifier,
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw ExportError.invalidImage
        }
        if sourceFormat == destinationFormat { return sourceData }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output, destinationFormat.typeIdentifier as CFString, 1, nil
        ) else { throw ExportError.encodingFailed }
        let options: CFDictionary? = destinationFormat == .jpeg
            ? [kCGImageDestinationLossyCompressionQuality: 0.90] as CFDictionary
            : nil
        CGImageDestinationAddImage(destination, image, options)
        guard CGImageDestinationFinalize(destination) else {
            throw ExportError.encodingFailed
        }
        return output as Data
    }
}
