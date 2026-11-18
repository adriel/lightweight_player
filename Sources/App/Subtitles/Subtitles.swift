import Foundation

struct SubtitleCue: Equatable {
    var start: Double
    var end: Double
    var text: String
}

/// A selectable subtitle track (embedded stream or external file).
struct SubtitleTrackInfo: Identifiable, Equatable {
    enum Kind: Equatable { case text, image, unsupported }
    let id: Int               // stream index for embedded tracks; 10_000+ for external files
    var title: String
    var language: String?
    var codec: String
    var isForced: Bool
    var isDefault: Bool
    var kind: Kind
    var externalURL: URL?

    var displayName: String {
        var parts: [String] = []
        if !title.isEmpty { parts.append(title) }
        if let language, !language.isEmpty, language != "und" {
            let name = Locale.current.localizedString(forLanguageCode: language) ?? language
            if !parts.contains(where: { $0.localizedCaseInsensitiveContains(name) }) { parts.append(name) }
        }
        if parts.isEmpty { parts.append("Track \(id)") }
        if isForced && !parts.joined().localizedCaseInsensitiveContains("forced") { parts.append("Forced") }
        var s = parts.joined(separator: " – ")
        if externalURL != nil { s += " (external)" }
        if kind == .unsupported { s += " — not supported" }
        return s
    }
}

enum SubtitleText {
    /// Converts a demuxed subtitle packet payload into plain display text.
    static func fromPacket(codec: String, data: Data) -> String {
        switch codec {
        case "ass", "ssa":
            // Matroska ASS packets: ReadOrder,Layer,Style,Name,MarginL,MarginR,MarginV,Effect,Text
            let s = String(decoding: data, as: UTF8.self)
            let fields = s.split(separator: ",", maxSplits: 8, omittingEmptySubsequences: false)
            return cleanASS(fields.count == 9 ? String(fields[8]) : s)
        case "webvtt-mp4":
            // ISO 14496-30 sample: vttc box containing a payl box with the cue text.
            guard let r = data.range(of: Data("payl".utf8)), r.lowerBound >= data.startIndex + 4 else { return "" }
            let size = data[(r.lowerBound - 4)..<r.lowerBound].reduce(0) { $0 << 8 | Int($1) }
            return stripTags(String(decoding: data[r.upperBound..<min(data.endIndex, r.lowerBound - 4 + size)], as: UTF8.self))
        case "mov_text":
            guard data.count >= 2 else { return "" }
            let len = Int(data[data.startIndex]) << 8 | Int(data[data.startIndex + 1])
            return String(decoding: data.dropFirst(2).prefix(len), as: UTF8.self)
        default:
            return stripTags(String(decoding: data, as: UTF8.self))
        }
    }

    static func cleanASS(_ s: String) -> String {
        var out = ""
        var depth = 0
        for ch in s {
            if ch == "{" { depth += 1; continue }
            if ch == "}" { depth = max(0, depth - 1); continue }
            if depth == 0 { out.append(ch) }
        }
        return out.replacingOccurrences(of: "\\N", with: "\n").replacingOccurrences(of: "\\n", with: "\n").replacingOccurrences(of: "\\h", with: " ")
    }

    static func stripTags(_ s: String) -> String {
        guard s.contains("<") else { return s.trimmingCharacters(in: .whitespacesAndNewlines) }
        var out = ""
        var inTag = false
        for ch in s {
            if ch == "<" { inTag = true; continue }
            if ch == ">" { inTag = false; continue }
            if !inTag { out.append(ch) }
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Parses external .srt / .vtt / .ass files.
enum SubtitleFileParser {
    static func parse(_ url: URL) -> [SubtitleCue] {
        guard let raw = try? Data(contentsOf: url) else { return [] }
        let text = String(data: raw, encoding: .utf8) ?? String(data: raw, encoding: .windowsCP1252) ?? ""
        switch url.pathExtension.lowercased() {
        case "ass", "ssa": return parseASS(text)
        default: return parseSRTorVTT(text)
        }
    }

    private static func time(_ s: Substring) -> Double? {
        // 00:01:02,345 | 01:02.345 | 00:01:02.345
        let parts = s.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".").split(separator: ":")
        guard parts.count >= 2 else { return nil }
        var t = 0.0
        for p in parts { guard let v = Double(p) else { return nil }; t = t * 60 + v }
        return t
    }

    static func parseSRTorVTT(_ text: String) -> [SubtitleCue] {
        var cues: [SubtitleCue] = []
        let blocks = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n\n")
        for block in blocks {
            let lines = block.split(separator: "\n", omittingEmptySubsequences: false)
            guard let ti = lines.firstIndex(where: { $0.contains("-->") }) else { continue }
            let arrow = lines[ti].components(separatedBy: "-->")
            guard arrow.count == 2, let a = time(Substring(arrow[0])),
                  let b = time(Substring(arrow[1].split(separator: " ").first ?? "")) else { continue }
            let body = lines[(ti + 1)...].joined(separator: "\n")
            let clean = SubtitleText.stripTags(body)
            if !clean.isEmpty { cues.append(SubtitleCue(start: a, end: b, text: clean)) }
        }
        return cues.sorted { $0.start < $1.start }
    }

    static func parseASS(_ text: String) -> [SubtitleCue] {
        var cues: [SubtitleCue] = []
        for line in text.split(whereSeparator: \.isNewline) where line.hasPrefix("Dialogue:") {
            let f = line.dropFirst(9).split(separator: ",", maxSplits: 9, omittingEmptySubsequences: false)
            guard f.count == 10, let a = time(f[1]), let b = time(f[2]) else { continue }
            cues.append(SubtitleCue(start: a, end: b, text: SubtitleText.cleanASS(String(f[9]))))
        }
        return cues.sorted { $0.start < $1.start }
    }

    /// Finds sidecar subtitle files next to a local video ("Movie.mkv" -> "Movie.srt", "Movie.en.forced.srt").
    static func sidecars(for video: URL) -> [URL] {
        guard video.isFileURL else { return [] }
        let dir = video.deletingLastPathComponent()
        let stem = video.deletingPathExtension().lastPathComponent.lowercased()
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return files.filter { u in
            ["srt", "vtt", "ass", "ssa"].contains(u.pathExtension.lowercased()) && u.lastPathComponent.lowercased().hasPrefix(stem)
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}

/// Time-indexed cue store; engines append cues as packets arrive, the overlay queries by time.
final class CueStore {
    private var cues: [SubtitleCue] = []
    private let lock = NSLock()

    func replaceAll(_ c: [SubtitleCue]) { lock.withLock { cues = c } }
    func append(_ c: SubtitleCue) {
        lock.withLock {
            if let last = cues.last, last.start <= c.start { cues.append(c) }
            else if !cues.contains(c) {
                let i = cues.firstIndex { $0.start > c.start } ?? cues.endIndex
                cues.insert(c, at: i)
            }
            // Embedded tracks: keep memory bounded on very long files.
            if cues.count > 5000 { cues.removeFirst(1000) }
        }
    }
    func clear() { lock.withLock { cues.removeAll(); bitmapCues.removeAll(); _live = nil } }

    // Bitmap (PGS / VobSub / DVB) cues. Open-ended cues end when the next display set arrives.
    private var bitmapCues: [(start: Double, end: Double, items: [SubtitleBitmap])] = []

    func appendBitmaps(start: Double, end: Double?, _ items: [SubtitleBitmap]) {
        lock.withLock {
            for i in bitmapCues.indices.reversed() where bitmapCues[i].end == .infinity && bitmapCues[i].start <= start {
                bitmapCues[i].end = start
                break
            }
            if !items.isEmpty { bitmapCues.append((start, end ?? .infinity, items)) }
            if bitmapCues.count > 400 { bitmapCues.removeFirst(100) }
        }
    }

    func bitmaps(at t: Double) -> [SubtitleBitmap] {
        lock.withLock { bitmapCues.last { $0.start <= t && t < $0.end }?.items ?? [] }
    }

    /// Text pushed by engines that render cue timing themselves (AVPlayer legible output).
    var liveText: String? {
        get { lock.withLock { _live } }
        set { lock.withLock { _live = newValue } }
    }
    private var _live: String?

    func text(at t: Double) -> String? {
        if let l = liveText { return l }
        return lock.withLock {
            let active = cues.filter { $0.start <= t && t < $0.end }
            return active.isEmpty ? nil : active.map(\.text).joined(separator: "\n")
        }
    }
}
