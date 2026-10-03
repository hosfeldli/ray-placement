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
    print("Zen 1.3.0 status: broad=\(hasBroad), exactExample=\(hasExactExample), interactions=\(hasInteractions)")
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
    print("Zen 1.3.0 read: example.com identity verified")

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
    print("Zen 1.3.0 Open tab: user-approved background navigation verified")
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
    guard case .object(let info) = result,
          case .string(let rawURL)? = info["url"],
          let url = URL(string: rawURL),
          url.host == "example.com",
          url.query == "lima-bridge-acceptance=1" else {
        Issue.record("Zen did not confirm the exact-site background tab")
        return
    }
    print("Zen 1.3.0 exact-site Open tab: user-approved background navigation verified")
}
