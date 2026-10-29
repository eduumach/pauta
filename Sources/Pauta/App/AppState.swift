import AppKit
import Observation
import UserNotifications

@MainActor
@Observable
final class AppState {
    static let shared = AppState()

    enum Phase: Equatable {
        case idle
        case starting
        case recording(meetingID: UUID, since: Date)
        case stopping
    }

    let store = MeetingStore()
    private(set) var phase: Phase = .idle
    /// Recent loudness values (0...1) for the live waveform, oldest first.
    private(set) var levels: [Float] = Array(repeating: 0, count: 28)
    /// Meeting that just finished processing, shown briefly in the island.
    private(set) var justFinished: UUID?
    var lastError: String?
    var selection: SidebarItem? = .memory

    /// Finalized live transcript of the meeting being recorded.
    private(set) var liveSegments: [TranscriptSegment] = []
    /// Not-yet-final text per speaker label.
    private(set) var liveVolatile: [String: String] = [:]
    private(set) var isLiveTranscribing = false
    private var lastLiveSpeaker: String?

    @ObservationIgnored private let recorder = MeetingRecorder()
    @ObservationIgnored private let liveSink = LiveSink()
    /// Live transcript kept in case the final transcription fails.
    @ObservationIgnored private var fallbackTranscripts: [UUID: [TranscriptSegment]] = [:]
    @ObservationIgnored private var justFinishedTask: Task<Void, Never>?

    private init() {
        recorder.onLevel = { [weak self] level in
            Task { @MainActor in self?.push(level) }
        }
        recorder.onError = { [weak self] error in
            Task { @MainActor in
                self?.lastError = error.localizedDescription
                await self?.stopRecording()
            }
        }
        let sink = liveSink
        recorder.onAudio = { type, buffer, time in
            let label = type == .microphone ? LocalSpeech.meLabel : LocalSpeech.othersLabel
            sink.transcriber?.append(buffer, label: label, time: time)
        }
    }

    /// Speaker of `liveCaption`.
    var liveCaptionSpeaker: String? {
        if let speaker = lastLiveSpeaker, let text = liveVolatile[speaker], !text.isEmpty { return speaker }
        return liveSegments.last?.speaker
    }

    /// Latest line being spoken, for the island caption.
    var liveCaption: String? {
        if let speaker = lastLiveSpeaker, let text = liveVolatile[speaker], !text.isEmpty { return text }
        return liveSegments.last?.text
    }

    var isRecording: Bool {
        if case .recording = phase { return true }
        return false
    }

    var recordingStart: Date? {
        if case .recording(_, let since) = phase { return since }
        return nil
    }

    var currentMeetingID: UUID? {
        if case .recording(let id, _) = phase { return id }
        return nil
    }

    var processing: [Meeting] { store.meetings.filter(\.isProcessing) }

    // MARK: Recording

    func toggleRecording() {
        Task {
            switch phase {
            case .idle: await startRecording()
            case .recording: await stopRecording()
            default: break
            }
        }
    }

    func startRecording() async {
        guard phase == .idle else { return }
        phase = .starting
        lastError = nil
        let meeting = Meeting(title: "Reunião de \(Date.now.formatted(date: .abbreviated, time: .shortened))")
        liveSegments = []
        liveVolatile = [:]
        lastLiveSpeaker = nil
        // Start the analyzers before audio flows so the live transcript covers the whole meeting.
        if TranscriptionMode.current.isLive { _ = await startLive() }
        do {
            try await recorder.start(
                in: store.directory(for: meeting.id),
                captureSystemAudio: Pref.bool(Pref.captureSystemAudio)
            )
            store.save(meeting)
            phase = .recording(meetingID: meeting.id, since: .now)
            selection = .meeting(meeting.id)
        } catch {
            phase = .idle
            lastError = error.localizedDescription
            store.delete(meeting.id)
            _ = await liveSink.take()?.finish()
            isLiveTranscribing = false
        }
    }

    private func startLive() async -> Bool {
        let live = LiveTranscriber()
        live.onEvent = { [weak self] event in
            Task { @MainActor in self?.handle(event) }
        }
        let labels = Pref.bool(Pref.captureSystemAudio) ? [LocalSpeech.meLabel, LocalSpeech.othersLabel] : [LocalSpeech.meLabel]
        do {
            try await live.start(labels: labels)
            liveSink.transcriber = live
            isLiveTranscribing = true
            return true
        } catch LocalSpeech.SpeechError.modelMissing {
            lastError = "Baixando o modelo de transcrição local… o texto ao vivo aparece assim que terminar."
            Task {
                do {
                    try await LocalSpeech.installModel()
                    lastError = nil
                    // Join mid-meeting; the final transcript then comes from the saved audio.
                    if isRecording { _ = await startLive() }
                } catch {
                    lastError = error.localizedDescription
                }
            }
            return false
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    private func handle(_ event: LiveTranscriber.Event) {
        guard isRecording || phase == .stopping else { return }
        switch event {
        case .final(let segment):
            let index = liveSegments.lastIndex { $0.start <= segment.start }.map { $0 + 1 } ?? 0
            liveSegments.insert(segment, at: index)
            if let speaker = segment.speaker { liveVolatile[speaker] = nil }
            lastLiveSpeaker = segment.speaker
        case .volatile(let speaker, let text):
            liveVolatile[speaker] = text
            lastLiveSpeaker = speaker
        }
    }

    func stopRecording() async {
        guard case .recording(let id, let since) = phase else { return }
        phase = .stopping
        let tracks = await recorder.stop()
        let liveTranscript = await liveSink.take()?.finish() ?? []
        isLiveTranscribing = false
        levels = levels.map { _ in 0 }
        phase = .idle
        liveSegments = []
        liveVolatile = [:]

        let mode = TranscriptionMode.current
        store.update(id) {
            $0.duration = Date.now.timeIntervalSince(since)
            $0.status = .transcribing
        }
        // The final transcript is always redone from the saved tracks (more accurate, and immune
        // to live hiccups); the live one is kept only as a fallback.
        if !liveTranscript.isEmpty { fallbackTranscripts[id] = liveTranscript }
        guard !tracks.isEmpty else {
            store.update(id) {
                $0.status = .failed
                $0.errorMessage = "Nenhum áudio foi capturado."
            }
            return
        }
        await process(id, engine: mode.finalEngine)
    }

    func addBookmark(note: String = "") {
        guard case .recording(let id, let since) = phase else { return }
        store.update(id) { $0.bookmarks.append(Bookmark(time: Date.now.timeIntervalSince(since), note: note)) }
    }

    private func push(_ level: Float) {
        guard isRecording else { return }
        levels.removeFirst()
        levels.append(level)
    }

    // MARK: Pipeline

    func process(_ id: UUID, engine: TranscriptionEngine = TranscriptionMode.current.finalEngine) async {
        defer { fallbackTranscripts[id] = nil }
        let dir = store.directory(for: id)
        let mixed = dir.appending(path: "audio.m4a")
        do {
            let ai = try MeetingAI()
            store.update(id) {
                $0.status = .transcribing
                $0.errorMessage = nil
            }

            if !FileManager.default.fileExists(atPath: mixed.path) {
                let tracks = [MeetingRecorder.systemURL(in: dir), MeetingRecorder.micURL(in: dir)]
                    .filter(isUsableTrack)
                let duration = try await AudioTools.mix(tracks, into: mixed)
                store.update(id) { $0.duration = duration }
            }

            if store.meeting(id)?.transcript == nil {
                let (transcript, cost) = try await transcribe(id, in: dir, mixed: mixed, engine: engine, ai: ai)
                store.update(id) {
                    $0.transcript = transcript
                    $0.cost += cost
                }
            }

            guard let meeting = store.meeting(id), let transcript = meeting.transcript else { return }
            guard !transcript.segments.isEmpty else {
                throw NSError(domain: "Pauta", code: 1, userInfo: [NSLocalizedDescriptionKey: "Não foi detectada fala na gravação."])
            }

            store.update(id) { $0.status = .analyzing }
            let (analysis, cost) = try await ai.analyze(meeting)
            store.update(id) {
                $0.analysis = analysis
                if !analysis.title.isEmpty { $0.title = analysis.title }
                $0.cost += cost
                $0.status = .ready
            }
            announceFinished(id)
        } catch {
            store.update(id) {
                $0.status = .failed
                $0.errorMessage = error.localizedDescription
            }
        }
    }

    private func transcribe(_ id: UUID, in dir: URL, mixed: URL, engine: TranscriptionEngine, ai: MeetingAI) async throws -> (Transcript, Double) {
        do {
            return try await transcribe(in: dir, mixed: mixed, engine: engine, ai: ai)
        } catch {
            guard let fallback = fallbackTranscripts[id], !fallback.isEmpty else { throw error }
            lastError = "A transcrição final falhou (\(error.localizedDescription)). Usando a transcrição ao vivo."
            return (Transcript(text: fallback.map(\.text).joined(separator: " "), segments: fallback), 0)
        }
    }

    private func transcribe(in dir: URL, mixed: URL, engine: TranscriptionEngine, ai: MeetingAI) async throws -> (Transcript, Double) {
        switch engine {
        case .local:
            let mic = MeetingRecorder.micURL(in: dir)
            let system = MeetingRecorder.systemURL(in: dir)
            let me = isUsableTrack(mic) ? try await LocalSpeech.transcribe(file: mic, speaker: LocalSpeech.meLabel) : []
            let others = isUsableTrack(system) ? try await LocalSpeech.transcribe(file: system, speaker: LocalSpeech.othersLabel) : []
            let segments = LocalSpeech.merge(me: me, others: others)
            return (Transcript(text: segments.map(\.text).joined(separator: " "), segments: segments), 0)
        case .cloud:
            let chunks = try await AudioTools.split(mixed, every: 15 * 60, into: dir.appending(path: "chunks"))
            defer { try? FileManager.default.removeItem(at: dir.appending(path: "chunks")) }
            return try await ai.transcribe(chunks)
        }
    }

    /// Skips missing tracks and the empty files a failed writer leaves behind.
    private func isUsableTrack(_ url: URL) -> Bool {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        return size > 0
    }

    func retry(_ id: UUID, reanalyzeOnly: Bool = false, engine: TranscriptionEngine? = nil) {
        if !reanalyzeOnly {
            store.update(id) {
                $0.transcript = nil
                $0.speakerNames = [:]
            }
        }
        Task { await process(id, engine: engine ?? TranscriptionMode.current.finalEngine) }
    }

    private func announceFinished(_ id: UUID) {
        justFinished = id
        justFinishedTask?.cancel()
        justFinishedTask = Task {
            try? await Task.sleep(for: .seconds(8))
            if !Task.isCancelled { justFinished = nil }
        }

        guard let meeting = store.meeting(id) else { return }
        let content = UNMutableNotificationContent()
        content.title = meeting.title
        let decisions = meeting.analysis?.decisions.count ?? 0
        let tasks = meeting.analysis?.actionItems.count ?? 0
        content.body = "Resumo pronto · \(decisions) decisões · \(tasks) tarefas"
        content.userInfo = ["meetingID": id.uuidString]
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id.uuidString, content: content, trigger: nil))
    }

    func dismissFinished() {
        justFinished = nil
    }

    // MARK: Chat

    func ask(_ question: String, in id: UUID) async {
        guard var meeting = store.meeting(id) else { return }
        if id == currentMeetingID {
            // Mid-meeting question: answer from what has been said so far.
            meeting.transcript = Transcript(text: liveSegments.map(\.text).joined(separator: " "), segments: liveSegments)
        }
        let history = meeting.chat
        store.update(id) { $0.chat.append(ChatMessage(role: .user, text: question)) }
        do {
            let reply = try await MeetingAI().answer(question, scope: .meeting(meeting), history: history)
            store.update(id) {
                $0.chat.append(ChatMessage(role: .assistant, text: reply.text))
                $0.cost += reply.cost
            }
        } catch {
            store.update(id) { $0.chat.append(ChatMessage(role: .assistant, text: "⚠️ \(error.localizedDescription)")) }
        }
    }

    func askMemory(_ question: String, history: [ChatMessage]) async -> String {
        do {
            return try await MeetingAI().answer(question, scope: .all(store.meetings), history: history).text
        } catch {
            return "⚠️ \(error.localizedDescription)"
        }
    }

    // MARK: Windows

    func openMain(selecting id: UUID? = nil) {
        if let id { selection = .meeting(id) }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        openMainWindow?()
    }

    /// Set by the SwiftUI scene so AppKit code (island, hotkey, notifications) can open the window.
    @ObservationIgnored var openMainWindow: (() -> Void)?
}

/// Thread-safe handoff of the live transcriber to the capture queue.
final class LiveSink: @unchecked Sendable {
    private let lock = NSLock()
    private var _transcriber: LiveTranscriber?

    var transcriber: LiveTranscriber? {
        get { lock.withLock { _transcriber } }
        set { lock.withLock { _transcriber = newValue } }
    }

    func take() -> LiveTranscriber? {
        lock.withLock {
            defer { _transcriber = nil }
            return _transcriber
        }
    }
}
