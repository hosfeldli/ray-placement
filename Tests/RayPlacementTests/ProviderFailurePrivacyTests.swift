import Foundation
import Testing
@testable import RayPlacement

@Test func providerFailuresNeverEchoRawBodiesMessagesOrUnknownFields() throws {
    let secret = "private-document-text-and-api-key"
    let body = try JSONSerialization.data(withJSONObject: [
        "error": ["message": secret, "code": secret, "param": secret]
    ])
    for status in [400, 401, 403, 404, 429, 500] {
        #expect(!AIProviderHTTP.failure(status, body).contains(secret))
    }
    #expect(!AIProviderHTTP.failure(400, Data(secret.utf8)).contains(secret))
    #expect(AIProviderFailure.code(secret) == nil)
    #expect(AIProviderFailure.parameter(secret) == nil)
    #expect(AIProviderFailure.parameter("tools[0].parameters.properties.sk_private_value.format") == "tools")
    #expect(AIProviderFailure.message(error: ["code": "invalid_prompt", "message": secret]) == "The input is invalid.")
}

@Test func providerFailurePreservesOnlyWhitelistedActionableDetails() throws {
    let secret = "private-document-text-and-api-key"
    let body = try JSONSerialization.data(withJSONObject: [
        "error": [
            "code": "unsupported_parameter",
            "param": "reasoning.summary",
            "message": secret
        ]
    ])
    let details = AIProviderFailure.details(data: body, status: 400)
    #expect(details.code == "unsupported_parameter")
    #expect(details.parameter == "reasoning.summary")
    #expect(!details.message.contains(secret))

    let presentation = AIProviderFailure.presentation(
        provider: "OpenAI",
        model: "gpt-6-luna",
        status: 400,
        code: details.code,
        parameter: details.parameter,
        fallback: details.message
    )
    #expect(presentation.contains("OpenAI rejected this request"))
    #expect(presentation.contains("HTTP 400 · gpt-6-luna"))
    #expect(presentation.contains("Unsupported request option: reasoning.summary."))
    #expect(!presentation.contains(secret))
    #expect(!AIProviderFailure.presentation(
        provider: "OpenAI",
        model: secret,
        status: 400,
        code: details.code,
        parameter: details.parameter,
        fallback: details.message
    ).contains(secret))
}

@Test func providerFailureMapsVerifiedToolSchemaPathToKnownLimaTool() throws {
    let path = "tools[6].parameters.properties.urls.items.format"
    let body = try JSONSerialization.data(withJSONObject: [
        "error": [
            "code": "invalid_request_error",
            "param": path,
            "message": "This provider text must not be shown."
        ]
    ])
    let details = AIProviderFailure.details(data: body, status: 400)
    #expect(details.parameter == path)

    let parameters: [String: Any] = [
        "type": "object",
        "properties": [
            "urls": [
                "type": "array",
                "items": ["type": "string", "format": "email"]
            ]
        ],
        "required": ["urls"],
        "additionalProperties": false
    ]
    var outgoingTools = Array(repeating: ["type": "mcp"] as [String: Any], count: 6)
    outgoingTools.append([
        "type": "function",
        "name": "browser_open_tabs",
        "parameters": parameters
    ])

    let toolName = AIProviderFailure.localToolName(
        forSchemaParameter: details.parameter,
        outgoingTools: outgoingTools
    )
    #expect(toolName == "browser_open_tabs")

    let presentation = AIProviderFailure.presentation(
        provider: "OpenAI",
        model: "gpt-6-luna",
        status: 400,
        code: details.code,
        parameter: details.parameter,
        fallback: details.message,
        toolName: toolName
    )
    #expect(presentation.contains("The model rejected a Lima tool schema."))
    #expect(presentation.contains("Tool: browser_open_tabs"))
    #expect(presentation.contains("Schema field: urls.items.format."))
    #expect(!presentation.contains("This provider text must not be shown."))
}

@Test func responsesFailureSanitizesNestedAndTopLevelProviderErrors() throws {
    let secret = "private-document-text-and-api-key"
    for type in ["error", "response.failed"] {
        let error: [String: Any] = ["code": secret, "param": secret, "message": secret]
        let payload: [String: Any] = type == "error" ? ["error": error] : ["response": ["id": "fixture", "error": error]]
        let data = try JSONSerialization.data(withJSONObject: payload)
        let events = AIResponsesEventDecoder.events(eventType: type, dataLines: [String(decoding: data, as: UTF8.self)], model: "fixture-model")
        #expect(events.contains { if case .failed = $0 { return true }; return false })
        for event in events {
            if case .failed(let message) = event { #expect(!message.contains(secret)) }
            if case .diagnostic(let diagnostic) = event {
                #expect(!diagnostic.developerSummary.contains(secret))
                #expect(diagnostic.errorCode == nil)
                #expect(diagnostic.errorParameter == nil)
            }
        }
    }
    let item = AIOutputItem(phase: .completed, payload: ["type": "function_call", "error": ["message": secret]])
    #expect(item.errorMessage != nil)
    #expect(item.errorMessage?.contains(secret) == false)
}

@Test func transportAndPersistedDiagnosticsCannotEchoUntrustedDetails() throws {
    let secret = "private-document-text-and-api-key"
    let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut,
                        userInfo: [NSLocalizedDescriptionKey: secret, NSURLErrorFailingURLStringErrorKey: secret])
    #expect(AIProviderFailure.transport(error).contains("timed out"))
    #expect(!AIProviderFailure.sanitizedError(error).userInfo.description.contains(secret))
    #expect(!AIProviderFailure.transport(AIChatResponsesClient.ClientError.requestFailed(401, secret)).contains(secret))
    let diagnostic = AIChatDiagnostic(stage: .api, endpoint: secret, model: secret,
        responseID: secret, eventType: secret, outputItemType: secret, toolName: secret,
        errorCode: secret, errorParameter: secret, message: secret)
    let data = try JSONEncoder().encode(diagnostic)
    #expect(!String(decoding: data, as: UTF8.self).contains(secret))
    var legacy = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    for key in ["endpoint", "model", "responseID", "eventType", "outputItemType", "toolName", "message"] {
        legacy[key] = secret
    }
    let restored = try JSONDecoder().decode(AIChatDiagnostic.self, from: JSONSerialization.data(withJSONObject: legacy))
    #expect(!restored.developerSummary.contains(secret))
    #expect(!String(decoding: try JSONEncoder().encode(restored), as: UTF8.self).contains(secret))
}

@Test func sharedSSEFramerPreservesBoundariesWhitespaceAndTrailingFrame() throws {
    for separator in ["\n", "\r\n", "\r"] {
        let wire = "event: sample" + separator + "data:  leading and trailing  " + separator + "data: second" + separator + separator
        var framer = AIProviderSSEFramer()
        var frames: [AIProviderSSEFrame] = []
        for byte in wire.utf8 { if let frame = try framer.append(byte) { frames.append(frame) } }
        #expect(frames.count == 1)
        #expect(frames.first?.event == "sample")
        #expect(frames.first?.data == " leading and trailing  \nsecond")
    }
    var framer = AIProviderSSEFramer()
    for byte in "data: tail".utf8 { _ = try framer.append(byte) }
    #expect(try framer.finish()?.data == "tail")
    #expect(try framer.finish() == nil)
}

@Test func sharedSSEFramerRejectsEveryBufferOverflowAndNeverResumes() throws {
    let cases: [(AIProviderSSEFramer, String)] = [
        (AIProviderSSEFramer(maximumLineBytes: 8), String(repeating: "x", count: 9)),
        (AIProviderSSEFramer(maximumEventBytes: 20), "data: 12345\ndata: 12345\n"),
        (AIProviderSSEFramer(maximumStreamBytes: 8), String(repeating: ":\n\n", count: 4)),
        (AIProviderSSEFramer(maximumDataLines: 1), "data: 1\ndata: 2\n")
    ]
    for (initial, wire) in cases {
        var framer = initial
        var rejected = false
        do { for byte in wire.utf8 { _ = try framer.append(byte) } }
        catch { rejected = true }
        #expect(rejected)
        #expect(framer.failed)
        #expect(throws: AIProviderSSEFramer.Failure.self) { _ = try framer.finish() }
        #expect(throws: AIProviderSSEFramer.Failure.self) { _ = try framer.append(10) }
    }
    var parser = AIResponsesSSEParser(model: nil)
    let events = parser.append(line: String(repeating: "x", count: 1_048_577))
    #expect(parser.failed)
    #expect(events.count == 1)
    #expect(events.contains { if case .failed = $0 { return true }; return false })
    #expect(parser.finish().isEmpty)
}

@Test func mcpSSEDiscoveryCannotForwardCredentialsAcrossOrigins() throws {
    let base = URL(string: "https://example.com/sse")!
    #expect(try MCPHTTPClient.validatedSSEEndpoint("/messages?session=123", relativeTo: base).host == "example.com")
    for candidate in ["https://evil.example/messages", "//evil.example/messages",
                      "http://example.com/messages", "https://example.com:444/messages",
                      "https://user:secret@example.com/messages", "https://example.com/messages#fragment"] {
        #expect(throws: (any Error).self) { _ = try MCPHTTPClient.validatedSSEEndpoint(candidate, relativeTo: base) }
    }
}

@Test func knownProviderFailureCategoriesRemainActionable() {
    #expect(AIProviderFailure.message(error: ["type": "authentication_error"]).contains("API key"))
    #expect(AIProviderFailure.message(error: ["code": "model_not_found"]).contains("model"))
    #expect(AIProviderFailure.message(error: ["code": "context_length_exceeded"]).contains("context limit"))
    #expect(AIProviderFailure.message(status: 429).contains("quota"))
    #expect(AIProviderFailure.parameter("reasoning.effort") == "reasoning.effort")
}
