import Foundation
import Combine

/// What was played, when, and how far (for the Welcome window's recent list and Window › Playback History).
/// Stored as JSON in ~/Library/Application Support/LightPlayer/history.json, readable only by this user
/// (stream URLs can carry credentials, which are needed to replay them).
@MainActor final class PlaybackHistory: ObservableObject {
    static let shared = PlaybackHistory()

    struct Entry: Codable, Identifiable, Hashable {
        var id: String            // resume key (path, or stream URL without credentials)
        var url: String           // full URL to reopen
        var name: String
        var playedAt: Date
        var position: Double
        var duration: Double
        var progress: Double { duration > 0 ? min(1, max(0, position / duration)) : 0 }
        var isFile: Bool { URL(string: url)?.isFileURL ?? false }
        var folder: String {
            guard let u = URL(string: url) else { return "" }
            return u.isFileURL ? u.deletingLastPathComponent().path : (u.host ?? "")
        }
    }

    @Published private(set) var entries: [Entry] = []      // most recent first
    private let file: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("LightPlayer", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("history.json")
    }()
    private var saveWork: DispatchWorkItem?
    private static let limit = 1000

    private init() {
        if let d = try? Data(contentsOf: file), let e = try? JSONDecoder().decode([Entry].self, from: d) { entries = e; return }
        // First run: seed from saved resume positions (local files that still exist) so recents aren't empty.
        let resume = UserDefaults.standard.dictionary(forKey: "resume") ?? [:]
        let now = Date()
        for (i, (key, value)) in resume.enumerated() where key.hasPrefix("/") && FileManager.default.fileExists(atPath: key) {
            let u = URL(fileURLWithPath: key)
            entries.append(Entry(id: key, url: u.absoluteString, name: u.lastPathComponent, playedAt: now.addingTimeInterval(-Double(i)),
                                 position: (value as? Double) ?? 0, duration: 0))
        }
        if !entries.isEmpty { scheduleSave() }
    }

    var enabled: Bool { Settings.shared.keepHistory }

    /// A file/stream was opened: move it to the top (one entry per item).
    func didOpen(_ url: URL, key: String, name: String) {
        guard enabled else { return }
        var e = entries.first { $0.id == key } ?? Entry(id: key, url: url.absoluteString, name: name, playedAt: Date(), position: 0, duration: 0)
        e.url = url.absoluteString; e.name = name; e.playedAt = Date()
        entries.removeAll { $0.id == key }
        entries.insert(e, at: 0)
        if entries.count > Self.limit { entries.removeLast(entries.count - Self.limit) }
        scheduleSave()
    }

    func updateProgress(key: String, position: Double, duration: Double) {
        guard enabled, let i = entries.firstIndex(where: { $0.id == key }) else { return }
        guard abs(entries[i].position - position) > 1 || entries[i].duration != duration else { return }
        entries[i].position = position; entries[i].duration = duration
        scheduleSave()
    }

    /// Older entries (seeded from resume positions) have no duration: read it from the file headers in the
    /// background so their progress bars can be drawn. Header-only, no decoding; local files only.
    private var probing = false
    func fillMissingDurations() {
        guard !probing else { return }
        let todo = entries.filter { $0.duration <= 0 && $0.isFile }.compactMap { e in URL(string: e.url).map { (e.id, $0.path) } }
        guard !todo.isEmpty else { return }
        probing = true
        DispatchQueue.global(qos: .utility).async {
            var found: [(String, Double)] = []
            for (id, path) in todo where FileManager.default.fileExists(atPath: path) {
                if let d = FFDemuxer.headerDuration(path: path), d > 0 { found.append((id, d)) }
            }
            DispatchQueue.main.async {
                self.probing = false
                for (id, d) in found { if let i = self.entries.firstIndex(where: { $0.id == id }) { self.entries[i].duration = d } }
                if !found.isEmpty { self.scheduleSave() }
            }
        }
    }

    func remove(_ ids: Set<String>) { entries.removeAll { ids.contains($0.id) }; scheduleSave() }
    func clear() { entries.removeAll(); scheduleSave() }

    private func scheduleSave() {
        saveWork?.cancel()
        let snapshot = entries, file = file
        let w = DispatchWorkItem {
            guard let d = try? JSONEncoder().encode(snapshot) else { return }
            try? d.write(to: file, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        }
        saveWork = w
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1, execute: w)
    }
}
