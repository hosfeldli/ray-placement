import AppKit
import Foundation
import SwiftUI

@MainActor
final class EndpointTesterWindowController: NSWindowController {
    private let model = EndpointTesterModel()
    private var hasPresented = false

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1_080, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Endpoint Tester"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.backgroundColor = .clear
        window.appearance = NSAppearance(named: .darkAqua)
        window.minSize = NSSize(width: 820, height: 560)
        window.setAccessibilityLabel("RayPlacement endpoint tester")
        self.init(window: window)
        window.contentView = NSHostingView(rootView: EndpointTesterView(model: model))
    }

    func present() {
        if !hasPresented {
            window?.center()
            hasPresented = true
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func shutdown() {
        model.cancel()
    }
}

private struct EndpointKeyValueRow: Identifiable, Hashable {
    let id: UUID
    var enabled: Bool
    var key: String
    var value: String

    init(id: UUID = UUID(), enabled: Bool = true, key: String = "", value: String = "") {
        self.id = id
        self.enabled = enabled
        self.key = key
        self.value = value
    }
}

private struct EndpointRequestSnapshot: Identifiable {
    let id = UUID()
    let sentAt: Date
    let method: String
    let url: String
    let parameters: [EndpointKeyValueRow]
    let headers: [EndpointKeyValueRow]
    let bodyKind: EndpointTesterModel.BodyKind
    let body: String
    let statusCode: Int?

    var title: String {
        guard let components = URLComponents(string: url), let host = components.host else { return url }
        let path = components.path.isEmpty ? "/" : components.path
        return host + path
    }
}

private struct EndpointResponse {
    let statusCode: Int
    let elapsed: TimeInterval
    let byteCount: Int
    let body: String
    let headers: String
    let raw: String

    var succeeded: Bool { (200..<400).contains(statusCode) }
}

@MainActor
private final class EndpointTesterModel: ObservableObject {
    enum RequestTab: String, CaseIterable, Identifiable {
        case params = "Params"
        case authorization = "Auth"
        case headers = "Headers"
        case body = "Body"
        var id: String { rawValue }
    }

    enum ResponseTab: String, CaseIterable, Identifiable {
        case body = "Body"
        case headers = "Headers"
        case raw = "Raw"
        var id: String { rawValue }
    }

    enum AuthKind: String, CaseIterable, Identifiable {
        case none = "No Auth"
        case bearer = "Bearer Token"
        case basic = "Basic Auth"
        case apiKey = "API Key"
        var id: String { rawValue }
    }

    enum APIKeyLocation: String, CaseIterable, Identifiable {
        case header = "Header"
        case query = "Query parameter"
        var id: String { rawValue }
    }

    enum BodyKind: String, CaseIterable, Identifiable {
        case none = "None"
        case json = "JSON"
        case text = "Text"
        case xml = "XML"
        var id: String { rawValue }

        var contentType: String? {
            switch self {
            case .none: return nil
            case .json: return "application/json"
            case .text: return "text/plain; charset=utf-8"
            case .xml: return "application/xml"
            }
        }
    }

    @Published var method = "GET"
    @Published var urlText = ""
    @Published var requestTab: RequestTab = .params
    @Published var responseTab: ResponseTab = .body
    @Published var parameters = [EndpointKeyValueRow()]
    @Published var headers = [EndpointKeyValueRow()]
    @Published var authKind: AuthKind = .none
    @Published var bearerToken = ""
    @Published var username = ""
    @Published var password = ""
    @Published var apiKeyName = ""
    @Published var apiKeyValue = ""
    @Published var apiKeyLocation: APIKeyLocation = .header
    @Published var bodyKind: BodyKind = .none
    @Published var body = ""
    @Published var response: EndpointResponse?
    @Published var history: [EndpointRequestSnapshot] = []
    @Published var error: String?
    @Published var isRunning = false

    private var task: URLSessionDataTask?
    private var usageTask: UUID?

    var displayedResponse: String {
        guard let response else {
            return isRunning ? "Waiting for the endpoint…" : "Send a request to inspect its response."
        }
        switch responseTab {
        case .body: return response.body.isEmpty ? "No response body" : response.body
        case .headers: return response.headers.isEmpty ? "No response headers" : response.headers
        case .raw: return response.raw
        }
    }

    func addParameter() { parameters.append(EndpointKeyValueRow()) }
    func addHeader() { headers.append(EndpointKeyValueRow()) }
    func removeParameter(_ id: UUID) { parameters.removeAll { $0.id == id } }
    func removeHeader(_ id: UUID) { headers.removeAll { $0.id == id } }

    func prettyPrintJSON() {
        guard let data = body.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let formatted = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) else {
            error = "The request body is not valid JSON."
            return
        }
        body = String(decoding: formatted, as: UTF8.self)
        error = nil
    }

    func send() {
        guard !isRunning else { return }
        do {
            let request = try buildRequest()
            error = nil
            response = nil
            isRunning = true
            let started = Date()
            let performance = SettingsStore.shared.runtimeExtensionPerformance
            usageTask = UsageMonitor.shared.begin(
                category: .extensionCommand,
                operation: "Endpoint Tester",
                performance: performance,
                inputCharacters: (request.httpBody?.count ?? 0) + (request.url?.absoluteString.count ?? 0)
            )
            let dataTask = URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
                let elapsed = Date().timeIntervalSince(started)
                Task { @MainActor in
                    guard let self else { return }
                    self.task = nil
                    self.isRunning = false
                    if let error {
                        self.error = error.localizedDescription
                        self.finishUsage(succeeded: false, detail: error.localizedDescription)
                        self.recordHistory(statusCode: nil)
                        return
                    }
                    guard let http = response as? HTTPURLResponse else {
                        self.error = "The endpoint did not return an HTTP response."
                        self.finishUsage(succeeded: false, detail: self.error)
                        return
                    }
                    let fullData = data ?? Data()
                    let limited = Data(fullData.prefix(2_000_000))
                    let bodyText = Self.formattedBody(limited)
                    let headerText = http.allHeaderFields
                        .map { "\($0.key): \($0.value)" }
                        .sorted()
                        .joined(separator: "\n")
                    let statusLine = "HTTP \(http.statusCode) \(HTTPURLResponse.localizedString(forStatusCode: http.statusCode))"
                    self.response = EndpointResponse(
                        statusCode: http.statusCode,
                        elapsed: elapsed,
                        byteCount: fullData.count,
                        body: bodyText,
                        headers: headerText,
                        raw: [statusLine, headerText, bodyText].filter { !$0.isEmpty }.joined(separator: "\n\n")
                    )
                    self.finishUsage(
                        succeeded: (200..<400).contains(http.statusCode),
                        outputCharacters: bodyText.count,
                        detail: "HTTP \(http.statusCode)"
                    )
                    self.recordHistory(statusCode: http.statusCode)
                }
            }
            task = dataTask
            dataTask.resume()
        } catch {
            self.error = error.localizedDescription
        }
    }

    func cancel() {
        guard isRunning else { return }
        task?.cancel()
        task = nil
        isRunning = false
        finishUsage(succeeded: false, detail: "Cancelled by user")
    }

    func load(_ entry: EndpointRequestSnapshot) {
        method = entry.method
        urlText = entry.url
        parameters = entry.parameters.isEmpty ? [EndpointKeyValueRow()] : entry.parameters
        headers = entry.headers.isEmpty ? [EndpointKeyValueRow()] : entry.headers
        bodyKind = entry.bodyKind
        body = entry.body
        authKind = .none
        bearerToken = ""
        username = ""
        password = ""
        apiKeyName = ""
        apiKeyValue = ""
        error = nil
    }

    func clearHistory() { history = [] }

    func copyResponse() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(displayedResponse, forType: .string)
    }

    func copyAsCURL() {
        do {
            let request = try buildRequest()
            var components = ["curl", "-X", Self.shellQuote(request.httpMethod ?? "GET"), Self.shellQuote(request.url?.absoluteString ?? urlText)]
            for (name, value) in request.allHTTPHeaderFields?.sorted(by: { $0.key < $1.key }) ?? [] {
                components += ["-H", Self.shellQuote("\(name): \(value)")]
            }
            if let body = request.httpBody.flatMap({ String(data: $0, encoding: .utf8) }), !body.isEmpty {
                components += ["--data-raw", Self.shellQuote(body)]
            }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(components.joined(separator: " "), forType: .string)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func buildRequest() throws -> URLRequest {
        let rawURL = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: rawURL),
              let scheme = components.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              components.host != nil else {
            throw EndpointTesterError.invalidURL
        }

        var queryItems = components.queryItems ?? []
        for item in parameters where item.enabled && !item.key.trimmingCharacters(in: .whitespaces).isEmpty {
            queryItems.append(URLQueryItem(name: item.key, value: item.value))
        }
        if authKind == .apiKey, apiKeyLocation == .query, !apiKeyName.isEmpty {
            queryItems.append(URLQueryItem(name: apiKeyName, value: apiKeyValue))
        }
        components.queryItems = queryItems.isEmpty ? nil : queryItems
        guard let url = components.url else { throw EndpointTesterError.invalidURL }

        var request = URLRequest(url: url)
        request.httpMethod = method
        let configuredTimeout = 30.0
        let performanceTimeout = SettingsStore.shared.runtimeExtensionPerformance.extensionTimeout
        request.timeoutInterval = performanceTimeout > 0 ? min(configuredTimeout, performanceTimeout) : configuredTimeout

        for header in headers where header.enabled && !header.key.trimmingCharacters(in: .whitespaces).isEmpty {
            request.setValue(header.value, forHTTPHeaderField: header.key)
        }
        switch authKind {
        case .none:
            break
        case .bearer:
            if !bearerToken.isEmpty { request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization") }
        case .basic:
            let credential = Data("\(username):\(password)".utf8).base64EncodedString()
            request.setValue("Basic \(credential)", forHTTPHeaderField: "Authorization")
        case .apiKey:
            if apiKeyLocation == .header, !apiKeyName.isEmpty {
                request.setValue(apiKeyValue, forHTTPHeaderField: apiKeyName)
            }
        }

        if bodyKind != .none {
            if bodyKind == .json, !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                guard let data = body.data(using: .utf8), (try? JSONSerialization.jsonObject(with: data)) != nil else {
                    throw EndpointTesterError.invalidJSON
                }
            }
            request.httpBody = Data(body.utf8)
            if request.value(forHTTPHeaderField: "Content-Type") == nil, let contentType = bodyKind.contentType {
                request.setValue(contentType, forHTTPHeaderField: "Content-Type")
            }
        }
        return request
    }

    private func recordHistory(statusCode: Int?) {
        history.insert(EndpointRequestSnapshot(
            sentAt: Date(),
            method: method,
            // Keep the editable base URL instead of the resolved request URL.
            // This avoids duplicating Params on restore and never stores API-key
            // query values produced by the authorization editor.
            url: urlText,
            parameters: parameters.filter { !$0.key.isEmpty || !$0.value.isEmpty },
            headers: headers.filter { !$0.key.isEmpty || !$0.value.isEmpty },
            bodyKind: bodyKind,
            body: body,
            statusCode: statusCode
        ), at: 0)
        if history.count > 50 { history.removeLast(history.count - 50) }
    }

    private func finishUsage(succeeded: Bool, outputCharacters: Int = 0, detail: String? = nil) {
        guard let usageTask else { return }
        self.usageTask = nil
        UsageMonitor.shared.finish(usageTask, succeeded: succeeded, outputCharacters: outputCharacters, detail: detail)
    }

    private static func formattedBody(_ data: Data) -> String {
        if let object = try? JSONSerialization.jsonObject(with: data),
           let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) {
            return String(decoding: pretty, as: UTF8.self)
        }
        return String(decoding: data, as: UTF8.self)
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

private enum EndpointTesterError: LocalizedError {
    case invalidURL
    case invalidJSON

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Enter a complete HTTP or HTTPS endpoint."
        case .invalidJSON: return "The JSON request body is not valid."
        }
    }
}

private struct EndpointTesterView: View {
    @ObservedObject var model: EndpointTesterModel
    @FocusState private var urlFocused: Bool

    var body: some View {
        ZStack {
            LiquidGlassBackdrop(material: .underWindowBackground, blendingMode: .behindWindow)
            VStack(spacing: 9) {
                header
                HSplitView {
                    history
                        .frame(minWidth: 165, idealWidth: 185, maxWidth: 220)
                    VStack(spacing: 9) {
                        requestBar
                        requestEditor
                            .frame(minHeight: 170, idealHeight: 220, maxHeight: 290)
                        responseViewer
                    }
                    .frame(minWidth: 610)
                }
            }
            .padding(10)
        }
        .preferredColorScheme(.dark)
        .tint(SettingsStore.shared.accentTheme.primary)
        .onAppear { urlFocused = true }
    }

    private var header: some View {
        HStack(spacing: 9) {
            Image(systemName: "network")
                .foregroundStyle(SettingsStore.shared.accentTheme.gradient)
            Text("Endpoint Tester")
                .font(.system(size: 15, weight: .semibold, design: .rounded))
            Text("HTTP workspace")
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
            Spacer()
            if model.isRunning {
                ProgressView().controlSize(.small)
                Text("Sending").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            }
            Button("Copy cURL", action: model.copyAsCURL)
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        .padding(.horizontal, 13)
        .frame(height: 44)
        .liquidGlass(cornerRadius: 15, depth: .raised, accentOpacity: 0.038)
    }

    private var history: some View {
        VStack(spacing: 0) {
            HStack {
                Text("HISTORY").font(.caption2.bold()).foregroundStyle(.secondary)
                Spacer()
                if !model.history.isEmpty {
                    Button(action: model.clearHistory) { Image(systemName: "trash") }
                        .buttonStyle(.plain)
                        .help("Clear session history")
                }
            }
            .padding(.horizontal, 11)
            .frame(height: 36)
            GlassHairline()
            if model.history.isEmpty {
                Spacer()
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 18))
                    .foregroundStyle(.tertiary)
                Text("Requests appear here")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.top, 5)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(model.history) { entry in
                            Button { model.load(entry) } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    HStack(spacing: 5) {
                                        Text(entry.method)
                                            .font(.caption2.monospaced().bold())
                                            .foregroundStyle(SettingsStore.shared.accentTheme.primary)
                                        Spacer()
                                        if let status = entry.statusCode {
                                            Text(String(status)).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                                        }
                                    }
                                    Text(entry.title).font(.caption.weight(.medium)).lineLimit(1)
                                    Text(entry.sentAt.formatted(date: .omitted, time: .shortened))
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(8)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .liquidGlass(cornerRadius: 9, depth: .recessed, accentOpacity: 0.012)
                        }
                    }
                    .padding(6)
                }
            }
        }
        .liquidGlass(cornerRadius: 16, depth: .floating, accentOpacity: 0.018)
    }

    private var requestBar: some View {
        HStack(spacing: 7) {
            Picker("Method", selection: $model.method) {
                ForEach(["GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS"], id: \.self) { Text($0).tag($0) }
            }
            .labelsHidden()
            .frame(width: 105)
            TextField("https://api.example.com/resource", text: $model.urlText)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5, design: .monospaced))
                .focused($urlFocused)
                .onSubmit(model.send)
                .padding(.horizontal, 10)
                .frame(height: 34)
                .liquidGlass(cornerRadius: 9, depth: .recessed, accentOpacity: 0.012)
            if model.isRunning {
                Button("Cancel", action: model.cancel)
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
            } else {
                Button("Send", action: model.send)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                    .keyboardShortcut(.return, modifiers: [.command])
            }
        }
        .padding(9)
        .liquidGlass(cornerRadius: 14, depth: .floating, accentOpacity: 0.026)
    }

    private var requestEditor: some View {
        VStack(spacing: 0) {
            Picker("Request", selection: $model.requestTab) {
                ForEach(EndpointTesterModel.RequestTab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(9)
            GlassHairline()
            Group {
                switch model.requestTab {
                case .params: keyValueEditor(rows: $model.parameters, add: model.addParameter, remove: model.removeParameter, keyPlaceholder: "Parameter")
                case .headers: keyValueEditor(rows: $model.headers, add: model.addHeader, remove: model.removeHeader, keyPlaceholder: "Header")
                case .authorization: authorizationEditor
                case .body: bodyEditor
                }
            }
        }
        .liquidGlass(cornerRadius: 15, depth: .floating, accentOpacity: 0.018)
    }

    private func keyValueEditor(
        rows: Binding<[EndpointKeyValueRow]>,
        add: @escaping () -> Void,
        remove: @escaping (UUID) -> Void,
        keyPlaceholder: String
    ) -> some View {
        VStack(spacing: 6) {
            ScrollView {
                LazyVStack(spacing: 5) {
                    ForEach(rows) { $row in
                        HStack(spacing: 7) {
                            Toggle("", isOn: $row.enabled).labelsHidden().toggleStyle(.checkbox)
                            TextField(keyPlaceholder, text: $row.key).textFieldStyle(.plain)
                            Rectangle()
                                .fill(Color.white.opacity(0.10))
                                .frame(width: 0.7, height: 18)
                            TextField("Value", text: $row.value).textFieldStyle(.plain)
                            Button { remove(row.id) } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(.plain)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 9)
                        .frame(height: 31)
                        .liquidGlass(cornerRadius: 8, depth: .recessed, accentOpacity: 0.008)
                    }
                }
                .padding(.horizontal, 9)
                .padding(.top, 7)
            }
            HStack {
                Button(action: add) { Label("Add row", systemImage: "plus") }
                    .buttonStyle(.plain)
                    .font(.caption.weight(.medium))
                Spacer()
            }
            .padding(.horizontal, 11)
            .padding(.bottom, 8)
        }
    }

    private var authorizationEditor: some View {
        VStack(alignment: .leading, spacing: 9) {
            Picker("Authorization", selection: $model.authKind) {
                ForEach(EndpointTesterModel.AuthKind.allCases) { Text($0.rawValue).tag($0) }
            }
            .frame(width: 220)
            Group {
                switch model.authKind {
                case .none:
                    Text("This request does not add authorization.").foregroundStyle(.secondary)
                case .bearer:
                    SecureField("Token", text: $model.bearerToken)
                case .basic:
                    HStack { TextField("Username", text: $model.username); SecureField("Password", text: $model.password) }
                case .apiKey:
                    HStack {
                        TextField("Key name", text: $model.apiKeyName)
                        SecureField("Value", text: $model.apiKeyValue)
                        Picker("Location", selection: $model.apiKeyLocation) {
                            ForEach(EndpointTesterModel.APIKeyLocation.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .frame(width: 155)
                    }
                }
            }
            .textFieldStyle(.plain)
            .padding(.horizontal, 10)
            .frame(height: 34)
            .liquidGlass(cornerRadius: 9, depth: .recessed, accentOpacity: 0.01)
            Spacer(minLength: 0)
        }
        .padding(11)
    }

    private var bodyEditor: some View {
        VStack(spacing: 7) {
            HStack {
                Picker("Body", selection: $model.bodyKind) {
                    ForEach(EndpointTesterModel.BodyKind.allCases) { Text($0.rawValue).tag($0) }
                }
                .frame(width: 150)
                Spacer()
                if model.bodyKind == .json {
                    Button("Pretty", action: model.prettyPrintJSON).buttonStyle(.plain).font(.caption.weight(.medium))
                }
            }
            TextEditor(text: $model.body)
                .font(.system(size: 12, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(7)
                .disabled(model.bodyKind == .none)
                .opacity(model.bodyKind == .none ? 0.45 : 1)
                .liquidGlass(cornerRadius: 9, depth: .recessed, accentOpacity: 0.01)
        }
        .padding(9)
    }

    private var responseViewer: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                if let response = model.response {
                    Circle().fill(response.succeeded ? Color.green : Color.orange).frame(width: 7, height: 7)
                    Text(String(response.statusCode)).font(.callout.monospacedDigit().bold())
                    Text(String(format: "%.0f ms", response.elapsed * 1_000)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    Text(ByteCountFormatter.string(fromByteCount: Int64(response.byteCount), countStyle: .file))
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                } else if let error = model.error {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(error).font(.caption.weight(.medium)).lineLimit(1)
                } else {
                    Text("RESPONSE").font(.caption2.bold()).foregroundStyle(.secondary)
                }
                Spacer()
                Picker("Response", selection: $model.responseTab) {
                    ForEach(EndpointTesterModel.ResponseTab.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 220)
                Button(action: model.copyResponse) { Image(systemName: "doc.on.doc") }
                    .buttonStyle(.plain)
                    .help("Copy selected response view")
            }
            .padding(.horizontal, 12)
            .frame(height: 39)
            GlassHairline()
            ScrollView(.vertical) {
                Text(model.displayedResponse)
                    .font(.system(size: 11.8, design: .monospaced))
                    .foregroundStyle(model.response == nil ? .secondary : .primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(13)
            }
        }
        .liquidGlass(cornerRadius: 16, depth: .recessed, accentOpacity: 0.02)
    }
}
