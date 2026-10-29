import Foundation

enum OpenRouterError: LocalizedError {
    case missingAPIKey
    case http(Int, String)
    case emptyResponse

    var errorDescription: String? {
        switch self {
        case .missingAPIKey: "Configure sua chave do OpenRouter nos Ajustes."
        case .http(let code, let message): "OpenRouter (\(code)): \(message)"
        case .emptyResponse: "O modelo não retornou conteúdo."
        }
    }

    var isClientError: Bool {
        if case .http(let code, _) = self { return (400..<500).contains(code) && code != 429 }
        return false
    }
}

struct OpenRouterClient {
    static let baseURL = URL(string: "https://openrouter.ai/api/v1/")!

    let apiKey: String

    init(apiKey: String = Pref.apiKey) throws {
        guard !apiKey.isEmpty else { throw OpenRouterError.missingAPIKey }
        self.apiKey = apiKey
    }

    // MARK: Speech to text

    struct Transcription: Decodable {
        var text: String
        var segments: [Segment]?
        var words: [Word]?
        var usage: Usage?

        struct Segment: Decodable {
            var start: Double
            var end: Double
            var text: String
            var speaker: FlexibleString?
        }

        struct Word: Decodable {
            var word: String?
            var text: String?
            var start: Double?
            var end: Double?
            var speaker: FlexibleString?
            var speaker_label: String?
        }
    }

    struct Usage: Decodable {
        var cost: Double?
    }

    func transcribe(_ audio: URL, model: String, language: String, diarize: Bool) async throws -> Transcription {
        let data = try Data(contentsOf: audio)
        var body: [String: Any] = [
            "model": model,
            "input_audio": ["data": data.base64EncodedString(), "format": "m4a"],
        ]
        if !language.isEmpty { body["language"] = language }
        if diarize {
            body["response_format"] = "verbose_json"
            body["timestamp_granularities"] = ["segment", "word"]
            body["diarize"] = true
        }
        let response = try await post("audio/transcriptions", body: body, timeout: 600)
        return try JSONDecoder().decode(Transcription.self, from: response)
    }

    // MARK: Chat

    struct Message: Encodable {
        var role: String
        var content: String
    }

    struct Completion {
        var text: String
        var cost: Double
    }

    func complete(model: String, messages: [Message], json: Bool = false) async throws -> Completion {
        var body: [String: Any] = [
            "model": model,
            "messages": messages.map { ["role": $0.role, "content": $0.content] },
            "temperature": 0.3,
            "usage": ["include": true],
        ]
        if json { body["response_format"] = ["type": "json_object"] }

        struct Response: Decodable {
            struct Choice: Decodable {
                struct Msg: Decodable { var content: String? }
                var message: Msg
            }
            var choices: [Choice]
            var usage: Usage?
        }
        let data = try await post("chat/completions", body: body, timeout: 300)
        let response = try JSONDecoder().decode(Response.self, from: data)
        guard let text = response.choices.first?.message.content, !text.isEmpty else {
            throw OpenRouterError.emptyResponse
        }
        return Completion(text: text, cost: response.usage?.cost ?? 0)
    }

    // MARK: Transport

    private func post(_ path: String, body: [String: Any], timeout: TimeInterval) async throws -> Data {
        var request = URLRequest(url: Self.baseURL.appending(path: path), timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("https://github.com/edu/pauta", forHTTPHeaderField: "HTTP-Referer")
        request.setValue("Pauta", forHTTPHeaderField: "X-Title")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            struct ErrorBody: Decodable {
                struct Inner: Decodable { var message: String }
                var error: Inner
            }
            let message = (try? JSONDecoder().decode(ErrorBody.self, from: data))?.error.message
                ?? String(data: data, encoding: .utf8)?.prefix(300).description
                ?? "erro desconhecido"
            throw OpenRouterError.http(status, message)
        }
        return data
    }
}

/// Providers label speakers as either `0` or `"speaker_0"`.
struct FlexibleString: Decodable, Hashable {
    var value: String

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let s = try? c.decode(String.self) {
            value = s
        } else if let i = try? c.decode(Int.self) {
            value = "speaker_\(i)"
        } else {
            value = "speaker_0"
        }
    }
}
