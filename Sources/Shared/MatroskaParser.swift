import Foundation

// Minimal, lazy Matroska/WebM demuxer used by the MediaExtension format reader (engine B).
// Design goals: never read a whole file to index it; parse one cluster at a time on demand, keep only
// a small LRU of parsed clusters; expose stable sample positions (cluster offset + index) for cursors.

protocol MKVByteReader: AnyObject {
    var length: Int64 { get }
    /// Reads up to `count` bytes at `offset` (fewer only at end of file).
    func read(_ offset: Int64, _ count: Int) throws -> Data
}

enum MKVError: Error, CustomStringConvertible {
    case parse(String)
    case noSamples
    var description: String {
        switch self { case .parse(let s): "MKV parse error: \(s)"; case .noSamples: "no samples" }
    }
}

enum MKVID {
    static let ebml: UInt32 = 0x1A45DFA3, segment: UInt32 = 0x18538067, seekHead: UInt32 = 0x114D9B74
    static let seek: UInt32 = 0x4DBB, seekID: UInt32 = 0x53AB, seekPosition: UInt32 = 0x53AC
    static let info: UInt32 = 0x1549A966, timestampScale: UInt32 = 0x2AD7B1, duration: UInt32 = 0x4489, title: UInt32 = 0x7BA9
    static let tracks: UInt32 = 0x1654AE6B, trackEntry: UInt32 = 0xAE, trackNumber: UInt32 = 0xD7, trackType: UInt32 = 0x83
    static let flagEnabled: UInt32 = 0xB9, flagDefault: UInt32 = 0x88, flagForced: UInt32 = 0x55AA
    static let defaultDuration: UInt32 = 0x23E383, name: UInt32 = 0x536E, language: UInt32 = 0x22B59C, languageBCP47: UInt32 = 0x22B59D
    static let codecID: UInt32 = 0x86, codecPrivate: UInt32 = 0x63A2, codecDelay: UInt32 = 0x56AA
    static let video: UInt32 = 0xE0, pixelWidth: UInt32 = 0xB0, pixelHeight: UInt32 = 0xBA, displayWidth: UInt32 = 0x54B0, displayHeight: UInt32 = 0x54BA
    static let colour: UInt32 = 0x55B0, matrix: UInt32 = 0x55B1, bitsPerChannel: UInt32 = 0x55B2, range: UInt32 = 0x55B9
    static let transfer: UInt32 = 0x55BA, primaries: UInt32 = 0x55BB, maxCLL: UInt32 = 0x55BC, maxFALL: UInt32 = 0x55BD
    static let mastering: UInt32 = 0x55D0, lumMax: UInt32 = 0x55D9, lumMin: UInt32 = 0x55DA // chromaticities 0x55D1...0x55D8
    static let audio: UInt32 = 0xE1, samplingFrequency: UInt32 = 0xB5, outputSamplingFrequency: UInt32 = 0x78B5, channels: UInt32 = 0x9F, bitDepth: UInt32 = 0x6264
    static let contentEncodings: UInt32 = 0x6D80, contentEncoding: UInt32 = 0x6240, contentCompression: UInt32 = 0x5034
    static let contentCompAlgo: UInt32 = 0x4254, contentCompSettings: UInt32 = 0x4255
    static let cues: UInt32 = 0x1C53BB6B, cuePoint: UInt32 = 0xBB, cueTime: UInt32 = 0xB3, cueTrackPositions: UInt32 = 0xB7
    static let cueTrack: UInt32 = 0xF7, cueClusterPosition: UInt32 = 0xF1
    static let cluster: UInt32 = 0x1F43B675, timestamp: UInt32 = 0xE7, simpleBlock: UInt32 = 0xA3, blockGroup: UInt32 = 0xA0
    static let block: UInt32 = 0xA1, blockDuration: UInt32 = 0x9B, referenceBlock: UInt32 = 0xFB
    static let void: UInt32 = 0xEC, crc32: UInt32 = 0xBF, tags: UInt32 = 0x1254C367, chapters: UInt32 = 0x1043A770, attachments: UInt32 = 0x1941A469
    static let topLevel: Set<UInt32> = [cluster, cues, tags, chapters, attachments, seekHead, info, tracks]
}

struct MKVColour {
    var matrix: Int?, bitsPerChannel: Int?, range: Int?, transfer: Int?, primaries: Int?
    var maxCLL: Int?, maxFALL: Int?
    var chromaticities: [Double?] = Array(repeating: nil, count: 8) // RX RY GX GY BX BY WX WY
    var lumMax: Double?, lumMin: Double?
}

final class MKVTrack {
    var number: UInt64 = 0
    var type: Int = 0                 // 1 video, 2 audio, 17 subtitle
    var codecID = ""
    var codecPrivate = Data()
    var defaultDurationNs: Int64 = 0
    var codecDelayNs: Int64 = 0
    var name: String?
    var language = "eng"
    var languageBCP47: String?
    var enabled = true, isDefault = true, isForced = false
    var width = 0, height = 0, displayWidth = 0, displayHeight = 0
    var colour: MKVColour?
    var sampleRate = 0.0, outputSampleRate = 0.0, channels = 1, bitDepth = 0
    /// Bytes removed from the start of every frame (ContentCompAlgo 3, header stripping).
    var strippedHeader: Data?
    var unsupportedEncoding = false
    /// Decode-time offset for codecs with frame reordering (set when the first cluster is parsed).
    var reorderDelayNs: Int64 = -1

    var isVideo: Bool { type == 1 }
    var isAudio: Bool { type == 2 }
    var mayReorder: Bool { codecID.hasPrefix("V_MPEG4/ISO/AVC") || codecID.hasPrefix("V_MPEGH/ISO/HEVC") || codecID == "V_MPEG2" || codecID.hasPrefix("V_MS/VFW") }
}

struct MKVSample {
    var ptsNs: Int64
    var dtsNs: Int64
    var durationNs: Int64
    var offset: Int64
    var size: Int32
    var isKey: Bool
    var isDiscardable: Bool
}

final class MKVCluster {
    let offset: Int64       // element start
    let dataStart: Int64
    var end: Int64          // exclusive (resolved for unknown-size clusters when parsed)
    var sizeKnown: Bool
    var timestamp: Int64?   // in TimestampScale units
    init(offset: Int64, dataStart: Int64, end: Int64, sizeKnown: Bool) {
        self.offset = offset; self.dataStart = dataStart; self.end = end; self.sizeKnown = sizeKnown
    }
}

/// A parsed cluster: samples per track number, in decode (file) order.
final class MKVParsedCluster {
    var samples: [UInt64: [MKVSample]] = [:]
    /// Same samples sorted by PTS (indices into `samples[track]`), built lazily for presentation stepping.
    var presentationOrder: [UInt64: [Int]] = [:]
}

struct MKVPosition: Equatable {
    var cluster: Int64   // cluster offset
    var index: Int       // index within that cluster's samples for the track (decode order)
}

final class MatroskaFile {
    let reader: MKVByteReader
    private(set) var tracks: [MKVTrack] = []
    private(set) var timestampScale: Int64 = 1_000_000
    private(set) var durationNs: Int64 = 0
    private(set) var title: String?
    private(set) var segmentDataStart: Int64 = 0
    private(set) var segmentEnd: Int64 = 0
    private var cuePoints: [(timeNs: Int64, cluster: Int64)] = []

    private let lock = NSRecursiveLock()
    private var clusters: [Int64: MKVCluster] = [:]
    private var knownOffsets: [Int64] = []          // sorted
    private var nextOf: [Int64: Int64] = [:]        // cluster offset -> next cluster offset
    private var lastClusterOffset: Int64?
    private var firstClusterOffset: Int64?
    private var parsed: [Int64: MKVParsedCluster] = [:]
    private var lru: [Int64] = []
    private let maxParsed = 48

    init(reader: MKVByteReader) throws {
        self.reader = reader
        try parseHeaders()
    }

    func track(_ number: UInt64) -> MKVTrack? { tracks.first { $0.number == number } }

    // MARK: - EBML primitives

    struct Header { let id: UInt32; let size: Int64?; let headerLength: Int }

    static func readID(_ d: Data, _ p: Int) -> (UInt32, Int)? {
        guard p < d.count else { return nil }
        let b = d[d.startIndex + p]
        guard b != 0 else { return nil }
        let len = b.leadingZeroBitCount + 1
        guard len <= 4, p + len <= d.count else { return nil }
        var v: UInt32 = 0
        for i in 0..<len { v = (v << 8) | UInt32(d[d.startIndex + p + i]) }
        return (v, len)
    }

    /// Returns (value, length, isUnknown).
    static func readVint(_ d: Data, _ p: Int) -> (Int64, Int, Bool)? {
        guard p < d.count else { return nil }
        let b = d[d.startIndex + p]
        guard b != 0 else { return nil }
        let len = b.leadingZeroBitCount + 1
        guard p + len <= d.count else { return nil }
        var v = Int64(b & (0xFF >> len))
        var allOnes = v == Int64(0xFF >> len)
        for i in 1..<len {
            let x = d[d.startIndex + p + i]
            v = (v << 8) | Int64(x)
            if x != 0xFF { allOnes = false }
        }
        return (v, len, allOnes)
    }

    static func readHeader(_ d: Data, _ p: Int) -> Header? {
        guard let (id, il) = readID(d, p), let (sz, sl, unknown) = readVint(d, p + il) else { return nil }
        return Header(id: id, size: unknown ? nil : sz, headerLength: il + sl)
    }

    static func uint(_ d: Data) -> UInt64 { d.reduce(0) { ($0 << 8) | UInt64($1) } }
    static func float(_ d: Data) -> Double {
        if d.count == 4 { return Double(Float(bitPattern: UInt32(uint(d)))) }
        if d.count == 8 { return Double(bitPattern: uint(d)) }
        return 0
    }
    static func string(_ d: Data) -> String { String(decoding: d.prefix { $0 != 0 }, as: UTF8.self) }

    /// Iterates the children of a fully-loaded master element payload.
    static func children(_ d: Data, _ body: (UInt32, Data) throws -> Void) rethrows {
        var p = 0
        while p < d.count, let h = readHeader(d, p) {
            let start = p + h.headerLength
            let size = Int(h.size ?? Int64(d.count - start))
            let end = min(d.count, start + size)
            try body(h.id, d.subdata(in: (d.startIndex + start)..<(d.startIndex + end)))
            p = end
        }
    }

    private func readHeader(at offset: Int64) throws -> Header {
        let d = try reader.read(offset, 12)
        guard let h = Self.readHeader(d, 0) else { throw MKVError.parse("bad element header at \(offset)") }
        return h
    }

    private func readElement(at offset: Int64) throws -> (Header, Data) {
        let h = try readHeader(at: offset)
        guard let size = h.size, size < 64 << 20 else { throw MKVError.parse("element too large at \(offset)") }
        return (h, try reader.read(offset + Int64(h.headerLength), Int(size)))
    }

    // MARK: - Headers

    private func parseHeaders() throws {
        let ebml = try readHeader(at: 0)
        guard ebml.id == MKVID.ebml, let ebmlSize = ebml.size else { throw MKVError.parse("not an EBML file") }
        let segOffset = Int64(ebml.headerLength) + ebmlSize
        let seg = try readHeader(at: segOffset)
        guard seg.id == MKVID.segment else { throw MKVError.parse("no Segment") }
        segmentDataStart = segOffset + Int64(seg.headerLength)
        segmentEnd = seg.size.map { min(segmentDataStart + $0, reader.length) } ?? reader.length

        var seekTargets: [UInt32: Int64] = [:]
        var sawInfo = false, sawTracks = false, sawCues = false
        var pos = segmentDataStart
        // Walk top-level elements up to the first cluster.
        while pos < segmentEnd {
            let h = try readHeader(at: pos)
            if h.id == MKVID.cluster { firstClusterOffset = pos; break }
            guard let size = h.size else { break }
            let payload = pos + Int64(h.headerLength)
            switch h.id {
            case MKVID.seekHead:
                let d = try reader.read(payload, Int(size))
                Self.children(d) { id, seek in
                    guard id == MKVID.seek else { return }
                    var sid: UInt32 = 0, spos: Int64 = 0
                    Self.children(seek) { cid, v in
                        if cid == MKVID.seekID { sid = UInt32(truncatingIfNeeded: Self.uint(v)) }
                        if cid == MKVID.seekPosition { spos = Int64(Self.uint(v)) }
                    }
                    if seekTargets[sid] == nil { seekTargets[sid] = segmentDataStart + spos }
                }
            case MKVID.info: try parseInfo(try reader.read(payload, Int(size))); sawInfo = true
            case MKVID.tracks: try parseTracks(try reader.read(payload, Int(size))); sawTracks = true
            case MKVID.cues: try parseCues(try reader.read(payload, Int(size))); sawCues = true
            default: break
            }
            pos = payload + size
        }
        if !sawInfo, let p = seekTargets[MKVID.info], let (h, d) = try? readElement(at: p), h.id == MKVID.info { try parseInfo(d) }
        if !sawTracks, let p = seekTargets[MKVID.tracks], let (h, d) = try? readElement(at: p), h.id == MKVID.tracks { try parseTracks(d) }
        if !sawCues, let p = seekTargets[MKVID.cues], let (h, d) = try? readElement(at: p), h.id == MKVID.cues { try parseCues(d) }
        guard !tracks.isEmpty else { throw MKVError.parse("no tracks") }
        guard let first = firstClusterOffset else { throw MKVError.parse("no clusters") }
        // Cue cluster offsets are known positions; their headers are read lazily on first use.
        knownOffsets = Array(Set(cuePoints.map(\.cluster) + [first])).sorted()
        _ = try cluster(at: first)
    }

    private func parseInfo(_ d: Data) throws {
        var dur = 0.0
        Self.children(d) { id, v in
            switch id {
            case MKVID.timestampScale: timestampScale = Int64(Self.uint(v))
            case MKVID.duration: dur = Self.float(v)
            case MKVID.title: title = Self.string(v)
            default: break
            }
        }
        durationNs = Int64(dur * Double(timestampScale))
    }

    private func parseTracks(_ d: Data) throws {
        Self.children(d) { id, entry in
            guard id == MKVID.trackEntry else { return }
            let t = MKVTrack()
            Self.children(entry) { id, v in
                switch id {
                case MKVID.trackNumber: t.number = Self.uint(v)
                case MKVID.trackType: t.type = Int(Self.uint(v))
                case MKVID.codecID: t.codecID = Self.string(v)
                case MKVID.codecPrivate: t.codecPrivate = v
                case MKVID.defaultDuration: t.defaultDurationNs = Int64(Self.uint(v))
                case MKVID.codecDelay: t.codecDelayNs = Int64(Self.uint(v))
                case MKVID.name: t.name = Self.string(v)
                case MKVID.language: t.language = Self.string(v)
                case MKVID.languageBCP47: t.languageBCP47 = Self.string(v)
                case MKVID.flagEnabled: t.enabled = Self.uint(v) != 0
                case MKVID.flagDefault: t.isDefault = Self.uint(v) != 0
                case MKVID.flagForced: t.isForced = Self.uint(v) != 0
                case MKVID.video:
                    Self.children(v) { id, v in
                        switch id {
                        case MKVID.pixelWidth: t.width = Int(Self.uint(v))
                        case MKVID.pixelHeight: t.height = Int(Self.uint(v))
                        case MKVID.displayWidth: t.displayWidth = Int(Self.uint(v))
                        case MKVID.displayHeight: t.displayHeight = Int(Self.uint(v))
                        case MKVID.colour: t.colour = Self.parseColour(v)
                        default: break
                        }
                    }
                case MKVID.audio:
                    Self.children(v) { id, v in
                        switch id {
                        case MKVID.samplingFrequency: t.sampleRate = Self.float(v)
                        case MKVID.outputSamplingFrequency: t.outputSampleRate = Self.float(v)
                        case MKVID.channels: t.channels = Int(Self.uint(v))
                        case MKVID.bitDepth: t.bitDepth = Int(Self.uint(v))
                        default: break
                        }
                    }
                case MKVID.contentEncodings:
                    Self.children(v) { id, enc in
                        guard id == MKVID.contentEncoding else { return }
                        Self.children(enc) { id, comp in
                            guard id == MKVID.contentCompression else { t.unsupportedEncoding = true; return }
                            var algo: UInt64 = 0; var settings = Data()
                            Self.children(comp) { id, v in
                                if id == MKVID.contentCompAlgo { algo = Self.uint(v) }
                                if id == MKVID.contentCompSettings { settings = v }
                            }
                            if algo == 3 { t.strippedHeader = settings } else { t.unsupportedEncoding = true }
                        }
                    }
                default: break
                }
            }
            if t.number != 0 { tracks.append(t) }
        }
    }

    private static func parseColour(_ d: Data) -> MKVColour {
        var c = MKVColour()
        children(d) { id, v in
            switch id {
            case MKVID.matrix: c.matrix = Int(uint(v))
            case MKVID.bitsPerChannel: c.bitsPerChannel = Int(uint(v))
            case MKVID.range: c.range = Int(uint(v))
            case MKVID.transfer: c.transfer = Int(uint(v))
            case MKVID.primaries: c.primaries = Int(uint(v))
            case MKVID.maxCLL: c.maxCLL = Int(uint(v))
            case MKVID.maxFALL: c.maxFALL = Int(uint(v))
            case MKVID.mastering:
                children(v) { id, v in
                    if id >= 0x55D1 && id <= 0x55D8 { c.chromaticities[Int(id - 0x55D1)] = float(v) }
                    if id == MKVID.lumMax { c.lumMax = float(v) }
                    if id == MKVID.lumMin { c.lumMin = float(v) }
                }
            default: break
            }
        }
        return c
    }

    private func parseCues(_ d: Data) throws {
        var points: [(Int64, Int64)] = []
        Self.children(d) { id, cp in
            guard id == MKVID.cuePoint else { return }
            var time: Int64 = 0; var pos: Int64 = -1
            Self.children(cp) { id, v in
                if id == MKVID.cueTime { time = Int64(Self.uint(v)) }
                if id == MKVID.cueTrackPositions, pos < 0 {
                    Self.children(v) { id, v in if id == MKVID.cueClusterPosition { pos = Int64(Self.uint(v)) } }
                }
            }
            if pos >= 0 { points.append((time * timestampScale, segmentDataStart + pos)) }
        }
        points.sort { $0.0 < $1.0 }
        // Collapse to one entry per cluster (earliest cue time in it).
        var seen = Set<Int64>()
        cuePoints = points.filter { seen.insert($0.1).inserted }.map { (timeNs: $0.0, cluster: $0.1) }
    }

    // MARK: - Cluster index

    /// Registers (or returns) the cluster whose element starts at `offset`, reading its header and timestamp.
    func cluster(at offset: Int64) throws -> MKVCluster {
        lock.lock(); defer { lock.unlock() }
        if let c = clusters[offset] { return c }
        let d = try reader.read(offset, 64)
        guard let h = Self.readHeader(d, 0), h.id == MKVID.cluster else { throw MKVError.parse("no cluster at \(offset)") }
        let dataStart = offset + Int64(h.headerLength)
        let end = h.size.map { min(dataStart + $0, segmentEnd) } ?? segmentEnd
        let c = MKVCluster(offset: offset, dataStart: dataStart, end: end, sizeKnown: h.size != nil)
        // Timestamp is (almost always) the first child.
        var p = h.headerLength
        while p < d.count, let ch = Self.readHeader(d, p), let sz = ch.size {
            if ch.id == MKVID.timestamp, p + ch.headerLength + Int(sz) <= d.count {
                c.timestamp = Int64(Self.uint(d.subdata(in: (d.startIndex + p + ch.headerLength)..<(d.startIndex + p + ch.headerLength + Int(sz)))))
                break
            }
            if ch.id == MKVID.simpleBlock || ch.id == MKVID.blockGroup { break }
            p += ch.headerLength + Int(sz)
        }
        clusters[offset] = c
        let i = knownOffsets.insertionIndex(of: offset)
        if i >= knownOffsets.count || knownOffsets[i] != offset { knownOffsets.insert(offset, at: i) }
        return c
    }

    func firstCluster() throws -> MKVCluster { try cluster(at: firstClusterOffset!) }

    func nextCluster(after c: MKVCluster) throws -> MKVCluster? {
        lock.lock(); defer { lock.unlock() }
        if let n = nextOf[c.offset] { return clusters[n] }
        if lastClusterOffset == c.offset { return nil }
        if !c.sizeKnown { _ = try parsedCluster(c) } // resolves `end`
        var pos = c.end
        while pos + 2 < segmentEnd {
            guard let h = try? readHeader(at: pos) else { break }
            if h.id == MKVID.cluster {
                let n = try cluster(at: pos)
                nextOf[c.offset] = pos
                return n
            }
            guard let size = h.size, MKVID.topLevel.contains(h.id) || h.id == MKVID.void || h.id == MKVID.crc32 else { break }
            pos += Int64(h.headerLength) + size
        }
        lastClusterOffset = c.offset
        return nil
    }

    func previousCluster(before c: MKVCluster) throws -> MKVCluster? {
        lock.lock(); defer { lock.unlock() }
        let i = knownOffsets.insertionIndex(of: c.offset)
        guard i > 0 else { return nil }
        var x = try cluster(at: knownOffsets[i - 1])
        while let n = try nextCluster(after: x), n.offset < c.offset { x = n }
        return x
    }

    func lastCluster() throws -> MKVCluster {
        lock.lock(); defer { lock.unlock() }
        var c = try cluster(at: knownOffsets.last!)
        while let n = try nextCluster(after: c) { c = n }
        return c
    }

    /// The cluster to start scanning from for presentation time `ns`.
    func seekCluster(forTime ns: Int64) throws -> MKVCluster {
        guard !cuePoints.isEmpty else { return try firstCluster() }
        var lo = 0, hi = cuePoints.count - 1, best = -1
        while lo <= hi {
            let mid = (lo + hi) / 2
            if cuePoints[mid].timeNs <= ns { best = mid; lo = mid + 1 } else { hi = mid - 1 }
        }
        return best < 0 ? try firstCluster() : try cluster(at: cuePoints[best].cluster)
    }

    // MARK: - Cluster parsing

    func parsedCluster(_ c: MKVCluster) throws -> MKVParsedCluster {
        lock.lock(); defer { lock.unlock() }
        if let p = parsed[c.offset] {
            if let i = lru.firstIndex(of: c.offset) { lru.remove(at: i) }
            lru.append(c.offset)
            return p
        }
        let p = try parseBlocks(c)
        parsed[c.offset] = p
        lru.append(c.offset)
        if lru.count > maxParsed { parsed.removeValue(forKey: lru.removeFirst()) }
        return p
    }

    private func parseBlocks(_ c: MKVCluster) throws -> MKVParsedCluster {
        let out = MKVParsedCluster()
        let win = WindowReader(reader: reader, limit: c.sizeKnown ? c.end : segmentEnd)
        var pos = c.dataStart
        let end = c.sizeKnown ? c.end : segmentEnd
        while pos < end {
            guard let h = try win.header(at: pos) else { break }
            let payload = pos + Int64(h.headerLength)
            if !c.sizeKnown && MKVID.topLevel.contains(h.id) { c.end = pos; c.sizeKnown = true; break }
            guard let size = h.size else { break }
            switch h.id {
            case MKVID.timestamp:
                c.timestamp = Int64(Self.uint(try win.bytes(payload, Int(size))))
            case MKVID.simpleBlock:
                let flags = try parseBlock(win, payload, size, cluster: c, into: out, durationTicks: nil, keyOverride: nil)
                _ = flags
            case MKVID.blockGroup:
                var blockAt: (Int64, Int64)?
                var hasRef = false
                var dur: Int64?
                var q = payload
                while q < payload + size, let ch = try win.header(at: q), let cs = ch.size {
                    let cp = q + Int64(ch.headerLength)
                    switch ch.id {
                    case MKVID.block: blockAt = (cp, cs)
                    case MKVID.referenceBlock: hasRef = true
                    case MKVID.blockDuration: dur = Int64(Self.uint(try win.bytes(cp, Int(cs))))
                    default: break
                    }
                    q = cp + cs
                }
                if let (bp, bs) = blockAt {
                    _ = try parseBlock(win, bp, bs, cluster: c, into: out, durationTicks: dur, keyOverride: !hasRef)
                }
            default: break
            }
            pos = payload + size
        }
        if !c.sizeKnown { c.end = pos; c.sizeKnown = true }
        finalizeTimings(out)
        return out
    }

    @discardableResult
    private func parseBlock(_ win: WindowReader, _ payload: Int64, _ size: Int64, cluster c: MKVCluster, into out: MKVParsedCluster,
                            durationTicks: Int64?, keyOverride: Bool?) throws -> UInt8 {
        let head = try win.bytes(payload, Int(min(size, 16)))
        guard let (trackNo, tl, _) = Self.readVint(head, 0), head.count >= tl + 3 else { return 0 }
        guard let track = track(UInt64(trackNo)), track.isVideo || track.isAudio else { return 0 }
        let rel = Int64(Int16(bitPattern: UInt16(head[head.startIndex + tl]) << 8 | UInt16(head[head.startIndex + tl + 1])))
        let flags = head[head.startIndex + tl + 2]
        let isKey = keyOverride ?? (flags & 0x80 != 0)
        let discardable = flags & 0x01 != 0
        let basePts = ((c.timestamp ?? 0) + rel) * timestampScale - (track.isAudio ? track.codecDelayNs : 0)
        var frames: [(Int64, Int32)] = []   // (offset, size)
        let dataStart = payload + Int64(tl + 3)
        let lacing = (flags >> 1) & 0x03
        if lacing == 0 {
            frames.append((dataStart, Int32(size - Int64(tl + 3))))
        } else {
            let lh = try win.bytes(dataStart, Int(min(size - Int64(tl + 3), 8192)))
            guard !lh.isEmpty else { return flags }
            let n = Int(lh[lh.startIndex]) + 1
            var p = 1
            var sizes: [Int64] = []
            switch lacing {
            case 1: // Xiph
                for _ in 0..<(n - 1) {
                    var s: Int64 = 0
                    while p < lh.count { let b = lh[lh.startIndex + p]; p += 1; s += Int64(b); if b != 255 { break } }
                    sizes.append(s)
                }
            case 3: // EBML
                guard let (first, l, _) = Self.readVint(lh, p) else { return flags }
                p += l; sizes.append(first)
                var prev = first
                for _ in 1..<max(n - 1, 1) where n > 2 {
                    guard let (raw, l2, _) = Self.readVint(lh, p) else { return flags }
                    p += l2
                    let bias = (Int64(1) << (7 * l2 - 1)) - 1
                    prev = prev + (raw - bias)
                    sizes.append(prev)
                }
            default: // fixed
                let total = size - Int64(tl + 3) - 1
                sizes = Array(repeating: total / Int64(n), count: n - 1)
            }
            let total = size - Int64(tl + 3) - Int64(p)
            sizes.append(total - sizes.reduce(0, +))
            var off = dataStart + Int64(p)
            for s in sizes { frames.append((off, Int32(s))); off += s }
        }
        let frameDur = track.defaultDurationNs > 0 ? track.defaultDurationNs : estimatedFrameDuration(track)
        let blockDur = durationTicks.map { $0 * timestampScale }
        var arr = out.samples[track.number] ?? []
        for (i, f) in frames.enumerated() {
            let pts = basePts + Int64(i) * frameDur
            let dur = frames.count == 1 ? (blockDur ?? track.defaultDurationNs) : frameDur
            arr.append(MKVSample(ptsNs: pts, dtsNs: pts, durationNs: dur, offset: f.0, size: f.1, isKey: track.isAudio || isKey, isDiscardable: discardable))
        }
        out.samples[track.number] = arr
        return flags
    }

    private func estimatedFrameDuration(_ t: MKVTrack) -> Int64 {
        guard t.isAudio, t.sampleRate > 0 else { return 0 }
        let frames: Double
        switch t.codecID {
        case let s where s.hasPrefix("A_AAC"): frames = 1024
        case "A_AC3", "A_EAC3": frames = 1536
        case "A_MPEG/L3", "A_MPEG/L2": frames = 1152
        case "A_OPUS": frames = 960
        default: return 0
        }
        return Int64(frames / t.sampleRate * 1e9)
    }

    /// Fills missing durations and synthesizes decode timestamps for reordering codecs.
    private func finalizeTimings(_ p: MKVParsedCluster) {
        for (no, var arr) in p.samples {
            guard let t = track(no), !arr.isEmpty else { continue }
            let order = arr.indices.sorted { arr[$0].ptsNs < arr[$1].ptsNs }
            for (k, i) in order.enumerated() where arr[i].durationNs <= 0 {
                if k + 1 < order.count { arr[i].durationNs = arr[order[k + 1]].ptsNs - arr[i].ptsNs }
                else if k > 0 { arr[i].durationNs = arr[i].ptsNs - arr[order[k - 1]].ptsNs }
            }
            if t.mayReorder {
                let sorted = order.map { arr[$0].ptsNs }
                if t.reorderDelayNs < 0 {
                    var shift: Int64 = 0
                    for i in arr.indices { shift = max(shift, sorted[i] - arr[i].ptsNs) }
                    let fd = t.defaultDurationNs > 0 ? t.defaultDurationNs : (arr.first?.durationNs ?? 0)
                    t.reorderDelayNs = max(shift, 2 * fd)
                }
                for i in arr.indices { arr[i].dtsNs = min(sorted[i] - t.reorderDelayNs, arr[i].ptsNs) }
            }
            p.samples[no] = arr
            p.presentationOrder[no] = order
        }
    }

    // MARK: - Sample navigation (decode order)

    func samples(_ track: UInt64, in c: MKVCluster) throws -> [MKVSample] {
        try parsedCluster(c).samples[track] ?? []
    }

    func sample(_ track: UInt64, _ pos: MKVPosition) throws -> MKVSample {
        let arr = try samples(track, in: try cluster(at: pos.cluster))
        guard pos.index < arr.count else { throw MKVError.noSamples }
        return arr[pos.index]
    }

    func firstPosition(_ track: UInt64) throws -> MKVPosition {
        var c: MKVCluster? = try firstCluster()
        while let cc = c {
            if try !samples(track, in: cc).isEmpty { return MKVPosition(cluster: cc.offset, index: 0) }
            c = try nextCluster(after: cc)
        }
        throw MKVError.noSamples
    }

    func lastPosition(_ track: UInt64) throws -> MKVPosition {
        var c: MKVCluster? = try lastCluster()
        while let cc = c {
            let n = try samples(track, in: cc).count
            if n > 0 { return MKVPosition(cluster: cc.offset, index: n - 1) }
            c = try previousCluster(before: cc)
        }
        throw MKVError.noSamples
    }

    /// Steps in decode order. Returns the new position and the number of steps actually taken.
    func step(_ track: UInt64, from pos: MKVPosition, by count: Int64) throws -> (MKVPosition, Int64) {
        var cur = pos
        var taken: Int64 = 0
        var c = try cluster(at: cur.cluster)
        var arr = try samples(track, in: c)
        if count > 0 {
            while taken < count {
                let room = Int64(arr.count - 1 - cur.index)
                if room >= count - taken { cur.index += Int(count - taken); taken = count; break }
                taken += max(room, 0); cur.index = arr.count - 1
                // move to the next cluster that has samples for this track
                var found = false
                var n = try nextCluster(after: c)
                while let nc = n {
                    let na = try samples(track, in: nc)
                    if !na.isEmpty { c = nc; arr = na; cur = MKVPosition(cluster: nc.offset, index: 0); taken += 1; found = true; break }
                    n = try nextCluster(after: nc)
                }
                if !found { break }
            }
        } else if count < 0 {
            let want = -count
            while taken < want {
                if Int64(cur.index) >= want - taken { cur.index -= Int(want - taken); taken = want; break }
                taken += Int64(cur.index); cur.index = 0
                var found = false
                var p = try previousCluster(before: c)
                while let pc = p {
                    let pa = try samples(track, in: pc)
                    if !pa.isEmpty { c = pc; arr = pa; cur = MKVPosition(cluster: pc.offset, index: pa.count - 1); taken += 1; found = true; break }
                    p = try previousCluster(before: pc)
                }
                if !found { break }
            }
            taken = -taken
        }
        return (cur, taken)
    }

    // MARK: - Presentation order

    /// Position of the sample with the greatest PTS <= `ns` (or the first sample if `ns` precedes all).
    func position(_ track: UInt64, atPTS ns: Int64) throws -> MKVPosition {
        var c: MKVCluster? = try seekCluster(forTime: ns)
        var best: (MKVPosition, Int64)?
        var firstSeen: MKVPosition?
        let margin: Int64 = 2_000_000_000
        while let cc = c {
            if let ts = cc.timestamp, ts * timestampScale > ns + margin, best != nil { break }
            let arr = try samples(track, in: cc)
            for (i, s) in arr.enumerated() {
                if firstSeen == nil { firstSeen = MKVPosition(cluster: cc.offset, index: i) }
                if s.ptsNs <= ns, best == nil || s.ptsNs > best!.1 { best = (MKVPosition(cluster: cc.offset, index: i), s.ptsNs) }
            }
            if let ts = cc.timestamp, ts * timestampScale > ns + margin { break }
            c = try nextCluster(after: cc)
        }
        if let best { return best.0 }
        if let firstSeen { return firstSeen }
        return try firstPosition(track)
    }

    /// Steps in presentation order (approximated per cluster, which is exact for closed-GOP content).
    func stepPresentation(_ track: UInt64, from pos: MKVPosition, by count: Int64) throws -> (MKVPosition, Int64) {
        var cur = pos
        var taken: Int64 = 0
        let dir: Int64 = count >= 0 ? 1 : -1
        while taken != count {
            var c = try cluster(at: cur.cluster)
            let pc = try parsedCluster(c)
            guard let order = pc.presentationOrder[track], let k = order.firstIndex(of: cur.index) else { break }
            let nk = k + Int(dir)
            if nk >= 0 && nk < order.count { cur.index = order[nk]; taken += dir; continue }
            // cross cluster boundary
            var moved = false
            while true {
                guard let nc = try (dir > 0 ? nextCluster(after: c) : previousCluster(before: c)) else { break }
                c = nc
                let npc = try parsedCluster(nc)
                if let o = npc.presentationOrder[track], !o.isEmpty {
                    cur = MKVPosition(cluster: nc.offset, index: dir > 0 ? o.first! : o.last!)
                    taken += dir; moved = true; break
                }
            }
            if !moved { break }
        }
        return (cur, taken)
    }

    // MARK: - Data

    func readSample(_ s: MKVSample, track: MKVTrack) throws -> Data {
        var d = try reader.read(s.offset, Int(s.size))
        if let h = track.strippedHeader { d = h + d }
        return d
    }

    var estimatedBytesPerSecond: Double {
        durationNs > 0 ? Double(reader.length) / (Double(durationNs) / 1e9) : 0
    }
}

/// Small read-through window so walking block headers inside a cluster doesn't issue a read per element
/// when blocks are small (audio), while large video frames are skipped without being read.
final class WindowReader {
    let reader: MKVByteReader
    let limit: Int64
    private var base: Int64 = -1
    private var data = Data()
    private let windowSize = 32 * 1024
    init(reader: MKVByteReader, limit: Int64) { self.reader = reader; self.limit = limit }

    func bytes(_ offset: Int64, _ count: Int) throws -> Data {
        if base >= 0, offset >= base, offset + Int64(count) <= base + Int64(data.count) {
            let s = data.startIndex + Int(offset - base)
            return data.subdata(in: s..<(s + count))
        }
        let want = Int(min(Int64(max(count, windowSize)), max(limit - offset, Int64(count))))
        data = try reader.read(offset, want)
        base = offset
        return data.prefix(count)
    }

    func header(at offset: Int64) throws -> MatroskaFile.Header? {
        MatroskaFile.readHeader(try bytes(offset, Int(min(12, max(limit - offset, 0)))), 0)
    }
}

extension Array where Element == Int64 {
    func insertionIndex(of v: Int64) -> Int {
        var lo = 0, hi = count
        while lo < hi { let m = (lo + hi) / 2; if self[m] < v { lo = m + 1 } else { hi = m } }
        return lo
    }
}

/// File-backed reader for testing the parser in-process.
final class FileMKVReader: MKVByteReader {
    let handle: FileHandle
    let length: Int64
    init(path: String) throws {
        handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        length = Int64(try handle.seekToEnd())
    }
    func read(_ offset: Int64, _ count: Int) throws -> Data {
        try handle.seek(toOffset: UInt64(offset))
        return try handle.read(upToCount: count) ?? Data()
    }
}
