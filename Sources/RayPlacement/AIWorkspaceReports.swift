import AppKit
import SwiftUI
import WebKit

struct AIWorkspaceReport: Identifiable {
    let id: UUID
    let conversationID: UUID
    let title: String
    let summary: String
    let sections: [Section]
    struct Section: Codable { let heading: String; let body: String }

    var html: String {
        func escape(_ text: String) -> String {
            text.replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
                .replacingOccurrences(of: "\"", with: "&quot;")
        }
        return """
        <!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; img-src 'none'; form-action 'none'; base-uri 'none'">
        <title>\(escape(title))</title><style>
        :root{color-scheme:light dark}body{font:16px/1.65 system-ui;margin:0;background:#f5f6fa;color:#242936}
        main{max-width:780px;margin:auto;padding:48px 28px}header{border-bottom:1px solid #8884;padding-bottom:24px;margin-bottom:28px}
        .eyebrow{font-size:11px;letter-spacing:.15em;color:#8392bb}h1{font-size:34px;line-height:1.2;letter-spacing:-.03em}h2{font-size:20px}
        section{background:white;border:1px solid #8883;border-radius:16px;padding:22px;margin:18px 0;overflow-wrap:anywhere}
        @media(prefers-color-scheme:dark){body{background:#14161c;color:#e8ebf3}section{background:#20242e}}
        .body{white-space:pre-wrap}footer{font-size:12px;opacity:.6;margin-top:30px}
        </style></head><body><main><header><div class="eyebrow">LIMA · TEMPORARY REPORT</div>
        <h1>\(escape(title))</h1><p>\(escape(summary))</p></header>
        \(sections.map { "<section><h2>\(escape($0.heading))</h2><div class=\"body\">\(escape($0.body))</div></section>" }.joined())
        <footer>Generated for this chat · Expires when Lima quits.</footer>
        </main></body></html>
        """
    }
}

@MainActor
final class AIWorkspaceReportStore: ObservableObject {
    static let shared = AIWorkspaceReportStore()
    @Published private(set) var reports: [AIWorkspaceReport] = []
    private var windows: [UUID: NSWindowController] = [:]

    func reports(for conversationID: UUID?) -> [AIWorkspaceReport] {
        reports.filter { $0.conversationID == conversationID }
    }

    func create(conversationID: UUID, title: String, summary: String, sections: [AIWorkspaceReport.Section]) -> AIWorkspaceReport {
        let report = AIWorkspaceReport(id: UUID(), conversationID: conversationID, title: title, summary: summary, sections: sections)
        while reports.count >= 24 || reports(for: conversationID).count >= 8 {
            let victim = reports(for: conversationID).count >= 8 ? reports(for: conversationID)[0] : reports[0]
            windows.removeValue(forKey: victim.id)?.close()
            reports.removeAll { $0.id == victim.id }
        }
        reports.append(report)
        return report
    }

    func open(_ report: AIWorkspaceReport) {
        if let controller = windows[report.id] { controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil); return }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        let web = WKWebView(frame: .zero, configuration: configuration)
        web.loadHTMLString(report.html, baseURL: nil)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 720), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = report.title; window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 420, height: 320); window.contentView = web; window.center()
        let controller = NSWindowController(window: window); windows[report.id] = controller
        controller.showWindow(nil); window.makeKeyAndOrderFront(nil)
    }
}

@MainActor
enum AIWorkspaceReportTool {
    static let id = "workspace_report"
    static let definition = LimaAIToolDefinition(id: id, name: id,
        description: "Create, list, read, or open a temporary webpage report owned by this chat. Use create with title, summary, and sections of heading/body text, then open with its report_id. Reports are escaped, script-free local pages with no network or form submission, expire when Lima quits, and may be shown alongside ongoing work. Cite real source URLs in body text; do not invent evidence.",
        parameters: ["type": "object", "properties": [
            "action": ["type": "string", "enum": ["create", "list", "read", "open"]],
            "report_id": ["type": "string"], "title": ["type": "string"], "summary": ["type": "string"],
            "sections": ["type": "array", "items": ["type": "object", "properties": ["heading": ["type": "string"], "body": ["type": "string"]], "required": ["heading", "body"], "additionalProperties": false]]
        ], "required": ["action"], "additionalProperties": false], risk: .read)

    static func execute(_ call: AIOutputItem, conversationID: UUID) -> LimaAIToolExecution {
        guard let raw = call.arguments, raw.utf8.count <= 100_000, let data = raw.data(using: .utf8),
              let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let action = body["action"] as? String else {
            return .json(["error": "Invalid report request."], isError: true)
        }
        let store = AIWorkspaceReportStore.shared
        func payload(_ report: AIWorkspaceReport) -> [String: Any] {
            ["report_id": report.id.uuidString, "title": report.title, "summary": report.summary,
             "sections": report.sections.map { ["heading": $0.heading, "body": $0.body] }, "temporary": true]
        }
        if action == "list" { return .json(["reports": store.reports(for: conversationID).map(payload)]) }
        if action == "create" {
            guard let title = body["title"] as? String, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, title.count <= 160,
                  let summary = body["summary"] as? String, summary.count <= 2000,
                  let array = body["sections"] as? [[String: String]], (1...20).contains(array.count),
                  array.allSatisfy({ ($0["heading"]?.count ?? 1000) <= 200 && ($0["body"]?.count ?? 100_000) <= 20_000 }) else {
                return .json(["error": "Provide a title, summary and 1–20 bounded heading/body sections."], isError: true)
            }
            let report = store.create(conversationID: conversationID, title: title, summary: summary,
                sections: array.map { .init(heading: $0["heading"]!, body: $0["body"]!) })
            return .json(payload(report))
        }
        guard ["read", "open"].contains(action), let rawID = body["report_id"] as? String,
              let report = store.reports(for: conversationID).first(where: { $0.id.uuidString == rawID }) else {
            return .json(["error": "Report not found in this chat; it may have expired."], isError: true)
        }
        if action == "open" { store.open(report) }
        return .json(payload(report))
    }
}
