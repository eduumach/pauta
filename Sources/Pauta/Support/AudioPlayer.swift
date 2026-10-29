import AVFoundation
import Observation

@MainActor
@Observable
final class AudioPlayer {
    private(set) var isPlaying = false
    private(set) var current: TimeInterval = 0
    private(set) var duration: TimeInterval = 0
    private(set) var isLoaded = false

    @ObservationIgnored private var player: AVPlayer?
    @ObservationIgnored private var observer: Any?

    func load(_ url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let player = AVPlayer(url: url)
        self.player = player
        isLoaded = true
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 4), queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.current = time.seconds
                if let item = player.currentItem, item.duration.isNumeric { self.duration = item.duration.seconds }
                self.isPlaying = player.rate > 0
            }
        }
    }

    func toggle() {
        guard let player else { return }
        if player.rate > 0 { player.pause() } else { player.play() }
        isPlaying = player.rate > 0
    }

    func seek(to time: TimeInterval, play: Bool = true) {
        guard let player else { return }
        player.seek(to: CMTime(seconds: time, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        current = time
        if play {
            player.play()
            isPlaying = true
        }
    }

    func stop() {
        player?.pause()
        if let observer { player?.removeTimeObserver(observer) }
        observer = nil
        player = nil
    }
}
