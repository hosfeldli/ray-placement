import Foundation

/// A bounded semantic link captured from the currently granted browser page.
public struct SalesforcePageLink: Equatable, Sendable {
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
}

public enum SalesforceCaseResolution: Equatable, Sendable {
    case found(URL)
    case notFound
    case ambiguous(matchCount: Int)
}

/// Resolves a case number only against actual Case-record links present in the
/// current page snapshot. It does not navigate, fetch pages, or broaden site access.
public enum SalesforceCaseResolver {
    private static let maximumLinks = 500

    public static func resolve(
        caseNumber: String,
        pageURL: URL,
        links: [SalesforcePageLink]
    ) -> SalesforceCaseResolution {
        let number = caseNumber.trimmingCharacters(in: .whitespacesAndNewlines)
        guard number.range(of: "^[0-9]{1,32}$", options: .regularExpression) != nil,
              hasSecureOrigin(pageURL) else {
            return .notFound
        }

        let expression = try? NSRegularExpression(
            pattern: "(?<![A-Za-z0-9])\(number)(?![A-Za-z0-9])",
            options: [.caseInsensitive]
        )
        guard let expression else { return .notFound }

        var matchesByURL: [String: URL] = [:]
        for link in links.prefix(maximumLinks) {
            guard [link.text, link.accessibleName, link.title]
                .compactMap({ $0 })
                .contains(where: { containsCaseNumber(number, in: $0, expression: expression) }),
                  let destination = resolvedDestination(link.href, relativeTo: pageURL),
                  isSameSecureOrigin(destination, as: pageURL),
                  isCaseRecordURL(destination) else {
                continue
            }
            matchesByURL[destination.absoluteString] = destination
        }

        let matches = matchesByURL.keys.sorted().compactMap { matchesByURL[$0] }
        switch matches.count {
        case 0:
            return .notFound
        case 1:
            return .found(matches[0])
        default:
            return .ambiguous(matchCount: matches.count)
        }
    }

    private static func containsCaseNumber(
        _ number: String,
        in value: String,
        expression: NSRegularExpression
    ) -> Bool {
        guard value.utf16.count <= 4_096 else { return false }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return expression.firstMatch(in: value, range: range) != nil
    }

    private static func resolvedDestination(_ href: String, relativeTo pageURL: URL) -> URL? {
        guard href.utf16.count <= 4_096,
              !href.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              let destination = URL(string: href, relativeTo: pageURL)?.absoluteURL,
              destination.user == nil,
              destination.password == nil else {
            return nil
        }
        return destination
    }

    private static func hasSecureOrigin(_ url: URL) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return false }
        return components.scheme?.lowercased() == "https"
            && components.host?.isEmpty == false
            && components.user == nil
            && components.password == nil
    }

    private static func isSameSecureOrigin(_ candidate: URL, as pageURL: URL) -> Bool {
        guard let page = URLComponents(url: pageURL, resolvingAgainstBaseURL: false),
              let destination = URLComponents(url: candidate, resolvingAgainstBaseURL: false),
              page.scheme?.lowercased() == "https",
              destination.scheme?.lowercased() == "https",
              let pageHost = page.host?.lowercased(),
              let destinationHost = destination.host?.lowercased() else {
            return false
        }

        return pageHost == destinationHost
            && normalizedPort(page.port) == normalizedPort(destination.port)
    }

    private static func normalizedPort(_ port: Int?) -> Int {
        port ?? 443
    }

    private static func isCaseRecordURL(_ url: URL) -> Bool {
        let path = url.pathComponents
            .filter { $0 != "/" }
            .map { $0.removingPercentEncoding ?? $0 }

        // Salesforce record IDs use the Case key prefix and are 15 or 18 chars.
        func isCaseID(_ value: String) -> Bool {
            (value.count == 15 || value.count == 18)
                && value.lowercased().hasPrefix("500")
                && value.unicodeScalars.allSatisfy(CharacterSet.alphanumerics.contains)
        }

        // Classic Salesforce record URLs use the ID as the first path component.
        if path.count == 1, isCaseID(path[0]) {
            return true
        }

        // Lightning and Experience Cloud URLs identify the object before the ID.
        for index in path.indices {
            guard path[index].caseInsensitiveCompare("Case") == .orderedSame,
                  index + 1 < path.count,
                  isCaseID(path[index + 1]) else {
                continue
            }
            if index == 0 || ["r", "s"].contains(path[index - 1].lowercased()) {
                return true
            }
        }
        return false
    }
}
