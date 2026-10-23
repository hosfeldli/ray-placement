import Foundation

enum BrowserAIControlMode: String, CaseIterable, Codable, Sendable {
    case off
    case readOnly
    case navigate
    case fullControl

    var title: String {
        switch self {
        case .off: "Off"
        case .readOnly: "Read Only"
        case .navigate: "Navigate"
        case .fullControl: "Full Control"
        }
    }

    var canRead: Bool { self != .off }
    var canNavigate: Bool { self == .navigate || self == .fullControl }
    var canInteract: Bool { self == .fullControl }
}

enum BrowserReadiness: String, Codable, Sendable {
    case loading
    case hydrating
    case readyWithContent
    case readyEmpty
    case unstable
    case timedOut
    case error
}

struct BrowserPageIdentity: Codable, Equatable, Sendable {
    let documentID: String
    let routeGeneration: UInt64
    let mutationRevision: UInt64
    let userRevision: UInt64
    let snapshotRevision: UInt64
    let url: String
}

struct BrowserTargetState: Codable, Equatable, Sendable {
    let enabled: Bool
    let selected: Bool?
    let checked: Bool?
    let expanded: Bool?
    let required: Bool
    let sensitive: Bool
    let invalid: Bool?
    let blockedByModal: Bool
    /// Presence only. Never contains the field's value.
    var filled: Bool? = nil
}

struct BrowserSelectOption: Codable, Equatable, Sendable {
    let label: String
    let selected: Bool
    let enabled: Bool
}

struct BrowserDialogSummary: Codable, Equatable, Sendable {
    let role: String
    let label: String
    let modal: Bool
    let targetIDs: [String]
    let frameID: String
}

struct BrowserFormSummary: Codable, Equatable, Sendable {
    let id: String
    let label: String
    let frameID: String
    let fields: [BrowserTarget]
    let submitTargets: [BrowserTarget]
}

struct BrowserFormRead: Codable, Equatable, Sendable {
    let tabID: UUID?
    let identity: BrowserPageIdentity
    let readiness: BrowserReadiness
    let forms: [BrowserFormSummary]
    let unassociatedFields: [BrowserTarget]
    let activeDialog: BrowserDialogSummary?
}

struct BrowserTarget: Codable, Equatable, Sendable, Identifiable {
    let id: String
    let role: String
    let label: String
    let destination: String?
    let relationship: String?
    let x: Double
    let y: Double
    let width: Double
    let height: Double
    let frameID: String
    let sensitive: Bool
    var kind: String? = nil
    var availableActions: [String]? = nil
    var state: BrowserTargetState? = nil
    var options: [BrowserSelectOption]? = nil
    var formID: String? = nil
    var formLabel: String? = nil
    var isSubmit: Bool? = nil
    /// Classified confidential input, distinct from consequential actions.
    var confidential: Bool = false
    var secureKind: String? = nil

    func blockedByModal() -> BrowserTarget {
        var blocked = self
        blocked.availableActions = []
        if let state {
            blocked.state = BrowserTargetState(
                enabled: false, selected: state.selected, checked: state.checked,
                expanded: state.expanded, required: state.required,
                sensitive: state.sensitive, invalid: state.invalid,
                blockedByModal: true, filled: state.filled
            )
        }
        return blocked
    }
}

struct BrowserSemanticItem: Codable, Equatable, Sendable {
    let stableKey: String
    let role: String
    let text: String
    let linkTargetIDs: [String]
    let controlTargetIDs: [String]
    var frameID: String? = nil
}

struct BrowserFrameContext: Codable, Equatable, Sendable {
    let id: String
    let url: String
    let origin: String
    let readiness: BrowserReadiness
}

struct BrowserDiagnostics: Codable, Equatable, Sendable {
    let textLength: Int
    let linkCount: Int
    let controlCount: Int
    let headingCount: Int
    let semanticRowCount: Int
    let shadowRootCount: Int
    let frameCount: Int
    let quietMS: Int
    let truncated: Bool
}

struct BrowserSemanticMatch: Codable, Equatable, Sendable {
    let role: String
    let text: String
    let targetID: String?
    let url: String?
    let stableKey: String?
    let frameID: String?
    let sensitive: Bool
    var kind: String? = nil
    var availableActions: [String]? = nil
    var state: BrowserTargetState? = nil
}

struct BrowserSecureFieldStatus: Codable, Equatable, Sendable {
    let kind: String
    let label: String
    let frameID: String
    let required: Bool
    let filled: Bool
}

struct BrowserPageSnapshot: Codable, Equatable, Sendable {
    let identity: BrowserPageIdentity
    let readiness: BrowserReadiness
    let title: String
    let text: String
    let links: [BrowserTarget]
    let controls: [BrowserTarget]
    let headings: [String]
    let rows: [BrowserSemanticItem]
    let diagnostics: BrowserDiagnostics
    var tabID: UUID? = nil
    var frameID: String? = nil
    var frameContexts: [BrowserFrameContext]? = nil
    var activeDialog: BrowserDialogSummary? = nil

    var secureFields: [BrowserSecureFieldStatus] {
        controls.compactMap { target in
            guard target.confidential, let kind = target.secureKind else { return nil }
            return BrowserSecureFieldStatus(kind: kind, label: target.label,
                                            frameID: target.frameID,
                                            required: target.state?.required == true,
                                            filled: target.state?.filled == true)
        }
    }

    func formRead() -> BrowserFormRead {
        let fieldKinds: Set<String> = [
            "textbox", "searchbox", "combobox", "listbox", "checkbox", "radio",
            "switch", "spinbutton", "slider", "date", "time"
        ]
        let fields = controls.filter { fieldKinds.contains($0.kind ?? "") }
        var groups: [BrowserFormSummary] = []
        var seen: Set<String> = []
        for target in controls {
            guard let id = target.formID, !seen.contains(id) else { continue }
            seen.insert(id)
            let members = controls.filter { $0.formID == id }
            groups.append(BrowserFormSummary(
                id: id, label: target.formLabel ?? "Form", frameID: target.frameID,
                fields: members.filter { fieldKinds.contains($0.kind ?? "") },
                submitTargets: members.filter { $0.isSubmit == true }
            ))
        }
        return BrowserFormRead(
            tabID: tabID, identity: identity, readiness: readiness,
            forms: groups, unassociatedFields: fields.filter { $0.formID == nil },
            activeDialog: activeDialog
        )
    }

    func find(_ query: String) -> [BrowserSemanticMatch] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return [] }
        let headingMatches = headings.filter { $0.localizedStandardContains(term) }.map {
            BrowserSemanticMatch(role: "heading", text: $0, targetID: nil, url: nil,
                                 stableKey: nil, frameID: nil, sensitive: false)
        }
        let rowMatches = rows.filter { $0.text.localizedStandardContains(term) }.map {
            BrowserSemanticMatch(role: $0.role, text: $0.text, targetID: nil, url: nil,
                                 stableKey: $0.stableKey, frameID: $0.frameID, sensitive: false)
        }
        let targetMatches = (links + controls).filter {
            $0.label.localizedStandardContains(term) ||
            ($0.destination?.localizedStandardContains(term) ?? false)
        }.map {
            BrowserSemanticMatch(role: $0.role, text: $0.label, targetID: $0.id,
                                 url: $0.destination, stableKey: nil, frameID: $0.frameID,
                                 sensitive: $0.sensitive, kind: $0.kind,
                                 availableActions: $0.availableActions, state: $0.state)
        }
        // Plain paragraph text is still discoverable even when it has no
        // heading, row, link, or control wrapper. Return bounded context, not
        // the full page body or an invented actionable target.
        var textMatches: [BrowserSemanticMatch] = []
        var searchStart = text.startIndex
        while textMatches.count < 12, searchStart < text.endIndex,
              let range = text.range(of: term, options: [.caseInsensitive, .diacriticInsensitive],
                                     range: searchStart..<text.endIndex) {
            let start = text.index(range.lowerBound, offsetBy: -80, limitedBy: text.startIndex) ?? text.startIndex
            let end = text.index(range.upperBound, offsetBy: 80, limitedBy: text.endIndex) ?? text.endIndex
            let excerpt = String(text[start..<end]).replacingOccurrences(of: "\n", with: " ")
            textMatches.append(BrowserSemanticMatch(
                role: "text", text: excerpt, targetID: nil, url: nil,
                stableKey: nil, frameID: nil, sensitive: false
            ))
            searchStart = range.upperBound
        }
        return headingMatches + rowMatches + targetMatches + textMatches
    }

    static func aggregate(_ main: BrowserPageSnapshot, children: [BrowserPageSnapshot],
                          expectedFrameCount: Int,
                          frameOrigins: [String: String] = [:]) -> BrowserPageSnapshot {
        let snapshots = [main] + children
        let modalInMainFrame = main.activeDialog?.modal == true
        let allLinks = snapshots.flatMap(\.links).map { target in
            modalInMainFrame && target.frameID != "main"
                ? target.blockedByModal() : target
        }
        let allControls = snapshots.flatMap(\.controls).map { target in
            modalInMainFrame && target.frameID != "main"
                ? target.blockedByModal() : target
        }
        let links = Array(allLinks.prefix(400))
        let controls = Array(allControls.prefix(max(0, 400 - links.count)))
        let allHeadings = snapshots.flatMap(\.headings)
        let allRows = snapshots.flatMap(\.rows)
        let headings = Array(allHeadings.prefix(120))
        let rows = Array(allRows.prefix(160))
        let allText = snapshots.map(\.text).joined(separator: "\n")
        let text = String(allText.prefix(48_000))
        let truncated = snapshots.contains { $0.diagnostics.truncated } ||
            expectedFrameCount > snapshots.count || allLinks.count + allControls.count > 400 ||
            allHeadings.count > 120 || allRows.count > 160 || allText.count > 48_000
        let diagnostics = BrowserDiagnostics(
            textLength: text.count, linkCount: links.count, controlCount: controls.count,
            headingCount: headings.count, semanticRowCount: rows.count,
            shadowRootCount: snapshots.reduce(0) { $0 + $1.diagnostics.shadowRootCount },
            frameCount: max(expectedFrameCount, snapshots.count),
            quietMS: snapshots.map(\.diagnostics.quietMS).min() ?? 0,
            truncated: truncated
        )
        // The main document can be quiet while an embedded app is still
        // hydrating. Aggregate readiness across every observed frame; missing
        // frames remain unstable rather than masquerading as an empty page.
        let readiness: BrowserReadiness
        if expectedFrameCount > snapshots.count || snapshots.contains(where: {
            [.unstable, .timedOut, .error].contains($0.readiness)
        }) {
            readiness = .unstable
        } else if snapshots.contains(where: { $0.readiness == .loading }) {
            readiness = .loading
        } else if snapshots.contains(where: { $0.readiness == .hydrating }) {
            readiness = .hydrating
        } else if snapshots.contains(where: { $0.readiness == .readyWithContent }) {
            readiness = .readyWithContent
        } else {
            readiness = .readyEmpty
        }
        var result = BrowserPageSnapshot(
            identity: main.identity, readiness: readiness, title: main.title,
            text: text, links: links, controls: controls, headings: headings,
            rows: rows, diagnostics: diagnostics
        )
        result.frameID = "main"
        result.activeDialog = snapshots.compactMap(\.activeDialog).first
        result.frameContexts = snapshots.map { snapshot in
            let url = snapshot.identity.url
            let components = URLComponents(string: url)
            let host = components?.host
            let fallbackOrigin = host.map { value in
                let port = components?.port.map { ":\($0)" } ?? ""
                return "\(components?.scheme ?? "https")://\(value)\(port)"
            } ?? "opaque"
            let id = snapshot.frameID ?? "main"
            return BrowserFrameContext(
                id: id, url: url,
                origin: frameOrigins[id] ?? fallbackOrigin, readiness: snapshot.readiness
            )
        }
        // Any frame can echo a value entered into a protected field in another
        // frame. Once a protected field is filled on a multi-frame page, keep
        // only protected-field presence until navigation; per-frame redaction
        // cannot prove that other frames did not transform or repeat the value.
        if snapshots.count > 1 &&
            snapshots.contains(where: { $0.secureFields.contains(where: \.filled) }) {
            let safeLabels = [
                "password": "Password or secret", "one_time_code": "One-time code",
                "card_security_code": "Card security code", "card_expiration": "Card expiration",
                "card_number": "Card number", "bank_account": "Bank account",
                "government_id": "Government ID"
            ]
            let safeControls = controls.filter(\.confidential).map { target in
                var safe = BrowserTarget(
                    id: target.id, role: "textbox",
                    label: safeLabels[target.secureKind ?? ""] ?? "Protected field",
                    destination: nil, relationship: nil,
                    x: target.x, y: target.y, width: target.width, height: target.height,
                    frameID: target.frameID, sensitive: true
                )
                safe.kind = "textbox"
                safe.availableActions = ["request_secure_input"]
                safe.state = target.state
                safe.confidential = true
                safe.secureKind = target.secureKind
                return safe
            }
            let safeText = "Protected information is present in an embedded frame. Continue on the website."
            let safeDiagnostics = BrowserDiagnostics(
                textLength: safeText.count, linkCount: 0, controlCount: safeControls.count,
                headingCount: 0, semanticRowCount: 0,
                shadowRootCount: diagnostics.shadowRootCount,
                frameCount: diagnostics.frameCount, quietMS: diagnostics.quietMS,
                truncated: diagnostics.truncated
            )
            var safe = BrowserPageSnapshot(
                identity: main.identity, readiness: readiness,
                title: "Protected Browser page", text: safeText,
                links: [], controls: safeControls, headings: [], rows: [],
                diagnostics: safeDiagnostics
            )
            safe.frameID = "main"
            safe.frameContexts = result.frameContexts
            return safe
        }
        return result
    }
}

enum BrowserRuntimeError: LocalizedError {
    case missingTab
    case missingSnapshot
    case staleTarget
    case pageChangedByUser
    case invalidDestination
    case noVerifiedDestination
    case controlDisabled
    case userPaused
    case sensitiveTarget
    case screenshotProtected
    case privatePageIncomplete
    case targetOccluded
    case targetNotInteractable
    case commitApprovalRequired
    case unsupportedAction

    var errorDescription: String? {
        switch self {
        case .missingTab: "The Lima browser tab is no longer open."
        case .missingSnapshot: "Read this tab before using a semantic target."
        case .staleTarget: "The page changed. Read it again before acting on this target."
        case .pageChangedByUser: "The user changed this page. Read it again before acting on a target."
        case .invalidDestination: "Only HTTPS or loopback HTTP (localhost, 127.0.0.1, or [::1]) destinations without embedded credentials are supported."
        case .noVerifiedDestination: "This link-like target has no verified destination; activate it in the current tab and read the resulting page."
        case .controlDisabled: "This action is not available in the current Browser AI Control mode."
        case .userPaused: "AI was explicitly paused for this tab. Resume AI in the Browser workspace, then read the page again."
        case .sensitiveTarget: "Sensitive fields and forms are always protected."
        case .screenshotProtected: "This page contains sensitive controls or content the Browser could not account for; no screenshot was saved."
        case .privatePageIncomplete: "The Browser could not account for all page or frame content, so it withheld AI-visible content."
        case .targetOccluded: "Another page layer covers this target. Resolve the visible dialog or overlay, then read the page again."
        case .targetNotInteractable: "This target is disabled or no longer visible. Read the page again before acting."
        case .commitApprovalRequired: "A final web action requires explicit approval for this exact tool call."
        case .unsupportedAction: "This semantic target does not support the requested action."
        }
    }
}

/// Holds revisioned semantic snapshots and validates opaque targets away from
/// the WebKit/UI actor. WKWebView itself is never sent across this boundary.
actor BrowserRuntime {
    static let shared = BrowserRuntime()
    private var snapshots: [UUID: BrowserPageSnapshot] = [:]
    private var frameIdentities: [UUID: [String: BrowserPageIdentity]] = [:]

    func replace(_ snapshot: BrowserPageSnapshot,
                 frameIdentities: [String: BrowserPageIdentity] = [:], for tabID: UUID) {
        snapshots[tabID] = snapshot
        self.frameIdentities[tabID] = frameIdentities
    }

    func snapshot(for tabID: UUID) -> BrowserPageSnapshot? {
        snapshots[tabID]
    }

    func identity(tabID: UUID, frameID: String) throws -> BrowserPageIdentity {
        guard let snapshot = snapshots[tabID] else { throw BrowserRuntimeError.missingSnapshot }
        if frameID == "main" { return snapshot.identity }
        guard let identity = frameIdentities[tabID]?[frameID] else {
            throw BrowserRuntimeError.staleTarget
        }
        return identity
    }

    func remove(tabID: UUID) {
        snapshots.removeValue(forKey: tabID)
        frameIdentities.removeValue(forKey: tabID)
    }

    func resolve(tabID: UUID, targetID: String, link: Bool) throws -> (BrowserPageIdentity, BrowserTarget) {
        guard let snapshot = snapshots[tabID] else { throw BrowserRuntimeError.missingSnapshot }
        let targets = link ? snapshot.links : snapshot.controls
        guard let target = targets.first(where: { $0.id == targetID }) else {
            throw BrowserRuntimeError.staleTarget
        }
        guard !target.sensitive else { throw BrowserRuntimeError.sensitiveTarget }
        let identity: BrowserPageIdentity
        if target.frameID == "main" {
            identity = snapshot.identity
        } else if let frameIdentity = frameIdentities[tabID]?[target.frameID] {
            identity = frameIdentity
        } else {
            throw BrowserRuntimeError.staleTarget
        }
        return (identity, target)
    }

    func resolveAny(tabID: UUID, targetID: String) throws -> BrowserTarget {
        guard let snapshot = snapshots[tabID] else { throw BrowserRuntimeError.missingSnapshot }
        guard let target = (snapshot.links + snapshot.controls).first(where: { $0.id == targetID }) else {
            throw BrowserRuntimeError.staleTarget
        }
        guard !target.sensitive else { throw BrowserRuntimeError.sensitiveTarget }
        return target
    }

    static func safeLinkDestination(_ target: BrowserTarget) -> URL? {
        guard target.role == "link", !target.sensitive,
              target.relationship == "normal" || target.relationship == "new_tab",
              let raw = target.destination else { return nil }
        return safeDestination(raw)
    }

    static func safeDestination(_ raw: String) -> URL? {
        guard let components = URLComponents(string: raw),
              components.user == nil, components.password == nil,
              let host = components.host, !host.isEmpty,
              let url = components.url else { return nil }
        switch components.scheme?.lowercased() {
        case "https":
            break
        case "http":
            // Development previews may use cleartext only on exact loopback hosts.
            // Do not widen this to private-network addresses or subdomains.
            guard ["localhost", "127.0.0.1", "[::1]"].contains(host.lowercased()),
                  components.port.map({ (1...65_535).contains($0) }) ?? true else { return nil }
        default:
            return nil
        }
        return url
    }

    static func addressDestination(_ input: String) -> URL? {
        let address = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !address.isEmpty else { return nil }
        if address.contains("://") { return safeDestination(address) }
        // A schemeless loopback address is a local development preview; all
        // other schemeless addresses keep the existing HTTPS default.
        return safeDestination("http://" + address) ?? safeDestination("https://" + address)
    }
}

/// Executed in a named WebKit content world, never in the page's own JS world.
/// Targets live only until the next snapshot or any observed DOM/route change.
enum BrowserSemanticScript {
    static let world = "LimaSemantic"
    static let frameHandler = "limaSemanticFrame"

    static let install = #"""
    (() => {
      if (globalThis.__limaSemantic) return;
      const state = {
        documentID: crypto.randomUUID?.() || String(Date.now()) + Math.random(), routeGeneration: 0,
        frameID: window === window.top ? "main" : (crypto.randomUUID?.() || String(Date.now()) + Math.random()),
        mutationRevision: 0, userRevision: 0, snapshotRevision: 0,
        lastMutationAt: performance.now(), lastURL: location.href,
        targets: new Map(), visualHits: new Map(),
        frameReports: new Map(), frameGeometry: new Map()
      };
      globalThis.__limaSemantic = state;
      try { window.webkit.messageHandlers.limaSemanticFrame.postMessage({frameID: state.frameID}); } catch {}
      // Frames report through parent windows because WKFrameInfo has no viewport
      // rectangle. Match the sender to an actual iframe rather than trusting
      // page-supplied coordinates; actions still use revisioned WKFrameInfo.
      const geometryMarker = "lima-semantic-frame-geometry-v1";
      const reportOwnFrame = () => {
        if (window === window.parent) return;
        try {
          window.parent.postMessage({
            marker: geometryMarker, frameID: state.frameID, ownFrame: true,
            x: 0, y: 0, scaleX: 1, scaleY: 1,
            clipX: 0, clipY: 0, clipWidth: innerWidth, clipHeight: innerHeight
          }, "*");
        } catch {}
      };
      const publishFrameReport = (frameID, report) => {
        const element = Array.from(document.querySelectorAll("iframe,frame"))
          .find(frame => frame.contentWindow === report.source);
        if (!element || !element.isConnected) {
          state.frameReports.delete(frameID);
          state.frameGeometry.delete(frameID);
          return;
        }
        const rect = element.getBoundingClientRect();
        const scaleX = rect.width / Math.max(1, element.offsetWidth);
        const scaleY = rect.height / Math.max(1, element.offsetHeight);
        if (!Number.isFinite(scaleX) || !Number.isFinite(scaleY)) return;
        const data = report.data;
        const x = rect.x + element.clientLeft * scaleX + data.x * scaleX;
        const y = rect.y + element.clientTop * scaleY + data.y * scaleY;
        const contentX = rect.x + element.clientLeft * scaleX;
        const contentY = rect.y + element.clientTop * scaleY;
        const contentWidth = element.clientWidth * scaleX;
        const contentHeight = element.clientHeight * scaleY;
        const incomingClipX = contentX + data.clipX * scaleX;
        const incomingClipY = contentY + data.clipY * scaleY;
        const clipX = Math.max(contentX, incomingClipX, 0);
        const clipY = Math.max(contentY, incomingClipY, 0);
        const clipRight = Math.min(contentX + contentWidth,
          incomingClipX + data.clipWidth * scaleX, innerWidth);
        const clipBottom = Math.min(contentY + contentHeight,
          incomingClipY + data.clipHeight * scaleY, innerHeight);
        const geometry = {
          marker: geometryMarker, frameID, ownFrame: false, x, y,
          scaleX: data.scaleX * scaleX, scaleY: data.scaleY * scaleY,
          clipX, clipY, clipWidth: Math.max(0, clipRight - clipX),
          clipHeight: Math.max(0, clipBottom - clipY)
        };
        state.frameGeometry.set(frameID, geometry);
        if (window !== window.parent) {
          try { window.parent.postMessage(geometry, "*"); } catch {}
        }
      };
      window.addEventListener("message", event => {
        const data = event.data;
        if (!data || data.marker !== geometryMarker ||
            typeof data.frameID !== "string" || data.frameID.length > 100 ||
            !Number.isFinite(data.x) || !Number.isFinite(data.y) ||
            !Number.isFinite(data.scaleX) || !Number.isFinite(data.scaleY) ||
            !Number.isFinite(data.clipX) || !Number.isFinite(data.clipY) ||
            !Number.isFinite(data.clipWidth) || !Number.isFinite(data.clipHeight)) return;
        if (!Array.from(document.querySelectorAll("iframe,frame"))
              .some(frame => frame.contentWindow === event.source)) return;
        if (data.ownFrame === true) {
          // A navigated iframe gets a new frame ID. Retire geometry for its
          // prior document and descendants instead of exhausting the cap.
          for (const [knownID, report] of state.frameReports) {
            if (report.source !== event.source) continue;
            state.frameReports.delete(knownID);
            state.frameGeometry.delete(knownID);
          }
        }
        if (!state.frameReports.has(data.frameID) && state.frameReports.size >= 32) return;
        state.frameReports.set(data.frameID, {source: event.source, data});
        publishFrameReport(data.frameID, {source: event.source, data});
      });
      let geometryScheduled = false;
      const refreshFrameGeometry = () => {
        if (geometryScheduled) return;
        geometryScheduled = true;
        requestAnimationFrame(() => {
          geometryScheduled = false;
          reportOwnFrame();
          for (const [frameID, report] of state.frameReports) {
            publishFrameReport(frameID, report);
          }
        });
      };
      new MutationObserver(() => {
        state.mutationRevision++;
        state.lastMutationAt = performance.now();
        refreshFrameGeometry();
      }).observe(document, {subtree: true, childList: true, characterData: true, attributes: true});
      addEventListener("scroll", refreshFrameGeometry, true);
      addEventListener("resize", refreshFrameGeometry);
      addEventListener("pageshow", refreshFrameGeometry);
      reportOwnFrame();
      const userChangedPage = event => {
        if (!event.isTrusted) return;
        state.userRevision++;
        state.targets.clear();
      };
      for (const name of ["pointerdown", "keydown", "wheel", "touchstart"]) {
        document.addEventListener(name, userChangedPage, {capture: true, passive: true});
      }
      const routeCheck = () => {
        if (state.lastURL !== location.href) {
          state.lastURL = location.href;
          state.routeGeneration++;
          state.targets.clear();
          state.lastMutationAt = performance.now();
        }
      };
      for (const method of ["pushState", "replaceState"]) {
        const original = history[method];
        history[method] = function(...args) {
          const result = original.apply(this, args);
          routeCheck();
          return result;
        };
      }
      addEventListener("popstate", routeCheck);
      addEventListener("hashchange", routeCheck);
      addEventListener("pageshow", routeCheck);
      setInterval(routeCheck, 200);
    })();
    """#

    static let frameGeometry = #"""
    const state = globalThis.__limaSemantic;
    if (!state || window !== window.top) return null;
    const geometry = state.frameGeometry.get(frameID);
    if (!geometry || geometry.clipWidth <= 0 || geometry.clipHeight <= 0) return null;
    return JSON.stringify(geometry);
    """#

    static let snapshot = #"""
    const state = globalThis.__limaSemantic;
    if (!state) throw new Error("semantic_observer_unavailable");
    if (state.lastURL !== location.href) {
      state.lastURL = location.href;
      state.routeGeneration++;
      state.lastMutationAt = performance.now();
    }
    state.snapshotRevision++;
    state.targets.clear();
    state.visualHits.clear();
    const links = [], controls = [], headings = [], rowElements = [];
    const shadowTextParts = [];
    const formIDs = new Map();
    const visibleDialogs = Array.from(document.querySelectorAll(
      "dialog[open],[role=dialog],[role=alertdialog],[popover]"
    )).filter(element => {
      const rect = element.getBoundingClientRect();
      const style = getComputedStyle(element);
      return rect.width > 0 && rect.height > 0 &&
        style.display !== "none" && style.visibility !== "hidden";
    });
    const activeDialogElement = visibleDialogs.at(-1) || null;
    const activeModal = visibleDialogs.filter(element =>
      element.getAttribute("aria-modal") === "true" ||
      element.getAttribute("role") === "alertdialog" ||
      (element.localName === "dialog" && element.hasAttribute("open"))
    ).at(-1) || null;
    state.activeModal = activeModal;
    let shadowRootCount = 0, embeddedFrameCount = 0, truncated = false, inspected = 0;
    let shadowTextLength = 0, shadowTextNodes = 0;
    const maxTargets = 240;
    const visible = element => {
      const rect = element.getBoundingClientRect();
      const style = getComputedStyle(element);
      return rect.width > 0 && rect.height > 0 &&
        style.display !== "none" && style.visibility !== "hidden" &&
        rect.bottom >= 0 && rect.top <= innerHeight &&
        rect.right >= 0 && rect.left <= innerWidth;
    };
    const secureKind = element => {
      if (!element.matches("input,textarea,[contenteditable=true]")) return null;
      const type = (element.getAttribute("type") || "").toLowerCase();
      const autocomplete = (element.getAttribute("autocomplete") || "").toLowerCase();
      const hint = [element.name, element.id, autocomplete,
        element.getAttribute("aria-label"), element.getAttribute("placeholder"),
        element.labels?.[0]?.innerText].filter(Boolean).join(" ").toLowerCase();
      if (type === "password" || /password|passcode|credential|secret|api.?key|access.?token/.test(hint)) return "password";
      if (autocomplete.includes("one-time-code") || /one.?time.?code|otp|verification.?code|security.?code/.test(hint)) return "one_time_code";
      if (autocomplete.includes("cc-csc") || /cvv|cvc|card.?security/.test(hint)) return "card_security_code";
      if (autocomplete.includes("cc-exp") || /card.?expir|expiry|expiration/.test(hint)) return "card_expiration";
      if (autocomplete.includes("cc-number") || /card.?number|credit.?card|debit.?card|\bpan\b/.test(hint)) return "card_number";
      if (/routing.?number|bank.?account|iban|swift.?code/.test(hint)) return "bank_account";
      if (/social.?security|\bssn\b|government.?id|passport.?number/.test(hint)) return "government_id";
      return null;
    };
    const secureLabels = {
      password: "Password or secret", one_time_code: "One-time code",
      card_security_code: "Card security code", card_expiration: "Card expiration",
      card_number: "Card number", bank_account: "Bank account",
      government_id: "Government ID"
    };
    const secureValues = [];
    let shortSecureValue = false, scannedSecure = 0;
    const collectSecureValues = root => {
      for (const node of root.querySelectorAll("*")) {
        if (++scannedSecure > 20000) { truncated = true; break; }
        if (node.shadowRoot) collectSecureValues(node.shadowRoot);
        if (!secureKind(node)) continue;
        const value = String(node.isContentEditable ? node.textContent : node.value || "");
        if (!value) continue;
        if (value.length < 3) shortSecureValue = true;
        else if (secureValues.length < 120) secureValues.push(value);
        else truncated = true;
      }
    };
    collectSecureValues(document);
    const redact = raw => {
      let value = String(raw || "");
      if (shortSecureValue) return "[protected content]";
      for (const secret of secureValues) {
        const variants = [secret, encodeURIComponent(secret),
          encodeURIComponent(secret).replace(/%20/g, "+")];
        if (/^[\d\s-]+$/.test(secret)) variants.push(secret.replace(/[\s-]/g, ""));
        for (const variant of variants) {
          if (variant.length >= 3) value = value.split(variant).join("[redacted]");
        }
      }
      return value.replace(/(?:\d[ -]?){13,19}/g, "[redacted]");
    };
    state.redact = redact;
    const label = element => {
      const confidential = secureKind(element);
      if (confidential) return secureLabels[confidential];
      const ids = (element.getAttribute("aria-labelledby") || "").trim().split(/\s+/).filter(Boolean);
      const labelledBy = ids.map(id =>
        element.getRootNode().getElementById?.(id) || document.getElementById(id)
      ).filter(Boolean).map(node => node.innerText || node.textContent || "").join(" ");
      const submitLabel = element.matches("input[type=submit],input[type=button],input[type=reset]")
        ? element.getAttribute("value") : null;
      return redact(element.getAttribute("aria-label") || labelledBy ||
        element.getAttribute("title") || element.labels?.[0]?.innerText ||
        element.getAttribute("alt") || submitLabel || element.innerText ||
        element.getAttribute("placeholder") || "").trim().slice(0, 240);
    };
    const sensitive = element => {
      const type = (element.getAttribute("type") || "").toLowerCase();
      const form = element.form || element.closest("form");
      const dialog = element.closest("dialog,[role=dialog],[role=alertdialog]") ||
        element.getRootNode().host?.closest("dialog,[role=dialog],[role=alertdialog]");
      const context = element.closest("form,section,article,[role=group]") ||
        element.getRootNode().host?.closest("form,section,article,[role=group]");
      const contextHeading = [dialog, form, context].map(node =>
        node?.querySelector("h1,h2,h3,[role=heading],legend")?.textContent
      ).filter(Boolean).join(" ");
      const hint = [element.name, element.id, element.autocomplete,
        element.getAttribute("aria-label"), element.getAttribute("aria-description"),
        element.getAttribute("placeholder"), element.getAttribute("title"),
        element.getAttribute("value"), element.getAttribute("data-action"),
        element.getAttribute("data-destructive"), element.labels?.[0]?.innerText,
        element.innerText, form?.getAttribute("action"),
        dialog?.getAttribute("aria-label"), form?.getAttribute("aria-label"),
        context?.getAttribute("aria-label"), contextHeading
      ].filter(Boolean).join(" ").toLowerCase();
      const visualHint = [element.getAttribute("aria-label"), element.getAttribute("title"),
        element.getAttribute("data-label")].filter(Boolean).join(" ");
      const protectedVisual = element.localName === "canvas" &&
        /password|passcode|otp|one.?time.?code|card.?number|credit.?card|cvv|cvc|bank.?account|routing.?number|social.?security|ssn/i.test(visualHint);
      return Boolean(secureKind(element)) || protectedVisual || ["file", "hidden"].includes(type) ||
        Boolean(element.closest("[data-destructive],[data-danger]")) ||
        /delete|remove|erase|destroy|close.?account|transfer|send.?money|wire|withdraw|refund|cancel.?subscription|sign.?out|log.?out|deactivate|revoke|purge|terminate|irreversible|permanent.?delete|reset.?password/i.test(hint);
    };
    state.isSensitive = sensitive;
    state.secureKind = secureKind;
    const semanticRole = element => {
      const declared = element.getAttribute("role");
      if (declared) return declared.trim().split(/\s+/)[0];
      if (element.localName === "a" || element.localName === "area") return "link";
      if (element.localName === "button") return "button";
      if (element.localName === "textarea" || element.isContentEditable) return "textbox";
      if (element.localName === "select") return element.multiple ? "listbox" : "combobox";
      if (element.localName === "input") {
        const type = (element.type || "text").toLowerCase();
        if (type === "checkbox" || type === "radio") return type;
        if (type === "search") return "searchbox";
        if (type === "number") return "spinbutton";
        if (type === "date" || type === "time" || type === "datetime-local") return type;
        if (["submit", "button", "reset", "image"].includes(type)) return "button";
        return "textbox";
      }
      return element.localName;
    };
    const add = (array, element, role, destination, relationship) => {
      if (links.length + controls.length >= maxTargets) { truncated = true; return; }
      const rect = element.getBoundingClientRect();
      const id = "t_" + state.frameID + "_" + state.snapshotRevision + "_" + state.targets.size;
      state.targets.set(id, element);
      const protectedTarget = sensitive(element);
      const confidential = secureKind(element);
      const host = element.getRootNode().host;
      const blockedByModal = Boolean(activeModal &&
        !activeModal.contains(element) && !(host && activeModal.contains(host)));
      const enabled = !blockedByModal &&
        !element.matches(":disabled,[aria-disabled=true]") &&
        !element.closest("[inert]");
      const nativeText = element.matches(
        "textarea,input:not([type]),input[type=text],input[type=search],input[type=email],input[type=url],input[type=tel],input[type=number],input[type=date],input[type=time],input[type=datetime-local]"
      ) || element.isContentEditable;
      const nativeSelect = element.localName === "select";
      const submitControl = element.matches(
        "button:not([type=button]):not([type=reset]),input[type=submit],input[type=image]"
      ) && Boolean(element.form || element.closest("form"));
      const kind = role === "datetime-local" ? "date" : role;
      const boolAttribute = name => {
        const value = element.getAttribute(name);
        return value === "true" ? true : value === "false" ? false : null;
      };
      const checked = element.matches("input[type=checkbox],input[type=radio]")
        ? element.checked : boolAttribute("aria-checked");
      const selected = element.localName === "option" ? element.selected :
        boolAttribute("aria-selected");
      const stateInfo = {
        enabled, selected, checked, expanded: boolAttribute("aria-expanded"),
        required: element.required === true || element.getAttribute("aria-required") === "true",
        sensitive: protectedTarget,
        filled: confidential ? Boolean(element.isContentEditable ? element.textContent : element.value) : null,
        invalid: boolAttribute("aria-invalid") ??
          (element.willValidate && !element.validity.valid ? true : null),
        blockedByModal
      };
      const formElement = element.form || element.closest("form,[role=form]") ||
        host?.closest("form,[role=form]");
      let formID = null, formLabel = null;
      if (formElement) {
        if (!formIDs.has(formElement)) {
          formIDs.set(formElement, "f_" + state.frameID + "_" +
            state.snapshotRevision + "_" + formIDs.size);
        }
        formID = formIDs.get(formElement);
        formLabel = redact(formElement.getAttribute("aria-label") ||
          formElement.querySelector("legend,h1,h2,h3,[role=heading]")?.textContent ||
          formElement.id || "Form").trim().slice(0, 160);
      }
      const availableActions = confidential ? ["request_secure_input"] :
        protectedTarget || !enabled ? [] :
        destination && relationship !== "download" ?
          ["activate", "open_current_tab", "open_new_tab", "open_background_tab"] :
        relationship === "unverified" || relationship === "download" ? [] :
        submitControl ? ["focus", "submit"] :
        nativeSelect ? ["focus", "select"] :
        nativeText ? ["focus", "type", "set_value", "clear"] :
        ["checkbox", "radio", "switch"].includes(kind) ? ["activate", "focus", "toggle"] :
        ["button", "link", "tab", "menuitem", "option", "gridcell", "combobox", "genericClickable"].includes(kind)
          ? ["activate", "focus"] : [];
      if (nativeSelect && element.options.length > 60) truncated = true;
      const options = nativeSelect ? Array.from(element.options).slice(0, 60).map(option => ({
        label: redact(option.label || option.textContent || "").trim().slice(0, 160),
        selected: option.selected, enabled: !option.disabled
      })) : null;
      array.push({
        id, role, kind, availableActions, state: stateInfo, options,
        formID, formLabel, isSubmit: submitControl,
        confidential: Boolean(confidential), secureKind: confidential,
        label: label(element), destination: destination || null,
        relationship: relationship || null,
        x: rect.x, y: rect.y, width: rect.width, height: rect.height,
        frameID: state.frameID, sensitive: protectedTarget
      });
    };
    const collectShadowText = root => {
      const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
      while (walker.nextNode()) {
        if (++shadowTextNodes > 20000) { truncated = true; break; }
        const node = walker.currentNode;
        const parent = node.parentElement;
        if (!parent || ["script", "style"].includes(parent.localName) || !visible(parent)) continue;
        const value = (node.textContent || "").replace(/\\s+/g, " ").trim();
        if (!value) continue;
        const remaining = 48000 - shadowTextLength;
        if (remaining <= 0) { truncated = true; break; }
        const part = value.slice(0, Math.min(remaining, 500));
        shadowTextParts.push(redact(part));
        shadowTextLength += part.length + 1;
        if (part.length < value.length) truncated = true;
      }
    };
    const walk = root => {
      const elements = root.querySelectorAll("*");
      for (const element of elements) {
        if (++inspected > 20000) { truncated = true; break; }
        if (element.shadowRoot) {
          shadowRootCount++;
          collectShadowText(element.shadowRoot);
          walk(element.shadowRoot);
        }
        const tag = element.localName;
        if (tag === "iframe" || tag === "frame") embeddedFrameCount++;
        if (!visible(element)) continue;
        if (/^h[1-6]$/.test(tag) && headings.length < 80) headings.push(label(element));
        const role = semanticRole(element);
        if (["tr", "li", "article"].includes(tag) ||
            ["row", "listitem", "article"].includes(role)) {
          if (rowElements.length < 120) rowElements.push({element, role});
          else truncated = true;
        }
        if (tag === "a" || tag === "area" || role === "link") {
          const raw = element.getAttribute("href") || element.getAttribute("data-href") || element.getAttribute("data-url");
          let destination = null;
          try {
            if (raw) {
              const url = new URL(raw, document.baseURI);
              const loopback = ["localhost", "127.0.0.1", "[::1]"].includes(url.hostname.toLowerCase());
              if (url.protocol === "https:" || (url.protocol === "http:" && loopback)) destination = url.href;
            }
          } catch {}
          const relationship = element.hasAttribute("download") ? "download" :
            element.getAttribute("target") === "_blank" ? "new_tab" : "normal";
          if (destination) {
            add(links, element, "link", destination, relationship);
          } else {
            // Keep JS-driven links semantically link-like. An unsafe href is
            // not equivalent to an absent href and must not be clicked around
            // the verified-destination policy.
            add(controls, element, "link", null, raw ? "unverified" : "scripted");
          }
        } else if (["button", "input", "textarea", "select"].includes(tag) ||
                   ["button", "textbox", "searchbox", "combobox", "listbox",
                    "option", "checkbox", "radio", "switch", "spinbutton", "slider",
                    "tab", "menuitem", "gridcell", "date", "time"].includes(role) ||
                   element.getAttribute("contenteditable") === "true") {
          add(controls, element, role, null, null);
        } else if (element.tabIndex >= 0 &&
                   (element.onclick || element.hasAttribute("data-action"))) {
          add(controls, element, "genericClickable", null, null);
        } else if ((tag === "canvas" || element.hasAttribute("aria-label")) &&
                   sensitive(element)) {
          // Include sensitive nonsemantic surfaces in the snapshot so private
          // screenshots cannot bypass ordinary target-based redaction.
          add(controls, element, "protectedVisual", null, null);
        }
      }
    };
    walk(document);
    const stableHash = value => {
      let hash = 2166136261;
      for (let i = 0; i < value.length; i++) {
        hash ^= value.charCodeAt(i);
        hash = Math.imul(hash, 16777619);
      }
      return (hash >>> 0).toString(36);
    };
    const rows = rowElements.map(({element, role}) => {
      const rowText = redact(element.innerText || "").replace(/\s+/g, " ").trim().slice(0, 500);
      const linkTargetIDs = links.filter(target => element.contains(state.targets.get(target.id))).map(target => target.id);
      const controlTargetIDs = controls.filter(target => element.contains(state.targets.get(target.id))).map(target => target.id);
      const evidence = redact(element.getAttribute("data-key") || element.getAttribute("data-id") ||
        element.id || element.getAttribute("aria-rowindex") ||
        element.querySelector("a[href]")?.getAttribute("href") || rowText);
      return {
        stableKey: "row_" + stableHash(state.frameID + ":" + role + ":" + evidence), role,
        text: rowText, linkTargetIDs, controlTargetIDs, frameID: state.frameID
      };
    }).filter(row => row.text || row.linkTargetIDs.length || row.controlTargetIDs.length);
    const activeDialog = activeDialogElement ? {
      role: activeDialogElement.getAttribute("role") ||
        (activeDialogElement.localName === "dialog" ? "dialog" : "popover"),
      label: redact(activeDialogElement.getAttribute("aria-label") ||
        activeDialogElement.querySelector("h1,h2,h3,[role=heading]")?.textContent ||
        "Dialog").trim().slice(0, 160),
      modal: activeDialogElement === activeModal,
      targetIDs: controls.filter(target =>
        activeDialogElement.contains(state.targets.get(target.id))
      ).map(target => target.id).slice(0, 120),
      frameID: state.frameID
    } : null;
    const bodyText = document.body?.innerText || "";
    let text = redact(bodyText.slice(0, 48000));
    for (const part of shadowTextParts) {
      const remaining = 48000 - text.length;
      if (remaining <= 0) { truncated = true; break; }
      text += "\\n" + part.slice(0, Math.max(0, remaining - 1));
    }
    const frameCount = 1 + embeddedFrameCount;
    const quietMS = Math.max(0, Math.floor(performance.now() - state.lastMutationAt));
    const hasContent = text.trim().length > 0 || links.length > 0 || controls.length > 0;
    const readiness = document.readyState === "loading" ? "loading" :
      quietMS < 500 ? "hydrating" : hasContent ? "readyWithContent" : "readyEmpty";
    const payload = {
      identity: {
        documentID: state.documentID, routeGeneration: state.routeGeneration,
        mutationRevision: state.mutationRevision, userRevision: state.userRevision,
        snapshotRevision: state.snapshotRevision,
        url: location.href
      },
      readiness, title: redact(document.title.slice(0, 300)), text, frameID: state.frameID,
      links, controls, headings, rows, activeDialog,
      diagnostics: {
        textLength: text.length, linkCount: links.length, controlCount: controls.length,
        headingCount: headings.length, semanticRowCount: rows.length, shadowRootCount, frameCount,
        quietMS, truncated: truncated || bodyText.length + shadowTextLength > 48000
      }
    };
    return JSON.stringify(payload);
    """#

    /// Returns only geometry. No confidential values cross into Swift.
    static let screenshotRedaction = #"""
    const state = globalThis.__limaSemantic;
    if (!state || state.lastURL !== location.href) throw new Error("stale_target");
    const rects = [];
    const secrets = [];
    // Capture safety must not depend on a prior semantic snapshot. Visual-only
    // observation installs the isolated world but never calls snapshot().
    const secureKind = element => {
      if (!element.matches("input,textarea,[contenteditable=true]")) return null;
      const type = (element.getAttribute("type") || "").toLowerCase();
      const autocomplete = (element.getAttribute("autocomplete") || "").toLowerCase();
      const hint = [element.name, element.id, autocomplete,
        element.getAttribute("aria-label"), element.getAttribute("placeholder"),
        element.labels?.[0]?.innerText].filter(Boolean).join(" ").toLowerCase();
      if (type === "password" || /password|passcode|credential|secret|api.?key|access.?token/.test(hint)) return "password";
      if (autocomplete.includes("one-time-code") || /one.?time.?code|otp|verification.?code|security.?code/.test(hint)) return "one_time_code";
      if (autocomplete.includes("cc-csc") || /cvv|cvc|card.?security/.test(hint)) return "card_security_code";
      if (autocomplete.includes("cc-exp") || /card.?expir|expiry|expiration/.test(hint)) return "card_expiration";
      if (autocomplete.includes("cc-number") || /card.?number|credit.?card|debit.?card|\bpan\b/.test(hint)) return "card_number";
      if (/routing.?number|bank.?account|iban|swift.?code/.test(hint)) return "bank_account";
      if (/social.?security|\bssn\b|government.?id|passport.?number/.test(hint)) return "government_id";
      return null;
    };
    const protectedCanvas = element => {
      if (element.localName !== "canvas") return false;
      const hint = [element.getAttribute("aria-label"), element.getAttribute("title"),
        element.getAttribute("data-label")].filter(Boolean).join(" ");
      return /password|passcode|otp|one.?time.?code|card.?number|credit.?card|cvv|cvc|bank.?account|routing.?number|social.?security|ssn/i.test(hint);
    };
    let inspected = 0, complete = true, frameCount = 0;
    const addRect = node => {
      const box = node?.getBoundingClientRect?.();
      if (!box || box.width <= 0 || box.height <= 0) return;
      if (rects.length >= 240) { complete = false; return; }
      rects.push({x: box.x, y: box.y, width: box.width, height: box.height});
    };
    const walk = root => {
      for (const node of root.querySelectorAll("*")) {
        if (++inspected > 20000) { complete = false; break; }
        if (node.shadowRoot) walk(node.shadowRoot);
        if (node.localName === "iframe" || node.localName === "frame") {
          frameCount++;
          addRect(node);
        }
        if (protectedCanvas(node)) addRect(node);
        const kind = secureKind(node);
        if (!kind) continue;
        addRect(node);
        const value = String(node.isContentEditable ? node.textContent : node.value || "");
        if (!value) continue;
        secrets.push(value);
        addRect(node.closest("form,section,article,[role=group]") ||
          node.getRootNode().host?.closest("form,section,article,[role=group]") ||
          document.body);
      }
    };
    walk(document);
    if (secrets.some(secret => secret.length < 3)) addRect(document.body);
    if (secrets.length) {
      const variants = secrets.flatMap(secret => [secret, encodeURIComponent(secret),
        encodeURIComponent(secret).replace(/%20/g, "+")]);
      const containsSecret = value => variants.some(secret =>
        secret.length >= 3 && String(value || "").includes(secret));
      const visitText = root => {
        const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
        while (walker.nextNode()) {
          if (++inspected > 40000) { complete = false; break; }
          const node = walker.currentNode;
          const value = node.textContent || "";
          if (!secrets.some(secret => value.includes(secret)) &&
              !/(?:\d[ -]?){13,19}/.test(value)) continue;
          const range = document.createRange();
          range.selectNodeContents(node);
          addRect(range);
        }
      };
      visitText(document.body);
      let inspectedAttributes = 0;
      const visitElements = root => {
        for (const node of root.querySelectorAll("*")) {
          if (++inspectedAttributes > 20000) { complete = false; break; }
          if (node.shadowRoot) {
            visitText(node.shadowRoot);
            visitElements(node.shadowRoot);
          }
          if (node.localName === "canvas") addRect(node);
          if (Array.from(node.attributes || []).some(attribute =>
              containsSecret(attribute.value))) addRect(node);
        }
      };
      visitElements(document);
      // A reflected value may span descendants or a site-controlled paint.
      // Mask the whole page rather than release those pixels.
      if (containsSecret(document.body?.innerText)) {
        addRect(document.body);
      }
    }
    return JSON.stringify({
      identity: {documentID: state.documentID, routeGeneration: state.routeGeneration,
        mutationRevision: state.mutationRevision, userRevision: state.userRevision,
        snapshotRevision: state.snapshotRevision, url: location.href},
      complete, frameCount, hasFilledSecureField: secrets.length > 0, rects
    });
    """#

    static let visualHitTest = #"""
    const state = globalThis.__limaSemantic;
    if (!state || state.documentID !== documentID ||
        state.routeGeneration !== routeGeneration ||
        state.mutationRevision !== mutationRevision ||
        state.userRevision !== userRevision ||
        state.snapshotRevision !== snapshotRevision ||
        state.lastURL !== location.href) throw new Error("stale_target");
    if (!Number.isFinite(x) || !Number.isFinite(y) ||
        x < 0 || y < 0 || x >= innerWidth || y >= innerHeight) {
      throw new Error("target_not_interactable");
    }
    const deepestAt = (pointX, pointY) => {
      let found = document.elementFromPoint(pointX, pointY);
      for (let depth = 0; depth < 8 && found?.shadowRoot; depth++) {
        const inner = found.shadowRoot.elementFromPoint(pointX, pointY);
        if (!inner || inner === found) break;
        found = inner;
      }
      return found;
    };
    const composedContains = (ancestor, descendant) => {
      let node = descendant;
      for (let depth = 0; depth < 32 && node; depth++) {
        if (node === ancestor) return true;
        node = node.parentElement || node.getRootNode()?.host;
      }
      return false;
    };
    const hit = deepestAt(x, y);
    if (state.activeModal?.isConnected && !composedContains(state.activeModal, hit)) {
      throw new Error("target_occluded");
    }
    if (!hit || hit.localName === "iframe" || hit.localName === "frame") {
      throw new Error("unsupported_action");
    }
    let element = hit;
    while (element && element !== document.body) {
      const style = getComputedStyle(element);
      if (element.localName === "canvas" || element.onclick ||
          element.hasAttribute("data-action") || style.cursor === "pointer" ||
          element.matches("button,a,input,select,textarea,[role]")) break;
      element = element.parentElement || element.getRootNode().host;
    }
    if (!element || element === document.body || !element.isConnected ||
        element.matches(":disabled,[aria-disabled=true],[inert]") ||
        element.closest("[inert]")) throw new Error("target_not_interactable");
    if (state.isSensitive?.(element) || state.isSensitive?.(hit)) {
      throw new Error("sensitive_target");
    }
    const rect = element.getBoundingClientRect();
    const style = getComputedStyle(element);
    if (rect.width <= 0 || rect.height <= 0 ||
        style.display === "none" || style.visibility === "hidden") {
      throw new Error("target_not_interactable");
    }
    const directLabel = (element.getAttribute("aria-label") ||
      element.getAttribute("title") || element.getAttribute("alt") ||
      element.innerText || element.textContent || "").trim().slice(0, 160);
    const contextLabel = (element.closest("section,article,[role=group]") ||
      element.getRootNode().host?.closest("section,article,[role=group]"))
      ?.querySelector("h1,h2,h3,[role=heading],legend")?.textContent?.trim().slice(0, 100);
    const label = state.redact?.(directLabel || contextLabel ||
      `Unlabeled ${element.localName} at ${Math.round(x)}, ${Math.round(y)}`) ||
      "Unlabeled visual target";
    const semantic = Array.from(state.targets.entries()).find(([, node]) =>
      composedContains(node, element) || composedContains(node, hit)
    );
    state.visualHits.set(hitID, {element, x, y});
    if (state.visualHits.size > 24) {
      state.visualHits.delete(state.visualHits.keys().next().value);
    }
    return JSON.stringify({
      label, role: element.getAttribute("role") || element.localName,
      x: rect.x, y: rect.y, width: rect.width, height: rect.height,
      semanticTargetID: semantic?.[0] || null
    });
    """#

    static let visualPointerClick = #"""
    const state = globalThis.__limaSemantic;
    if (!state || state.documentID !== documentID ||
        state.routeGeneration !== routeGeneration ||
        state.mutationRevision !== mutationRevision ||
        state.userRevision !== userRevision ||
        state.snapshotRevision !== snapshotRevision ||
        state.lastURL !== location.href) throw new Error("stale_target");
    const hit = state.visualHits.get(hitID);
    if (!hit || !hit.element.isConnected) throw new Error("stale_target");
    const {element, x, y} = hit;
    const composedContains = (ancestor, descendant) => {
      let node = descendant;
      for (let depth = 0; depth < 32 && node; depth++) {
        if (node === ancestor) return true;
        node = node.parentElement || node.getRootNode()?.host;
      }
      return false;
    };
    let underPoint = document.elementFromPoint(x, y);
    for (let depth = 0; depth < 8 && underPoint?.shadowRoot; depth++) {
      const inner = underPoint.shadowRoot.elementFromPoint(x, y);
      if (!inner || inner === underPoint) break;
      underPoint = inner;
    }
    if (!underPoint || !composedContains(element, underPoint) ||
        (state.activeModal?.isConnected && !composedContains(state.activeModal, underPoint))) {
      throw new Error("target_occluded");
    }
    if (state.isSensitive?.(element) || state.isSensitive?.(underPoint)) {
      throw new Error("sensitive_target");
    }
    if (element.matches(":disabled,[aria-disabled=true],[inert]") ||
        element.closest("[inert]") ||
        underPoint.matches(":disabled,[aria-disabled=true],[inert]") ||
        underPoint.closest("[inert]")) throw new Error("target_not_interactable");
    const semantic = Array.from(state.targets.values()).some(node =>
      composedContains(node, element) || composedContains(node, underPoint)
    );
    if (semantic) throw new Error("use_semantic_target");
    const pointer = (name, button) => {
      const options = {bubbles: true, cancelable: true, composed: true,
        clientX: x, clientY: y, button, buttons: name.endsWith("down") ? 1 : 0};
      if (globalThis.PointerEvent && name.startsWith("pointer")) {
        underPoint.dispatchEvent(new PointerEvent(name, {
          ...options, pointerId: 1, pointerType: "mouse", isPrimary: true
        }));
      } else {
        underPoint.dispatchEvent(new MouseEvent(name, options));
      }
    };
    pointer("pointerdown", 0);
    pointer("mousedown", 0);
    pointer("pointerup", 0);
    pointer("mouseup", 0);
    pointer("click", 0);
    state.visualHits.delete(hitID);
    return JSON.stringify({
      requested: true, performed: true, action: "pointerClick", verified: false
    });
    """#

    static let action = #"""
    const state = globalThis.__limaSemantic;
    if (!state || state.documentID !== documentID ||
        state.routeGeneration !== routeGeneration ||
        state.mutationRevision !== mutationRevision ||
        state.userRevision !== userRevision ||
        state.snapshotRevision !== snapshotRevision ||
        state.lastURL !== location.href) throw new Error("stale_target");
    const element = state.targets.get(targetID);
    if (!element || !element.isConnected) throw new Error("stale_target");
    const rect = element.getBoundingClientRect();
    const style = getComputedStyle(element);
    if (rect.width <= 0 || rect.height <= 0 || rect.bottom <= 0 ||
        rect.top >= innerHeight || rect.right <= 0 || rect.left >= innerWidth ||
        style.display === "none" || style.visibility === "hidden" ||
        element.matches(":disabled,[aria-disabled=true],[inert]")) {
      throw new Error("target_not_interactable");
    }
    const type = (element.getAttribute("type") || "").toLowerCase();
    const form = element.form || element.closest("form");
    const dialog = element.closest("dialog,[role=dialog],[role=alertdialog]") ||
      element.getRootNode().host?.closest("dialog,[role=dialog],[role=alertdialog]");
    const context = element.closest("form,section,article,[role=group]") ||
      element.getRootNode().host?.closest("form,section,article,[role=group]");
    const contextHeading = [dialog, form, context].map(node =>
      node?.querySelector("h1,h2,h3,[role=heading],legend")?.textContent
    ).filter(Boolean).join(" ");
    const hint = [element.name, element.id, element.autocomplete,
      element.getAttribute("aria-label"), element.getAttribute("aria-description"),
      element.getAttribute("placeholder"), element.getAttribute("title"),
      element.getAttribute("value"), element.getAttribute("data-action"),
      element.getAttribute("data-destructive"), element.labels?.[0]?.innerText,
      element.innerText, form?.getAttribute("action"),
      dialog?.getAttribute("aria-label"), form?.getAttribute("aria-label"),
      context?.getAttribute("aria-label"), contextHeading
    ].filter(Boolean).join(" ").toLowerCase();
    if (state.isSensitive?.(element)) throw new Error("sensitive_target");
    const submitButton = element.matches("button:not([type=button]):not([type=reset]),input[type=submit],input[type=image]");
    const initialChecked = element.matches("input[type=checkbox],input[type=radio]") ? element.checked : null;
    const stateAttributes = ["aria-pressed", "aria-checked", "aria-expanded", "aria-selected"];
    const initialStates = stateAttributes.map(name => element.getAttribute(name));
    const modal = Array.from(document.querySelectorAll(
      "dialog[open],[role=dialog][aria-modal=true],[role=alertdialog]"
    )).filter(node => {
      const box = node.getBoundingClientRect();
      return box.width > 0 && box.height > 0 && getComputedStyle(node).display !== "none";
    }).at(-1);
    const host = element.getRootNode().host;
    if (modal && !modal.contains(element) && !(host && modal.contains(host))) {
      throw new Error("target_occluded");
    }
    const hitTest = () => {
      const x = Math.max(0, Math.min(innerWidth - 1, rect.left + rect.width / 2));
      const y = Math.max(0, Math.min(innerHeight - 1, rect.top + rect.height / 2));
      const root = element.getRootNode();
      const hit = root.elementFromPoint?.(x, y) || document.elementFromPoint(x, y);
      const outer = document.elementFromPoint(x, y);
      const directHit = hit === element || element.contains(hit);
      const hostHit = host && (hit === host || host.contains(hit));
      if (!hit || (!directHit && !hostHit) ||
          (host && outer !== host && !host.contains(outer))) {
        throw new Error("target_occluded");
      }
    };
    if (["click", "toggle", "submit", "validate"].includes(action)) hitTest();
    const valueOf = () => element.isContentEditable ? element.textContent : element.value;
    const setNativeValue = next => {
      const input = element.matches(
        "textarea,input:not([type]),input[type=text],input[type=search],input[type=email],input[type=url],input[type=tel],input[type=number],input[type=date],input[type=time],input[type=datetime-local]"
      );
      if ((!input && !element.isContentEditable) || element.readOnly) {
        throw new Error("not_text_input");
      }
      element.focus();
      if (element.isContentEditable) {
        element.textContent = next;
      } else {
        const prototype = element.localName === "textarea" ?
          HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
        const setter = Object.getOwnPropertyDescriptor(prototype, "value")?.set;
        if (!setter) throw new Error("not_text_input");
        setter.call(element, next);
      }
      element.dispatchEvent(new InputEvent("input", {
        bubbles: true, data: next, inputType: next ? "insertText" : "deleteContentBackward"
      }));
      element.dispatchEvent(new Event("change", {bubbles: true}));
    };
    let expectedValue = null, expectedChecked = null, expectedOption = null;
    if (action === "click") {
      if (element.closest("a[href]") || element.hasAttribute("href")) throw new Error("use_open_link");
      if (form && submitButton) throw new Error("use_submit");
      if (!hint.trim()) throw new Error("unlabeled_target");
      element.click();
    } else if (action === "focus") {
      element.focus();
    } else if (["type", "setValue", "clear"].includes(action)) {
      expectedValue = action === "clear" ? "" : text;
      setNativeValue(expectedValue);
    } else if (action === "select") {
      if (element.localName !== "select" || element.multiple) throw new Error("not_single_select");
      const normalize = value => value.trim().replace(/\s+/g, " ").toLocaleLowerCase();
      const matches = Array.from(element.options).filter(option =>
        !option.disabled && normalize(option.label || option.textContent || "") === normalize(text)
      );
      if (matches.length !== 1) throw new Error("option_missing_or_ambiguous");
      expectedOption = matches[0];
      element.focus();
      element.selectedIndex = expectedOption.index;
      element.dispatchEvent(new Event("input", {bubbles: true}));
      element.dispatchEvent(new Event("change", {bubbles: true}));
    } else if (action === "toggle") {
      if (text !== "true" && text !== "false") throw new Error("invalid_toggle");
      expectedChecked = text === "true";
      const role = element.getAttribute("role");
      if (element.matches("input[type=checkbox],input[type=radio]")) {
        if (element.type === "radio" && !expectedChecked) throw new Error("radio_cannot_uncheck");
        if (element.checked !== expectedChecked) element.click();
      } else if (role === "switch" || role === "checkbox" || role === "radio") {
        if (role === "radio" && !expectedChecked) throw new Error("radio_cannot_uncheck");
        const current = element.getAttribute("aria-checked") === "true";
        if (current !== expectedChecked) element.click();
      } else throw new Error("not_toggle");
    } else if (action === "pressKey") {
      const permittedKeys = ["Escape", "ArrowUp", "ArrowDown", "ArrowLeft", "ArrowRight", "Home", "End", "PageUp", "PageDown"];
      if (!permittedKeys.includes(text)) throw new Error("unsupported_key");
      element.focus();
      if (element.getRootNode().activeElement !== element) throw new Error("target_not_focusable");
      const eventOptions = {key: text, bubbles: true, cancelable: true, composed: true};
      element.dispatchEvent(new KeyboardEvent("keydown", eventOptions));
      element.dispatchEvent(new KeyboardEvent("keyup", eventOptions));
    } else if (action === "validate") {
      return JSON.stringify({valid: true});
    } else if (action === "submit") {
      if (!form || !submitButton) throw new Error("not_submit_control");
      const missingProtected = Array.from(form.querySelectorAll("input,textarea")).some(node =>
        state.secureKind?.(node) && node.required && !String(node.value || "").trim()
      );
      if (missingProtected) throw new Error("sensitive_form");
      form.requestSubmit(element);
    } else throw new Error("unsupported_action");
    if (["type", "setValue", "clear", "select", "toggle"].includes(action)) {
      await new Promise(resolve => setTimeout(resolve, 30));
    }
    const checkedNow = element.matches("input[type=checkbox],input[type=radio]") ?
      element.checked : element.getAttribute("aria-checked") === "true";
    const verified = element.isConnected && (action === "focus" ?
      element.getRootNode().activeElement === element :
      ["type", "setValue", "clear"].includes(action) ? valueOf() === expectedValue :
      action === "select" ? element.selectedOptions.length === 1 &&
        element.selectedOptions[0] === expectedOption :
      action === "toggle" ? checkedNow === expectedChecked :
      action === "click" && ((initialChecked !== null && element.checked !== initialChecked) ||
        stateAttributes.some((name, index) => element.getAttribute(name) !== initialStates[index])));
    return JSON.stringify({requested: true, performed: true, action, verified});
    """#

    static let scroll = #"""
    const state = globalThis.__limaSemantic;
    if (!state || state.documentID !== documentID ||
        state.routeGeneration !== routeGeneration ||
        state.mutationRevision !== mutationRevision ||
        state.userRevision !== userRevision ||
        state.snapshotRevision !== snapshotRevision ||
        state.lastURL !== location.href) throw new Error("stale_page");
    if (!["up", "down"].includes(direction) ||
        !Number.isFinite(fraction) || fraction < 0.5 || fraction > 1) {
      throw new Error("invalid_scroll");
    }
    const candidates = [];
    const root = document.scrollingElement;
    const consider = element => {
      if (!element || element.clientHeight < 24 ||
          element.scrollHeight - element.clientHeight < 8) return;
      const isRoot = element === root;
      const style = getComputedStyle(element);
      if (!isRoot && !/auto|scroll|overlay/.test(style.overflowY)) return;
      const rect = element.getBoundingClientRect();
      if (rect.width < 8 || rect.height < 8 ||
          rect.bottom <= 0 || rect.top >= innerHeight) return;
      const role = element.getAttribute("role") || "";
      const semantic = /grid|list|table|feed|tree/.test(role) ? 1000000 : 0;
      candidates.push({
        element, rect, role,
        score: semantic + Math.min(100000, element.scrollHeight - element.clientHeight)
      });
    };
    consider(root);
    let inspected = 0;
    for (const element of document.querySelectorAll("*")) {
      if (++inspected > 10000) break;
      if (element !== root) consider(element);
    }
    candidates.sort((a, b) => b.score - a.score);
    const selected = candidates[0];
    if (!selected) return JSON.stringify({
      performed: false, before: 0, after: 0, endReached: true,
      regionLabel: "", x: 0, y: 0, width: 0, height: 0,
      availableRegions: 0, truncated: inspected > 10000
    });
    const element = selected.element;
    const before = element.scrollTop;
    const amount = Math.max(1, Math.round(element.clientHeight * fraction));
    element.scrollTop = before + (direction === "down" ? amount : -amount);
    const after = element.scrollTop;
    if (after !== before) {
      state.mutationRevision++;
      state.lastMutationAt = performance.now();
      state.targets.clear();
    }
    const rect = selected.rect;
    return JSON.stringify({
      performed: after !== before, before, after,
      endReached: direction === "down" ?
        after >= element.scrollHeight - element.clientHeight - 2 : after <= 2,
      regionLabel: (state.redact?.(element.getAttribute("aria-label") || selected.role ||
        element.id || (element === root ? "main page" : "scroll region")) ||
        "scroll region").slice(0, 100),
      x: rect.x, y: rect.y, width: rect.width, height: rect.height,
      availableRegions: candidates.length, truncated: inspected > 10000
    });
    """#
}
