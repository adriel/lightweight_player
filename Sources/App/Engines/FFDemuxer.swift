import Foundation
import CoreMedia
import CoreVideo
import AudioToolbox
import VideoToolbox
import CFFmpeg

/// Thin libavformat wrapper: demux only (no libavcodec decoding). Produces CMFormatDescriptions
/// and wraps AVPackets as CMSampleBuffers without copying the payload.
final class FFDemuxer {
    private(set) var ctx: UnsafeMutablePointer<AVFormatContext>?
    private(set) var videoIndex: Int32 = -1
    private(set) var audioIndex: Int32 = -1
    private(set) var videoFormat: CMVideoFormatDescription?
    private(set) var audioFormat: CMAudioFormatDescription?
    private(set) var warnings: [String] = []
    private(set) var subtitleIndex: Int32 = -1
    /// Software fallbacks (only created when macOS can't decode the stream itself).
    private(set) var swVideo: SWVideoDecoder?
    private(set) var swAudio: SWAudioDecoder?
    /// In-app VideoToolbox decoding for hardware formats (see HWVideoDecoder).
    private(set) var hwVideo: HWVideoDecoder?
    private var swSubtitle: SWSubtitleDecoder?
    /// Informational messages (e.g. "AV1 decoded in software") — not problems.
    private(set) var notices: [String] = []
    private(set) var subtitleStreams: [SubtitleTrackInfo] = []
    private(set) var videoCodecName = "-"
    private(set) var audioCodecName = "-"
    /// True when the video bitstream is Annex-B (start codes) and must be converted to length-prefixed NALUs.
    private var videoNeedsAnnexBConversion = false
    private var audioFramesPerPacket: UInt32 = 0
    private var interruptFlag = UnsafeMutablePointer<Int32>.allocate(capacity: 1)

    /// Custom I/O (used for network streams through the disk cache).
    private var ioContext: UnsafeMutablePointer<AVIOContext>?
    private var ioBox: Unmanaged<IOBox>?

    convenience init(url: String) throws { try self.init(url: url, source: nil) }

    init(url: String, source: CachedHTTPSource?) throws {
        interruptFlag.initialize(to: 0)
        var c: UnsafeMutablePointer<AVFormatContext>? = avformat_alloc_context()
        c?.pointee.interrupt_callback.callback = { opaque in opaque!.assumingMemoryBound(to: Int32.self).pointee }
        c?.pointee.interrupt_callback.opaque = UnsafeMutableRawPointer(interruptFlag)
        var opts: OpaquePointer?
        if let source {
            let box = Unmanaged.passRetained(IOBox(source))
            ioBox = box
            let bufSize: Int32 = 256 * 1024
            let buf = av_malloc(Int(bufSize))!.assumingMemoryBound(to: UInt8.self)
            ioContext = avio_alloc_context(buf, bufSize, 0, box.toOpaque(), { opaque, buf, size in
                let b = Unmanaged<IOBox>.fromOpaque(opaque!).takeUnretainedValue()
                let n = b.source.read(buf!, count: Int(size), at: b.position)
                if n > 0 { b.position += Int64(n); return Int32(n) }
                return n == 0 ? lp_averror_eof() : -5 /* AVERROR(EIO) */
            }, nil, { opaque, offset, whence in
                let b = Unmanaged<IOBox>.fromOpaque(opaque!).takeUnretainedValue()
                switch whence & ~AVSEEK_FORCE {
                case AVSEEK_SIZE: return b.source.length
                case SEEK_SET: b.position = offset
                case SEEK_CUR: b.position += offset
                case SEEK_END: b.position = b.source.length + offset
                default: return -1
                }
                return b.position
            })
            ioContext?.pointee.seekable = AVIO_SEEKABLE_NORMAL
            c?.pointee.pb = ioContext
            c?.pointee.flags |= AVFMT_FLAG_CUSTOM_IO
        } else if !url.contains("://"), let f = FragmentedMP4(path: url) {
            // Unindexed fragmented MP4: don't let libavformat walk every fragment at open (see FragmentedMP4).
            fragmented = f
            c?.pointee.flags |= AVFMT_FLAG_IGNIDX
        } else {
            av_dict_set(&opts, "reconnect", "1", 0)
            av_dict_set(&opts, "reconnect_streamed", "1", 0)
            av_dict_set(&opts, "reconnect_delay_max", "10", 0)
        }
        let tOpen = Date()
        let r = avformat_open_input(&c, source == nil ? url : nil, nil, &opts)
        av_dict_free(&opts)
        if ProcessInfo.processInfo.environment["LP_OPEN_DEBUG"] != nil { NSLog("open: avformat_open_input %.0f ms", Date().timeIntervalSince(tOpen) * 1000) }
        guard r >= 0, let c else { throw FFError.open(r) }
        ctx = c
        // MP4/MKV headers carry full codec parameters; only probe packets when they don't.
        if needsProbe(c) {
            let t = Date()
            c.pointee.probesize = 2_000_000
            c.pointee.max_analyze_duration = 2 * Int64(AV_TIME_BASE)
            avformat_find_stream_info(c, nil)
            if ProcessInfo.processInfo.environment["LP_OPEN_DEBUG"] != nil { NSLog("open: find_stream_info %.0f ms", Date().timeIntervalSince(t) * 1000) }
        }
        videoIndex = av_find_best_stream(c, AVMEDIA_TYPE_VIDEO, -1, -1, nil, 0)
        audioIndex = av_find_best_stream(c, AVMEDIA_TYPE_AUDIO, -1, videoIndex, nil, 0)
        // Discard every stream we don't render so libavformat doesn't allocate packets for them.
        for i in 0..<Int32(c.pointee.nb_streams) where i != videoIndex && i != audioIndex {
            c.pointee.streams[Int(i)]!.pointee.discard = AVDISCARD_ALL
        }
        if videoIndex >= 0 { buildVideoFormat() }
        if videoIndex >= 0, swVideo == nil, let fd = videoFormat, ProcessInfo.processInfo.environment["LP_LAYER_DECODE"] == nil {
            hwVideo = HWVideoDecoder(format: fd, toneMapToSDR: !Settings.shared.hdrEnabled && FFDemuxer.isHDR(fd))     // nil (→ the layer decodes) if VideoToolbox can't do it in hardware
        }
        if audioIndex >= 0 { buildAudioFormat() }
        collectSubtitleStreams()
    }

    /// Audio streams (for the track picker).
    var audioStreams: [AudioTrackInfo] {
        guard let ctx else { return [] }
        var out: [AudioTrackInfo] = []
        for i in 0..<Int(ctx.pointee.nb_streams) {
            let st = ctx.pointee.streams[i]!.pointee
            let par = st.codecpar.pointee
            guard par.codec_type == AVMEDIA_TYPE_AUDIO else { continue }
            func tag(_ k: String) -> String? { av_dict_get(st.metadata, k, nil, 0).map { String(cString: $0.pointee.value) } }
            let codec = String(cString: avcodec_get_name(par.codec_id)).uppercased().replacingOccurrences(of: "EAC3", with: "E-AC-3").replacingOccurrences(of: "AC3", with: "AC-3")
            let ch = Int(par.ch_layout.nb_channels)
            let chs = ch == 6 ? "5.1" : ch == 8 ? "7.1" : ch == 2 ? "stereo" : ch == 1 ? "mono" : "\(ch) ch"
            out.append(AudioTrackInfo(id: i, title: tag("title") ?? tag("handler_name").flatMap { $0.contains("Handler") ? nil : $0 } ?? "",
                                      language: tag("language"), detail: "\(codec) \(chs)", isDefault: st.disposition & AV_DISPOSITION_DEFAULT != 0))
        }
        return out
    }

    /// Switch the demuxed audio stream. Call on the demux queue; the caller re-seeks to refill.
    func selectAudio(_ index: Int32) -> Bool {
        guard let ctx, index != audioIndex, index >= 0, index < Int32(ctx.pointee.nb_streams),
              stream(index).pointee.codecpar.pointee.codec_type == AVMEDIA_TYPE_AUDIO else { return false }
        if audioIndex >= 0 { stream(audioIndex).pointee.discard = AVDISCARD_ALL }
        audioIndex = index
        stream(index).pointee.discard = AVDISCARD_DEFAULT
        swAudio = nil; audioFormat = nil
        buildAudioFormat()
        return audioIndex >= 0
    }

    /// Chapters from the container (start time + title).
    var chapters: [ChapterInfo] {
        guard let ctx, ctx.pointee.nb_chapters > 0 else { return [] }
        return (0..<Int(ctx.pointee.nb_chapters)).compactMap { i in
            guard let ch = ctx.pointee.chapters[i]?.pointee else { return nil }
            let t = Double(ch.start) * av_q2d(ch.time_base)
            let title = av_dict_get(ch.metadata, "title", nil, 0).map { String(cString: $0.pointee.value) } ?? "Chapter \(i + 1)"
            return ChapterInfo(start: t, title: title)
        }.sorted { $0.start < $1.start }
    }

    private func collectSubtitleStreams() {
        guard let ctx else { return }
        let textCodecs: Set<String> = ["subrip", "srt", "ass", "ssa", "webvtt", "mov_text", "text", "microdvd", "sami"]
        let imageCodecs: Set<String> = ["hdmv_pgs_subtitle", "dvd_subtitle", "dvb_subtitle", "xsub", "dvb_teletext"]
        for i in 0..<Int(ctx.pointee.nb_streams) {
            let st = ctx.pointee.streams[i]!.pointee
            guard st.codecpar.pointee.codec_type == AVMEDIA_TYPE_SUBTITLE else { continue }
            let codec = String(cString: avcodec_get_name(st.codecpar.pointee.codec_id))
            func tag(_ k: String) -> String? { av_dict_get(st.metadata, k, nil, 0).map { String(cString: $0.pointee.value) } }
            let kind: SubtitleTrackInfo.Kind = textCodecs.contains(codec) ? .text : imageCodecs.contains(codec) ? .image : .unsupported
            subtitleStreams.append(SubtitleTrackInfo(id: i, title: tag("title") ?? "", language: tag("language"), codec: codec,
                                                     isForced: st.disposition & AV_DISPOSITION_FORCED != 0,
                                                     isDefault: st.disposition & AV_DISPOSITION_DEFAULT != 0, kind: kind, externalURL: nil))
        }
    }

    /// Enables demuxing of one subtitle stream (others stay discarded). Call on the demux queue.
    func selectSubtitle(_ index: Int32?) {
        guard let ctx else { return }
        if subtitleIndex >= 0 { ctx.pointee.streams[Int(subtitleIndex)]!.pointee.discard = AVDISCARD_ALL }
        subtitleIndex = index ?? -1
        swSubtitle = nil
        if subtitleIndex >= 0 {
            let st = ctx.pointee.streams[Int(subtitleIndex)]!
            st.pointee.discard = AVDISCARD_DEFAULT
            if subtitleStreams.first(where: { $0.id == Int(subtitleIndex) })?.kind == .image {
                swSubtitle = SWSubtitleDecoder(par: st.pointee.codecpar, videoSize: naturalSize)
            }
        }
    }

    var naturalSize: CGSize {
        guard videoIndex >= 0 else { return .zero }
        let par = stream(videoIndex).pointee.codecpar.pointee
        var w = Double(par.width), h = Double(par.height)
        let sar = par.sample_aspect_ratio
        if sar.num > 0 && sar.den > 0 && sar.num != sar.den { w = w * Double(sar.num) / Double(sar.den) }
        if w <= 0 || h <= 0 { w = 16; h = 9 }
        return CGSize(width: w, height: h)
    }

    var bitRate: Int64 { ctx?.pointee.bit_rate ?? 0 }

    /// Static description of the file and decode path for the inspector (call on the demux queue).
    func mediaInfo() -> MediaInfo {
        var m = MediaInfo()
        guard let ctx else { return m }
        func long(_ id: AVCodecID) -> String { avcodec_descriptor_get(id).flatMap { $0.pointee.long_name.map { String(cString: $0) } } ?? String(cString: avcodec_get_name(id)) }
        func str(_ p: UnsafePointer<CChar>?) -> String? { p.map { String(cString: $0) } }
        func tag(_ d: OpaquePointer?, _ k: String) -> String? { av_dict_get(d, k, nil, 0).map { String(cString: $0.pointee.value) } }
        func layout(_ l: AVChannelLayout) -> String {
            var l = l; var buf = [CChar](repeating: 0, count: 64)
            av_channel_layout_describe(&l, &buf, 64)
            let d = String(cString: buf)
            return d.hasSuffix("channels") ? InfoFormat.channels(Int(l.nb_channels)) : d
        }
        if videoIndex >= 0 {
            let st = stream(videoIndex).pointee, p = st.codecpar.pointee
            let fr = av_q2d(st.avg_frame_rate) > 0 ? av_q2d(st.avg_frame_rate) : av_q2d(st.r_frame_rate)
            var decoder: String
            if let sw = swVideo { decoder = "\(sw.decoderName) (software, \(sw.threads) threads)" }
            else if let fd = videoFormat { decoder = InfoFormat.videoDecoder(for: fd) + (hwVideo != nil ? " · in-app session" : " · inside the display layer") } else { decoder = "—" }
            var dovi = false
            for i in 0..<Int(p.nb_coded_side_data) where p.coded_side_data[i].type == AV_PKT_DATA_DOVI_CONF { dovi = true }
            let fdExt = videoFormat.flatMap { CMFormatDescriptionGetExtensions($0) as? [String: Any] }
            let fdTransfer = fdExt?[kCVImageBufferTransferFunctionKey as String] as? String
            let trc = p.color_trc != AVCOL_TRC_UNSPECIFIED ? str(av_color_transfer_name(p.color_trc)) : nil
            let extradata = p.extradata_size > 0 ? Data(bytes: p.extradata, count: Int(p.extradata_size)) : Data()
            let cfg = ParamSets.configInfo(extradata, hevc: p.codec_id == AV_CODEC_ID_HEVC, h264: p.codec_id == AV_CODEC_ID_H264)
            let profile = str(avcodec_profile_name(p.codec_id, p.profile)) ?? cfg.profile.flatMap { str(avcodec_profile_name(p.codec_id, $0)) } ?? "—"
            let pixfmt = str(av_get_pix_fmt_name(AVPixelFormat(rawValue: p.format))) ?? cfg.pixelFormat ?? "—"
            let bps = Double(p.bit_rate) > 0 ? Double(p.bit_rate) : Double(tag(st.metadata, "BPS") ?? tag(st.metadata, "BPS-eng") ?? "") ?? 0
            let dr = dovi ? "Dolby Vision (HDR10 base layer)" : trc == "smpte2084" ? "HDR10 (PQ)" : trc == "arib-std-b67" ? "HDR (HLG)" : InfoFormat.dynamicRange(transfer: fdTransfer)
            func color(_ name: String?, _ key: CFString) -> String {
                if let name, name != "unknown", name != "reserved" { return name }
                return (fdExt?[key as String] as? String).map(InfoFormat.prettyColor) ?? "N/A"
            }
            m.video = [("Format", videoCodecName), ("Codec", long(p.codec_id)),
                       ("Profile", profile),
                       ("Decoder", decoder), ("Renderer", swVideo == nil && hwVideo == nil ? "AVSampleBufferDisplayLayer (compressed → VideoToolbox)" : "AVSampleBufferDisplayLayer (decoded IOSurface frames)"),
                       ("Pixel format", pixfmt),
                       ("Size", "\(p.width)×\(p.height)" + (p.sample_aspect_ratio.num > 0 && p.sample_aspect_ratio.num != p.sample_aspect_ratio.den ? " (SAR \(p.sample_aspect_ratio.num):\(p.sample_aspect_ratio.den))" : "")),
                       ("Primaries", color(p.color_primaries != AVCOL_PRI_UNSPECIFIED ? str(av_color_primaries_name(p.color_primaries)) : nil, kCVImageBufferColorPrimariesKey)),
                       ("Transfer", color(trc, kCVImageBufferTransferFunctionKey)),
                       ("Matrix", color(p.color_space != AVCOL_SPC_UNSPECIFIED ? str(av_color_space_name(p.color_space)) : nil, kCVImageBufferYCbCrMatrixKey)),
                       ("Range", p.color_range == AVCOL_RANGE_JPEG || (fdExt?[kCMFormatDescriptionExtension_FullRangeVideo as String] as? Bool) == true ? "full" : "limited"),
                       ("Dynamic range", dr),
                       ("Bit rate", InfoFormat.bitrate(bps)), ("FPS", InfoFormat.fps(fr))]
        }
        if audioIndex >= 0 {
            let st = stream(audioIndex).pointee, p = st.codecpar.pointee
            let abps = Double(p.bit_rate) > 0 ? Double(p.bit_rate) : Double(tag(st.metadata, "BPS") ?? tag(st.metadata, "BPS-eng") ?? "") ?? 0
            m.audio = [("Format", audioCodecName), ("Codec", long(p.codec_id)),
                       ("Profile", str(avcodec_profile_name(p.codec_id, p.profile)) ?? tag(st.metadata, "title") ?? "—"),
                       ("Decoder", swAudio != nil ? "FFmpeg \(audioCodecName) (software) → Float32 PCM" + (Settings.shared.dtsCoreOnly && p.codec_id == AV_CODEC_ID_DTS ? ", core only" : "") : "Core Audio (AudioToolbox)"),
                       ("Renderer", "AVSampleBufferAudioRenderer"),
                       ("Channels", layout(p.ch_layout)), ("Sample rate", "\(p.sample_rate) Hz"),
                       ("Bit rate", InfoFormat.bitrate(abps))]
        }
        for i in 0..<Int(ctx.pointee.nb_streams) {
            let st = ctx.pointee.streams[i]!.pointee, p = st.codecpar.pointee
            let kind = p.codec_type == AVMEDIA_TYPE_VIDEO ? "Video" : p.codec_type == AVMEDIA_TYPE_AUDIO ? "Audio" : p.codec_type == AVMEDIA_TYPE_SUBTITLE ? "Subtitle" : "Data"
            var rows: [MediaInfo.Row] = [("Codec", long(p.codec_id))]
            if let l = tag(st.metadata, "language") { rows.append(("Language", l)) }
            if p.codec_type == AVMEDIA_TYPE_VIDEO { rows.append(("Size", "\(p.width)×\(p.height)")) }
            if p.codec_type == AVMEDIA_TYPE_AUDIO { rows.append(("Channels", layout(p.ch_layout))); rows.append(("Sample rate", "\(p.sample_rate) Hz")) }
            var flags: [String] = []
            if st.disposition & AV_DISPOSITION_DEFAULT != 0 { flags.append("default") }
            if st.disposition & AV_DISPOSITION_FORCED != 0 { flags.append("forced") }
            if st.disposition & AV_DISPOSITION_HEARING_IMPAIRED != 0 { flags.append("SDH") }
            if !flags.isEmpty { rows.append(("Flags", flags.joined(separator: ", "))) }
            if p.bit_rate > 0 { rows.append(("Bit rate", InfoFormat.bitrate(Double(p.bit_rate)))) }
            let title = "#\(i) \(String(cString: avcodec_get_name(p.codec_id)))" + (tag(st.metadata, "title").map { " — \($0)" } ?? "")
            let active = Int32(i) == videoIndex || Int32(i) == audioIndex || Int32(i) == subtitleIndex
            m.tracks.append(.init(id: i, kind: kind, title: title, rows: rows, active: active))
        }
        let fmtName = ctx.pointee.iformat.flatMap { $0.pointee.long_name.map { String(cString: $0) } } ?? "—"
        m.file = [("Container", fmtName), ("Duration", formatTime(duration)),
                  ("Overall bit rate", InfoFormat.bitrate(Double(ctx.pointee.bit_rate))),
                  ("Streams", "\(ctx.pointee.nb_streams)"), ("Chapters", "\(ctx.pointee.nb_chapters)")]
        var e: UnsafePointer<AVDictionaryEntry>? = nil
        while let next = av_dict_get(ctx.pointee.metadata, "", e, AV_DICT_IGNORE_SUFFIX) {
            m.metadata.append((String(cString: next.pointee.key), String(cString: next.pointee.value)))
            e = UnsafePointer(next)
        }
        return m
    }

    deinit {
        if ctx != nil { avformat_close_input(&ctx) }
        if spliceIO != nil { av_freep(&spliceIO!.pointee.buffer); avio_context_free(&spliceIO) }
        spliceBox?.release()
        if ioContext != nil {
            av_freep(&ioContext!.pointee.buffer)
            avio_context_free(&ioContext)
        }
        ioBox?.release()
        interruptFlag.deallocate()
    }

    func interrupt() { interruptFlag.pointee = 1 }

    // MARK: Unindexed fragmented MP4

    private(set) var fragmented: FragmentedMP4?
    private var spliceIO: UnsafeMutablePointer<AVIOContext>?
    private var spliceBox: Unmanaged<SpliceBox>?

    /// Re-opens the demuxer on header + the fragment at `offset` onward (timestamps stay absolute via tfdt).
    private func reopenSpliced(at offset: Int64) -> Bool {
        guard let f = fragmented else { return false }
        let box = Unmanaged.passRetained(SpliceBox(f, offset: offset))
        let bufSize: Int32 = 256 * 1024
        let buf = av_malloc(Int(bufSize))!.assumingMemoryBound(to: UInt8.self)
        var io = avio_alloc_context(buf, bufSize, 0, box.toOpaque(), { opaque, buf, size in
            let b = Unmanaged<SpliceBox>.fromOpaque(opaque!).takeUnretainedValue()
            let n = b.read(buf!, Int(size))
            return n > 0 ? Int32(n) : (n == 0 ? lp_averror_eof() : -5)
        }, nil, { opaque, offset, whence in
            let b = Unmanaged<SpliceBox>.fromOpaque(opaque!).takeUnretainedValue()
            return b.seek(offset, whence)
        })
        io?.pointee.seekable = AVIO_SEEKABLE_NORMAL
        var c: UnsafeMutablePointer<AVFormatContext>? = avformat_alloc_context()
        c?.pointee.pb = io
        c?.pointee.flags |= AVFMT_FLAG_CUSTOM_IO | AVFMT_FLAG_IGNIDX
        c?.pointee.interrupt_callback.callback = { opaque in opaque!.assumingMemoryBound(to: Int32.self).pointee }
        c?.pointee.interrupt_callback.opaque = UnsafeMutableRawPointer(interruptFlag)
        guard avformat_open_input(&c, nil, nil, nil) >= 0, let c, c.pointee.nb_streams == ctx?.pointee.nb_streams else {
            if io != nil { av_freep(&io!.pointee.buffer); avio_context_free(&io) }
            box.release()
            return false
        }
        // Same streams; carry over which ones we demux.
        if let old = ctx {
            for i in 0..<Int(c.pointee.nb_streams) { c.pointee.streams[i]!.pointee.discard = old.pointee.streams[i]!.pointee.discard }
        }
        if ctx != nil { avformat_close_input(&ctx) }
        if spliceIO != nil { av_freep(&spliceIO!.pointee.buffer); avio_context_free(&spliceIO) }
        spliceBox?.release()
        ctx = c; spliceIO = io; spliceBox = box
        return true
    }

    var duration: Double {
        if let f = fragmented, f.duration > 0 { return f.duration }
        guard let ctx else { return 0 }
        if ctx.pointee.duration > 0 { return Double(ctx.pointee.duration) / Double(AV_TIME_BASE) }
        // Without avformat_find_stream_info the container duration may be unset; fall back to streams.
        var best = 0.0
        for i in 0..<Int(ctx.pointee.nb_streams) {
            let st = ctx.pointee.streams[i]!.pointee
            if st.duration > 0 { best = max(best, Double(st.duration) * av_q2d(st.time_base)) }
        }
        return best
    }

    func stream(_ i: Int32) -> UnsafeMutablePointer<AVStream> { ctx!.pointee.streams[Int(i)]! }

    // MARK: Reading

    /// Returns the next packet for the video or audio stream (others are discarded), or nil at EOF/error.
    func readPacket() -> UnsafeMutablePointer<AVPacket>? {
        guard let ctx else { return nil }
        var pkt: UnsafeMutablePointer<AVPacket>? = av_packet_alloc()
        while true {
            let r = av_read_frame(ctx, pkt)
            if r < 0 { av_packet_free(&pkt); return nil }
            let si = pkt!.pointee.stream_index
            if si == videoIndex || si == audioIndex || (si == subtitleIndex && subtitleIndex >= 0) { return pkt }
            av_packet_unref(pkt)
        }
    }

    /// Lands on the last keyframe at or before the target, or (`forward`) the first one at or after it, so
    /// repeated forward keyframe seeks always advance.
    func seek(to seconds: Double, forward: Bool = false) {
        guard let ctx else { return }
        let ts = Int64(seconds * Double(AV_TIME_BASE))
        let tSeek = Date()
        if let f = fragmented, reopenSpliced(at: f.keyframeFragment(for: seconds, forward: forward)) {
            // done: positioned at the keyframe fragment
        } else if !forward || avformat_seek_file(ctx, -1, ts, ts, Int64.max, 0) < 0 {
            avformat_seek_file(ctx, -1, Int64.min, ts, ts, 0)
        }
        if ProcessInfo.processInfo.environment["LP_OPEN_DEBUG"] != nil { NSLog("open: seek to %.0f s took %.0f ms", seconds, Date().timeIntervalSince(tSeek) * 1000) }
        swVideo?.flush(); hwVideo?.flush(); swAudio?.flush(); swSubtitle?.flush()
    }

    private func softwareVideo(_ notice: String) {
        guard let d = SWVideoDecoder(par: stream(videoIndex).pointee.codecpar) else {
            warnings.append("Video codec \(videoCodecName) can't be decoded; playing audio only.")
            videoIndex = -1
            return
        }
        swVideo = d
        notices.append(notice + " (\(d.decoderName))")
        var fd: CMFormatDescription?
        CMFormatDescriptionCreate(allocator: nil, mediaType: kCMMediaType_Video, mediaSubType: 0x73776463 /* swdc */, extensions: nil, formatDescriptionOut: &fd)
        videoFormat = fd
    }

    // MARK: Format descriptions

    private func needsProbe(_ c: UnsafeMutablePointer<AVFormatContext>) -> Bool {
        for i in 0..<Int(c.pointee.nb_streams) {
            let p = c.pointee.streams[i]!.pointee.codecpar!.pointee
            if p.codec_type == AVMEDIA_TYPE_VIDEO && (p.width == 0 || (p.extradata_size == 0 && (p.codec_id == AV_CODEC_ID_H264 || p.codec_id == AV_CODEC_ID_HEVC))) { return true }
            if p.codec_type == AVMEDIA_TYPE_AUDIO && (p.sample_rate == 0) { return true }
        }
        return c.pointee.nb_streams == 0
    }

    private func buildVideoFormat() {
        let par = stream(videoIndex).pointee.codecpar!.pointee
        videoCodecName = String(cString: avcodec_get_name(par.codec_id))
        let extradata = par.extradata_size > 0 ? Data(bytes: par.extradata, count: Int(par.extradata_size)) : Data()
        var ext: [CFString: Any] = colorExtensions(par)
        var codecType: CMVideoCodecType
        var atoms: [String: Data] = [:]

        switch par.codec_id {
        case AV_CODEC_ID_H264:
            codecType = kCMVideoCodecType_H264
            // Prefer building from the SPS/PPS so CoreMedia parses VUI colour info (HDR flags etc.).
            if extradata.first == 1, let fd = ParamSets.formatDescription(fromConfig: extradata, hevc: false, extensions: ext) { videoFormat = fd; return }
            if extradata.first == 1 { atoms["avcC"] = extradata }
            else { videoNeedsAnnexBConversion = true; videoFormat = parameterSetFormat(extradata, hevc: false, ext: ext); return }
        case AV_CODEC_ID_HEVC:
            codecType = kCMVideoCodecType_HEVC
            if extradata.count > 22 && extradata.first == 1, let fd = ParamSets.formatDescription(fromConfig: extradata, hevc: true, extensions: ext) { videoFormat = fd; return }
            if extradata.count > 22 && extradata.first == 1 { atoms["hvcC"] = extradata }
            else { videoNeedsAnnexBConversion = true; videoFormat = parameterSetFormat(extradata, hevc: true, ext: ext); return }
        case AV_CODEC_ID_VP9:
            codecType = kCMVideoCodecType_VP9
            VTRegisterSupplementalVideoDecoderIfAvailable(codecType)
            if !VTIsHardwareDecodeSupported(codecType) { softwareVideo("VP9 is decoded in software on this Mac"); return }
            atoms["vpcC"] = makeVPCC(par)
        case AV_CODEC_ID_AV1:
            codecType = kCMVideoCodecType_AV1
            VTRegisterSupplementalVideoDecoderIfAvailable(codecType)
            if !VTIsHardwareDecodeSupported(codecType) { softwareVideo("AV1 is decoded in software (hardware AV1 needs M3 or newer)"); return }
            if !extradata.isEmpty { atoms["av1C"] = extradata }
        case AV_CODEC_ID_PRORES:
            codecType = par.codec_tag != 0 ? par.codec_tag.bigEndianFourCC : kCMVideoCodecType_AppleProRes422
        case AV_CODEC_ID_MPEG2VIDEO:
            codecType = kCMVideoCodecType_MPEG2Video
        case AV_CODEC_ID_MPEG4:
            codecType = kCMVideoCodecType_MPEG4Video
            if !extradata.isEmpty { atoms["esds"] = makeESDS(objectType: 0x20, streamType: 0x11, dsi: extradata) }
        default:
            softwareVideo("\(videoCodecName) is decoded in software")
            return
        }
        if !atoms.isEmpty { ext[kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms] = atoms }
        var fd: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreate(allocator: nil, codecType: codecType, width: par.width, height: par.height,
                                       extensions: ext as CFDictionary, formatDescriptionOut: &fd)
        videoFormat = fd
    }

    /// Build a format description from Annex-B parameter sets (MPEG-TS style extradata).
    private func parameterSetFormat(_ annexB: Data, hevc: Bool, ext: [CFString: Any]) -> CMVideoFormatDescription? {
        let nalus = AnnexB.split(annexB)
        let wanted: Set<UInt8> = hevc ? [32, 33, 34] : [7, 8]
        let sets = nalus.filter { n in
            guard let f = n.first else { return false }
            return wanted.contains(hevc ? (f >> 1) & 0x3f : f & 0x1f)
        }
        guard !sets.isEmpty else { return nil }
        var fd: CMFormatDescription?
        let ptrs = sets.map { d -> UnsafePointer<UInt8> in
            let p = UnsafeMutablePointer<UInt8>.allocate(capacity: d.count); d.copyBytes(to: p, count: d.count); return UnsafePointer(p)
        }
        defer { ptrs.forEach { UnsafeMutablePointer(mutating: $0).deallocate() } }
        let sizes = sets.map { $0.count }
        if hevc {
            CMVideoFormatDescriptionCreateFromHEVCParameterSets(allocator: nil, parameterSetCount: sets.count, parameterSetPointers: ptrs, parameterSetSizes: sizes, nalUnitHeaderLength: 4, extensions: ext as CFDictionary, formatDescriptionOut: &fd)
        } else {
            CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: nil, parameterSetCount: sets.count, parameterSetPointers: ptrs, parameterSetSizes: sizes, nalUnitHeaderLength: 4, formatDescriptionOut: &fd)
        }
        return fd
    }

    private func buildAudioFormat() {
        let par = stream(audioIndex).pointee.codecpar!.pointee
        audioCodecName = String(cString: avcodec_get_name(par.codec_id))
        let extradata = par.extradata_size > 0 ? Data(bytes: par.extradata, count: Int(par.extradata_size)) : Data()
        var asbd = AudioStreamBasicDescription()
        asbd.mSampleRate = Float64(par.sample_rate)
        asbd.mChannelsPerFrame = UInt32(par.ch_layout.nb_channels)
        var cookie: Data?
        switch par.codec_id {
        case AV_CODEC_ID_AAC:
            asbd.mFormatID = par.profile == 4 /* HE-AAC */ ? kAudioFormatMPEG4AAC_HE : kAudioFormatMPEG4AAC
            asbd.mFramesPerPacket = 1024
            if !extradata.isEmpty { cookie = makeESDS(objectType: 0x40, streamType: 0x15, dsi: extradata) }
        case AV_CODEC_ID_AC3: asbd.mFormatID = kAudioFormatAC3; asbd.mFramesPerPacket = 1536
        case AV_CODEC_ID_EAC3: asbd.mFormatID = kAudioFormatEnhancedAC3; asbd.mFramesPerPacket = 1536
        case AV_CODEC_ID_MP3: asbd.mFormatID = kAudioFormatMPEGLayer3; asbd.mFramesPerPacket = 1152
        case AV_CODEC_ID_MP2: asbd.mFormatID = kAudioFormatMPEGLayer2; asbd.mFramesPerPacket = 1152
        case AV_CODEC_ID_ALAC: asbd.mFormatID = kAudioFormatAppleLossless; asbd.mFramesPerPacket = 4096; cookie = extradata
        case AV_CODEC_ID_FLAC:
            asbd.mFormatID = kAudioFormatFLAC
            // 'dfLa' payload: version/flags + STREAMINFO metadata block marked as last.
            var d = Data([0, 0, 0, 0, 0x80, 0, 0, 34])
            d.append(extradata.count >= 34 ? extradata.suffix(34) : extradata)
            cookie = d
        case AV_CODEC_ID_OPUS:
            asbd.mFormatID = kAudioFormatOpus; asbd.mFramesPerPacket = 960
            asbd.mSampleRate = 48000
            cookie = extradata
        case AV_CODEC_ID_PCM_S16LE, AV_CODEC_ID_PCM_S24LE, AV_CODEC_ID_PCM_S32LE, AV_CODEC_ID_PCM_F32LE, AV_CODEC_ID_PCM_S16BE, AV_CODEC_ID_PCM_S24BE:
            let bits: UInt32 = [AV_CODEC_ID_PCM_S16LE, AV_CODEC_ID_PCM_S16BE].contains(par.codec_id) ? 16 :
                               [AV_CODEC_ID_PCM_S24LE, AV_CODEC_ID_PCM_S24BE].contains(par.codec_id) ? 24 : 32
            asbd.mFormatID = kAudioFormatLinearPCM
            asbd.mFormatFlags = (par.codec_id == AV_CODEC_ID_PCM_F32LE ? kAudioFormatFlagIsFloat : kAudioFormatFlagIsSignedInteger) | kAudioFormatFlagIsPacked
            if [AV_CODEC_ID_PCM_S16BE, AV_CODEC_ID_PCM_S24BE].contains(par.codec_id) { asbd.mFormatFlags |= kAudioFormatFlagIsBigEndian }
            asbd.mBitsPerChannel = bits
            asbd.mBytesPerFrame = bits / 8 * asbd.mChannelsPerFrame
            asbd.mFramesPerPacket = 1
            asbd.mBytesPerPacket = asbd.mBytesPerFrame
        default:
            // DTS, TrueHD, Vorbis, WMA, …: decode with libavcodec to Float32 PCM.
            let coreOnly = Settings.shared.dtsCoreOnly
            guard let d = SWAudioDecoder(par: stream(audioIndex).pointee.codecpar, coreOnly: coreOnly) else {
                warnings.append("Audio codec \(audioCodecName) can't be decoded — playing without sound.")
                audioIndex = -1
                return
            }
            swAudio = d
            let profile = par.profile
            let hd = par.codec_id == AV_CODEC_ID_DTS && profile >= 0 && (avcodec_profile_name(par.codec_id, profile).map { String(cString: $0) } ?? "").contains("HD")
            notices.append("\(audioCodecName.uppercased()) audio decoded in software" + (hd && coreOnly ? " (DTS core)" : ""))
            var fd: CMFormatDescription?
            CMFormatDescriptionCreate(allocator: nil, mediaType: kCMMediaType_Audio, mediaSubType: 0x73776463, extensions: nil, formatDescriptionOut: &fd)
            audioFormat = fd
            return
        }
        audioFramesPerPacket = asbd.mFramesPerPacket
        var layout = AudioChannelLayout()
        layout.mChannelLayoutTag = channelLayoutTag(Int(asbd.mChannelsPerFrame))
        var fd: CMAudioFormatDescription?
        let status: OSStatus = cookie.map { c in
            c.withUnsafeBytes { raw in
                CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: MemoryLayout<AudioChannelLayout>.size, layout: &layout, magicCookieSize: c.count, magicCookie: raw.baseAddress, extensions: nil, formatDescriptionOut: &fd)
            }
        } ?? CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: MemoryLayout<AudioChannelLayout>.size, layout: &layout, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &fd)
        if status != noErr { warnings.append("Could not describe audio (\(audioCodecName)): \(status)"); audioIndex = -1 }
        audioFormat = fd
    }

    private func channelLayoutTag(_ ch: Int) -> AudioChannelLayoutTag {
        switch ch {
        case 1: kAudioChannelLayoutTag_Mono
        case 2: kAudioChannelLayoutTag_Stereo
        case 6: kAudioChannelLayoutTag_MPEG_5_1_A
        case 8: kAudioChannelLayoutTag_MPEG_7_1_C
        default: kAudioChannelLayoutTag_DiscreteInOrder | AudioChannelLayoutTag(ch)
        }
    }

    // MARK: Sample buffers

    /// Pooled allocator for sample payloads: freed blocks are recycled, then returned to the OS
    /// after ~0.5 s idle, so the malloc heap doesn't keep a fragmented high-water mark of packet data.
    private let memoryPool = CMMemoryPoolCreate(options: nil)

    /// Converts a packet to a CMSampleBuffer (payload copied into pooled memory) and frees the packet.
    func makeSampleBuffer(_ pkt: UnsafeMutablePointer<AVPacket>) -> CMSampleBuffer? {
        defer { var p: UnsafeMutablePointer<AVPacket>? = pkt; av_packet_free(&p) }
        let si = pkt.pointee.stream_index
        let isVideo = si == videoIndex
        guard let fmt: CMFormatDescription = isVideo ? videoFormat : audioFormat, pkt.pointee.size > 0 else { return nil }
        let tb = stream(si).pointee.time_base
        let src = UnsafeBufferPointer(start: pkt.pointee.data, count: Int(pkt.pointee.size))
        let converted: Data? = (isVideo && videoNeedsAnnexBConversion) ? AnnexB.toLengthPrefixed(src) : nil
        let size = converted?.count ?? src.count

        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: size, blockAllocator: CMMemoryPoolGetAllocator(memoryPool),
                                                 customBlockSource: nil, offsetToData: 0, dataLength: size, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block) == noErr,
              let block else { return nil }
        if let converted {
            converted.withUnsafeBytes { _ = CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: size) }
        } else {
            CMBlockBufferReplaceDataBytes(with: src.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: size)
        }

        var pts = time(pkt.pointee.pts, tb)
        var dts = time(pkt.pointee.dts, tb)
        var dur = pkt.pointee.duration > 0 ? time(pkt.pointee.duration, tb) : .invalid
        if isVideo, let grid = videoGrid {
            // Shift DTS by the same correction as PTS only when it snaps cleanly; otherwise keep the original
            // so decode order stays monotonic for B-frame streams.
            pts = grid.snap(pts)
            // Without stream probing, coarse-clock containers (Matroska) don't give real decode timestamps for
            // B-frame streams (dts == pts, out of order). Decoding happens in enqueue order anyway.
            dts = .invalid
            dur = CMTime(value: grid.den, timescale: CMTimeScale(clamping: grid.num))
        }
        var sb: CMSampleBuffer?
        if isVideo {
            var timing = CMSampleTimingInfo(duration: dur, presentationTimeStamp: pts.isValid ? pts : dts, decodeTimeStamp: dts)
            var sz = size
            CMSampleBufferCreateReady(allocator: nil, dataBuffer: block, formatDescription: fmt, sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1, sampleSizeArray: &sz, sampleBufferOut: &sb)
            if let sb, pkt.pointee.flags & AV_PKT_FLAG_KEY == 0 {
                sb.setAttachment(kCMSampleAttachmentKey_NotSync, true)
            }
        } else {
            let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fmt)!.pointee
            if asbd.mFormatID == kAudioFormatLinearPCM {
                let frames = size / Int(max(asbd.mBytesPerFrame, 1))
                CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: nil, dataBuffer: block, formatDescription: fmt, sampleCount: frames, presentationTimeStamp: pts.isValid ? pts : dts, packetDescriptions: nil, sampleBufferOut: &sb)
            } else {
                var desc = AudioStreamPacketDescription(mStartOffset: 0, mVariableFramesInPacket: 0, mDataByteSize: UInt32(size))
                CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: nil, dataBuffer: block, formatDescription: fmt, sampleCount: 1, presentationTimeStamp: pts.isValid ? pts : dts, packetDescriptions: &desc, sampleBufferOut: &sb)
            }
        }
        return sb
    }

    enum Item { case video(CMSampleBuffer), audio(CMSampleBuffer), subtitle(SubtitleCue), bitmaps(start: Double, end: Double?, [SubtitleBitmap]) }

    /// Reads and converts the next packet; nil at EOF.
    func readItem() -> Item? {
        while let pkt = readPacket() {
            let si = pkt.pointee.stream_index
            if si == subtitleIndex {
                defer { var p: UnsafeMutablePointer<AVPacket>? = pkt; av_packet_free(&p) }
                let tb = av_q2d(stream(si).pointee.time_base)
                let start = Double(pkt.pointee.pts == lp_av_nopts() ? pkt.pointee.dts : pkt.pointee.pts) * tb
                if let sw = swSubtitle {
                    if let (s, e, bmps) = sw.decode(pkt, start: start) { return .bitmaps(start: s, end: e, bmps) }
                    continue
                }
                let dur = pkt.pointee.duration > 0 ? Double(pkt.pointee.duration) * tb : 4
                let codec = String(cString: avcodec_get_name(stream(si).pointee.codecpar.pointee.codec_id))
                let text = SubtitleText.fromPacket(codec: codec, data: Data(bytes: pkt.pointee.data, count: Int(pkt.pointee.size)))
                if !text.isEmpty { return .subtitle(SubtitleCue(start: start, end: start + dur, text: text)) }
                continue
            }
            let isVideo = si == videoIndex
            if let sb = makeSampleBuffer(pkt) { return isVideo ? .video(sb) : .audio(sb) }
        }
        return nil
    }

    /// Exact constant frame-rate grid for the video stream (e.g. 24000/1001). Matroska stores timestamps rounded to
    /// 1 ms, so a 41.708 ms frame lands at 41 or 42 ms; on a 60 Hz display that flips frames between vsyncs and turns the
    /// steady 3:2 cadence into visible judder. Timestamps within 2 ms of the grid are snapped onto it.
    /// Rebuilds the in-app decoder when the HDR setting changes for HDR content. Returns true if it changed
    /// (the caller then re-seeks so decoding restarts at a keyframe).
    func setToneMapToSDR(_ sdr: Bool) -> Bool {
        guard let hw = hwVideo, let fd = videoFormat, FFDemuxer.isHDR(fd), hw.toneMapToSDR != sdr,
              let fresh = HWVideoDecoder(format: fd, toneMapToSDR: sdr) else { return false }
        hwVideo = fresh
        return true
    }

    /// Duration from the container header only (no stream probing, no decoding) — for history entries.
    static func headerDuration(path: String) -> Double? {
        if let f = FragmentedMP4(path: path) { return f.duration }
        var c: UnsafeMutablePointer<AVFormatContext>?
        guard avformat_open_input(&c, path, nil, nil) >= 0, let ctx = c else { return nil }
        defer { avformat_close_input(&c) }
        if ctx.pointee.duration > 0 { return Double(ctx.pointee.duration) / Double(AV_TIME_BASE) }
        var best = 0.0
        for i in 0..<Int(ctx.pointee.nb_streams) {
            let st = ctx.pointee.streams[i]!.pointee
            if st.duration > 0 { best = max(best, Double(st.duration) * av_q2d(st.time_base)) }
        }
        return best > 0 ? best : nil
    }

    /// "Dolby Vision" / "HDR10" / "HLG" for the video stream (nil = SDR).
    var hdrFormatName: String? {
        guard videoIndex >= 0 else { return nil }
        let p = stream(videoIndex).pointee.codecpar.pointee
        for i in 0..<Int(p.nb_coded_side_data) where p.coded_side_data[i].type == AV_PKT_DATA_DOVI_CONF { return "Dolby Vision" }
        switch p.color_trc {
        case AVCOL_TRC_SMPTE2084: return "HDR10"
        case AVCOL_TRC_ARIB_STD_B67: return "HLG"
        default:
            // Without stream probing the container may not carry colour info; the format description built from
            // the bitstream's own VUI (hvcC/avcC) does.
            let tf = videoFormat.flatMap { CMFormatDescriptionGetExtension($0, extensionKey: kCMFormatDescriptionExtension_TransferFunction) as? String }
            if tf == (kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ as String) { return "HDR10" }
            if tf == (kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG as String) { return "HLG" }
            return nil
        }
    }

    /// Decoder in use for the video stream.
    var videoDecoding: VideoDecodingInfo? {
        guard videoIndex >= 0 else { return nil }
        let codec = videoCodecName.uppercased()
        if let sw = swVideo { return VideoDecodingInfo(hardware: false, detail: "\(codec) · software (\(sw.decoderName), \(sw.threads) threads)") }
        return VideoDecodingInfo(hardware: true, detail: "\(codec) · hardware (VideoToolbox media engine)")
    }

    static func isHDR(_ fd: CMFormatDescription) -> Bool {
        let tf = CMFormatDescriptionGetExtension(fd, extensionKey: kCMFormatDescriptionExtension_TransferFunction) as? String
        return tf == (kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ as String) || tf == (kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG as String)
    }

    struct FrameGrid {
        let num: Int64, den: Int64      // frames per second = num / den
        let base: Double                // stream start, seconds
        func snap(_ t: CMTime) -> CMTime {
            guard t.isValid else { return t }
            let s = t.seconds - base
            let idx = (s * Double(num) / Double(den)).rounded()
            let snapped = idx * Double(den) / Double(num)
            guard abs(snapped - s) < 0.002 else { return t }    // VFR content / discontinuity: leave alone
            // Express exactly in a frame-rate timescale (no rounding), offset by the stream start.
            let baseTime = CMTime(seconds: base, preferredTimescale: CMTimeScale(clamping: num))
            return CMTime(value: Int64(idx) * den, timescale: CMTimeScale(clamping: num)) + baseTime
        }
    }
    /// Exact frame rate and stream start for display sync (nil for variable / unknown rates).
    var frameRateInfo: (fps: Double, base: Double)? {
        if let g = videoGrid { return (Double(g.num) / Double(g.den), g.base) }
        guard videoIndex >= 0 else { return nil }
        let st = stream(videoIndex).pointee
        let fr = st.r_frame_rate
        guard fr.num > 0, fr.den > 0, av_q2d(fr) > 5, av_q2d(fr) < 241 else { return nil }
        let start = st.start_time != lp_av_nopts() ? Double(st.start_time) * av_q2d(st.time_base) : 0
        return (av_q2d(fr), start)
    }

    private lazy var videoGrid: FrameGrid? = {
        guard videoIndex >= 0 else { return nil }
        let st = stream(videoIndex).pointee
        let tb = st.time_base
        // Only needed when the container clock is coarser than ~0.1 ms (Matroska/WebM, FLV, some AVI).
        guard tb.den > 0, Double(tb.num) / Double(tb.den) >= 0.0001 else { return nil }
        // Prefer the nominal rate (exact, e.g. 25/1 or 24000/1001) when it agrees with the measured average.
        var fr = st.r_frame_rate
        let avg = st.avg_frame_rate
        if fr.num <= 0 || fr.den <= 0 || (avg.num > 0 && avg.den > 0 && abs(av_q2d(avg) - av_q2d(fr)) / av_q2d(fr) > 0.005) { fr = avg }
        guard fr.num > 0, fr.den > 0, av_q2d(fr) > 5, av_q2d(fr) < 241 else { return nil }
        // Encoders sometimes write e.g. 29999/1200 (24.9992) for 25 fps: use the exact standard rate when within 0.01%.
        let standard: [(Int32, Int32)] = [(24000, 1001), (24, 1), (25, 1), (30000, 1001), (30, 1), (48, 1), (50, 1), (60000, 1001), (60, 1), (100, 1), (120000, 1001), (120, 1)]
        if let std = standard.first(where: { abs(Double($0.0) / Double($0.1) - av_q2d(fr)) / av_q2d(fr) < 0.0001 }) {
            fr = AVRational(num: std.0, den: std.1)
        }
        let start = st.start_time != lp_av_nopts() ? Double(st.start_time) * av_q2d(tb) : 0
        return FrameGrid(num: Int64(fr.num), den: Int64(fr.den), base: start)
    }()

    private func time(_ v: Int64, _ tb: AVRational) -> CMTime {
        guard v != lp_av_nopts() else { return .invalid }
        // Rescale to a fixed fine timescale to avoid overflow with odd time bases.
        return CMTime(value: av_rescale_q(v, tb, AVRational(num: 1, den: 90000)), timescale: 90000)
    }

    // MARK: Helpers

    private func colorExtensions(_ par: AVCodecParameters) -> [CFString: Any] {
        var e: [CFString: Any] = [:]
        switch par.color_primaries {
        case AVCOL_PRI_BT709: e[kCMFormatDescriptionExtension_ColorPrimaries] = kCMFormatDescriptionColorPrimaries_ITU_R_709_2
        case AVCOL_PRI_BT2020: e[kCMFormatDescriptionExtension_ColorPrimaries] = kCMFormatDescriptionColorPrimaries_ITU_R_2020
        case AVCOL_PRI_SMPTE170M, AVCOL_PRI_SMPTE240M: e[kCMFormatDescriptionExtension_ColorPrimaries] = kCMFormatDescriptionColorPrimaries_SMPTE_C
        case AVCOL_PRI_BT470BG: e[kCMFormatDescriptionExtension_ColorPrimaries] = kCMFormatDescriptionColorPrimaries_EBU_3213
        case AVCOL_PRI_SMPTE432: e[kCMFormatDescriptionExtension_ColorPrimaries] = kCMFormatDescriptionColorPrimaries_P3_D65
        default: break
        }
        switch par.color_trc {
        case AVCOL_TRC_BT709, AVCOL_TRC_SMPTE170M, AVCOL_TRC_BT2020_10, AVCOL_TRC_BT2020_12: e[kCMFormatDescriptionExtension_TransferFunction] = kCMFormatDescriptionTransferFunction_ITU_R_709_2
        case AVCOL_TRC_SMPTE2084: e[kCMFormatDescriptionExtension_TransferFunction] = kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ
        case AVCOL_TRC_ARIB_STD_B67: e[kCMFormatDescriptionExtension_TransferFunction] = kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG
        case AVCOL_TRC_IEC61966_2_1: e[kCMFormatDescriptionExtension_TransferFunction] = kCMFormatDescriptionTransferFunction_sRGB
        default: break
        }
        switch par.color_space {
        case AVCOL_SPC_BT709: e[kCMFormatDescriptionExtension_YCbCrMatrix] = kCMFormatDescriptionYCbCrMatrix_ITU_R_709_2
        case AVCOL_SPC_BT2020_NCL, AVCOL_SPC_BT2020_CL: e[kCMFormatDescriptionExtension_YCbCrMatrix] = kCMFormatDescriptionYCbCrMatrix_ITU_R_2020
        case AVCOL_SPC_SMPTE170M, AVCOL_SPC_BT470BG: e[kCMFormatDescriptionExtension_YCbCrMatrix] = kCMFormatDescriptionYCbCrMatrix_ITU_R_601_4
        default: break
        }
        if par.color_range == AVCOL_RANGE_JPEG { e[kCMFormatDescriptionExtension_FullRangeVideo] = true }
        // HDR10 static metadata, in the big-endian layouts CoreMedia expects (mdcv / clli box payloads).
        for i in 0..<Int(par.nb_coded_side_data) {
            let sd = par.coded_side_data[i]
            if sd.type == AV_PKT_DATA_MASTERING_DISPLAY_METADATA {
                let m = UnsafeRawPointer(sd.data).assumingMemoryBound(to: AVMasteringDisplayMetadata.self).pointee
                guard m.has_primaries != 0, m.has_luminance != 0 else { continue }
                var d = Data()
                func u16(_ r: AVRational, _ scale: Double) { let v = UInt16(clamping: Int(av_q2d(r) * scale + 0.5)); d.append(UInt8(v >> 8)); d.append(UInt8(v & 0xff)) }
                func u32(_ r: AVRational, _ scale: Double) { let v = UInt32(clamping: Int(av_q2d(r) * scale + 0.5)); withUnsafeBytes(of: v.bigEndian) { d.append(contentsOf: $0) } }
                // mdcv order: G, B, R primaries
                let p = m.display_primaries
                for c in [p.1, p.2, p.0] { u16(c.0, 50000); u16(c.1, 50000) }
                u16(m.white_point.0, 50000); u16(m.white_point.1, 50000)
                u32(m.max_luminance, 10000); u32(m.min_luminance, 10000)
                e[kCMFormatDescriptionExtension_MasteringDisplayColorVolume] = d
            } else if sd.type == AV_PKT_DATA_CONTENT_LIGHT_LEVEL {
                let cll = UnsafeRawPointer(sd.data).assumingMemoryBound(to: UInt32.self) // MaxCLL, MaxFALL (unsigned ints)
                let maxCLL = UInt16(clamping: cll[0]), maxFALL = UInt16(clamping: cll[1])
                e[kCMFormatDescriptionExtension_ContentLightLevelInfo] = Data([UInt8(maxCLL >> 8), UInt8(maxCLL & 0xff), UInt8(maxFALL >> 8), UInt8(maxFALL & 0xff)])
            }
        }
        return e
    }

    private func makeVPCC(_ par: AVCodecParameters) -> Data {
        let bitDepth: UInt8 = (par.format == AV_PIX_FMT_YUV420P10LE.rawValue || par.format == AV_PIX_FMT_YUV420P10BE.rawValue) ? 10 : 8
        let chroma: UInt8 = 1 // 4:2:0 colocated with luma
        let full: UInt8 = par.color_range == AVCOL_RANGE_JPEG ? 1 : 0
        return Data([1, 0, 0, 0, UInt8(max(par.profile, 0)), UInt8(max(par.level, 0) & 0xff),
                     (bitDepth << 4) | (chroma << 1) | full,
                     UInt8(par.color_primaries.rawValue), UInt8(par.color_trc.rawValue), UInt8(par.color_space.rawValue), 0, 0])
    }

    /// MPEG-4 ES_Descriptor (the 'esds' payload) wrapping a DecoderSpecificInfo.
    private func makeESDS(objectType: UInt8, streamType: UInt8, dsi: Data) -> Data {
        func desc(_ tag: UInt8, _ body: Data) -> Data {
            var d = Data([tag]); let n = body.count
            d.append(contentsOf: [UInt8(0x80 | ((n >> 21) & 0x7f)), UInt8(0x80 | ((n >> 14) & 0x7f)), UInt8(0x80 | ((n >> 7) & 0x7f)), UInt8(n & 0x7f)])
            d.append(body); return d
        }
        var dcd = Data([objectType, (streamType << 2) | 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0])
        dcd.append(desc(0x05, dsi))
        var es = Data([0, 0, 0])
        es.append(desc(0x04, dcd))
        es.append(desc(0x06, Data([0x02])))
        var out = Data([0, 0, 0, 0]) // version + flags
        out.append(desc(0x03, es))
        return out
    }
}

/// Virtual file for a spliced fragmented MP4: file[0..<headerEnd] followed by file[fragment...].
final class SpliceBox {
    let f: FragmentedMP4
    let offset: Int64
    var position: Int64 = 0
    var length: Int64 { f.headerEnd + (f.length - offset) }
    init(_ f: FragmentedMP4, offset: Int64) { self.f = f; self.offset = offset }
    func read(_ buf: UnsafeMutablePointer<UInt8>, _ size: Int) -> Int {
        guard position < length else { return 0 }
        var done = 0
        while done < size, position < length {
            let (fileOff, avail) = position < f.headerEnd ? (position, f.headerEnd - position)
                                                          : (offset + position - f.headerEnd, length - position)
            let n = Darwin.pread(f.fd, buf + done, min(size - done, Int(avail)), fileOff)
            if n <= 0 { return done > 0 ? done : (n == 0 ? 0 : -1) }
            done += n; position += Int64(n)
        }
        return done
    }
    func seek(_ off: Int64, _ whence: Int32) -> Int64 {
        switch whence & ~AVSEEK_FORCE {
        case AVSEEK_SIZE: return length
        case SEEK_SET: position = off
        case SEEK_CUR: position += off
        case SEEK_END: position = length + off
        default: return -1
        }
        return position
    }
}

/// State shared with libavformat's custom I/O callbacks.
final class IOBox {
    let source: CachedHTTPSource
    var position: Int64 = 0
    init(_ s: CachedHTTPSource) { source = s }
}

enum FFError: Error, CustomStringConvertible {
    case open(Int32)
    var description: String {
        switch self {
        case .open(let r):
            var buf = [CChar](repeating: 0, count: 256)
            av_strerror(r, &buf, 256)
            return "open failed: \(String(cString: buf))"
        }
    }
}

enum AnnexB {
    /// Splits an Annex-B byte stream into NAL units (without start codes).
    static func split(_ data: Data) -> [Data] {
        data.withUnsafeBytes { raw in split(UnsafeBufferPointer(start: raw.bindMemory(to: UInt8.self).baseAddress, count: raw.count)).map { Data($0) } }
    }
    static func split(_ b: UnsafeBufferPointer<UInt8>) -> [UnsafeBufferPointer<UInt8>] {
        var out: [UnsafeBufferPointer<UInt8>] = []
        let n = b.count
        var i = 0, start = -1
        while i + 2 < n {
            if b[i] == 0 && b[i + 1] == 0 && b[i + 2] == 1 {
                if start >= 0 {
                    var end = i
                    while end > start && b[end - 1] == 0 { end -= 1 }
                    out.append(UnsafeBufferPointer(rebasing: b[start..<end]))
                }
                i += 3; start = i
            } else { i += 1 }
        }
        if start >= 0 && start < n { out.append(UnsafeBufferPointer(rebasing: b[start..<n])) }
        return out
    }
    static func toLengthPrefixed(_ b: UnsafeBufferPointer<UInt8>) -> Data {
        var out = Data(capacity: b.count + 16)
        for nal in split(b) {
            withUnsafeBytes(of: UInt32(nal.count).bigEndian) { out.append(contentsOf: $0) }
            out.append(contentsOf: nal)
        }
        return out
    }
}

extension UInt32 {
    /// libavformat stores codec tags little-endian ('apch' => 0x68637061); CoreMedia wants big-endian FourCC.
    var bigEndianFourCC: FourCharCode { byteSwapped }
}

extension CMSampleBuffer {
    func setAttachment(_ key: CFString, _ value: Bool) {
        guard let atts = CMSampleBufferGetSampleAttachmentsArray(self, createIfNecessary: true) as? [NSMutableDictionary] else { return }
        for a in atts { a[key] = value }
    }
}

/// Parameter-set helpers for avcC / hvcC decoder configuration records.
enum ParamSets {
    /// Splits an avcC/hvcC record into (NAL length size, parameter-set NAL units).
    static func extract(_ cfg: Data, hevc: Bool) -> (Int, [Data])? {
        let b = [UInt8](cfg)
        var sets: [Data] = []
        if hevc {
            guard b.count > 23 else { return nil }
            let lenSize = Int(b[21] & 3) + 1
            var p = 23
            for _ in 0..<Int(b[22]) {
                guard p + 3 <= b.count else { return nil }
                let n = Int(b[p + 1]) << 8 | Int(b[p + 2]); p += 3
                for _ in 0..<n {
                    guard p + 2 <= b.count else { return nil }
                    let l = Int(b[p]) << 8 | Int(b[p + 1]); p += 2
                    guard p + l <= b.count else { return nil }
                    sets.append(Data(b[p..<(p + l)])); p += l
                }
            }
            return (lenSize, sets)
        } else {
            guard b.count > 6 else { return nil }
            let lenSize = Int(b[4] & 3) + 1
            var p = 5
            for group in 0..<2 {
                guard p < b.count else { break }
                let n = group == 0 ? Int(b[p] & 0x1f) : Int(b[p]); p += 1
                for _ in 0..<n {
                    guard p + 2 <= b.count else { return nil }
                    let l = Int(b[p]) << 8 | Int(b[p + 1]); p += 2
                    guard p + l <= b.count else { return nil }
                    sets.append(Data(b[p..<(p + l)])); p += l
                }
            }
            return (lenSize, sets)
        }
    }

    /// Format description built by CoreMedia from the parameter sets (it parses VUI colour / HDR info).
    /// Container-level extensions (Matroska Colour, mastering metadata) are merged on top.
    static func formatDescription(fromConfig cfg: Data, hevc: Bool, extensions: [CFString: Any]) -> CMVideoFormatDescription? {
        guard let (lenSize, sets) = extract(cfg, hevc: hevc), !sets.isEmpty else { return nil }
        let ptrs = sets.map { d -> UnsafePointer<UInt8> in
            let p = UnsafeMutablePointer<UInt8>.allocate(capacity: d.count); d.copyBytes(to: p, count: d.count); return UnsafePointer(p)
        }
        defer { ptrs.forEach { UnsafeMutablePointer(mutating: $0).deallocate() } }
        var fd: CMFormatDescription?
        let st: OSStatus
        if hevc {
            st = CMVideoFormatDescriptionCreateFromHEVCParameterSets(allocator: nil, parameterSetCount: sets.count, parameterSetPointers: ptrs, parameterSetSizes: sets.map(\.count),
                                                                     nalUnitHeaderLength: Int32(lenSize), extensions: extensions.isEmpty ? nil : extensions as CFDictionary, formatDescriptionOut: &fd)
        } else {
            st = CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: nil, parameterSetCount: sets.count, parameterSetPointers: ptrs, parameterSetSizes: sets.map(\.count),
                                                                     nalUnitHeaderLength: Int32(lenSize), formatDescriptionOut: &fd)
            if st == noErr, let base = fd, !extensions.isEmpty {
                // H.264 variant has no extensions parameter: merge container colour info.
                var merged = (CMFormatDescriptionGetExtensions(base) as? [CFString: Any]) ?? [:]
                for (k, v) in extensions where merged[k] == nil { merged[k] = v }
                let dims = CMVideoFormatDescriptionGetDimensions(base)
                var out: CMFormatDescription?
                CMVideoFormatDescriptionCreate(allocator: nil, codecType: kCMVideoCodecType_H264, width: dims.width, height: dims.height, extensions: merged as CFDictionary, formatDescriptionOut: &out)
                return out ?? base
            }
        }
        return st == noErr ? fd : nil
    }

    /// Profile number and pixel format straight from the configuration record header.
    static func configInfo(_ cfg: Data, hevc: Bool, h264: Bool) -> (profile: Int32?, pixelFormat: String?) {
        let b = [UInt8](cfg)
        if hevc, b.count > 18, b[0] == 1 {
            let chroma = Int(b[16] & 3), depth = Int(b[17] & 7) + 8
            let c = ["gray", "420", "422", "444"][chroma]
            return (Int32(b[1] & 0x1f), "yuv\(c)p" + (depth > 8 ? "\(depth)" : ""))
        }
        if h264, b.count > 3, b[0] == 1 {
            var chroma = 1, depth = 8
            if [100, 110, 122, 244].contains(Int(b[1])), let (_, sets) = extract(cfg, hevc: false), sets.count > 1 {
                // High profiles append chroma/bit-depth after the PPS list.
                var p = 5
                for g in 0..<2 { let n = g == 0 ? Int(b[p] & 0x1f) : Int(b[p]); p += 1; for _ in 0..<n { p += 2 + (Int(b[p]) << 8 | Int(b[p + 1])) } }
                if p + 3 <= b.count { chroma = Int(b[p] & 3); depth = Int(b[p + 1] & 7) + 8 }
            }
            let c = ["gray", "420", "422", "444"][chroma]
            return (Int32(b[1]), "yuv\(c)p" + (depth > 8 ? "\(depth)" : ""))
        }
        return (nil, nil)
    }
}
