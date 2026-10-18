import Foundation
import Testing
@testable import RayPlacement

private final class MockGrammarHTTPProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "127.0.0.1" && request.url?.path == "/v1/chat/completions"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let correction = #"{"changes":[{"find":"This are","replacement":"This is","before":null,"after":null}]}"#
        let payload: [String: Any] = [
            "choices": [["message": ["content": correction]]]
        ]
        let data = try! JSONSerialization.data(withJSONObject: payload)
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private actor UnexpectedGrammarCLIRuntime: GrammarToolFreeRuntime {
    private var count = 0

    func infer(_ request: GrammarToolFreeRequest) async throws -> String {
        count += 1
        throw StealthGrammarRemoteClient.ClientError.invalidConfiguration
    }

    func calls() -> Int { count }
}

@Test @MainActor func grammarHTTPProviderStillUsesRemoteCorrectionAfterCLIRouting() async throws {
    let sessionConfiguration = URLSessionConfiguration.ephemeral
    sessionConfiguration.protocolClasses = [MockGrammarHTTPProtocol.self]
    let session = URLSession(configuration: sessionConfiguration)
    defer { session.invalidateAndCancel() }

    let runtime = UnexpectedGrammarCLIRuntime()
    let client = GrammarInferenceClient(
        remote: StealthGrammarRemoteClient(session: session),
        runtime: runtime
    )
    let provider = DeveloperGrammarConfiguration(
        provider: .openAICompatible, apiKey: "", model: "fixture-model",
        baseURL: "http://127.0.0.1:1234/v1"
    )
    let changes = try await client.correctDocument(
        "This are correct.", configuration: provider,
        systemPrompt: StealthGrammarRemoteClient.systemPrompt,
        temperature: 0.1, reasoningEffort: nil
    )

    #expect(changes.count == 1)
    #expect(changes.first?.find == "This are")
    #expect(changes.first?.replacement == "This is")
    #expect(await runtime.calls() == 0)
}
