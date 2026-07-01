import Foundation

enum ElevenLabsDiarizingError: Error {
    case missingAPIKey
    case http(Int, String)
    case noWords
}

/// In-repo ElevenLabs speech-to-text client with speaker diarization (`diarize=true`).
///
/// The bundled `LLMkit.ElevenLabsClient` is a remote, non-editable dependency that only parses
/// `text`, so diarization lives here instead. Sends the same multipart request plus `diarize=true`
/// (and optional `num_speakers`), then merges the per-word `speaker_id` stream into segments.
struct ElevenLabsDiarizingClient {
    struct Result {
        let text: String
        let segments: [SpeakerSegment]
    }

    private struct Response: Decodable {
        let text: String
        let words: [Word]?
        struct Word: Decodable {
            let text: String
            let start: Double?
            let end: Double?
            let type: String?
            let speaker_id: String?
        }
    }

    /// Pure: decode the ElevenLabs diarized JSON → text + merged speaker segments.
    static func parse(_ data: Data) throws -> Result {
        let r = try JSONDecoder().decode(Response.self, from: data)
        let words = (r.words ?? []).map {
            DiarizedWord(text: $0.text,
                         start: $0.start ?? 0,
                         end: $0.end ?? ($0.start ?? 0),
                         speakerId: $0.speaker_id ?? "speaker_0",
                         type: $0.type ?? "word")
        }
        return Result(text: r.text, segments: SpeakerSegment.merge(words: words))
    }

    /// Pure multipart body builder (kept separate so it is unit-testable).
    /// `numSpeakers` nil → omit `num_speakers` and let the model decide the speaker count.
    static func multipartBody(boundary: String, audio: Data, fileName: String,
                              model: String, language: String?, numSpeakers: Int?) -> Data {
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
        field("diarize", "true")
        if let numSpeakers { field("num_speakers", String(numSpeakers)) }
        if let language, !language.isEmpty { field("language_code", language) }
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        return body
    }

    /// Transcribe with diarization. Throws on missing key / HTTP error / empty words so the caller
    /// can degrade to a plain transcript.
    static func transcribeDiarized(audioData: Data, fileName: String, apiKey: String,
                                   model: String, language: String?, numSpeakers: Int?,
                                   timeout: TimeInterval) async throws -> Result {
        guard !apiKey.isEmpty else { throw ElevenLabsDiarizingError.missingAPIKey }
        let boundary = "voiceink-\(UUID().uuidString)"
        var req = URLRequest(url: URL(string: "https://api.elevenlabs.io/v1/speech-to-text")!)
        req.httpMethod = "POST"
        req.timeoutInterval = timeout
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        let body = multipartBody(boundary: boundary, audio: audioData, fileName: fileName,
                                 model: model, language: language, numSpeakers: numSpeakers)
        let (data, response) = try await URLSession.shared.upload(for: req, from: body)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw ElevenLabsDiarizingError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        let result = try parse(data)
        guard !result.segments.isEmpty else { throw ElevenLabsDiarizingError.noWords }
        return result
    }
}
