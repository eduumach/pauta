import Foundation

/// UserDefaults keys and defaults, shared by `@AppStorage` in views and plain reads in services.
enum Pref {
    static let sttModel = "sttModel"
    static let llmModel = "llmModel"
    static let language = "language"
    static let userName = "userName"
    static let captureSystemAudio = "captureSystemAudio"
    static let showIsland = "showIsland"
    static let diarize = "diarize"
    static let transcriptionMode = "transcriptionMode"
    static let showLiveCaption = "showLiveCaption"

    static let defaultSTTModel = "elevenlabs/scribe-v2"
    static let defaultLLMModel = "~deepseek/deepseek-flash-latest"

    static func register() {
        UserDefaults.standard.register(defaults: [
            sttModel: defaultSTTModel,
            llmModel: defaultLLMModel,
            language: "pt",
            userName: "",
            captureSystemAudio: true,
            showIsland: true,
            diarize: true,
            transcriptionMode: TranscriptionMode.local.rawValue,
            showLiveCaption: false,
        ])
    }

    static func string(_ key: String) -> String { UserDefaults.standard.string(forKey: key) ?? "" }
    static func bool(_ key: String) -> Bool { UserDefaults.standard.bool(forKey: key) }

    /// Read from the Keychain once per launch; every access would otherwise risk an auth prompt.
    nonisolated(unsafe) private static var cachedAPIKey: String?

    static var apiKey: String {
        get {
            if let cachedAPIKey { return cachedAPIKey }
            let key = Keychain.read("openrouter") ?? ""
            cachedAPIKey = key
            return key
        }
        set {
            guard newValue != cachedAPIKey else { return }
            cachedAPIKey = newValue
            Keychain.write(newValue, for: "openrouter")
        }
    }
}

enum TranscriptionMode: String, CaseIterable, Identifiable {
    /// Apple on-device, live. Free.
    case local
    /// OpenRouter speech-to-text after the meeting, with speaker identification.
    case cloud
    /// Live on-device while recording, refined in the cloud afterwards.
    case hybrid

    var id: String { rawValue }

    static var current: TranscriptionMode {
        TranscriptionMode(rawValue: Pref.string(Pref.transcriptionMode)) ?? .local
    }

    var isLive: Bool { self != .cloud }
    var finalEngine: TranscriptionEngine { self == .local ? .local : .cloud }
}

enum TranscriptionEngine {
    case local, cloud
}
