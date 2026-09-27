import Foundation

/// Data supplied by the companion WebExtension after the user explicitly
/// invokes it for the active tab. The host never evaluates page-provided code.
public struct LimaBrowserBridgeLink: Codable, Equatable, Sendable {
    public let href: String
    public let text: String
    public let accessibleName: String?
    public let title: String?

    public init(href: String, text: String = "", accessibleName: String? = nil, title: String? = nil) {
        self.href = href
        self.text = text
        self.accessibleName = accessibleName
        self.title = title
    }

    fileprivate var salesforceLink: SalesforcePageLink {
        SalesforcePageLink(href: href, text: text, accessibleName: accessibleName, title: title)
    }
}

/// Versioned, typed request accepted by Lima's Firefox-compatible native host.
public struct LimaBrowserBridgeRequest: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public let version: Int
    public let requestID: String
    public let command: String
    public let caseNumber: String?
    public let pageURL: String?
    public let links: [LimaBrowserBridgeLink]

    public init(
        version: Int = currentVersion,
        requestID: String,
        command: String,
        caseNumber: String? = nil,
        pageURL: String? = nil,
        links: [LimaBrowserBridgeLink] = []
    ) {
        self.version = version
        self.requestID = requestID
        self.command = command
        self.caseNumber = caseNumber
        self.pageURL = pageURL
        self.links = links
    }
}

public struct LimaBrowserBridgeResponse: Codable, Equatable, Sendable {
    public let version: Int
    public let requestID: String
    public let command: String
    public let ok: Bool
    public let status: String?
    public let recordURL: String?
    public let matchCount: Int?
    public let errorCode: String?

    public init(
        version: Int = LimaBrowserBridgeRequest.currentVersion,
        requestID: String,
        command: String,
        ok: Bool,
        status: String? = nil,
        recordURL: String? = nil,
        matchCount: Int? = nil,
        errorCode: String? = nil
    ) {
        self.version = version
        self.requestID = requestID
        self.command = command
        self.ok = ok
        self.status = status
        self.recordURL = recordURL
        self.matchCount = matchCount
        self.errorCode = errorCode
    }
}

/// Narrow dispatcher for browser requests. Only known, bounded operations are
/// accepted; opening a destination remains a distinct explicit browser action.
public enum LimaBrowserBridgeDispatcher {
    public static let maximumLinks = 500
    public static let maximumFieldLength = 4_096

    public static func handle(_ request: LimaBrowserBridgeRequest) -> LimaBrowserBridgeResponse {
        guard request.version == LimaBrowserBridgeRequest.currentVersion else {
            return failure(request, code: "unsupported_version")
        }
        guard isValidRequestID(request.requestID) else {
            return failure(request, code: "invalid_request_id")
        }

        switch request.command {
        case "ping":
            return LimaBrowserBridgeResponse(
                requestID: request.requestID,
                command: request.command,
                ok: true,
                status: "ready"
            )

        case "salesforce.resolve_case":
            guard let caseNumber = bounded(request.caseNumber),
                  caseNumber.range(of: "^[0-9]{1,32}$", options: .regularExpression) != nil,
                  let pageString = bounded(request.pageURL),
                  let pageURL = URL(string: pageString),
                  request.links.count <= maximumLinks else {
                return failure(request, code: "invalid_case_lookup")
            }

            let links = request.links.compactMap { link -> SalesforcePageLink? in
                guard let href = bounded(link.href), !href.isEmpty else { return nil }
                return SalesforcePageLink(
                    href: href,
                    text: bounded(link.text) ?? "",
                    accessibleName: bounded(link.accessibleName),
                    title: bounded(link.title)
                )
            }

            switch SalesforceCaseResolver.resolve(
                caseNumber: caseNumber,
                pageURL: pageURL,
                links: links
            ) {
            case .found(let url):
                return LimaBrowserBridgeResponse(
                    requestID: request.requestID,
                    command: request.command,
                    ok: true,
                    status: "found",
                    recordURL: url.absoluteString
                )
            case .notFound:
                return LimaBrowserBridgeResponse(
                    requestID: request.requestID,
                    command: request.command,
                    ok: true,
                    status: "not_found"
                )
            case .ambiguous(let matchCount):
                return LimaBrowserBridgeResponse(
                    requestID: request.requestID,
                    command: request.command,
                    ok: true,
                    status: "ambiguous",
                    matchCount: matchCount
                )
            }

        default:
            return failure(request, code: "unsupported_command")
        }
    }

    private static func failure(_ request: LimaBrowserBridgeRequest, code: String) -> LimaBrowserBridgeResponse {
        LimaBrowserBridgeResponse(
            requestID: isValidRequestID(request.requestID) ? request.requestID : "",
            command: String(request.command.prefix(64)),
            ok: false,
            errorCode: code
        )
    }

    private static func isValidRequestID(_ value: String) -> Bool {
        !value.isEmpty
            && value.utf16.count <= 128
            && value.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
    }

    private static func bounded(_ value: String?) -> String? {
        guard let value,
              value.utf16.count <= maximumFieldLength,
              !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            return nil
        }
        return value
    }
}

/// Firefox native messaging frames are a little-endian UInt32 byte count
/// followed by one UTF-8 JSON payload. The size cap also bounds JSON decoding.
public enum FirefoxNativeMessageFrame {
    public static let maximumPayloadBytes = 1_048_576

    public enum Error: Swift.Error, Equatable {
        case payloadTooLarge
        case truncatedHeader
        case truncatedPayload
        case trailingBytes
    }

    public static func encode(_ payload: Data) throws -> Data {
        guard payload.count <= maximumPayloadBytes, payload.count <= Int(UInt32.max) else {
            throw Error.payloadTooLarge
        }
        var length = UInt32(payload.count).littleEndian
        var framed = Data(bytes: &length, count: MemoryLayout<UInt32>.size)
        framed.append(payload)
        return framed
    }

    public static func payloadLength(fromHeader header: Data) throws -> Int {
        guard header.count == MemoryLayout<UInt32>.size else {
            throw header.count < MemoryLayout<UInt32>.size ? Error.truncatedHeader : Error.trailingBytes
        }
        let length = header.withUnsafeBytes { bytes in
            UInt32(littleEndian: bytes.loadUnaligned(as: UInt32.self))
        }
        guard length <= maximumPayloadBytes else { throw Error.payloadTooLarge }
        return Int(length)
    }

    public static func decode(_ framed: Data) throws -> Data {
        guard framed.count >= MemoryLayout<UInt32>.size else { throw Error.truncatedHeader }
        let header = Data(framed.prefix(MemoryLayout<UInt32>.size))
        let length = try payloadLength(fromHeader: header)
        let expectedCount = MemoryLayout<UInt32>.size + length
        guard framed.count >= expectedCount else { throw Error.truncatedPayload }
        guard framed.count == expectedCount else { throw Error.trailingBytes }
        return framed.suffix(length)
    }
}
