import Foundation

/// Explicitly selected off-device dictation. Never reads Lima notes or chat
/// context: each request contains one recorded WAV segment and its model name.
enum OpenAICloudTranscriber {
    enum Failure: LocalizedError, Equatable {
        case missingKey
        case audioTooLarge
        case emptyTranscript
        case rejected(Int)
        case invalidResponse

        var errorDescription: String? {
            switch self {
            case .missingKey:
                return "Add an OpenAI API key in Settings → AI before using Cloud Transcription."
            case .audioTooLarge:
                return "This recording segment is too large for cloud transcription. The audio was preserved for retry."
            case .emptyTranscript:
                return "No speech was recognized in this recording segment."
            case .rejected(401), .rejected(403):
                return "OpenAI rejected the transcription key. Check the OpenAI API key in Settings → AI."
            case .rejected(429):
                return "OpenAI is rate-limiting transcription. The audio was preserved for retry."
            case .rejected:
                return "OpenAI could not transcribe this recording segment. The audio was preserved for retry."
            case .invalidResponse:
                return "OpenAI returned an unreadable transcription. The audio was preserved for retry."
            }
        }
    }

    static let model = "gpt-4o-mini-transcribe"
    static let maximumAudioBytes = 24 * 1024 * 1024
    private static let endpoint = URL(string: "https://api.openai.com/v1/audio/transcriptions")!

    static func request(audio: Data, apiKey: String, boundary: String) throws -> (URLRequest, Data) {
        guard !apiKey.isEmpty else { throw Failure.missingKey }
        guard !audio.isEmpty, audio.count <= maximumAudioBytes else { throw Failure.audioTooLarge }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 180
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        var body = Data()
        func append(_ value: String) { body.append(Data(value.utf8)) }
        append("--\(boundary)\r\nContent-Disposition: form-data; name=\"model\"\r\n\r\n\(model)\r\n")
        append("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"dictation.wav\"\r\nContent-Type: audio/wav\r\n\r\n")
        body.append(audio)
        append("\r\n--\(boundary)--\r\n")
        return (request, body)
    }

    static func parse(_ data: Data, status: Int) throws -> String {
        guard (200..<300).contains(status) else { throw Failure.rejected(status) }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = object["text"] as? String else { throw Failure.invalidResponse }
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { throw Failure.emptyTranscript }
        return clean
    }

    static func transcribe(audioURL: URL, apiKey: String, session: URLSession? = nil) async throws -> String {
        try AIRequestPolicy.shared.check()
        let audio = try await Task.detached(priority: .utility) { () throws -> Data in
            let size = (try FileManager.default.attributesOfItem(atPath: audioURL.path)[.size] as? NSNumber)?.intValue ?? 0
            guard size > 0, size <= maximumAudioBytes else { throw Failure.audioTooLarge }
            return try Data(contentsOf: audioURL)
        }.value
        try Task.checkCancellation()
        let (request, body) = try self.request(audio: audio, apiKey: apiKey, boundary: "Lima-\(UUID().uuidString)")
        let uploadSession = try session ?? AIRequestPolicy.shared.checkedSession()
        let (data, response) = try await uploadSession.upload(for: request, from: body)
        try Task.checkCancellation()
        guard let response = response as? HTTPURLResponse else { throw Failure.invalidResponse }
        return try parse(data, status: response.statusCode)
    }
}
