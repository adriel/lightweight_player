import Foundation

/// Fast access to fragmented MP4s that have no fragment index (no `sidx`, no `mfra`) — typical of Twitch /
/// live-stream downloads: `ftyp` + small `moov` (with `mvex`) followed by hundreds of thousands of tiny
/// `moof`/`mdat` pairs.
///
/// libavformat (and AVFoundation) walk every fragment header at open to build a seek index: ~165k fragments in
/// a 13 GB, 3.8 h VOD = 12 s warm / 20–29 s cold before the first frame. Instead we open with `ignidx` (stops
/// after the first fragment) and seek ourselves: fragment timestamps (`tfdt`) increase with file offset, so a
/// binary search over byte offsets finds any time in ~20 small reads, then a short forward walk finds the
/// keyframe fragment. The demuxer is re-opened on a spliced view (header + that fragment onward); `tfdt` keeps
/// timestamps absolute. Nothing is indexed or kept in memory.
final class FragmentedMP4 {
    let path: String
    let fd: Int32
    let length: Int64
    /// End of `moov`: the spliced view is file[0..<headerEnd] + file[fragment...].
    let headerEnd: Int64
    let firstFragment: Int64
    private struct Track { let timescale: Double; let isVideo: Bool; let defaultFlags: UInt32 }
    private var tracks: [UInt32: Track] = [:]
    private(set) var duration: Double = 0

    struct Fragment { let offset: Int64; let size: Int64; let time: Double?; let key: Bool }

    /// Cheap check (a few small reads) — used to pick the engine.
    static func isUnindexedFragmented(_ path: String) -> Bool { FragmentedMP4(path: path, full: false) != nil }

    convenience init?(path: String) { self.init(path: path, full: true) }

    private init?(path: String, full: Bool) {
        let fd = Darwin.open(path, O_RDONLY)
        guard fd >= 0 else { return nil }
        var st = stat()
        guard fstat(fd, &st) == 0 else { Darwin.close(fd); return nil }
        self.path = path; self.fd = fd; self.length = Int64(st.st_size)
        // Top level: ftyp … moov(with mvex) … first moof; no sidx before it.
        var off: Int64 = 0, moov: (Int64, Int64)?, first: Int64?
        var n = 0
        while n < 16, let a = FragmentedMP4.atom(fd, off, length) {
            n += 1
            if a.type == "sidx" { break }
            if a.type == "moov" { moov = (off, a.size) }
            if a.type == "moof" { first = off; break }
            if a.type == "mdat" { break }      // regular (non-fragmented) file
            off += a.size
        }
        guard let moov, let first else { Darwin.close(fd); return nil }
        headerEnd = moov.0 + moov.1
        firstFragment = first
        // An `mfra` at the end means libavformat can index cheaply on its own.
        if let tail = FragmentedMP4.pread(fd, length - 16, 16), tail.count == 16, String(decoding: tail[4..<8], as: UTF8.self) == "mfro" {
            Darwin.close(fd); return nil
        }
        guard let moovData = FragmentedMP4.pread(fd, moov.0, Int(min(moov.1, 64 << 20))) else { Darwin.close(fd); return nil }
        parseMoov(moovData)
        guard tracks.values.contains(where: { $0.isVideo }), moovData.range(of: Data("mvex".utf8)) != nil else { Darwin.close(fd); return nil }
        if !full { return }
        duration = lastFragmentTime() ?? 0
    }

    deinit { Darwin.close(fd) }

    // MARK: Seeking

    /// Offset of the keyframe fragment at or before `t` (or the first one at or after it, `forward`).
    func keyframeFragment(for t: Double, forward: Bool) -> Int64 {
        var margin = 3.0
        while true {
            let start = forward ? fragment(before: t - 0.5) : fragment(before: t - margin)
            var best: Int64? = nil
            var off = start
            var steps = 0
            while steps < 20000, let f = parseFragment(at: off) {
                steps += 1
                if let time = f.time, f.key {
                    if forward { if time >= t - 0.001 { return f.offset } }
                    else if time <= t + 0.001 { best = f.offset } else { break }
                }
                if !forward, let time = f.time, time > t { break }
                guard let next = nextFragment(after: f) else { break }
                off = next
            }
            if let best { return best }
            if forward { return start }
            if start == firstFragment { return firstFragment }
            margin *= 4                                // very long GOP: look further back
        }
    }

    /// A fragment whose video time is ≤ t (binary search over byte offsets), or the first fragment.
    private func fragment(before t: Double) -> Int64 {
        guard t > 0 else { return firstFragment }
        var lo = firstFragment, hi = length
        var best = firstFragment
        for _ in 0..<40 where hi - lo > 1 << 20 {
            let mid = lo + (hi - lo) / 2
            guard let f = videoFragment(near: mid), let time = f.time else { hi = mid; continue }
            if time <= t { best = f.offset; lo = f.offset + f.size } else { hi = mid }
        }
        return best
    }

    /// First fragment carrying a video time at or after byte offset `off`.
    private func videoFragment(near off: Int64) -> Fragment? {
        guard var cur = findMoof(from: off) else { return nil }
        for _ in 0..<64 {
            guard let f = parseFragment(at: cur) else { return nil }
            if f.time != nil { return f }
            guard let n = nextFragment(after: f) else { return nil }
            cur = n
        }
        return nil
    }

    /// Scans forward from an arbitrary offset for a plausible `moof` header.
    private func findMoof(from off: Int64) -> Int64? {
        var pos = max(off, firstFragment)
        let chunk = 1 << 20
        while pos < length {
            guard let d = FragmentedMP4.pread(fd, pos, chunk), d.count > 16 else { return nil }
            var search = d.startIndex
            while let r = d.range(of: Data("moof".utf8), in: search..<d.endIndex) {
                let at = r.lowerBound - 4
                if at >= d.startIndex, r.upperBound + 8 <= d.endIndex {
                    let size = d[at..<r.lowerBound].reduce(0) { $0 << 8 | UInt32($1) }
                    if size >= 24, size < 4 << 20, String(decoding: d[(r.upperBound + 4)..<(r.upperBound + 8)], as: UTF8.self) == "mfhd" {
                        return pos + Int64(at - d.startIndex)
                    }
                }
                search = r.upperBound
            }
            pos += Int64(chunk - 16)
        }
        return nil
    }

    private func nextFragment(after f: Fragment) -> Int64? {
        var off = f.offset + f.size
        for _ in 0..<8 {
            guard let a = FragmentedMP4.atom(fd, off, length) else { return nil }
            if a.type == "moof" { return off }
            off += a.size
        }
        return nil
    }

    private func lastFragmentTime() -> Double? {
        var off = max(firstFragment, length - (8 << 20))
        var last: Double?
        guard var cur = findMoof(from: off) else { return nil }
        while let f = parseFragment(at: cur) {
            if let t = f.time { last = t }
            guard let n = nextFragment(after: f) else { break }
            cur = n; off = n
        }
        return last
    }

    // MARK: Box parsing

    func parseFragment(at off: Int64) -> Fragment? {
        guard let a = FragmentedMP4.atom(fd, off, length), a.type == "moof", a.size < 4 << 20,
              let d = FragmentedMP4.pread(fd, off, Int(a.size)) else { return nil }
        var time: Double?, key = false
        FragmentedMP4.children(d, from: 8, to: d.count) { type, s, e in
            guard type == "traf" else { return }
            var trackID: UInt32 = 0, tfhdFlags: UInt32 = 0, tfhdDefault: UInt32?
            var base: UInt64?, first: UInt32?
            FragmentedMP4.children(d, from: s, to: e) { t, cs, ce in
                switch t {
                case "tfhd":
                    tfhdFlags = FragmentedMP4.u32(d, cs) & 0xFFFFFF
                    trackID = FragmentedMP4.u32(d, cs + 4)
                    var p = cs + 8
                    if tfhdFlags & 0x1 != 0 { p += 8 }
                    if tfhdFlags & 0x2 != 0 { p += 4 }
                    if tfhdFlags & 0x8 != 0 { p += 4 }
                    if tfhdFlags & 0x10 != 0 { p += 4 }
                    if tfhdFlags & 0x20 != 0, p + 4 <= ce { tfhdDefault = FragmentedMP4.u32(d, p) }
                case "tfdt":
                    let v = d[d.startIndex + cs]
                    base = v == 1 ? FragmentedMP4.u64(d, cs + 4) : UInt64(FragmentedMP4.u32(d, cs + 4))
                case "trun" where first == nil:
                    let flags = FragmentedMP4.u32(d, cs) & 0xFFFFFF
                    var p = cs + 8
                    if flags & 0x1 != 0 { p += 4 }
                    if flags & 0x4 != 0 { first = FragmentedMP4.u32(d, p); break }
                    if flags & 0x400 != 0 {
                        if flags & 0x100 != 0 { p += 4 }
                        if flags & 0x200 != 0 { p += 4 }
                        first = FragmentedMP4.u32(d, p)
                    }
                default: break
                }
            }
            guard let tr = tracks[trackID], tr.isVideo, let base else { return }
            time = Double(base) / tr.timescale
            let flags = first ?? tfhdDefault ?? tr.defaultFlags
            key = (flags >> 16) & 1 == 0                    // sample_is_non_sync_sample == 0
        }
        return Fragment(offset: off, size: a.size, time: time, key: key)
    }

    private func parseMoov(_ d: Data) {
        var trex: [UInt32: UInt32] = [:]
        var found: [(UInt32, Double, Bool)] = []
        FragmentedMP4.children(d, from: 8, to: d.count) { type, s, e in
            if type == "mvex" {
                FragmentedMP4.children(d, from: s, to: e) { t, cs, _ in
                    if t == "trex" { trex[FragmentedMP4.u32(d, cs + 4)] = FragmentedMP4.u32(d, cs + 20) }
                }
            }
            guard type == "trak" else { return }
            var id: UInt32 = 0, scale = 0.0, video = false
            FragmentedMP4.children(d, from: s, to: e) { t, cs, ce in
                if t == "tkhd" { id = FragmentedMP4.u32(d, cs + (d[d.startIndex + cs] == 1 ? 20 : 12)) }
                if t == "mdia" {
                    FragmentedMP4.children(d, from: cs, to: ce) { mt, ms, _ in
                        if mt == "mdhd" { scale = Double(FragmentedMP4.u32(d, ms + (d[d.startIndex + ms] == 1 ? 20 : 12))) }
                        if mt == "hdlr" { video = String(decoding: d[(d.startIndex + ms + 8)..<(d.startIndex + ms + 12)], as: UTF8.self) == "vide" }
                    }
                }
            }
            if scale > 0 { found.append((id, scale, video)) }
        }
        for (id, scale, video) in found { tracks[id] = Track(timescale: scale, isVideo: video, defaultFlags: trex[id] ?? 0) }
    }

    // MARK: Low-level helpers

    static func pread(_ fd: Int32, _ off: Int64, _ n: Int) -> Data? {
        guard off >= 0, n > 0 else { return nil }
        var d = Data(count: n)
        let got = d.withUnsafeMutableBytes { Darwin.pread(fd, $0.baseAddress, n, off) }
        guard got > 0 else { return nil }
        if got < n { d.removeSubrange(got..<n) }
        return d
    }

    static func atom(_ fd: Int32, _ off: Int64, _ length: Int64) -> (type: String, size: Int64)? {
        guard off + 8 <= length, let h = pread(fd, off, 16), h.count >= 8 else { return nil }
        var size = Int64(u32(h, 0))
        if size == 1, h.count >= 16 { size = Int64(u64(h, 8)) }
        if size == 0 { size = length - off }
        guard size >= 8 else { return nil }
        return (String(decoding: h[4..<8], as: UTF8.self), size)
    }

    /// Iterates child boxes in d[from..<to]; the closure gets (type, payloadStart, end) as offsets into d.
    static func children(_ d: Data, from: Int, to: Int, _ body: (String, Int, Int) -> Void) {
        var p = from
        while p + 8 <= to {
            var size = Int(u32(d, p))
            var hdr = 8
            if size == 1, p + 16 <= to { size = Int(u64(d, p + 8)); hdr = 16 }
            if size == 0 { size = to - p }
            guard size >= hdr, p + size <= to else { return }
            let type = String(decoding: d[(d.startIndex + p + 4)..<(d.startIndex + p + 8)], as: UTF8.self)
            // Full boxes (version+flags) start their payload after 4 more bytes; callers index from `p + hdr`.
            body(type, p + hdr, p + size)
            p += size
        }
    }

    static func u32(_ d: Data, _ o: Int) -> UInt32 {
        let i = d.startIndex + o
        guard i + 4 <= d.endIndex else { return 0 }
        return d[i..<(i + 4)].reduce(0) { $0 << 8 | UInt32($1) }
    }
    static func u64(_ d: Data, _ o: Int) -> UInt64 {
        let i = d.startIndex + o
        guard i + 8 <= d.endIndex else { return 0 }
        return d[i..<(i + 8)].reduce(0) { $0 << 8 | UInt64($1) }
    }
}
