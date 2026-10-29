import Foundation

struct Meeting: Codable, Identifiable, Hashable {
    enum Status: String, Codable {
        case recording, transcribing, analyzing, ready, failed
    }

    var id: UUID = UUID()
    var title: String
    var createdAt: Date = .now
    var duration: TimeInterval = 0
    var status: Status = .recording
    var errorMessage: String?
    var bookmarks: [Bookmark] = []
    var transcript: Transcript?
    var analysis: MeetingAnalysis?
    var chat: [ChatMessage] = []
    var cost: Double = 0
    /// User-edited speaker names, keyed by transcript speaker label.
    var speakerNames: [String: String] = [:]

    var isProcessing: Bool { status == .transcribing || status == .analyzing }

    func displayName(forSpeaker label: String?) -> String {
        guard let label else { return "Pessoa" }
        if let name = speakerNames[label], !name.isEmpty { return name }
        if let name = analysis?.speakers.first(where: { $0.label == label })?.name, !name.isEmpty { return name }
        return Transcript.fallbackName(for: label)
    }
}

struct Bookmark: Codable, Hashable, Identifiable {
    var id: UUID = UUID()
    var time: TimeInterval
    var note: String
}

struct ChatMessage: Codable, Hashable, Identifiable {
    enum Role: String, Codable { case user, assistant }
    var id: UUID = UUID()
    var role: Role
    var text: String
    var date: Date = .now
}

struct Transcript: Codable, Hashable {
    var text: String
    var segments: [TranscriptSegment]

    /// Human-friendly fallback such as "Pessoa 1" for "B1-speaker_0".
    static func fallbackName(for label: String) -> String {
        if label == LocalSpeech.meLabel {
            let name = Pref.string(Pref.userName)
            return name.isEmpty ? "Você" : name
        }
        if label == LocalSpeech.othersLabel { return "Participantes" }
        let digits = label.split(separator: "_").last.flatMap { Int($0) }
        if let digits { return "Pessoa \(digits + 1)" }
        return label
    }
}

struct TranscriptSegment: Codable, Hashable, Identifiable {
    var id: UUID = UUID()
    var start: TimeInterval
    var end: TimeInterval
    var speaker: String?
    var text: String
}

struct MeetingAnalysis: Codable, Hashable {
    var title: String = ""
    var summary: String = ""
    var keyPoints: [String] = []
    var decisions: [Decision] = []
    var actionItems: [ActionItem] = []
    var openQuestions: [OpenQuestion] = []
    var risks: [String] = []
    var nextAgenda: [String] = []
    var speakers: [Speaker] = []

    struct Decision: Codable, Hashable, Identifiable {
        var id: UUID = UUID()
        var decision: String
        var rationale: String?
        var owner: String?
    }

    struct ActionItem: Codable, Hashable, Identifiable {
        var id: UUID = UUID()
        var title: String
        var owner: String?
        var dueDate: String?
        var priority: String?
        var done: Bool = false
    }

    struct OpenQuestion: Codable, Hashable, Identifiable {
        var id: UUID = UUID()
        var question: String
        var context: String?
        var options: [Option] = []
        var recommendation: String?

        struct Option: Codable, Hashable, Identifiable {
            var id: UUID = UUID()
            var option: String
            var pros: [String] = []
            var cons: [String] = []
        }
    }

    struct Speaker: Codable, Hashable {
        var label: String
        var name: String
    }
}

// MARK: - Lenient decoding
// LLM output and our own persisted files share these types, so every field
// tolerates being missing or null instead of failing the whole analysis.

extension MeetingAnalysis {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = (try? c.decodeIfPresent(String.self, forKey: .title)) ?? ""
        summary = (try? c.decodeIfPresent(String.self, forKey: .summary)) ?? ""
        keyPoints = (try? c.decodeIfPresent([String].self, forKey: .keyPoints)) ?? []
        decisions = (try? c.decodeIfPresent([Decision].self, forKey: .decisions)) ?? []
        actionItems = (try? c.decodeIfPresent([ActionItem].self, forKey: .actionItems)) ?? []
        openQuestions = (try? c.decodeIfPresent([OpenQuestion].self, forKey: .openQuestions)) ?? []
        risks = (try? c.decodeIfPresent([String].self, forKey: .risks)) ?? []
        nextAgenda = (try? c.decodeIfPresent([String].self, forKey: .nextAgenda)) ?? []
        speakers = (try? c.decodeIfPresent([Speaker].self, forKey: .speakers)) ?? []
    }
}

extension MeetingAnalysis.Decision {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decodeIfPresent(UUID.self, forKey: .id)) ?? UUID()
        decision = (try? c.decodeIfPresent(String.self, forKey: .decision)) ?? ""
        rationale = try? c.decodeIfPresent(String.self, forKey: .rationale)
        owner = try? c.decodeIfPresent(String.self, forKey: .owner)
    }
}

extension MeetingAnalysis.ActionItem {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decodeIfPresent(UUID.self, forKey: .id)) ?? UUID()
        title = (try? c.decodeIfPresent(String.self, forKey: .title)) ?? ""
        owner = try? c.decodeIfPresent(String.self, forKey: .owner)
        dueDate = try? c.decodeIfPresent(String.self, forKey: .dueDate)
        priority = try? c.decodeIfPresent(String.self, forKey: .priority)
        done = (try? c.decodeIfPresent(Bool.self, forKey: .done)) ?? false
    }
}

extension MeetingAnalysis.OpenQuestion {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decodeIfPresent(UUID.self, forKey: .id)) ?? UUID()
        question = (try? c.decodeIfPresent(String.self, forKey: .question)) ?? ""
        context = try? c.decodeIfPresent(String.self, forKey: .context)
        options = (try? c.decodeIfPresent([Option].self, forKey: .options)) ?? []
        recommendation = try? c.decodeIfPresent(String.self, forKey: .recommendation)
    }
}

extension MeetingAnalysis.OpenQuestion.Option {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decodeIfPresent(UUID.self, forKey: .id)) ?? UUID()
        option = (try? c.decodeIfPresent(String.self, forKey: .option)) ?? ""
        pros = (try? c.decodeIfPresent([String].self, forKey: .pros)) ?? []
        cons = (try? c.decodeIfPresent([String].self, forKey: .cons)) ?? []
    }
}

// MARK: - Formatting

extension TimeInterval {
    /// "mm:ss" or "h:mm:ss".
    var clock: String {
        let total = Int(self.rounded(.down))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }
}
