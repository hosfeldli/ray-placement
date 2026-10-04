import Foundation
import Testing
@testable import RayPlacement

@Test func cloudTranscriptionBuildsAudioOnlyMultipartRequest() throws {
    let audio = Data([0x52, 0x49, 0x46, 0x46, 0, 1, 2, 3])
    let (request, body) = try OpenAICloudTranscriber.request(
        audio: audio,
        apiKey: "test-only-key",
        boundary: "test-boundary"
    )
    #expect(request.url?.absoluteString == "https://api.openai.com/v1/audio/transcriptions")
    #expect(request.httpMethod == "POST")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-only-key")
    let bodyText = String(decoding: body, as: UTF8.self)
    #expect(bodyText.contains("name=\"model\""))
    #expect(bodyText.contains(OpenAICloudTranscriber.model))
    #expect(bodyText.contains("filename=\"dictation.wav\""))
    #expect(body.range(of: audio) != nil)
    #expect(!bodyText.contains("note"))
    #expect(!bodyText.contains("clipboard"))
}

private final class MockCloudTranscriptionProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "api.openai.com"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"text":"mock transcript"}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Test func cloudTranscriptionUploadsRecordedFileThroughInjectedSession() async throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("lima-cloud-test-\(UUID().uuidString).wav")
    defer { try? FileManager.default.removeItem(at: url) }
    try Data([0x52, 0x49, 0x46, 0x46, 0, 1, 2, 3]).write(to: url)
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [MockCloudTranscriptionProtocol.self]
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }
    #expect(try await OpenAICloudTranscriber.transcribe(audioURL: url, apiKey: "test-only-key", session: session) == "mock transcript")
    #expect(FileManager.default.fileExists(atPath: url.path))
}

@Test func cloudTranscriptionParsesTextAndRejectsFailures() throws {
    let response = Data(#"{"text":"  hello world  "}"#.utf8)
    #expect(try OpenAICloudTranscriber.parse(response, status: 200) == "hello world")
    do {
        _ = try OpenAICloudTranscriber.parse(Data(#"{"text":" "}"#.utf8), status: 200)
        Issue.record("Expected empty transcription to be rejected")
    } catch {
        #expect(error as? OpenAICloudTranscriber.Failure == .emptyTranscript)
    }
    do {
        _ = try OpenAICloudTranscriber.parse(Data(), status: 401)
        Issue.record("Expected authentication rejection")
    } catch {
        #expect(error as? OpenAICloudTranscriber.Failure == .rejected(401))
    }
}
