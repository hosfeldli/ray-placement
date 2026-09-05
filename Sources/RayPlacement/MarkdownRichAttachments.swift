import AppKit
import Foundation

@MainActor
protocol MarkdownPersistedAttachment: AnyObject {
    var markdownSource: String { get }
}

@MainActor
final class MarkdownTaskAttachment: NSTextAttachment, MarkdownPersistedAttachment {
    private(set) var checked: Bool
    var onChange: (() -> Void)?
    var markdownSource: String { checked ? "[x]" : "[ ]" }

    init(checked: Bool) {
        self.checked = checked
        super.init(data: Data([0]), ofType: "dev.lima.markdown-task")
        refreshImage()
    }

    required init?(coder: NSCoder) {
        checked = false
        super.init(coder: coder)
        refreshImage()
    }

    func toggle() {
        checked.toggle()
        refreshImage()
        onChange?()
    }

    private func refreshImage() {
        let symbol = checked ? "checkmark.square.fill" : "square"
        let configuration = NSImage.SymbolConfiguration(pointSize: 16, weight: .semibold)
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: checked ? "Completed task" : "Open task")?
            .withSymbolConfiguration(configuration)
    }

    override func attachmentBounds(
        for textContainer: NSTextContainer?,
        proposedLineFragment lineFragment: NSRect,
        glyphPosition position: NSPoint,
        characterIndex charIndex: Int
    ) -> NSRect {
        NSRect(x: 0, y: -3, width: 18, height: 18)
    }
}

@MainActor
final class MarkdownMediaAttachment: NSTextAttachment, MarkdownPersistedAttachment {
    let markdownSource: String
    private let displaySize: NSSize

    init(markdownSource: String, image: NSImage, maximumWidth: CGFloat = 620) {
        self.markdownSource = markdownSource
        let sourceSize = image.size.width > 0 && image.size.height > 0 ? image.size : NSSize(width: 560, height: 260)
        let scale = min(1, maximumWidth / sourceSize.width)
        displaySize = NSSize(width: sourceSize.width * scale, height: sourceSize.height * scale)
        super.init(data: Data([0]), ofType: "dev.lima.markdown-media")
        self.image = image
    }

    required init?(coder: NSCoder) {
        markdownSource = ""
        displaySize = NSSize(width: 560, height: 260)
        super.init(coder: coder)
    }

    override func attachmentBounds(
        for textContainer: NSTextContainer?,
        proposedLineFragment lineFragment: NSRect,
        glyphPosition position: NSPoint,
        characterIndex charIndex: Int
    ) -> NSRect {
        let available = max(240, lineFragment.width - 8)
        let scale = min(1, available / displaySize.width)
        return NSRect(x: 0, y: 0, width: displaySize.width * scale, height: displaySize.height * scale)
    }
}

@MainActor
enum MarkdownNoteAssetStore {
    static func importImage(_ image: NSImage) -> String? {
        guard let data = image.pngData else { return nil }
        return persist(data: data, extension: "png")
    }

    static func importFile(_ source: URL) -> String? {
        guard let data = try? Data(contentsOf: source), NSImage(data: data) != nil else { return nil }
        let ext = source.pathExtension.isEmpty ? "png" : source.pathExtension.lowercased()
        return persist(data: data, extension: ext)
    }

    static func image(for reference: String) -> NSImage? {
        guard let url = resolve(reference) else { return nil }
        return NSImage(contentsOf: url)
    }

    private static func persist(data: Data, extension ext: String) -> String? {
        do {
            try ApplicationPaths.prepare()
            let name = "image-\(UUID().uuidString).\(ext)"
            let destination = ApplicationPaths.noteAssets.appendingPathComponent(name)
            try data.write(to: destination, options: [.atomic])
            return "lima-note-asset://\(name)"
        } catch {
            return nil
        }
    }

    private static func resolve(_ reference: String) -> URL? {
        if reference.hasPrefix("lima-note-asset://") {
            let name = String(reference.dropFirst("lima-note-asset://".count))
                .removingPercentEncoding ?? ""
            guard !name.isEmpty, name == URL(fileURLWithPath: name).lastPathComponent else { return nil }
            return ApplicationPaths.noteAssets.appendingPathComponent(name)
        }
        guard let url = URL(string: reference), url.isFileURL else { return nil }
        return url
    }
}

@MainActor
enum MarkdownRichDocumentCodec {
    static func enrich(_ attributedString: NSAttributedString, onChange: @escaping () -> Void) -> NSAttributedString {
        let output = NSMutableAttributedString(attributedString: attributedString)
        enrichCharts(output)
        enrichImages(output)
        enrichTasks(output, onChange: onChange)
        return output
    }

    private static func enrichTasks(_ output: NSMutableAttributedString, onChange: @escaping () -> Void) {
        replace(pattern: #"(?m)(?<=- )\[([ xX])\](?=\s)"#, in: output) { match, source in
            let checked = source.substring(with: match.range(at: 1)).lowercased() == "x"
            let attachment = MarkdownTaskAttachment(checked: checked)
            attachment.onChange = onChange
            return NSAttributedString(attachment: attachment)
        }
    }

    private static func enrichImages(_ output: NSMutableAttributedString) {
        replace(pattern: #"(?m)^!\[([^\]]*)\]\(([^)]+)\)[ \t]*$"#, in: output) { match, source in
            let reference = source.substring(with: match.range(at: 2))
            guard let image = MarkdownNoteAssetStore.image(for: reference) else { return nil }
            return NSAttributedString(attachment: MarkdownMediaAttachment(
                markdownSource: source.substring(with: match.range),
                image: image
            ))
        }
    }

    private static func enrichCharts(_ output: NSMutableAttributedString) {
        replace(pattern: #"(?ms)^```chart[ \t]*\n(.*?)^```[ \t]*$"#, in: output) { match, source in
            let body = source.substring(with: match.range(at: 1))
            guard let image = MarkdownChartRenderer.render(body) else { return nil }
            return NSAttributedString(attachment: MarkdownMediaAttachment(
                markdownSource: source.substring(with: match.range),
                image: image
            ))
        }
    }

    private static func replace(
        pattern: String,
        in output: NSMutableAttributedString,
        builder: (NSTextCheckingResult, NSString) -> NSAttributedString?
    ) {
        let source = output.string as NSString
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return }
        let matches = expression.matches(in: source as String, range: NSRange(location: 0, length: source.length))
        for match in matches.reversed() {
            var intersectsAttachment = false
            output.enumerateAttribute(.attachment, in: match.range) { value, _, stop in
                if value != nil { intersectsAttachment = true; stop.pointee = true }
            }
            guard !intersectsAttachment, let replacement = builder(match, source) else { continue }
            output.replaceCharacters(in: match.range, with: replacement)
        }
    }
}

@MainActor
private enum MarkdownChartRenderer {
    private struct Point { let label: String; let value: Double }

    static func render(_ body: String) -> NSImage? {
        var title = "Chart"
        var type = "bar"
        var points: [Point] = []
        for rawLine in body.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.lowercased().hasPrefix("title:") {
                title = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces)
            } else if line.lowercased().hasPrefix("type:") {
                type = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces).lowercased()
            } else {
                let pieces = line.split(separator: ",", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                if pieces.count == 2, let value = Double(pieces[1]) { points.append(Point(label: pieces[0], value: value)) }
            }
        }
        guard !points.isEmpty else { return nil }
        let size = NSSize(width: 620, height: 280)
        let image = NSImage(size: size)
        image.lockFocus()
        defer { image.unlockFocus() }
        NSColor(calibratedWhite: 0.08, alpha: 0.94).setFill()
        NSBezierPath(roundedRect: NSRect(origin: .zero, size: size), xRadius: 12, yRadius: 12).fill()
        let titleAttributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 18, weight: .semibold), .foregroundColor: NSColor.white]
        title.draw(at: NSPoint(x: 22, y: 238), withAttributes: titleAttributes)
        let chartRect = NSRect(x: 42, y: 42, width: 548, height: 175)
        NSColor.white.withAlphaComponent(0.12).setStroke()
        let axis = NSBezierPath(); axis.move(to: chartRect.origin); axis.line(to: NSPoint(x: chartRect.minX, y: chartRect.maxY)); axis.move(to: chartRect.origin); axis.line(to: NSPoint(x: chartRect.maxX, y: chartRect.minY)); axis.stroke()
        let maxValue = max(points.map { abs($0.value) }.max() ?? 1, 1)
        let color = LimaAppKitDesign.accent
        if type == "line" {
            let path = NSBezierPath(); path.lineWidth = 3
            for (index, point) in points.enumerated() {
                let x = chartRect.minX + CGFloat(index) * chartRect.width / CGFloat(max(1, points.count - 1))
                let y = chartRect.minY + CGFloat(point.value / maxValue) * chartRect.height
                index == 0 ? path.move(to: NSPoint(x: x, y: y)) : path.line(to: NSPoint(x: x, y: y))
            }
            color.setStroke(); path.stroke()
        } else {
            let slot = chartRect.width / CGFloat(points.count)
            for (index, point) in points.enumerated() {
                let height = max(2, CGFloat(point.value / maxValue) * chartRect.height)
                let rect = NSRect(x: chartRect.minX + CGFloat(index) * slot + 8, y: chartRect.minY, width: max(8, slot - 16), height: height)
                color.withAlphaComponent(0.82).setFill(); NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).fill()
            }
        }
        let labelAttributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 10, weight: .medium), .foregroundColor: NSColor.secondaryLabelColor]
        for (index, point) in points.enumerated() {
            let slot = chartRect.width / CGFloat(points.count)
            String(point.label.prefix(14)).draw(at: NSPoint(x: chartRect.minX + CGFloat(index) * slot + 4, y: 18), withAttributes: labelAttributes)
        }
        return image
    }
}

private extension NSImage {
    var pngData: Data? {
        guard let tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffRepresentation) else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }
}
