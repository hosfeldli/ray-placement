import Foundation
import Testing
@testable import RayPlacement
import RayPlacementCore

/// Opt-in acceptance against the user's signed Zen companion. Never run in CI.
/// Use only a public example.com tab; never print unrelated tab URLs or page text.
@Test @MainActor func browserBridgeLiveZenReadAcceptance() async throws {
    guard ProcessInfo.processInfo.environment["LIMA_LIVE_ZEN_ACCEPTANCE"] == "1" else { return }
    let suite = "lima-live-zen-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    let service = BrowserBridgeService(
        defaults: defaults, socketURL: BrowserBridgeIdentity.socketURL, registry: TaskRegistry()
    )
    defer {
        service.stop()
        defaults.removePersistentDomain(forName: suite)
    }
    service.enabled = true
    for _ in 0..<150 where service.sessions.isEmpty {
        try await Task.sleep(nanoseconds: 100_000_000)
    }
    #expect(!service.sessions.isEmpty)
    guard !service.sessions.isEmpty else { return }

    let status = try await service.request("bridge.status")
    guard case .object(let statusFields) = status,
          case .array(let origins)? = statusFields["origins"],
          case .array(let capabilities)? = statusFields["capabilities"] else {
        Issue.record("Signed Zen companion did not return valid grant status")
        return
    }
    let hasBroad = origins.contains(.string("https://*/*"))
    let hasExactExample = origins.contains(.string("https://example.com/*"))
    let hasInteractions = capabilities.contains(.string("browser_interaction_v1"))
    print("Zen companion status: broad=\(hasBroad), exactExample=\(hasExactExample), interactions=\(hasInteractions)")
    // A signed companion may have an exact-site grant without the optional broad grant.
    #expect(hasBroad || hasExactExample)
    #expect(hasInteractions)

    func exampleTabID() async throws -> Double? {
        let result = try await service.request("browser.tabs")
        guard case .object(let fields) = result, case .array(let tabs)? = fields["tabs"] else {
            throw BrowserBridgeError.invalidResponse
        }
        for tab in tabs {
            guard case .object(let info) = tab,
                  case .string(let rawURL)? = info["url"],
                  URL(string: rawURL)?.host == "example.com",
                  case .number(let id)? = info["id"] else { continue }
            return id
        }
        return nil
    }

    defaults.set(false, forKey: AIComputerActionPolicy.broadBrowserGrantsKey)
    let off = try await exampleTabID()
    if !hasExactExample { #expect(off == nil) }

    defaults.set(true, forKey: AIComputerActionPolicy.broadBrowserGrantsKey)
    var on: Double?
    for _ in 0..<20 {
        on = try await exampleTabID()
        if on != nil { break }
        try await Task.sleep(nanoseconds: 250_000_000)
    }
    let tabID = try #require(on)
    let page = try await service.request("browser.read", arguments: ["tabID": .number(tabID)])
    guard case .object(let pageFields) = page,
          case .string(let url)? = pageFields["url"],
          URL(string: url)?.host == "example.com" else {
        Issue.record("Signed Zen companion returned an unexpected page identity")
        return
    }
    let ianaLinks: [String] = {
        guard case .array(let links)? = pageFields["links"] else { return [] }
        return links.compactMap { link in
            guard case .object(let fields) = link,
                  case .string(let href)? = fields["href"],
                  let url = URL(string: href),
                  url.host == "iana.org" || url.host == "www.iana.org" else { return nil }
            return href
        }
    }()
    #expect(ianaLinks.contains("https://iana.org/help/example-domains"))
    print("Zen companion read: example.com identity and IANA hyperlink verified")

    defaults.set(false, forKey: AIComputerActionPolicy.broadBrowserGrantsKey)
    let offAgain = try await exampleTabID()
    if !hasExactExample { #expect(offAgain == nil) }
}

/// Opt-in real popup approval check. The test cannot approve its own action;
/// a person must approve the pending Open tab request in the Zen companion.
@Test @MainActor func browserBridgeLiveZenOpenApproval() async throws {
    guard ProcessInfo.processInfo.environment["LIMA_LIVE_ZEN_OPEN"] == "1" else { return }
    let suite = "lima-live-zen-open-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    let service = BrowserBridgeService(
        defaults: defaults, socketURL: BrowserBridgeIdentity.socketURL, registry: TaskRegistry()
    )
    defer {
        service.stop()
        defaults.removePersistentDomain(forName: suite)
    }
    service.enabled = true
    for _ in 0..<150 where service.sessions.isEmpty {
        try await Task.sleep(nanoseconds: 100_000_000)
    }
    guard !service.sessions.isEmpty else {
        Issue.record("Signed Zen companion did not connect")
        return
    }
    let status = try await service.request("bridge.status")
    guard case .object(let fields) = status,
          case .array(let origins)? = fields["origins"],
          origins.contains(.string("https://*/*")) else {
        Issue.record("Signed Zen companion did not report its broad HTTPS grant")
        return
    }
    let arguments: [String: JSONValue] = [
        "url": .string("https://example.org/"),
        "active": .bool(false)
    ]
    do {
        _ = try await service.request("browser.open", arguments: arguments)
        Issue.record("Broad-only Open tab unexpectedly passed with the experiment off")
        return
    } catch BrowserBridgeError.broadGrantDisabled {
        // Expected: no browser action reached the companion.
    }
    defaults.set(true, forKey: AIComputerActionPolicy.broadBrowserGrantsKey)
    print("Zen companion approval pending: Open https://example.org/ in a background tab")
    let result = try await service.request("browser.open", arguments: arguments)
    guard case .object(let info) = result,
          case .string(let url)? = info["url"],
          URL(string: url)?.host == "example.org" else {
        Issue.record("Zen did not confirm the approved background tab")
        return
    }
    print("Zen companion Open tab: user-approved background navigation verified")
}

/// Exact-site navigation acceptance for installations that deliberately leave
/// the optional broad HTTPS grant disabled. Run only while a person can approve
/// the companion popup immediately; it creates one background example.com tab.
@Test @MainActor func browserBridgeLiveZenExactOpenApproval() async throws {
    guard ProcessInfo.processInfo.environment["LIMA_LIVE_ZEN_EXACT_OPEN"] == "1" else { return }
    let suite = "lima-live-zen-exact-open-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    let service = BrowserBridgeService(
        defaults: defaults, socketURL: BrowserBridgeIdentity.socketURL, registry: TaskRegistry()
    )
    defer {
        service.stop()
        defaults.removePersistentDomain(forName: suite)
    }
    service.enabled = true
    for _ in 0..<150 where service.sessions.isEmpty {
        try await Task.sleep(nanoseconds: 100_000_000)
    }
    guard !service.sessions.isEmpty else {
        Issue.record("Signed Zen companion did not connect")
        return
    }
    let status = try await service.request("bridge.status")
    guard case .object(let fields) = status,
          case .array(let origins)? = fields["origins"],
          origins.contains(.string("https://example.com/*")) else {
        Issue.record("Signed Zen companion did not report an exact example.com grant")
        return
    }
    defaults.set(false, forKey: AIComputerActionPolicy.broadBrowserGrantsKey)
    print("Zen companion approval pending: Open https://example.com/?lima-bridge-acceptance=1 in a background tab")
    let result = try await service.request(
        "browser.open",
        arguments: [
            "url": .string("https://example.com/?lima-bridge-acceptance=1"),
            "active": .bool(false)
        ]
    )
    // Firefox/Zen can return a provisional URL from tabs.create while the new
    // background tab is still loading. Verify the returned tab ID after it loads.
    guard case .object(let info) = result,
          case .number(let openedID)? = info["id"] else {
        Issue.record("Zen did not return an opened background tab ID")
        return
    }
    var verified = false
    for attempt in 0..<20 {
        let listed = try await service.request("browser.tabs")
        guard case .object(let fields) = listed,
              case .array(let tabs)? = fields["tabs"] else {
            Issue.record("Zen did not return granted tabs after opening")
            return
        }
        let openedTab = tabs.contains { tab in
            guard case .object(let tabInfo) = tab,
                  case .number(let id)? = tabInfo["id"], id == openedID,
                  case .string(let rawURL)? = tabInfo["url"],
                  let url = URL(string: rawURL) else { return false }
            return url.host == "example.com" && url.query == "lima-bridge-acceptance=1"
        }
        if openedTab {
            let page = try await service.request("browser.read", arguments: ["tabID": .number(openedID)])
            guard case .object(let pageFields) = page,
                  case .string(let rawURL)? = pageFields["url"],
                  let url = URL(string: rawURL),
                  url.host == "example.com",
                  url.query == "lima-bridge-acceptance=1" else {
                Issue.record("Zen opened the tab but could not read its expected page")
                return
            }
            verified = true
            break
        }
        if attempt < 19 { try await Task.sleep(nanoseconds: 250_000_000) }
    }
    guard verified else {
        Issue.record("Zen did not confirm the exact-site background tab after loading")
        return
    }
    print("Zen companion exact-site Open tab: user-approved navigation and page read verified")
}

/// Retrospective verification for a previously approved navigation. This never
/// creates another tab or presents an approval prompt.
@Test @MainActor func browserBridgeLiveZenVerifyOpenedExampleTab() async throws {
    guard ProcessInfo.processInfo.environment["LIMA_LIVE_ZEN_VERIFY_OPEN"] == "1" else { return }
    let suite = "lima-live-zen-verify-open-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    let service = BrowserBridgeService(
        defaults: defaults, socketURL: BrowserBridgeIdentity.socketURL, registry: TaskRegistry()
    )
    defer {
        service.stop()
        defaults.removePersistentDomain(forName: suite)
    }
    service.enabled = true
    for _ in 0..<150 where service.sessions.isEmpty {
        try await Task.sleep(nanoseconds: 100_000_000)
    }
    guard !service.sessions.isEmpty else {
        Issue.record("Signed Zen companion did not connect")
        return
    }
    let listed = try await service.request("browser.tabs")
    guard case .object(let fields) = listed,
          case .array(let tabs)? = fields["tabs"] else {
        Issue.record("Signed Zen companion did not return granted tabs")
        return
    }
    let matchingID: Double? = tabs.compactMap { tab in
        guard case .object(let info) = tab,
              case .string(let rawURL)? = info["url"],
              let url = URL(string: rawURL),
              url.host == "example.com",
              url.query == "lima-bridge-acceptance=1",
              case .number(let id)? = info["id"] else { return nil }
        return id
    }.first
    guard let matchingID else {
        Issue.record("Previously approved exact-site background tab was not found")
        return
    }
    let page = try await service.request("browser.read", arguments: ["tabID": .number(matchingID)])
    guard case .object(let pageFields) = page,
          case .string(let rawURL)? = pageFields["url"],
          let url = URL(string: rawURL),
          url.host == "example.com",
          url.query == "lima-bridge-acceptance=1" else {
        Issue.record("Previously approved tab could not be read at its expected URL")
        return
    }
    print("Zen companion exact-site Open tab: previously approved navigation and page read verified")
}
