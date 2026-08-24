import Foundation

public enum FormatterDocumentKind: String, CaseIterable, Codable, Sendable {
    case automatic
    case edi
    case json
    case xml

    public var title: String {
        switch self {
        case .automatic: return "Auto Detect"
        case .edi: return "EDI"
        case .json: return "JSON"
        case .xml: return "XML"
        }
    }
}

public enum FormatterOutputStyle: String, CaseIterable, Codable, Sendable {
    case pretty
    case minified

    public var title: String { self == .pretty ? "Pretty" : "Minified" }
}

public enum FormatterDiagnosticSeverity: String, Codable, Sendable {
    case error
    case warning
    case info
}

public struct FormatterDiagnostic: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public let severity: FormatterDiagnosticSeverity
    public let message: String
    public let location: String?

    public init(
        id: UUID = UUID(),
        severity: FormatterDiagnosticSeverity,
        message: String,
        location: String? = nil
    ) {
        self.id = id
        self.severity = severity
        self.message = message
        self.location = location
    }
}

public struct EDIField: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public let segmentIndex: Int
    public let segment: String
    public let elementIndex: Int
    public let value: String

    public init(segmentIndex: Int, segment: String, elementIndex: Int, value: String) {
        self.id = "\(segmentIndex)-\(elementIndex)"
        self.segmentIndex = segmentIndex
        self.segment = segment
        self.elementIndex = elementIndex
        self.value = value
    }

    public var path: String { "\(segment)\(String(format: "%02d", elementIndex))" }
}

public struct EDIMetadata: Hashable, Sendable {
    public let elementDelimiter: Character
    public let segmentDelimiter: Character
    public let componentDelimiter: Character?
    public let transactionSets: [String]
    public let segmentCount: Int
    public let fields: [EDIField]

    public init(
        elementDelimiter: Character,
        segmentDelimiter: Character,
        componentDelimiter: Character?,
        transactionSets: [String],
        segmentCount: Int,
        fields: [EDIField]
    ) {
        self.elementDelimiter = elementDelimiter
        self.segmentDelimiter = segmentDelimiter
        self.componentDelimiter = componentDelimiter
        self.transactionSets = transactionSets
        self.segmentCount = segmentCount
        self.fields = fields
    }
}

public struct DocumentFormatResult: Hashable, Sendable {
    public let kind: FormatterDocumentKind
    public let output: String
    public let inspection: [String]
    public let diagnostics: [FormatterDiagnostic]
    public let edi: EDIMetadata?

    public init(
        kind: FormatterDocumentKind,
        output: String,
        inspection: [String],
        diagnostics: [FormatterDiagnostic],
        edi: EDIMetadata? = nil
    ) {
        self.kind = kind
        self.output = output
        self.inspection = inspection
        self.diagnostics = diagnostics
        self.edi = edi
    }

    public var isValid: Bool { !diagnostics.contains { $0.severity == .error } }
}

public enum DocumentFormatterError: LocalizedError, Equatable {
    case emptyInput
    case unknownFormat
    case invalidJSON(String)
    case invalidXML(String)
    case invalidEDI(String)

    public var errorDescription: String? {
        switch self {
        case .emptyInput: return "Paste text or open a JSON, XML, or EDI file first."
        case .unknownFormat: return "RayPlacement could not identify this document. Choose EDI, JSON, or XML explicitly."
        case .invalidJSON(let detail): return "Invalid JSON: \(detail)"
        case .invalidXML(let detail): return "Invalid XML: \(detail)"
        case .invalidEDI(let detail): return "Invalid EDI: \(detail)"
        }
    }
}

public enum DocumentFormatterService {
    public static func format(
        _ source: String,
        kind requestedKind: FormatterDocumentKind = .automatic,
        style: FormatterOutputStyle = .pretty,
        ediSegmentDelimiter replacementDelimiter: Character? = nil
    ) throws -> DocumentFormatResult {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw DocumentFormatterError.emptyInput }
        let kind = requestedKind == .automatic ? detectKind(trimmed) : requestedKind
        switch kind {
        case .json: return try formatJSON(trimmed, style: style)
        case .xml: return try formatXML(trimmed, style: style)
        case .edi: return try formatEDI(trimmed, style: style, replacementDelimiter: replacementDelimiter)
        case .automatic: throw DocumentFormatterError.unknownFormat
        }
    }

    public static func detectKind(_ source: String) -> FormatterDocumentKind {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("{") || trimmed.hasPrefix("[") { return .json }
        if trimmed.hasPrefix("<") { return .xml }
        if trimmed.hasPrefix("ISA") || trimmed.hasPrefix("GS") || trimmed.hasPrefix("ST") { return .edi }
        return .automatic
    }

    public static func search(_ query: String, in text: String, limit: Int = 200) -> [Int] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return [] }
        return text.components(separatedBy: .newlines).enumerated().compactMap { index, line in
            line.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) == nil ? nil : index + 1
        }.prefix(limit).map { $0 }
    }

    private static func formatJSON(_ source: String, style: FormatterOutputStyle) throws -> DocumentFormatResult {
        do {
            let data = Data(source.utf8)
            let object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
            var options: JSONSerialization.WritingOptions = [.fragmentsAllowed, .withoutEscapingSlashes]
            if style == .pretty { options.formUnion([.prettyPrinted, .sortedKeys]) }
            let output = String(decoding: try JSONSerialization.data(withJSONObject: object, options: options), as: UTF8.self)
            var inspection: [String] = []
            inspectJSON(object, path: "$", into: &inspection, depth: 0)
            return DocumentFormatResult(
                kind: .json,
                output: output,
                inspection: inspection,
                diagnostics: [FormatterDiagnostic(severity: .info, message: "Valid JSON", location: "$" )]
            )
        } catch {
            throw DocumentFormatterError.invalidJSON(error.localizedDescription)
        }
    }

    private static func inspectJSON(_ value: Any, path: String, into lines: inout [String], depth: Int) {
        guard lines.count < 1_000, depth < 32 else { return }
        if let dictionary = value as? [String: Any] {
            lines.append("\(path) · object · \(dictionary.count) field\(dictionary.count == 1 ? "" : "s")")
            for key in dictionary.keys.sorted() {
                inspectJSON(dictionary[key] as Any, path: "\(path).\(key)", into: &lines, depth: depth + 1)
            }
        } else if let array = value as? [Any] {
            lines.append("\(path) · array · \(array.count) item\(array.count == 1 ? "" : "s")")
            for (index, child) in array.prefix(100).enumerated() {
                inspectJSON(child, path: "\(path)[\(index)]", into: &lines, depth: depth + 1)
            }
        } else if value is NSNull {
            lines.append("\(path) · null")
        } else {
            lines.append("\(path) · \(String(describing: value))")
        }
    }

    private static func formatXML(_ source: String, style: FormatterOutputStyle) throws -> DocumentFormatResult {
        do {
            let document = try XMLDocument(data: Data(source.utf8), options: [.nodePreserveAll])
            guard let root = document.rootElement() else {
                throw DocumentFormatterError.invalidXML("The document has no root element.")
            }
            if style == .minified { removeWhitespaceOnlyXMLNodes(from: root) }
            let options: XMLNode.Options = style == .pretty ? [.nodePrettyPrint] : []
            let serialized = String(decoding: document.xmlData(options: options), as: UTF8.self)
            let output = style == .minified
                ? serialized.replacingOccurrences(of: #">\s+<"#, with: "><", options: .regularExpression)
                : serialized
            var inspection: [String] = []
            inspectXML(root, path: "/\(root.name ?? "root")", into: &inspection, depth: 0)
            return DocumentFormatResult(
                kind: .xml,
                output: output,
                inspection: inspection,
                diagnostics: [FormatterDiagnostic(severity: .info, message: "Well-formed XML", location: "/\(root.name ?? "root")")]
            )
        } catch let formatterError as DocumentFormatterError {
            throw formatterError
        } catch {
            throw DocumentFormatterError.invalidXML(error.localizedDescription)
        }
    }

    private static func inspectXML(_ node: XMLElement, path: String, into lines: inout [String], depth: Int) {
        guard lines.count < 1_000, depth < 32 else { return }
        let attributes = node.attributes?.count ?? 0
        let elements = (node.children ?? []).compactMap { $0 as? XMLElement }
        lines.append("\(path) · element · \(attributes) attribute\(attributes == 1 ? "" : "s"), \(elements.count) child\(elements.count == 1 ? "" : "ren")")
        var nameCounts: [String: Int] = [:]
        for element in elements {
            let name = element.name ?? "element"
            let index = nameCounts[name, default: 0]
            nameCounts[name] = index + 1
            inspectXML(element, path: "\(path)/\(name)[\(index + 1)]", into: &lines, depth: depth + 1)
        }
    }

    private static func removeWhitespaceOnlyXMLNodes(from node: XMLNode) {
        for child in node.children ?? [] {
            if child.kind == .text,
               (child.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                child.detach()
            } else {
                removeWhitespaceOnlyXMLNodes(from: child)
            }
        }
    }

    private struct ParsedEDI {
        let segments: [[String]]
        let elementDelimiter: Character
        let segmentDelimiter: Character
        let componentDelimiter: Character?
    }

    private static func formatEDI(
        _ source: String,
        style: FormatterOutputStyle,
        replacementDelimiter: Character?
    ) throws -> DocumentFormatResult {
        let parsed = try parseEDI(source)
        let outputDelimiter = replacementDelimiter ?? parsed.segmentDelimiter
        let output: String
        if style == .minified {
            output = parsed.segments.map { $0.joined(separator: String(parsed.elementDelimiter)) }
                .joined(separator: String(outputDelimiter)) + String(outputDelimiter)
        } else if outputDelimiter.isNewline {
            output = parsed.segments.map { $0.joined(separator: String(parsed.elementDelimiter)) }
                .joined(separator: "\n")
        } else {
            output = parsed.segments.map {
                $0.joined(separator: String(parsed.elementDelimiter)) + String(outputDelimiter)
            }.joined(separator: "\n")
        }

        let fields = parsed.segments.enumerated().flatMap { segmentIndex, elements -> [EDIField] in
            guard let tag = elements.first else { return [] }
            return elements.dropFirst().enumerated().map { elementIndex, value in
                EDIField(segmentIndex: segmentIndex + 1, segment: tag, elementIndex: elementIndex + 1, value: value)
            }
        }
        let transactionSets = parsed.segments.filter { $0.first == "ST" }.compactMap { $0.count > 1 ? $0[1] : nil }
        let metadata = EDIMetadata(
            elementDelimiter: parsed.elementDelimiter,
            segmentDelimiter: parsed.segmentDelimiter,
            componentDelimiter: parsed.componentDelimiter,
            transactionSets: transactionSets,
            segmentCount: parsed.segments.count,
            fields: fields
        )
        let diagnostics = validateEDI(parsed.segments)
        let inspection = parsed.segments.enumerated().map { index, fields in
            let tag = fields.first ?? "?"
            return "\(index + 1). \(tag) · \(max(0, fields.count - 1)) element\(fields.count == 2 ? "" : "s")"
        }
        return DocumentFormatResult(kind: .edi, output: output, inspection: inspection, diagnostics: diagnostics, edi: metadata)
    }

    private static func parseEDI(_ source: String) throws -> ParsedEDI {
        let characters = Array(source)
        guard characters.count >= 3 else { throw DocumentFormatterError.invalidEDI("The document is too short.") }
        let elementDelimiter: Character
        if source.hasPrefix("ISA"), characters.count > 3 {
            elementDelimiter = characters[3]
        } else if let firstTagEnd = characters.firstIndex(where: { !$0.isLetter && !$0.isNumber && !$0.isWhitespace }) {
            elementDelimiter = characters[firstTagEnd]
        } else {
            throw DocumentFormatterError.invalidEDI("No element delimiter was found.")
        }

        let segmentDelimiter = detectEDISegmentDelimiter(source, elementDelimiter: elementDelimiter)
        let normalized = source.replacingOccurrences(of: "\r\n", with: "\n")
        let rawSegments: [String]
        if segmentDelimiter.isNewline {
            rawSegments = normalized.components(separatedBy: .newlines)
        } else {
            rawSegments = normalized.split(separator: segmentDelimiter, omittingEmptySubsequences: true).map(String.init)
        }
        let segments = rawSegments.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
                .split(separator: elementDelimiter, omittingEmptySubsequences: false)
                .map(String.init)
        }.filter { !$0.isEmpty && !$0[0].isEmpty }
        guard !segments.isEmpty else { throw DocumentFormatterError.invalidEDI("No segments were found.") }
        let component = segments.first(where: { $0.first == "ISA" }).flatMap { $0.count > 16 ? $0[16].first : nil }
        return ParsedEDI(
            segments: segments,
            elementDelimiter: elementDelimiter,
            segmentDelimiter: segmentDelimiter,
            componentDelimiter: component
        )
    }

    private static func detectEDISegmentDelimiter(_ source: String, elementDelimiter: Character) -> Character {
        let characters = Array(source)
        if source.hasPrefix("ISA"), characters.count > 105 { return characters[105] }
        for marker in ["GS\(elementDelimiter)", "ST\(elementDelimiter)"] {
            if let range = source.range(of: marker), range.lowerBound > source.startIndex {
                let candidate = source[source.index(before: range.lowerBound)]
                if !candidate.isWhitespace { return candidate }
            }
        }
        if source.contains("~") { return "~" }
        if source.contains("\n") { return "\n" }
        return "~"
    }

    private static func validateEDI(_ segments: [[String]]) -> [FormatterDiagnostic] {
        var diagnostics: [FormatterDiagnostic] = []
        let tags = segments.compactMap(\.first)
        func error(_ message: String, _ location: String? = nil) {
            diagnostics.append(FormatterDiagnostic(severity: .error, message: message, location: location))
        }
        func warning(_ message: String, _ location: String? = nil) {
            diagnostics.append(FormatterDiagnostic(severity: .warning, message: message, location: location))
        }

        if tags.contains("ISA") != tags.contains("IEA") { error("ISA and IEA envelope segments must both be present.", "ISA/IEA") }
        if tags.contains("GS") != tags.contains("GE") { error("GS and GE functional-group segments must both be present.", "GS/GE") }
        if tags.contains("ST") != tags.contains("SE") { error("ST and SE transaction segments must both be present.", "ST/SE") }

        if let isa = segments.first(where: { $0.first == "ISA" }),
           let iea = segments.last(where: { $0.first == "IEA" }),
           isa.count > 13, iea.count > 2, isa[13] != iea[2] {
            error("IEA02 should equal ISA13 (\(isa[13])), but it is \(iea[2]).", "ISA13 / IEA02")
        }
        if let gs = segments.first(where: { $0.first == "GS" }),
           let ge = segments.last(where: { $0.first == "GE" }),
           gs.count > 6, ge.count > 2, gs[6] != ge[2] {
            error("GE02 should equal GS06 (\(gs[6])), but it is \(ge[2]).", "GS06 / GE02")
        }

        var cursor = 0
        let supported = Set(["204", "210", "214", "990", "997"])
        while cursor < segments.count {
            guard segments[cursor].first == "ST" else { cursor += 1; continue }
            let start = cursor
            guard let end = segments[(cursor + 1)...].firstIndex(where: { $0.first == "SE" }) else {
                error("Transaction beginning at segment \(start + 1) has no SE trailer.", "ST")
                break
            }
            let st = segments[start]
            let se = segments[end]
            let type = st.count > 1 ? st[1] : ""
            if !supported.contains(type) {
                warning("Transaction set \(type.isEmpty ? "(missing)" : type) is not one of the built-in 204, 210, 214, 990, or 997 profiles.", "ST01")
            }
            if st.count <= 2 || st[2].isEmpty { error("ST02 transaction control number is required.", "ST02") }
            if st.count > 2, se.count > 2, st[2] != se[2] {
                error("SE02 should equal ST02 (\(st[2])), but it is \(se[2]).", "ST02 / SE02")
            }
            let actualCount = end - start + 1
            if se.count <= 1 || Int(se[1]) != actualCount {
                error("SE01 should report \(actualCount) segments from ST through SE, but it is \(se.count > 1 ? se[1] : "missing").", "SE01")
            }
            validateTransaction(type, segments: Array(segments[start...end]), diagnostics: &diagnostics)
            cursor = end + 1
        }
        if diagnostics.isEmpty {
            diagnostics.append(FormatterDiagnostic(severity: .info, message: "Basic EDI envelope and transaction checks passed."))
        }
        return diagnostics
    }

    private static func validateTransaction(
        _ type: String,
        segments: [[String]],
        diagnostics: inout [FormatterDiagnostic]
    ) {
        let tags = Set(segments.compactMap(\.first))
        let requiredByType: [String: [String]] = [
            "204": ["B2", "B2A"],
            "210": ["B3"],
            "214": ["B10", "AT7"],
            "990": ["B1"],
            "997": ["AK1", "AK9"]
        ]
        for required in requiredByType[type] ?? [] where !tags.contains(required) {
            diagnostics.append(FormatterDiagnostic(
                severity: .warning,
                message: "\(type) usually requires a \(required) segment; none was found.",
                location: required
            ))
        }
    }
}
