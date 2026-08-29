import AppKit
import Foundation
import RayPlacementCore
import SwiftUI
import UniformTypeIdentifiers

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
        if let window { WorkspaceWindowCoordinator.shared.present(window) }
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

private struct CollectionRunResult: Identifiable {
    let id = UUID()
    let requestName: String
    let iteration: Int
    let statusCode: Int?
    let elapsed: TimeInterval
    let error: String?

    var succeeded: Bool { statusCode.map { (200..<400).contains($0) } ?? false }
}

@MainActor
private final class EndpointTesterModel: ObservableObject {
    enum SidebarMode: String, CaseIterable, Identifiable {
        case collections = "Collections"
        case history = "History"
        var id: String { rawValue }
    }
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
    @Published var sidebarMode: SidebarMode = .collections
    @Published var collections: [PostmanCollection] = []
    @Published var environments: [PostmanEnvironment] = []
    @Published var selectedEnvironmentID: UUID?
    @Published var selectedCollectionID: UUID?
    @Published var selectedRequestID: UUID?
    @Published var isRunnerPresented = false
    @Published var runnerIterations = 1
    @Published var runnerDelayMilliseconds = 0
    @Published var runnerResults: [CollectionRunResult] = []
    @Published var runnerProgress = ""
    @Published var isRunnerRunning = false
    @Published var isEnvironmentEditorPresented = false
    @Published var isEnvironmentDeleteConfirmationPresented = false
    @Published var environmentDraftName = ""
    @Published var environmentDraftRows = [EndpointKeyValueRow()]

    private var task: URLSessionDataTask?
    private var usageTask: UUID?
    private var runnerTask: Task<Void, Never>?
    private var editingEnvironmentID: UUID?

    init() {
        loadWorkspace()
    }

    var selectedEnvironmentName: String {
        environments.first(where: { $0.id == selectedEnvironmentID })?.name ?? "No environment"
    }

    var selectedCollection: PostmanCollection? {
        collections.first { $0.id == selectedCollectionID }
    }

    var canDeleteEditingEnvironment: Bool { editingEnvironmentID != nil }

    var resolvedVariables: [String: String] {
        var values = selectedCollection?.variables ?? [:]
        if let environment = environments.first(where: { $0.id == selectedEnvironmentID }) {
            values.merge(environment.resolvedValues) { _, environmentValue in environmentValue }
        }
        return values
    }

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

    func importPostmanDocuments() {
        let panel = NSOpenPanel()
        panel.title = "Import Postman collections or environments"
        panel.prompt = "Import"
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        var importedNames: [String] = []
        do {
            for url in panel.urls {
                switch try PostmanImporter.decode(Data(contentsOf: url)) {
                case .collection(let collection):
                    collections.removeAll { $0.name == collection.name }
                    collections.append(collection)
                    selectedCollectionID = collection.id
                    importedNames.append(collection.name)
                    if let request = collection.requests.first { load(request, collectionID: collection.id) }
                case .environment(let environment):
                    environments.removeAll { $0.name == environment.name }
                    environments.append(environment)
                    selectedEnvironmentID = environment.id
                    importedNames.append(environment.name)
                }
            }
            saveWorkspace()
            error = importedNames.isEmpty ? "No Postman data was found." : nil
            sidebarMode = .collections
        } catch {
            self.error = error.localizedDescription
        }
    }

    func load(_ request: PostmanRequest, collectionID: UUID) {
        selectedCollectionID = collectionID
        selectedRequestID = request.id
        method = request.method
        urlText = request.url
        parameters = request.parameters.map { EndpointKeyValueRow(enabled: $0.enabled, key: $0.key, value: $0.value) }
        if parameters.isEmpty { parameters = [EndpointKeyValueRow()] }
        headers = request.headers.map { EndpointKeyValueRow(enabled: $0.enabled, key: $0.key, value: $0.value) }
        if headers.isEmpty { headers = [EndpointKeyValueRow()] }
        body = request.body
        switch request.contentType?.lowercased() {
        case let type where type?.contains("json") == true: bodyKind = .json
        case let type where type?.contains("xml") == true: bodyKind = .xml
        case .some: bodyKind = request.body.isEmpty ? .none : .text
        case .none: bodyKind = request.body.isEmpty ? .none : .text
        }
        apply(request.authorization)
        error = nil
    }

    func selectEnvironment(_ id: UUID?) {
        selectedEnvironmentID = id
        saveWorkspace()
    }

    func presentEnvironmentEditor(createNew: Bool = false) {
        if !createNew,
           let environment = environments.first(where: { $0.id == selectedEnvironmentID }) {
            editingEnvironmentID = environment.id
            environmentDraftName = environment.name
            environmentDraftRows = environment.values.map {
                EndpointKeyValueRow(enabled: $0.enabled, key: $0.key, value: $0.value)
            }
        } else {
            editingEnvironmentID = nil
            environmentDraftName = "New Environment"
            environmentDraftRows = [EndpointKeyValueRow()]
        }
        if environmentDraftRows.isEmpty { environmentDraftRows = [EndpointKeyValueRow()] }
        isEnvironmentEditorPresented = true
    }

    func addEnvironmentVariable() { environmentDraftRows.append(EndpointKeyValueRow()) }

    func removeEnvironmentVariable(_ id: UUID) {
        environmentDraftRows.removeAll { $0.id == id }
        if environmentDraftRows.isEmpty { environmentDraftRows = [EndpointKeyValueRow()] }
    }

    func saveEnvironment() {
        let name = environmentDraftName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            error = "Give the environment a name."
            return
        }
        let values = environmentDraftRows.compactMap { row -> PostmanKeyValue? in
            let key = row.key.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { return nil }
            return PostmanKeyValue(key: key, value: row.value, enabled: row.enabled)
        }
        let id = editingEnvironmentID ?? UUID()
        let environment = PostmanEnvironment(id: id, name: name, values: values)
        if let index = environments.firstIndex(where: { $0.id == id }) {
            environments[index] = environment
        } else {
            environments.append(environment)
        }
        selectedEnvironmentID = id
        saveWorkspace()
        isEnvironmentEditorPresented = false
        error = nil
    }

    func requestDeleteEditingEnvironment() {
        guard editingEnvironmentID != nil else { return }
        isEnvironmentDeleteConfirmationPresented = true
    }

    func deleteEditingEnvironment() {
        guard let id = editingEnvironmentID else { return }
        deleteEnvironment(id)
        editingEnvironmentID = nil
        isEnvironmentDeleteConfirmationPresented = false
        isEnvironmentEditorPresented = false
    }

    func deleteCollection(_ id: UUID) {
        collections.removeAll { $0.id == id }
        if selectedCollectionID == id {
            selectedCollectionID = collections.first?.id
            selectedRequestID = nil
        }
        saveWorkspace()
    }

    func deleteEnvironment(_ id: UUID) {
        environments.removeAll { $0.id == id }
        if selectedEnvironmentID == id { selectedEnvironmentID = nil }
        saveWorkspace()
    }

    func presentRunner() {
        guard selectedCollection != nil else {
            error = "Import or select a collection before opening the runner."
            return
        }
        runnerResults = []
        runnerProgress = "Ready"
        isRunnerPresented = true
    }

    func startRunner() {
        guard !isRunnerRunning, let collection = selectedCollection else { return }
        let iterations = max(1, runnerIterations)
        let delay = max(0, runnerDelayMilliseconds)
        let (total, overflowed) = iterations.multipliedReportingOverflow(by: collection.requests.count)
        guard !collection.requests.isEmpty else {
            runnerProgress = "This collection has no requests."
            return
        }
        guard !overflowed else {
            runnerProgress = "The requested run count is too large for this Mac."
            return
        }
        runnerResults = []
        isRunnerRunning = true
        runnerTask = Task { [weak self] in
            guard let self else { return }
            var completed = 0
            for iteration in 1...iterations {
                for imported in collection.requests {
                    guard !Task.isCancelled else {
                        self.isRunnerRunning = false
                        self.runnerProgress = "Cancelled · \(completed)/\(total)"
                        return
                    }
                    self.runnerProgress = "\(completed + 1) of \(total) · \(imported.name)"
                    let started = Date()
                    do {
                        let request = try self.buildRequest(for: imported, collection: collection)
                        let (_, response) = try await URLSession.shared.data(for: request)
                        let status = (response as? HTTPURLResponse)?.statusCode
                        self.runnerResults.append(CollectionRunResult(
                            requestName: imported.name,
                            iteration: iteration,
                            statusCode: status,
                            elapsed: Date().timeIntervalSince(started),
                            error: nil
                        ))
                    } catch {
                        self.runnerResults.append(CollectionRunResult(
                            requestName: imported.name,
                            iteration: iteration,
                            statusCode: nil,
                            elapsed: Date().timeIntervalSince(started),
                            error: error.localizedDescription
                        ))
                    }
                    completed += 1
                    if delay > 0, completed < total {
                        try? await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000)
                    }
                }
            }
            self.isRunnerRunning = false
            self.runnerProgress = "Complete · \(completed) requests"
        }
    }

    func cancelRunner() {
        runnerTask?.cancel()
        runnerTask = nil
        isRunnerRunning = false
    }

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
        if isRunning {
            task?.cancel()
            task = nil
            isRunning = false
            finishUsage(succeeded: false, detail: "Cancelled by user")
        }
        cancelRunner()
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
        let variables = resolvedVariables
        let rawURL = resolve(urlText, with: variables).trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: rawURL),
              let scheme = components.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              components.host != nil else {
            throw EndpointTesterError.invalidURL
        }

        var queryItems = components.queryItems ?? []
        for item in parameters where item.enabled && !item.key.trimmingCharacters(in: .whitespaces).isEmpty {
            queryItems.append(URLQueryItem(name: resolve(item.key, with: variables), value: resolve(item.value, with: variables)))
        }
        if authKind == .apiKey, apiKeyLocation == .query, !apiKeyName.isEmpty {
            queryItems.append(URLQueryItem(name: resolve(apiKeyName, with: variables), value: resolve(apiKeyValue, with: variables)))
        }
        components.queryItems = queryItems.isEmpty ? nil : queryItems
        guard let url = components.url else { throw EndpointTesterError.invalidURL }

        var request = URLRequest(url: url)
        request.httpMethod = method
        let configuredTimeout = 30.0
        let performanceTimeout = SettingsStore.shared.runtimeExtensionPerformance.extensionTimeout
        request.timeoutInterval = performanceTimeout > 0 ? min(configuredTimeout, performanceTimeout) : configuredTimeout

        for header in headers where header.enabled && !header.key.trimmingCharacters(in: .whitespaces).isEmpty {
            request.setValue(resolve(header.value, with: variables), forHTTPHeaderField: resolve(header.key, with: variables))
        }
        switch authKind {
        case .none:
            break
        case .bearer:
            if !bearerToken.isEmpty { request.setValue("Bearer \(resolve(bearerToken, with: variables))", forHTTPHeaderField: "Authorization") }
        case .basic:
            let credential = Data("\(resolve(username, with: variables)):\(resolve(password, with: variables))".utf8).base64EncodedString()
            request.setValue("Basic \(credential)", forHTTPHeaderField: "Authorization")
        case .apiKey:
            if apiKeyLocation == .header, !apiKeyName.isEmpty {
                request.setValue(resolve(apiKeyValue, with: variables), forHTTPHeaderField: resolve(apiKeyName, with: variables))
            }
        }

        if bodyKind != .none {
            if bodyKind == .json, !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let resolvedBody = resolve(body, with: variables)
                guard let data = resolvedBody.data(using: .utf8), (try? JSONSerialization.jsonObject(with: data)) != nil else {
                    throw EndpointTesterError.invalidJSON
                }
            }
            request.httpBody = Data(resolve(body, with: variables).utf8)
            if request.value(forHTTPHeaderField: "Content-Type") == nil, let contentType = bodyKind.contentType {
                request.setValue(contentType, forHTTPHeaderField: "Content-Type")
            }
        }
        return request
    }

    private func buildRequest(for imported: PostmanRequest, collection: PostmanCollection) throws -> URLRequest {
        var variables = collection.variables
        if let environment = environments.first(where: { $0.id == selectedEnvironmentID }) {
            variables.merge(environment.resolvedValues) { _, environmentValue in environmentValue }
        }
        let rawURL = resolve(imported.url, with: variables)
        guard var components = URLComponents(string: rawURL),
              let scheme = components.scheme?.lowercased(),
              ["http", "https"].contains(scheme), components.host != nil else {
            throw EndpointTesterError.invalidURL
        }
        var query = components.queryItems ?? []
        query += imported.parameters.filter(\.enabled).map {
            URLQueryItem(name: resolve($0.key, with: variables), value: resolve($0.value, with: variables))
        }
        if imported.authorization.kind == .apiKey,
           imported.authorization.values["in"]?.lowercased() == "query" {
            let key = resolve(imported.authorization.values["key"] ?? "", with: variables)
            let value = resolve(imported.authorization.values["value"] ?? "", with: variables)
            if !key.isEmpty {
                query.append(URLQueryItem(name: key, value: value))
            }
        }
        components.queryItems = query.isEmpty ? nil : query
        guard let finalURL = components.url else { throw EndpointTesterError.invalidURL }
        var request = URLRequest(url: finalURL)
        request.httpMethod = imported.method
        let timeout = SettingsStore.shared.runtimeExtensionPerformance.extensionTimeout
        request.timeoutInterval = timeout > 0 ? timeout : 60
        for header in imported.headers where header.enabled {
            request.setValue(resolve(header.value, with: variables), forHTTPHeaderField: resolve(header.key, with: variables))
        }
        apply(imported.authorization, to: &request, variables: variables)
        if !imported.body.isEmpty {
            request.httpBody = Data(resolve(imported.body, with: variables).utf8)
            if request.value(forHTTPHeaderField: "Content-Type") == nil, let type = imported.contentType {
                request.setValue(type, forHTTPHeaderField: "Content-Type")
            }
        }
        return request
    }

    private func apply(_ authorization: PostmanAuthorization) {
        switch authorization.kind {
        case .none:
            authKind = .none
        case .bearer:
            authKind = .bearer
            bearerToken = authorization.values["token"] ?? ""
        case .basic:
            authKind = .basic
            username = authorization.values["username"] ?? ""
            password = authorization.values["password"] ?? ""
        case .apiKey:
            authKind = .apiKey
            apiKeyName = authorization.values["key"] ?? ""
            apiKeyValue = authorization.values["value"] ?? ""
            apiKeyLocation = authorization.values["in"]?.lowercased() == "query" ? .query : .header
        }
    }

    private func apply(_ authorization: PostmanAuthorization, to request: inout URLRequest, variables: [String: String]) {
        switch authorization.kind {
        case .none: break
        case .bearer:
            let token = resolve(authorization.values["token"] ?? "", with: variables)
            if !token.isEmpty { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        case .basic:
            let user = resolve(authorization.values["username"] ?? "", with: variables)
            let password = resolve(authorization.values["password"] ?? "", with: variables)
            request.setValue("Basic \(Data("\(user):\(password)".utf8).base64EncodedString())", forHTTPHeaderField: "Authorization")
        case .apiKey:
            let key = resolve(authorization.values["key"] ?? "", with: variables)
            let value = resolve(authorization.values["value"] ?? "", with: variables)
            if authorization.values["in"]?.lowercased() != "query", !key.isEmpty {
                request.setValue(value, forHTTPHeaderField: key)
            }
        }
    }

    private func resolve(_ value: String, with variables: [String: String]) -> String {
        PostmanVariableResolver.resolve(value, values: variables)
    }

    private struct SavedWorkspace: Codable {
        var collections: [PostmanCollection]
        var environments: [PostmanEnvironment]
        var selectedEnvironmentID: UUID?
    }

    private var workspaceURL: URL {
        ApplicationPaths.applicationSupport.appendingPathComponent("api-workspace.json")
    }

    private func loadWorkspace() {
        guard let data = try? Data(contentsOf: workspaceURL),
              let saved = try? JSONDecoder().decode(SavedWorkspace.self, from: data) else { return }
        collections = saved.collections
        environments = saved.environments
        selectedEnvironmentID = saved.selectedEnvironmentID
        selectedCollectionID = collections.first?.id
    }

    private func saveWorkspace() {
        do {
            try ApplicationPaths.prepare()
            let data = try JSONEncoder().encode(SavedWorkspace(
                collections: collections,
                environments: environments,
                selectedEnvironmentID: selectedEnvironmentID
            ))
            try data.write(to: workspaceURL, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: workspaceURL.path)
        } catch {
            self.error = "Could not save API workspace: \(error.localizedDescription)"
        }
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
                    sidebar
                        .frame(minWidth: 190, idealWidth: 225, maxWidth: 285)
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
        .sheet(isPresented: $model.isRunnerPresented) {
            collectionRunner
        }
        .sheet(isPresented: $model.isEnvironmentEditorPresented) {
            environmentEditor
        }
    }

    private var header: some View {
        HStack(spacing: 9) {
            Image(systemName: "network")
                .foregroundStyle(SettingsStore.shared.accentTheme.gradient)
            Text("Endpoint Tester")
                .font(.system(size: 15, weight: .semibold, design: .rounded))
            Spacer()
            if model.isRunning {
                ProgressView().controlSize(.small)
                Text("Sending").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            }
            Menu {
                Button("No environment") { model.selectEnvironment(nil) }
                if !model.environments.isEmpty { Divider() }
                ForEach(model.environments) { environment in
                    Button {
                        model.selectEnvironment(environment.id)
                    } label: {
                        if environment.id == model.selectedEnvironmentID {
                            Label(environment.name, systemImage: "checkmark")
                        } else { Text(environment.name) }
                    }
                }
                Divider()
                Button("Edit Current…") { model.presentEnvironmentEditor() }
                Button("New Environment…") { model.presentEnvironmentEditor(createNew: true) }
            } label: {
                Label(model.selectedEnvironmentName, systemImage: "slider.horizontal.3")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            Button { model.presentEnvironmentEditor() } label: { Image(systemName: "slider.horizontal.3") }
                .help("Edit environment variables")
            Button(action: model.importPostmanDocuments) { Image(systemName: "square.and.arrow.down") }
                .help("Import Postman collection or environment")
            Button(action: model.presentRunner) { Image(systemName: "play.rectangle.on.rectangle") }
                .help("Run selected collection")
            Button("cURL", action: model.copyAsCURL)
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        .padding(.horizontal, 13)
        .frame(height: 44)
        .liquidGlass(cornerRadius: 15, depth: .raised, accentOpacity: 0.038)
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            Picker("Sidebar", selection: $model.sidebarMode) {
                ForEach(EndpointTesterModel.SidebarMode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(7)
            GlassHairline()
            Group {
                switch model.sidebarMode {
                case .collections:
                    if model.collections.isEmpty {
                        emptySidebar(symbol: "tray.and.arrow.down", title: "Import a Postman collection")
                    } else {
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 5) {
                                ForEach(model.collections) { collection in
                                    VStack(alignment: .leading, spacing: 3) {
                                        HStack(spacing: 6) {
                                            Image(systemName: "shippingbox.fill").foregroundStyle(.secondary)
                                            Text(collection.name).font(.caption.weight(.semibold)).lineLimit(1)
                                            Spacer()
                                            Menu { Button("Remove", role: .destructive) { model.deleteCollection(collection.id) } } label: {
                                                Image(systemName: "ellipsis").foregroundStyle(.secondary)
                                            }
                                            .menuStyle(.borderlessButton)
                                            .fixedSize()
                                        }
                                        .padding(.horizontal, 7)
                                        ForEach(collection.requests) { request in
                                            Button { model.load(request, collectionID: collection.id) } label: {
                                                HStack(spacing: 6) {
                                                    Text(request.method)
                                                        .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                                                        .foregroundStyle(SettingsStore.shared.accentTheme.primary)
                                                        .frame(width: 36, alignment: .leading)
                                                    VStack(alignment: .leading, spacing: 1) {
                                                        Text(request.name).font(.caption.weight(.medium)).lineLimit(1)
                                                        if !request.folderPath.isEmpty {
                                                            Text(request.folderPath.joined(separator: " / "))
                                                                .font(.system(size: 9.5))
                                                                .foregroundStyle(.tertiary)
                                                                .lineLimit(1)
                                                        }
                                                    }
                                                    Spacer(minLength: 0)
                                                }
                                                .padding(.horizontal, 7)
                                                .frame(height: request.folderPath.isEmpty ? 29 : 36)
                                                .contentShape(Rectangle())
                                            }
                                            .buttonStyle(.plain)
                                            .liquidGlass(
                                                cornerRadius: 8,
                                                depth: request.id == model.selectedRequestID ? .raised : .recessed,
                                                selected: request.id == model.selectedRequestID,
                                                accentOpacity: request.id == model.selectedRequestID ? 0.08 : 0.005
                                            )
                                        }
                                    }
                                    .padding(.vertical, 4)
                                }
                            }
                            .padding(6)
                        }
                    }
                case .history:
                    if model.history.isEmpty {
                        emptySidebar(symbol: "clock.arrow.circlepath", title: "Sent requests appear here")
                    } else {
                        ScrollView {
                            LazyVStack(spacing: 4) {
                                ForEach(model.history) { entry in
                                    Button { model.load(entry) } label: {
                                        VStack(alignment: .leading, spacing: 3) {
                                            HStack(spacing: 5) {
                                                Text(entry.method).font(.caption2.monospaced().bold()).foregroundStyle(SettingsStore.shared.accentTheme.primary)
                                                Spacer()
                                                if let status = entry.statusCode { Text(String(status)).font(.caption2.monospacedDigit()).foregroundStyle(.secondary) }
                                            }
                                            Text(entry.title).font(.caption.weight(.medium)).lineLimit(1)
                                            Text(entry.sentAt.formatted(date: .omitted, time: .shortened)).font(.caption2).foregroundStyle(.tertiary)
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
            }
            if model.sidebarMode == .history, !model.history.isEmpty {
                GlassHairline()
                Button("Clear history", action: model.clearHistory)
                    .buttonStyle(.plain)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(height: 30)
            }
        }
        .liquidGlass(cornerRadius: 16, depth: .floating, accentOpacity: 0.018)
    }

    private func emptySidebar(symbol: String, title: String) -> some View {
        VStack(spacing: 7) {
            Spacer()
            Image(systemName: symbol).font(.system(size: 18)).foregroundStyle(.tertiary)
            Text(title).font(.caption2).foregroundStyle(.tertiary).multilineTextAlignment(.center)
            if model.sidebarMode == .collections {
                Button("Import", action: model.importPostmanDocuments).buttonStyle(.bordered).controlSize(.small)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(12)
    }

    private var collectionRunner: some View {
        ZStack {
            LiquidGlassBackdrop(material: .underWindowBackground, blendingMode: .behindWindow)
            VStack(spacing: 10) {
                HStack {
                    Image(systemName: "play.rectangle.on.rectangle.fill").foregroundStyle(SettingsStore.shared.accentTheme.gradient)
                    Text(model.selectedCollection?.name ?? "Collection Runner").font(.headline)
                    Spacer()
                    Text(model.runnerProgress).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 13)
                .frame(height: 42)
                .liquidGlass(cornerRadius: 14, depth: .raised, accentOpacity: 0.04)
                HStack(spacing: 12) {
                    TextField("Iterations", value: $model.runnerIterations, format: .number)
                        .frame(width: 105)
                    TextField("Delay (ms)", value: $model.runnerDelayMilliseconds, format: .number)
                        .frame(width: 120)
                    Spacer()
                    if model.isRunnerRunning {
                        Button("Cancel", action: model.cancelRunner).buttonStyle(.bordered)
                    } else {
                        Button("Run", action: model.startRunner).buttonStyle(.borderedProminent)
                    }
                }
                .textFieldStyle(.roundedBorder)
                ScrollView {
                    LazyVStack(spacing: 5) {
                        ForEach(model.runnerResults) { result in
                            HStack(spacing: 8) {
                                Circle().fill(result.succeeded ? Color.green : Color.orange).frame(width: 6, height: 6)
                                Text("#\(result.iteration)").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                                Text(result.requestName).font(.caption.weight(.medium)).lineLimit(1)
                                Spacer()
                                if let status = result.statusCode { Text(String(status)).font(.caption.monospacedDigit().bold()) }
                                Text(String(format: "%.0f ms", result.elapsed * 1_000)).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                                if let error = result.error { Text(error).font(.caption2).foregroundStyle(.orange).lineLimit(1).frame(maxWidth: 180) }
                            }
                            .padding(.horizontal, 10)
                            .frame(height: 34)
                            .liquidGlass(cornerRadius: 9, depth: .recessed, accentOpacity: 0.01)
                        }
                    }
                    .padding(5)
                }
                .liquidGlass(cornerRadius: 14, depth: .recessed, accentOpacity: 0.015)
            }
            .padding(11)
        }
        .frame(width: 720, height: 510)
        .preferredColorScheme(.dark)
    }

    private var environmentEditor: some View {
        ZStack {
            LiquidGlassBackdrop(material: .underWindowBackground, blendingMode: .behindWindow)
            VStack(spacing: 10) {
                HStack(spacing: 9) {
                    Image(systemName: "slider.horizontal.3")
                        .foregroundStyle(SettingsStore.shared.accentTheme.gradient)
                    TextField("Environment name", text: $model.environmentDraftName)
                        .textFieldStyle(.plain)
                        .font(.headline)
                    Spacer()
                    if model.canDeleteEditingEnvironment {
                        Button(role: .destructive, action: model.requestDeleteEditingEnvironment) {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.bordered)
                        .help("Delete this environment")
                    }
                    Button("Cancel") { model.isEnvironmentEditorPresented = false }
                        .buttonStyle(.bordered)
                    Button("Save", action: model.saveEnvironment)
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.return, modifiers: [.command])
                }
                .padding(.horizontal, 13)
                .frame(height: 43)
                .liquidGlass(cornerRadius: 14, depth: .raised, accentOpacity: 0.04)

                VStack(spacing: 6) {
                    HStack {
                        Text("VARIABLES").font(.caption2.bold()).foregroundStyle(.secondary)
                        Spacer()
                        Button { model.addEnvironmentVariable() } label: { Label("Add", systemImage: "plus") }
                            .buttonStyle(.plain)
                            .font(.caption.weight(.medium))
                    }
                    ScrollView {
                        LazyVStack(spacing: 5) {
                            ForEach($model.environmentDraftRows) { $row in
                                HStack(spacing: 7) {
                                    Toggle("", isOn: $row.enabled).labelsHidden().toggleStyle(.checkbox)
                                    TextField("Variable", text: $row.key).textFieldStyle(.plain)
                                    Rectangle().fill(Color.white.opacity(0.10)).frame(width: 0.7, height: 18)
                                    TextField("Value", text: $row.value).textFieldStyle(.plain)
                                    Button { model.removeEnvironmentVariable(row.id) } label: { Image(systemName: "minus.circle") }
                                        .buttonStyle(.plain).foregroundStyle(.secondary)
                                }
                                .padding(.horizontal, 9)
                                .frame(height: 32)
                                .liquidGlass(cornerRadius: 8, depth: .recessed, accentOpacity: 0.008)
                            }
                        }
                    }
                }
                .padding(11)
                .liquidGlass(cornerRadius: 14, depth: .recessed, accentOpacity: 0.015)
            }
            .padding(11)
        }
        .frame(width: 640, height: 430)
        .preferredColorScheme(.dark)
        .confirmationDialog(
            "Delete this environment?",
            isPresented: $model.isEnvironmentDeleteConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("Delete Environment", role: .destructive) { model.deleteEditingEnvironment() }
        } message: {
            Text("This removes its local variables and secret references. It cannot affect the remote service.")
        }
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
