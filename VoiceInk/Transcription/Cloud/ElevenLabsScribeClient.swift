import Foundation

/// In-repo ElevenLabs speech-to-text client for plain (non-diarized) transcription that needs
/// parameters the bundled `LLMkit.ElevenLabsClient` doesn't expose — currently `no_verbatim`
/// (scribe_v2 only: strips filler words, false starts and non-speech sounds for cleaner notes).
///
/// Hits the same `/v1/speech-to-text` REST endpoint as `ElevenLabsDiarizingClient`, but omits
/// `diarize` and returns only `text`.
struct ElevenLabsScribeClient {
    private struct Response: Decodable { let text: String }

    /// Pure multipart body builder (unit-testable). `noVerbatim` emits `no_verbatim=true`.
    static func multipartBody(boundary: String, audio: Data, fileName: String,
                              model: String, language: String?, noVerbatim: Bool) -> Data {
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".data(using: .utf8)!)
        }
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(fileName)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append(audio)
        body.append("\r\n".data(using: .utf8)!)
        field("model_id", model)
        field("temperature", "0.0")
        field("tag_audio_events", "false")
        if noVerbatim { field("no_verbatim", "true") }
        if let language, !language.isEmpty { field("language_code", language) }
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        return body
    }

    /// Transcribe and return plain text. Throws on missing key / HTTP error so the caller can fall
    /// back to the normal (LLMkit) path.
    static func transcribe(audioData: Data, fileName: String, apiKey: String,
                           model: String, language: String?, noVerbatim: Bool,
                           timeout: TimeInterval) async throws -> String {
        guard !apiKey.isEmpty else { throw ElevenLabsDiarizingError.missingAPIKey }
        let boundary = "voiceink-\(UUID().uuidString)"
        var req = URLRequest(url: URL(string: "https://api.elevenlabs.io/v1/speech-to-text")!)
        req.httpMethod = "POST"
        req.timeoutInterval = timeout
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        let body = multipartBody(boundary: boundary, audio: audioData, fileName: fileName,
                                 model: model, language: language, noVerbatim: noVerbatim)
        let (data, response) = try await URLSession.shared.upload(for: req, from: body)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw ElevenLabsDiarizingError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        return try JSONDecoder().decode(Response.self, from: data).text
    }
}
