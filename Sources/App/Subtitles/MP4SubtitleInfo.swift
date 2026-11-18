import Foundation

/// Reads per-track subtitle hints from an MP4/MOV header without loading sample tables:
/// only `moov/trak/tkhd` and `moov/trak/udta` are read; `mdia` (where the big tables live) is skipped.
///
/// ffmpeg marks forced tracks with an MPEG-DASH role box (`udta/kind` = "forced-subtitle"),
/// which AVFoundation ignores, so we detect it here.
enum MP4SubtitleInfo {
    struct TrackHint { var forced = false; var isDefault = false; var name: String? }

    static func hints(for url: URL) -> [Int32: TrackHint] {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return [:] }
        defer { try? fh.close() }
        let length = (try? fh.seekToEnd()).map { Int64($0) } ?? 0
        func header(at off: Int64) -> (type: String, size: Int64, hdr: Int64)? {
            guard off + 8 <= length, (try? fh.seek(toOffset: UInt64(off))) != nil, let d = try? fh.read(upToCount: 16), d.count >= 8 else { return nil }
            var size = Int64(d.prefix(4).reduce(0) { $0 << 8 | UInt64($1) })
            let type = String(decoding: d[4..<8], as: UTF8.self)
            var hdr: Int64 = 8
            if size == 1, d.count >= 16 { size = Int64(d[8..<16].reduce(0) { $0 << 8 | UInt64($1) }); hdr = 16 }
            if size == 0 { size = length - off }
            guard size >= hdr else { return nil }
            return (type, size, hdr)
        }
        func read(_ off: Int64, _ n: Int64) -> Data {
            guard n > 0, n < 1 << 20, (try? fh.seek(toOffset: UInt64(off))) != nil else { return Data() }
            return (try? fh.read(upToCount: Int(n))) ?? Data()
        }
        // Find moov at top level.
        var off: Int64 = 0
        var moov: (Int64, Int64)?
        while let h = header(at: off) {
            if h.type == "moov" { moov = (off + h.hdr, off + h.size); break }
            off += h.size
        }
        guard let (mStart, mEnd) = moov else { return [:] }
        var result: [Int32: TrackHint] = [:]
        var t = mStart
        while t < mEnd, let trak = header(at: t) {
            defer { t += trak.size }
            guard trak.type == "trak" else { continue }
            var id: Int32 = 0
            var hint = TrackHint()
            var c = t + trak.hdr
            while c < t + trak.size, let ch = header(at: c) {
                let body = c + ch.hdr
                if ch.type == "tkhd" {
                    let d = read(body, 24)
                    if d.count >= 24 {
                        let version = d[d.startIndex]
                        let flags = UInt32(d[d.startIndex + 3]) | UInt32(d[d.startIndex + 2]) << 8
                        hint.isDefault = flags & 1 != 0 // track_enabled
                        let idOff = version == 1 ? 20 : 12
                        id = Int32(bitPattern: d[(d.startIndex + idOff)..<(d.startIndex + idOff + 4)].reduce(0) { $0 << 8 | UInt32($1) })
                    }
                } else if ch.type == "udta" {
                    var u = body
                    while u < c + ch.size, let uh = header(at: u) {
                        let payload = read(u + uh.hdr, uh.size - uh.hdr)
                        if uh.type == "kind" {
                            let s = String(decoding: payload.dropFirst(4), as: UTF8.self)
                            if s.contains("forced-subtitle") || s.contains("forced") { hint.forced = true }
                        } else if uh.type == "name" {
                            hint.name = String(decoding: payload.prefix { $0 != 0 }, as: UTF8.self)
                        }
                        u += uh.size
                    }
                }
                c += ch.size
            }
            if id != 0 { result[id] = hint }
        }
        return result
    }
}
