import AVFoundation
import OSLog
import Speech

private let log = Logger(subsystem: "com.edu.pauta", category: "speech")

/// On-device transcription with Apple's SpeechAnalyzer (macOS 26). Free, private, real time.
/// It has no diarization, so we transcribe the mic ("me") and system audio ("others") separately.
enum LocalSpeech {
    static let meLabel = "me"
    static let othersLabel = "others"

    enum SpeechError: LocalizedError {
        case unsupportedLanguage
        case modelMissing

        var errorDescription: String? {
            switch self {
            case .unsupportedLanguage: "O idioma escolhido não é suportado pela transcrição local da Apple."
            case .modelMissing: "O modelo de transcrição local ainda não foi baixado."
            }
        }
    }

    enum ModelStatus: Equatable {
        case unsupported, notInstalled, downloading, installed
    }

    /// Locale for the "language" preference ("pt", "en", ...).
    static var preferredLocale: Locale {
        switch Pref.string(Pref.language) {
        case "pt": Locale(identifier: "pt-BR")
        case "en": Locale(identifier: "en-US")
        case "es": Locale(identifier: "es-ES")
        default: Locale.current
        }
    }

    static func makeTranscriber(locale: Locale, live: Bool) -> SpeechTranscriber {
        SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: live ? [.volatileResults] : [],
            attributeOptions: [.audioTimeRange]
        )
    }

    static func supportedLocale() async -> Locale? {
        await SpeechTranscriber.supportedLocale(equivalentTo: preferredLocale)
    }

    static func modelStatus() async -> ModelStatus {
        guard let locale = await supportedLocale() else { return .unsupported }
        switch await AssetInventory.status(forModules: [makeTranscriber(locale: locale, live: false)]) {
        case .installed: return .installed
        case .downloading: return .downloading
        case .supported: return .notInstalled
        default: return .unsupported
        }
    }

    /// Downloads the language model if needed. `progress` receives 0...1.
    static func installModel(progress: (@Sendable (Double) -> Void)? = nil) async throws {
        guard let locale = await supportedLocale() else { throw SpeechError.unsupportedLanguage }
        let transcriber = makeTranscriber(locale: locale, live: false)
        guard let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) else { return }
        let observation = request.progress.observe(\.fractionCompleted) { p, _ in progress?(p.fractionCompleted) }
        defer { observation.invalidate() }
        try await request.downloadAndInstall()
    }

    // MARK: File transcription

    /// Transcribes a finished recording. Used when live transcription did not cover the whole meeting.
    static func transcribe(file url: URL, speaker: String) async throws -> [TranscriptSegment] {
        guard let locale = await supportedLocale() else { throw SpeechError.unsupportedLanguage }
        try await installModel()
        let transcriber = makeTranscriber(locale: locale, live: false)
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let collector = Task {
            var segments: [TranscriptSegment] = []
            for try await result in transcriber.results where result.isFinal {
                if let segment = segment(from: result, speaker: speaker) { segments.append(segment) }
            }
            return segments
        }
        let file = try AVAudioFile(forReading: url)
        if let end = try await analyzer.analyzeSequence(from: file) {
            try await analyzer.finalizeAndFinish(through: end)
        } else {
            await analyzer.cancelAndFinishNow()
        }
        return try await collector.value
    }

    static func segment(from result: SpeechTranscriber.Result, speaker: String) -> TranscriptSegment? {
        let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let start = result.range.start.seconds
        let end = result.range.end.seconds
        return TranscriptSegment(start: start.isFinite ? start : 0, end: end.isFinite ? end : 0, speaker: speaker, text: text)
    }

    // MARK: Merging

    /// Interleaves both tracks by time. Without headphones the mic also hears the call,
    /// so mic segments that repeat an overlapping system segment are dropped.
    static func merge(me: [TranscriptSegment], others: [TranscriptSegment]) -> [TranscriptSegment] {
        let echoFree = me.filter { mine in
            let words = wordSet(mine.text)
            guard words.count >= 3 else { return true }
            return !others.contains { theirs in
                theirs.start < mine.end + 1.5 && mine.start < theirs.end + 1.5
                    && similarity(words, wordSet(theirs.text)) > 0.5
            }
        }
        return (echoFree + others).sorted { $0.start < $1.start }
    }

    private static func wordSet(_ text: String) -> Set<String> {
        Set(text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init))
    }

    private static func similarity(_ a: Set<String>, _ b: Set<String>) -> Double {
        guard !a.isEmpty else { return 0 }
        return Double(a.intersection(b).count) / Double(a.count)
    }
}

/// Streams live audio from the recorder into one SpeechAnalyzer per source.
final class LiveTranscriber: @unchecked Sendable {
    enum Event {
        case final(TranscriptSegment)
        case volatile(speaker: String, text: String)
    }

    private final class Source {
        let label: String
        let transcriber: SpeechTranscriber
        let analyzer: SpeechAnalyzer
        let format: AVAudioFormat
        let continuation: AsyncStream<AnalyzerInput>.Continuation
        var converter: AVAudioConverter?
        var results: Task<[TranscriptSegment], Error>?
        var loggedFormat = false
        var dropped = 0

        init(label: String, transcriber: SpeechTranscriber, analyzer: SpeechAnalyzer, format: AVAudioFormat,
             continuation: AsyncStream<AnalyzerInput>.Continuation) {
            self.label = label
            self.transcriber = transcriber
            self.analyzer = analyzer
            self.format = format
            self.continuation = continuation
        }
    }

    var onEvent: (@Sendable (Event) -> Void)?
    private let lock = NSLock()
    private var sources: [String: Source] = [:]

    /// Prepares an analyzer per label. Throws `modelMissing` if the language model is not installed yet.
    func start(labels: [String]) async throws {
        guard let locale = await LocalSpeech.supportedLocale() else { throw LocalSpeech.SpeechError.unsupportedLanguage }
        guard await LocalSpeech.modelStatus() == .installed else { throw LocalSpeech.SpeechError.modelMissing }

        for label in labels {
            let transcriber = LocalSpeech.makeTranscriber(locale: locale, live: true)
            guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else { continue }
            let analyzer = SpeechAnalyzer(modules: [transcriber])
            try await analyzer.prepareToAnalyze(in: format)
            let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
            let source = Source(label: label, transcriber: transcriber, analyzer: analyzer, format: format, continuation: continuation)
            source.results = Task { [weak self] in
                var segments: [TranscriptSegment] = []
                for try await result in transcriber.results {
                    if result.isFinal {
                        guard let segment = LocalSpeech.segment(from: result, speaker: label) else { continue }
                        segments.append(segment)
                        self?.onEvent?(.final(segment))
                    } else {
                        self?.onEvent?(.volatile(speaker: label, text: String(result.text.characters)))
                    }
                }
                return segments
            }
            try await analyzer.start(inputSequence: stream)
            lock.withLock { sources[label] = source }
        }
    }

    /// Called on the recorder's queue for every audio buffer. `time` is seconds since the recording started.
    func append(_ sampleBuffer: CMSampleBuffer, label: String, time: TimeInterval) {
        guard let source = lock.withLock({ sources[label] }) else { return }
        if !source.loggedFormat {
            source.loggedFormat = true
            let asbd = sampleBuffer.formatDescription?.audioStreamBasicDescription
            log.info("\(label, privacy: .public) input: \(asbd.map { "\($0.mSampleRate) Hz, \($0.mChannelsPerFrame) ch, flags \($0.mFormatFlags), \($0.mBitsPerChannel) bit" } ?? "no format", privacy: .public) -> analyzer \(source.format, privacy: .public)")
        }
        guard let pcm = Self.pcmBuffer(from: sampleBuffer),
              let converted = Self.convert(pcm, to: source.format, using: &source.converter) else {
            source.dropped += 1
            if source.dropped == 1 || source.dropped % 500 == 0 {
                log.error("\(label, privacy: .public): dropped \(source.dropped) buffers (conversion failed)")
            }
            return
        }
        let start = CMTime(seconds: time, preferredTimescale: CMTimeScale(source.format.sampleRate))
        source.continuation.yield(AnalyzerInput(buffer: converted, bufferStartTime: start))
    }

    /// Flushes pending audio and returns every finalized segment, merged across sources.
    func finish() async -> [TranscriptSegment] {
        let all = lock.withLock { Array(sources.values) }
        var bySpeaker: [String: [TranscriptSegment]] = [:]
        for source in all {
            source.continuation.finish()
            try? await source.analyzer.finalizeAndFinishThroughEndOfInput()
            bySpeaker[source.label] = (try? await source.results?.value) ?? []
        }
        lock.withLock { sources.removeAll() }
        return LocalSpeech.merge(me: bySpeaker[LocalSpeech.meLabel] ?? [], others: bySpeaker[LocalSpeech.othersLabel] ?? [])
    }

    // MARK: Buffer plumbing

    private static func pcmBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let description = sampleBuffer.formatDescription else { return nil }
        let format = AVAudioFormat(cmAudioFormatDescription: description)
        let frames = AVAudioFrameCount(sampleBuffer.numSamples)
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        buffer.frameLength = frames
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer, at: 0, frameCount: Int32(frames), into: buffer.mutableAudioBufferList
        )
        return status == noErr ? buffer : nil
    }

    private static func convert(_ buffer: AVAudioPCMBuffer, to format: AVAudioFormat, using converter: inout AVAudioConverter?) -> AVAudioPCMBuffer? {
        if buffer.format == format { return buffer }
        if converter == nil || converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: format)
            converter?.primeMethod = .none
            if buffer.format.channelCount > 1, format.channelCount == 1 {
                // Multi-channel mics: keep the first channel instead of failing to downmix.
                converter?.channelMap = [0]
            }
        }
        guard let converter else { return nil }
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 16
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        var consumed = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        return error == nil && output.frameLength > 0 ? output : nil
    }
}
