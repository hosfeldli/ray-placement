import Foundation
import QuickLookUI

final class FileQuickLookItem: NSObject, QLPreviewItem {
    let previewItemURL: URL?

    init(url: URL) {
        previewItemURL = url
        super.init()
    }
}
