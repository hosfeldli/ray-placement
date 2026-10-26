import Foundation
import Testing
@testable import RayPlacement

@Test func cloudDictationCleanupRequestContainsOnlyTranscript() throws {
    let request = try OpenAICloudDictationPostprocessor.request(
        transcript: "  hello comma world  ", apiKey: "test-only-key"
    )
    #expect(request.url?.absoluteString == "https://api.openai.com/v1/responses")
    #expect(request.httpMethod == "POST")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-only-key")
    let body = try #require(request.httpBody)
    let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
    #expect(object["model"] as? String == OpenAICloudDictationPostprocessor.model)
    #expect(object["store"] as? Bool == false)
    #expect(object["input"] as? String == "hello comma world")
    #expect(!String(decoding: body, as: UTF8.self).contains("clipboard"))
    #expect(!String(decoding: body, as: UTF8.self).contains("notes"))
}

@Test func cloudDictationCleanupRejectsUnboundedOrInvalidInput() throws {
    #expect(throws: OpenAICloudDictationPostprocessor.Failure.invalidInput) {
        _ = try OpenAICloudDictationPostprocessor.request(
            transcript: String(repeating: "a", count: OpenAICloudDictationPostprocessor.maximumInputCharacters + 1),
            apiKey: "test-only-key"
        )
    }
    #expect(throws: OpenAICloudDictationPostprocessor.Failure.invalidInput) {
        _ = try OpenAICloudDictationPostprocessor.request(transcript: "  ", apiKey: "test-only-key")
    }
}

@Test func cloudDictationCleanupParsesOnlyOutputText() throws {
    let data = Data(#"{"status":"completed","output":[{"type":"reasoning","content":[]},{"type":"message","content":[{"type":"output_text","text":"  Hello, world.  "}]}]}"#.utf8)
    #expect(try OpenAICloudDictationPostprocessor.parse(data, status: 200) == "Hello, world.")
    #expect(throws: OpenAICloudDictationPostprocessor.Failure.invalidResponse) {
        _ = try OpenAICloudDictationPostprocessor.parse(Data(#"{"output":[]}"#.utf8), status: 200)
    }
    #expect(throws: OpenAICloudDictationPostprocessor.Failure.invalidResponse) {
        let partial = Data(#"{"status":"incomplete","output":[{"type":"message","content":[{"type":"output_text","text":"partial"}]}]}"#.utf8)
        _ = try OpenAICloudDictationPostprocessor.parse(partial, status: 200)
    }
    #expect(throws: OpenAICloudDictationPostprocessor.Failure.rejected(429)) {
        _ = try OpenAICloudDictationPostprocessor.parse(Data(), status: 429)
    }
}
