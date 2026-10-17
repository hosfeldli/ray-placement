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
                                 sensitive: $0.sensitive)
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
        let allLinks = snapshots.flatMap(\.links)
        let allControls = snapshots.flatMap(\.controls)
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
        return result
    }
}

enum BrowserRuntimeError: LocalizedError {
    case missingTab
    case missingSnapshot
    case staleTarget
    case pageChangedByUser
    case invalidDestination
    case controlDisabled
    case userPaused
    case sensitiveTarget
    case screenshotProtected
    case unsupportedAction
    case tabLimit

    var errorDescription: String? {
        switch self {
        case .missingTab: "The Lima browser tab is no longer open."
        case .missingSnapshot: "Read this tab before using a semantic target."
        case .staleTarget: "The page changed. Read it again before acting on this target."
        case .pageChangedByUser: "The user changed this page. Read it again before acting on a target."
        case .invalidDestination: "Only HTTPS or loopback HTTP (localhost, 127.0.0.1, or [::1]) destinations without embedded credentials are supported."
        case .controlDisabled: "This action is not available in the current Browser AI Control mode."
        case .userPaused: "AI was explicitly paused for this tab. Resume AI in the Browser workspace, then read the page again."
        case .sensitiveTarget: "Sensitive fields and forms are always protected."
        case .screenshotProtected: "This page contains sensitive controls or content the Browser could not account for; no screenshot was saved."
        case .unsupportedAction: "This semantic target does not support the requested action."
        case .tabLimit: "The Browser currently limits AI-created and page-opened logical tabs to 20; close a tab before opening another."
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
        targets: new Map(), frameReports: new Map(), frameGeometry: new Map()
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
    const links = [], controls = [], headings = [], rowElements = [];
    const shadowTextParts = [];
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
    const label = element => {
      const ids = (element.getAttribute("aria-labelledby") || "").trim().split(/\s+/).filter(Boolean);
      const labelledBy = ids.map(id =>
        element.getRootNode().getElementById?.(id) || document.getElementById(id)
      ).filter(Boolean).map(node => node.innerText || node.textContent || "").join(" ");
      const submitLabel = element.matches("input[type=submit],input[type=button],input[type=reset]")
        ? element.getAttribute("value") : null;
      return (element.getAttribute("aria-label") || labelledBy ||
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
      return ["password", "file", "hidden"].includes(type) ||
        Boolean(element.closest("[data-destructive],[data-danger]")) ||
        /password|passcode|one.?time.?code|credit.?card|card.?number|cvv|cvc|ssn|social.?security|token|secret|credential|payment|billing|bank.?account|routing.?number|verification.?code|delete|remove|erase|destroy|close.?account|place.?order|purchase|buy.?now|transfer|send.?money|wire|withdraw|refund|cancel.?subscription|sign.?out|log.?out|deactivate|revoke|purge|terminate|irreversible|permanent.?delete|reset.?password/i.test(hint) ||
        Boolean(form?.querySelector("input[type=password],input[type=file],input[autocomplete^=cc-],input[autocomplete=one-time-code]"));
    };
    const add = (array, element, role, destination, relationship) => {
      if (links.length + controls.length >= maxTargets) { truncated = true; return; }
      const rect = element.getBoundingClientRect();
      const id = "t_" + state.frameID + "_" + state.snapshotRevision + "_" + state.targets.size;
      state.targets.set(id, element);
      array.push({
        id, role, label: label(element), destination: destination || null,
        relationship: relationship || null,
        x: rect.x, y: rect.y, width: rect.width, height: rect.height,
        frameID: state.frameID, sensitive: sensitive(element)
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
        shadowTextParts.push(part);
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
        const role = element.getAttribute("role") || tag;
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
              if (url.protocol === "https:") destination = url.href;
            }
          } catch {}
          if (destination) {
            const relationship = element.hasAttribute("download") ? "download" :
              element.getAttribute("target") === "_blank" ? "new_tab" : "normal";
            add(links, element, "link", destination, relationship);
          } else {
            add(controls, element, "button", null, null);
          }
        } else if (["button", "input", "textarea", "select"].includes(tag) ||
                   ["button", "textbox", "checkbox", "radio", "combobox", "tab", "menuitem"].includes(role) ||
                   element.getAttribute("contenteditable") === "true") {
          add(controls, element, role, null, null);
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
      const rowText = (element.innerText || "").replace(/\s+/g, " ").trim().slice(0, 500);
      const linkTargetIDs = links.filter(target => element.contains(state.targets.get(target.id))).map(target => target.id);
      const controlTargetIDs = controls.filter(target => element.contains(state.targets.get(target.id))).map(target => target.id);
      const evidence = element.getAttribute("data-key") || element.getAttribute("data-id") ||
        element.id || element.getAttribute("aria-rowindex") ||
        element.querySelector("a[href]")?.getAttribute("href") || rowText;
      return {
        stableKey: "row_" + stableHash(state.frameID + ":" + role + ":" + evidence), role,
        text: rowText, linkTargetIDs, controlTargetIDs, frameID: state.frameID
      };
    }).filter(row => row.text || row.linkTargetIDs.length || row.controlTargetIDs.length);
    const bodyText = document.body?.innerText || "";
    let text = bodyText.slice(0, 48000);
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
      readiness, title: document.title.slice(0, 300), text, frameID: state.frameID,
      links, controls, headings, rows,
      diagnostics: {
        textLength: text.length, linkCount: links.length, controlCount: controls.length,
        headingCount: headings.length, semanticRowCount: rows.length, shadowRootCount, frameCount,
        quietMS, truncated: truncated || bodyText.length + shadowTextLength > 48000
      }
    };
    return JSON.stringify(payload);
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
    const risky = /password|passcode|one.?time.?code|credit.?card|card.?number|cvv|cvc|ssn|social.?security|token|secret|credential|payment|billing|bank.?account|routing.?number|verification.?code|delete|remove|erase|destroy|close.?account|place.?order|purchase|buy.?now|transfer|send.?money|wire|withdraw|refund|cancel.?subscription|sign.?out|log.?out|deactivate|revoke|purge|terminate|irreversible|permanent.?delete|reset.?password/i;
    if (["password", "file", "hidden"].includes(type) || risky.test(hint) ||
        element.closest("[data-destructive],[data-danger]") ||
        form?.querySelector("input[type=password],input[type=file],[autocomplete^=cc-],[autocomplete=one-time-code]")) {
      throw new Error("sensitive_target");
    }
    const submitButton = element.matches("button:not([type=button]):not([type=reset]),input[type=submit],input[type=image]");
    const initialChecked = element.matches("input[type=checkbox],input[type=radio]") ? element.checked : null;
    const stateAttributes = ["aria-pressed", "aria-checked", "aria-expanded"];
    const initialStates = stateAttributes.map(name => element.getAttribute(name));
    if (action === "click") {
      if (element.closest("a[href]") || element.localName === "a") throw new Error("use_open_link");
      if (form && submitButton) throw new Error("use_submit");
      if (!hint.trim()) throw new Error("unlabeled_target");
      element.click();
    } else if (action === "focus") {
      element.focus();
    } else if (action === "type") {
      const textInput = element.matches("textarea,input:not([type]),input[type=text],input[type=search],input[type=email],input[type=url],input[type=tel],input[type=number]");
      if ((!textInput && !element.isContentEditable) || element.readOnly) throw new Error("not_text_input");
      element.focus();
      if (element.isContentEditable) {
        element.textContent = text;
      } else {
        // Use the native prototype setter so controlled React/Vue inputs see
        // a real value transition rather than only their own value tracker.
        const prototype = element.localName === "textarea" ?
          HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
        const setter = Object.getOwnPropertyDescriptor(prototype, "value")?.set;
        if (!setter) throw new Error("not_text_input");
        setter.call(element, text);
      }
      element.dispatchEvent(new InputEvent("input", {bubbles: true, data: text, inputType: "insertText"}));
      element.dispatchEvent(new Event("change", {bubbles: true}));
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
      if (form.querySelector("input[type=password],input[type=file],[autocomplete^=cc-],[autocomplete=one-time-code]")) {
        throw new Error("sensitive_form");
      }
      form.requestSubmit(element);
    } else throw new Error("unsupported_action");
    const verified = element.isConnected && (action === "focus" ?
      element.getRootNode().activeElement === element :
      action === "type" ? (element.isContentEditable ? element.textContent === text : element.value === text) :
      action === "click" && ((initialChecked !== null && element.checked !== initialChecked) ||
        stateAttributes.some((name, index) => element.getAttribute(name) !== initialStates[index])));
    return JSON.stringify({requested: true, performed: true, action, verified});
    """#

    static let scroll = #"""
    const state = globalThis.__limaSemantic;
    if (!state || state.documentID !== documentID ||
        state.routeGeneration !== routeGeneration ||
        state.userRevision !== userRevision ||
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
      regionLabel: (element.getAttribute("aria-label") || selected.role ||
        element.id || (element === root ? "main page" : "scroll region")).slice(0, 100),
      x: rect.x, y: rect.y, width: rect.width, height: rect.height,
      availableRegions: candidates.length, truncated: inspected > 10000
    });
    """#
}
