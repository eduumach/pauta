import Foundation

/// Turns recorded audio into a transcript, a structured analysis, and chat answers.
struct MeetingAI {
    let client: OpenRouterClient
    var sttModel = Pref.string(Pref.sttModel)
    var llmModel = Pref.string(Pref.llmModel)
    var language = Pref.string(Pref.language)
    var diarize = Pref.bool(Pref.diarize)
    var userName = Pref.string(Pref.userName)

    init(apiKey: String = Pref.apiKey) throws {
        client = try OpenRouterClient(apiKey: apiKey)
    }

    // MARK: Transcription

    func transcribe(_ chunks: [AudioTools.Chunk]) async throws -> (Transcript, cost: Double) {
        let results = try await withThrowingTaskGroup(of: (Int, [TranscriptSegment], Double).self) { group in
            var pending = Array(chunks.enumerated())
            var collected: [(Int, [TranscriptSegment], Double)] = []
            // A few requests in flight keeps long meetings fast without tripping rate limits.
            for _ in 0..<min(3, pending.count) {
                let (index, chunk) = pending.removeFirst()
                group.addTask { try await transcribe(chunk, index: index, multiple: chunks.count > 1) }
            }
            while let result = try await group.next() {
                collected.append(result)
                if !pending.isEmpty {
                    let (index, chunk) = pending.removeFirst()
                    group.addTask { try await transcribe(chunk, index: index, multiple: chunks.count > 1) }
                }
            }
            return collected.sorted { $0.0 < $1.0 }
        }

        let segments = results.flatMap(\.1)
        let text = segments.map(\.text).joined(separator: " ")
        return (Transcript(text: text, segments: segments), results.reduce(0) { $0 + $1.2 })
    }

    private func transcribe(_ chunk: AudioTools.Chunk, index: Int, multiple: Bool) async throws -> (Int, [TranscriptSegment], Double) {
        let result: OpenRouterClient.Transcription
        do {
            result = try await client.transcribe(chunk.url, model: sttModel, language: language, diarize: diarize)
        } catch let error as OpenRouterError where diarize && error.isClientError {
            // The chosen model may not support diarization; fall back to plain text.
            result = try await client.transcribe(chunk.url, model: sttModel, language: language, diarize: false)
        }
        // Speaker labels restart in every chunk, so namespace them per chunk.
        let prefix = multiple ? "B\(index + 1)-" : ""
        let segments = Self.segments(from: result, offset: chunk.offset, speakerPrefix: prefix)
        return (index, segments, result.usage?.cost ?? 0)
    }

    /// Builds readable segments: prefers word-level speaker turns, then provider segments, then raw text.
    static func segments(from result: OpenRouterClient.Transcription, offset: TimeInterval, speakerPrefix: String) -> [TranscriptSegment] {
        func label(_ speaker: String?) -> String? { speaker.map { speakerPrefix + $0 } }

        if let words = result.words, words.contains(where: { $0.speaker != nil || $0.speaker_label != nil }) {
            var segments: [TranscriptSegment] = []
            var current: TranscriptSegment?
            for word in words {
                let token = (word.word ?? word.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !token.isEmpty else { continue }
                let speaker = label(word.speaker_label ?? word.speaker?.value)
                let start = offset + (word.start ?? current?.end ?? 0)
                let end = offset + (word.end ?? word.start ?? current?.end ?? 0)
                let longPause = current.map { start - $0.end > 2.5 } ?? false
                let tooLong = current.map { $0.text.count > 600 && token.last.map(".?!".contains) == true } ?? false
                if var seg = current, seg.speaker == speaker, !longPause, !tooLong {
                    seg.text += " " + token
                    seg.end = end
                    current = seg
                } else {
                    if let seg = current { segments.append(seg) }
                    current = TranscriptSegment(start: start, end: end, speaker: speaker, text: token)
                }
            }
            if let seg = current { segments.append(seg) }
            return segments
        }

        if let segs = result.segments, !segs.isEmpty {
            return segs.map {
                TranscriptSegment(start: offset + $0.start, end: offset + $0.end,
                                  speaker: label($0.speaker?.value),
                                  text: $0.text.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }

        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? [] : [TranscriptSegment(start: offset, end: offset, speaker: nil, text: text)]
    }

    // MARK: Analysis

    func analyze(_ meeting: Meeting) async throws -> (MeetingAnalysis, cost: Double) {
        let system = """
        Você é o Pauta, um parceiro de reuniões que ajuda a lembrar o que foi discutido e a tomar boas decisões.
        Hoje é \(Date.now.formatted(date: .complete, time: .omitted)).\(userLine)
        Analise a transcrição e responda APENAS com um objeto JSON válido, em português do Brasil, neste formato:
        {
          "title": "título curto e específico (máx. 8 palavras)",
          "summary": "resumo objetivo de 3 a 6 frases",
          "keyPoints": ["pontos principais discutidos"],
          "decisions": [{"decision": "o que foi decidido", "rationale": "por quê", "owner": "quem é responsável ou null"}],
          "actionItems": [{"title": "tarefa começando com verbo", "owner": "responsável ou null", "dueDate": "AAAA-MM-DD ou null", "priority": "alta | média | baixa"}],
          "openQuestions": [{"question": "decisão que ficou em aberto", "context": "contexto", "options": [{"option": "alternativa", "pros": ["..."], "cons": ["..."]}], "recommendation": "sua recomendação fundamentada"}],
          "risks": ["riscos, bloqueios ou pontos de atenção"],
          "nextAgenda": ["temas para a próxima reunião"],
          "speakers": [{"label": "rótulo exato entre chaves, ex.: speaker_0", "name": "nome ou papel inferido"}]
        }
        Regras:
        - Use somente o que está na transcrição para fatos, nomes, decisões e prazos; não invente.
        - Converta prazos relativos ("sexta", "semana que vem") em datas reais a partir de hoje.
        - Em openQuestions, ajude de verdade na decisão: liste prós e contras de cada alternativa
          (pode usar conhecimento geral, sem contradizer a reunião) e faça uma recomendação concreta.
        - Os rótulos de falante podem reiniciar a cada bloco (B1-, B2-...); deduza nomes pelo contexto quando possível.
        - O rótulo {me} é o usuário do app; {others} reúne todas as outras pessoas da chamada,
          então nunca atribua um único nome a {others}.
        - Listas vazias são permitidas.
        """
        let completion = try await client.complete(
            model: llmModel,
            messages: [
                .init(role: "system", content: system),
                .init(role: "user", content: Self.document(for: meeting, includeAnalysis: false)),
            ],
            json: true
        )
        let analysis = try JSONDecoder().decode(MeetingAnalysis.self, from: Data(Self.extractJSON(completion.text).utf8))
        return (analysis, completion.cost)
    }

    // MARK: Chat

    enum Scope {
        case meeting(Meeting)
        case all([Meeting])
    }

    func answer(_ question: String, scope: Scope, history: [ChatMessage]) async throws -> OpenRouterClient.Completion {
        let context: String
        switch scope {
        case .meeting(let meeting):
            context = Self.document(for: meeting, includeAnalysis: true)
        case .all(let meetings):
            context = Self.memory(of: meetings)
        }
        let system = """
        Você é o Pauta, um parceiro de reuniões. Hoje é \(Date.now.formatted(date: .complete, time: .omitted)).\(userLine)
        Responda em português do Brasil, de forma direta, usando Markdown simples.
        Baseie-se apenas no material abaixo. Cite a reunião e o horário ([mm:ss]) quando ajudar.
        Se a informação não estiver no material, diga isso claramente.
        Quando pedirem ajuda para decidir, compare alternativas com prós e contras e faça uma recomendação.

        MATERIAL:
        \(context)
        """
        var messages: [OpenRouterClient.Message] = [.init(role: "system", content: system)]
        messages += history.suffix(12).map { .init(role: $0.role.rawValue, content: $0.text) }
        messages.append(.init(role: "user", content: question))
        return try await client.complete(model: llmModel, messages: messages)
    }

    private var userLine: String {
        userName.isEmpty ? "" : "\nO usuário do app se chama \(userName)."
    }

    // MARK: Context building

    static func document(for meeting: Meeting, includeAnalysis: Bool) -> String {
        var parts: [String] = [
            "# \(meeting.title)",
            "Data: \(meeting.createdAt.formatted(date: .abbreviated, time: .shortened)) · Duração: \(meeting.duration.clock)",
        ]
        if !meeting.bookmarks.isEmpty {
            parts.append("Momentos marcados pelo usuário como importantes:")
            parts += meeting.bookmarks.map { "- [\($0.time.clock)] \($0.note.isEmpty ? "(sem nota)" : $0.note)" }
        }
        if includeAnalysis, let analysis = meeting.analysis {
            parts.append("Resumo: \(analysis.summary)")
            if !analysis.decisions.isEmpty {
                parts.append("Decisões: " + analysis.decisions.map(\.decision).joined(separator: "; "))
            }
        }
        parts.append("## Transcrição")
        parts += (meeting.transcript?.segments ?? []).map { seg in
            // Raw labels for analysis so the model can map them; names once we know them.
            let speaker = includeAnalysis ? meeting.displayName(forSpeaker: seg.speaker) : "{\(seg.speaker ?? "?")}"
            return "[\(seg.start.clock)] \(speaker): \(seg.text)"
        }
        return parts.joined(separator: "\n")
    }

    /// Compact view of every meeting, newest first. Full transcripts are included
    /// while they fit the budget; older meetings fall back to their analysis.
    static func memory(of meetings: [Meeting], characterBudget: Int = 600_000) -> String {
        var remaining = characterBudget
        var blocks: [String] = []
        for meeting in meetings.sorted(by: { $0.createdAt > $1.createdAt }) where meeting.status == .ready {
            let full = document(for: meeting, includeAnalysis: true)
            if full.count <= remaining {
                blocks.append(full)
                remaining -= full.count
                continue
            }
            var lines = ["# \(meeting.title)", "Data: \(meeting.createdAt.formatted(date: .abbreviated, time: .shortened))"]
            if let a = meeting.analysis {
                lines.append("Resumo: \(a.summary)")
                lines += a.decisions.map { "Decisão: \($0.decision)" }
                lines += a.actionItems.map { "Tarefa: \($0.title)\($0.owner.map { " (\($0)" + ")" } ?? "")" }
            }
            let compact = lines.joined(separator: "\n")
            guard compact.count <= remaining else { break }
            blocks.append(compact)
            remaining -= compact.count
        }
        return blocks.isEmpty ? "(nenhuma reunião processada ainda)" : blocks.joined(separator: "\n\n---\n\n")
    }

    /// Strips ```json fences or prose some models wrap around JSON.
    static func extractJSON(_ text: String) -> String {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}") else { return text }
        return String(text[start...end])
    }
}
