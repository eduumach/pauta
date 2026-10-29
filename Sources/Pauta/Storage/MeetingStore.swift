import Foundation
import Observation

/// Persists each meeting as `<root>/<id>/meeting.json` next to its audio files.
@MainActor
@Observable
final class MeetingStore {
    private(set) var meetings: [Meeting] = []

    let root: URL

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        root = support.appending(path: "Pauta/Meetings", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        load()
    }

    func directory(for id: UUID) -> URL {
        let dir = root.appending(path: id.uuidString, directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func meeting(_ id: UUID) -> Meeting? { meetings.first { $0.id == id } }

    func save(_ meeting: Meeting) {
        if let index = meetings.firstIndex(where: { $0.id == meeting.id }) {
            meetings[index] = meeting
        } else {
            meetings.insert(meeting, at: 0)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        do {
            let data = try encoder.encode(meeting)
            try data.write(to: directory(for: meeting.id).appending(path: "meeting.json"), options: .atomic)
        } catch {
            NSLog("Pauta: failed to save meeting \(meeting.id): \(error)")
        }
    }

    func update(_ id: UUID, _ change: (inout Meeting) -> Void) {
        guard var meeting = meeting(id) else { return }
        change(&meeting)
        save(meeting)
    }

    func delete(_ id: UUID) {
        meetings.removeAll { $0.id == id }
        try? FileManager.default.removeItem(at: root.appending(path: id.uuidString))
    }

    private func load() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let dirs = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        meetings = dirs.compactMap { dir in
            guard let data = try? Data(contentsOf: dir.appending(path: "meeting.json")) else { return nil }
            return try? decoder.decode(Meeting.self, from: data)
        }
        .sorted { $0.createdAt > $1.createdAt }

        // Anything mid-flight when the app quit can be retried from the saved audio.
        for var meeting in meetings where meeting.status != .ready && meeting.status != .failed {
            meeting.status = .failed
            meeting.errorMessage = "O app foi fechado antes de terminar. Tente processar de novo."
            save(meeting)
        }
    }
}
