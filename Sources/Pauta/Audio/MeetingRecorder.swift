import AVFoundation
import ScreenCaptureKit

enum RecorderError: LocalizedError {
    case noDisplay
    case permissionDenied(String)

    var errorDescription: String? {
        switch self {
        case .noDisplay: "Nenhuma tela encontrada para capturar o áudio do sistema."
        case .permissionDenied(let what): "Permissão negada: \(what). Libere em Ajustes do Sistema › Privacidade e Segurança."
        }
    }
}

/// Captures system audio (the other people in the call) and the microphone through
/// ScreenCaptureKit, writing each to its own AAC track: `system.m4a` and `mic.m4a`.
final class MeetingRecorder: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    /// Called ~15x per second with a 0...1 loudness value, on a background queue.
    var onLevel: (@Sendable (Float) -> Void)?
    /// Called if the stream stops on its own (e.g. permission revoked).
    var onError: (@Sendable (Error) -> Void)?
    /// Receives every audio buffer with its offset from the start of the recording, on the capture queue.
    var onAudio: ((SCStreamOutputType, CMSampleBuffer, TimeInterval) -> Void)?

    private let queue = DispatchQueue(label: "com.edu.pauta.recorder")
    private var stream: SCStream?
    private var systemWriter: TrackWriter?
    private var micWriter: TrackWriter?
    private var sessionStart: CMTime?
    private var lastLevelEmit = Date.distantPast
    private var peak: Float = 0

    static func systemURL(in dir: URL) -> URL { dir.appending(path: "system.m4a") }
    static func micURL(in dir: URL) -> URL { dir.appending(path: "mic.m4a") }

    func start(in directory: URL, captureSystemAudio: Bool) async throws {
        guard await AVCaptureDevice.requestAccess(for: .audio) else {
            throw RecorderError.permissionDenied("microfone")
        }

        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            throw RecorderError.permissionDenied("gravação de tela e áudio do sistema")
        }
        guard let display = content.displays.first else { throw RecorderError.noDisplay }

        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        let config = SCStreamConfiguration()
        config.capturesAudio = captureSystemAudio
        config.excludesCurrentProcessAudio = true
        config.captureMicrophone = true
        config.sampleRate = 48_000
        config.channelCount = 1
        // We only want audio; keep the video side as cheap as possible.
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        config.showsCursor = false

        queue.sync {
            sessionStart = nil
            systemWriter = captureSystemAudio ? TrackWriter(url: Self.systemURL(in: directory)) : nil
            micWriter = TrackWriter(url: Self.micURL(in: directory))
        }

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        if captureSystemAudio {
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        }
        try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream
    }

    /// Stops capture and finalizes both files. Returns the URLs that were actually written.
    func stop() async -> [URL] {
        if let stream {
            try? await stream.stopCapture()
        }
        stream = nil
        let writers = queue.sync { [systemWriter, micWriter].compactMap { $0 } }
        var urls: [URL] = []
        for writer in writers {
            if await writer.finish() { urls.append(writer.url) }
        }
        queue.sync {
            systemWriter = nil
            micWriter = nil
        }
        return urls
    }

    // MARK: SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sampleBuffer.isValid, type != .screen else { return }
        let pts = sampleBuffer.presentationTimeStamp
        // Both tracks share one timeline so they line up when mixed.
        if sessionStart == nil { sessionStart = pts }
        guard let start = sessionStart, pts >= start else { return }

        switch type {
        case .audio: systemWriter?.append(sampleBuffer, sessionStart: start)
        case .microphone: micWriter?.append(sampleBuffer, sessionStart: start)
        default: return
        }
        onAudio?(type, sampleBuffer, (pts - start).seconds)
        measureLevel(sampleBuffer)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onError?(error)
    }

    private func measureLevel(_ buffer: CMSampleBuffer) {
        guard let format = buffer.formatDescription?.audioStreamBasicDescription else { return }
        let isFloat = format.mFormatFlags & kAudioFormatFlagIsFloat != 0
        guard isFloat || format.mBitsPerChannel == 16 else { return }
        try? buffer.withAudioBufferList { list, _ in
            for audioBuffer in list {
                guard let data = audioBuffer.mData else { continue }
                var sum: Float = 0
                var count = 0
                if isFloat {
                    count = Int(audioBuffer.mDataByteSize) / MemoryLayout<Float>.size
                    let samples = data.assumingMemoryBound(to: Float.self)
                    for i in 0..<count { sum += samples[i] * samples[i] }
                } else {
                    count = Int(audioBuffer.mDataByteSize) / MemoryLayout<Int16>.size
                    let samples = data.assumingMemoryBound(to: Int16.self)
                    for i in 0..<count {
                        let v = Float(samples[i]) / Float(Int16.max)
                        sum += v * v
                    }
                }
                let rms = count > 0 ? sqrt(sum / Float(count)) : 0
                peak = max(peak, rms)
            }
        }
        let now = Date()
        if now.timeIntervalSince(lastLevelEmit) > 1.0 / 15 {
            // Perceptual-ish scaling: speech RMS sits around 0.01...0.2.
            let db = 20 * log10(max(peak, 0.000_01))
            let level = min(max((db + 50) / 45, 0), 1)
            onLevel?(level)
            peak = 0
            lastLevelEmit = now
        }
    }
}

/// One AAC track. The writer is created lazily from the first buffer so it matches
/// whatever sample rate the device actually delivers.
private final class TrackWriter {
    let url: URL
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?

    init(url: URL) {
        self.url = url
        try? FileManager.default.removeItem(at: url)
    }

    func append(_ buffer: CMSampleBuffer, sessionStart: CMTime) {
        if writer == nil { setUp(from: buffer, sessionStart: sessionStart) }
        guard let writer, let input, writer.status == .writing, input.isReadyForMoreMediaData else { return }
        input.append(buffer)
    }

    private func setUp(from buffer: CMSampleBuffer, sessionStart: CMTime) {
        guard let asbd = buffer.formatDescription?.audioStreamBasicDescription,
              let writer = try? AVAssetWriter(outputURL: url, fileType: .m4a) else { return }
        var layout = AudioChannelLayout()
        layout.mChannelLayoutTag = kAudioChannelLayoutTag_Mono
        let sampleRate = asbd.mSampleRate > 0 ? asbd.mSampleRate : 48_000
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVChannelLayoutKey: Data(bytes: &layout, count: MemoryLayout<AudioChannelLayout>.size),
            // AAC rejects 64 kbps at low rates (Bluetooth headsets deliver 16 kHz), failing the whole track.
            AVEncoderBitRateKey: min(64_000, Int(sampleRate * 2)),
        ]
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else { return }
        writer.add(input)
        guard writer.startWriting() else {
            NSLog("Pauta: writer failed to start: \(String(describing: writer.error))")
            return
        }
        writer.startSession(atSourceTime: sessionStart)
        self.writer = writer
        self.input = input
    }

    func finish() async -> Bool {
        guard let writer, let input, writer.status == .writing else {
            if let error = writer?.error { NSLog("Pauta: track \(url.lastPathComponent) failed: \(error)") }
            // A failed writer leaves an empty file behind that would break mixing later.
            try? FileManager.default.removeItem(at: url)
            return false
        }
        input.markAsFinished()
        await writer.finishWriting()
        return writer.status == .completed
    }
}
