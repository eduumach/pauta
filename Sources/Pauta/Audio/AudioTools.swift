import AVFoundation

enum AudioTools {
    struct Chunk {
        let url: URL
        let offset: TimeInterval
    }

    /// Mixes the recorded tracks into a single `audio.m4a` and returns its duration.
    static func mix(_ tracks: [URL], into output: URL) async throws -> TimeInterval {
        try? FileManager.default.removeItem(at: output)
        let composition = AVMutableComposition()
        for url in tracks {
            let asset = AVURLAsset(url: url)
            guard let source = try await asset.loadTracks(withMediaType: .audio).first else { continue }
            let range = try await source.load(.timeRange)
            let track = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
            try track?.insertTimeRange(range, of: source, at: range.start)
        }
        try await export(composition, to: output, range: nil)
        return try await duration(of: output)
    }

    /// Splits long audio into pieces short enough for the transcription provider
    /// (25 MB per request and a ~60 s upstream processing timeout).
    static func split(_ url: URL, every seconds: TimeInterval, into dir: URL) async throws -> [Chunk] {
        let total = try await duration(of: url)
        guard total > seconds * 1.1 else { return [Chunk(url: url, offset: 0)] }

        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let asset = AVURLAsset(url: url)
        var chunks: [Chunk] = []
        var start: TimeInterval = 0
        var index = 0
        while start < total {
            let length = min(seconds, total - start)
            let out = dir.appending(path: "chunk-\(index).m4a")
            let range = CMTimeRange(
                start: CMTime(seconds: start, preferredTimescale: 600),
                duration: CMTime(seconds: length, preferredTimescale: 600)
            )
            try await export(asset, to: out, range: range)
            chunks.append(Chunk(url: out, offset: start))
            start += seconds
            index += 1
        }
        return chunks
    }

    static func duration(of url: URL) async throws -> TimeInterval {
        try await AVURLAsset(url: url).load(.duration).seconds
    }

    private static func export(_ asset: AVAsset, to url: URL, range: CMTimeRange?) async throws {
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw CocoaError(.fileWriteUnknown)
        }
        if let range { session.timeRange = range }
        try await session.export(to: url, as: .m4a)
    }
}
