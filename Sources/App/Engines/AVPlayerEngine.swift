import AppKit
import AVFoundation
import AVKit
import MediaToolbox
import VideoToolbox

/// Engine A (and B when `useMediaExtensions`): AVPlayer rendering into an AVPlayerLayer.
/// In the app this is used for local MP4/MOV/M4V, where AVFoundation's own demuxer is the leanest.
final class AVPlayerEngine: NSObject, PlayerEngine {
    let kind: EngineKind
    private let player = AVPlayer()
    private let playerLayer: AVPlayerLayer
    let view: NSView
    var onEvent: ((EngineEvent) -> Void)?
    private(set) var warnings: [EngineWarning] = []
    let cues = CueStore()
    private var observers: [NSKeyValueObservation] = []
    private var endObserver: Any?
    private var asset: AVAsset?
    private var subtitleAssetTracks: [Int32: AVAssetTrack] = [:]
    private var subtitleLoad: Task<Void, Never>?
    private var _subtitleTracks: [SubtitleTrackInfo] = []
    private var _naturalSize = CGSize.zero
    private static var registeredReaders = false

    /// Extra HTTP headers for remote streams (YouTube/Twitch need yt-dlp's User-Agent etc.).
    var httpHeaders: [String: String] = [:]

    init(useMediaExtensions: Bool) {
        kind = useMediaExtensions ? .avplayerExt : .avplayer
        if useMediaExtensions && !Self.registeredReaders {
            // Opt in to installed + enabled Media Extensions: format readers (MKV, AVI, …) and
            // video decoders (AV1 / VP8 / … without hardware), e.g. from QuickLook Video.
            MTRegisterProfessionalVideoWorkflowFormatReaders()
            VTRegisterProfessionalVideoWorkflowVideoDecoders()
            Self.registeredReaders = true
        }
        playerLayer = AVPlayerLayer(player: player)
        playerLayer.videoGravity = .resizeAspect
        playerLayer.backgroundColor = NSColor.black.cgColor
        view = LayerHostView(hosted: playerLayer)
        super.init()
        player.automaticallyWaitsToMinimizeStalling = true
        player.preventsDisplaySleepDuringVideoPlayback = true
        // We choose subtitles ourselves (default off unless forced) and draw them in our own overlay.
        player.appliesMediaSelectionCriteriaAutomatically = false
    }

    var currentTime: Double { player.currentTime().seconds.finiteOrZero }
    var duration: Double { player.currentItem?.duration.seconds.finiteOrZero ?? 0 }
    var isPlaying: Bool { player.rate != 0 }
    var volume: Float {
        get { player.volume }
        set { player.volume = newValue }
    }
    var naturalSize: CGSize { _naturalSize }
    var subtitleTracks: [SubtitleTrackInfo] { _subtitleTracks }
    func appendWarning(_ message: String) { warnings.append(EngineWarning(message: message)) }

    func open(_ url: URL) {
        var options: [String: Any] = [AVURLAssetPreferPreciseDurationAndTimingKey: false]
        if !httpHeaders.isEmpty { options["AVURLAssetHTTPHeaderFieldsKey"] = httpHeaders }   // e.g. yt-dlp's headers
        openAsset(AVURLAsset(url: url, options: options), url: url)
    }

    private func openAsset(_ asset: AVAsset, url: URL) {
        self.asset = asset
        let item = AVPlayerItem(asset: asset)
        Task { @MainActor [weak self] in
            guard let self else { return }
            // AVFoundation can't decode some codecs (AV1 without hardware, DTS, ...): let engine C take over.
            if let tracks = try? await asset.load(.tracks) {
                for t in tracks where t.mediaType == .video || t.mediaType == .audio {
                    if (try? await t.load(.isDecodable)) == false { self.onEvent?(.needsFallback); return }
                }
            }
            if let v = try? await asset.loadTracks(withMediaType: .video).first,
               let (size, t) = try? await v.load(.naturalSize, .preferredTransform) {
                let r = CGRect(origin: .zero, size: size).applying(t)
                self._naturalSize = CGSize(width: abs(r.width), height: abs(r.height))
            }
            // Text subtitle tracks are read by us (AVAssetReader) and drawn in our overlay.
            let hints = url.isFileURL ? MP4SubtitleInfo.hints(for: url) : [:]
            var subs: [SubtitleTrackInfo] = []
            let subTracks = ((try? await asset.loadTracks(withMediaType: .subtitle)) ?? []) + ((try? await asset.loadTracks(withMediaType: .text)) ?? [])
            for t in subTracks {
                let fd = (try? await t.load(.formatDescriptions))?.first
                let subtype = fd.map { CMFormatDescriptionGetMediaSubType($0) } ?? 0
                // Apple-authored forced tracks: tx3g display flags 0x80000000 (all samples forced).
                let flags = (fd.flatMap { CMFormatDescriptionGetExtension($0, extensionKey: kCMTextFormatDescriptionExtension_DisplayFlags) } as? NSNumber)?.uint32Value ?? 0
                let hint = hints[t.trackID] ?? .init()
                var lang = try? await t.load(.extendedLanguageTag)
                if lang == nil { lang = try? await t.load(.languageCode) }
                let title = hint.name ?? ""
                subs.append(SubtitleTrackInfo(id: Int(t.trackID), title: title, language: lang, codec: subtype.fourCCString,
                                              isForced: hint.forced || flags & 0x8000_0000 != 0 || title.localizedCaseInsensitiveContains("forced"),
                                              isDefault: hint.isDefault, kind: .text, externalURL: nil))
                self.subtitleAssetTracks[t.trackID] = t
            }
            self._subtitleTracks = subs
            self.isHDRVideo = !((try? await asset.loadTracks(withMediaCharacteristic: .containsHDRVideo)) ?? []).isEmpty
            if self.isHDRVideo { _ = await self.sdrVideoComposition() }     // ready for an instant switch to SDR
            if let v = try? await asset.loadTracks(withMediaType: .video).first, let fd = (try? await v.load(.formatDescriptions))?.first {
                let sub = CMFormatDescriptionGetMediaSubType(fd)
                let tf = CMFormatDescriptionGetExtension(fd, extensionKey: kCMFormatDescriptionExtension_TransferFunction) as? String
                let dv: Set<FourCharCode> = [0x64766831 /* dvh1 */, 0x64766865 /* dvhe */, 0x64766131 /* dva1 */, 0x64766176 /* dvav */]
                self.hdrFormat = dv.contains(sub) ? "Dolby Vision"
                    : tf == (kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ as String) ? "HDR10"
                    : tf == (kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG as String) ? "HLG"
                    : (self.isHDRVideo ? "HDR" : nil)
                let hw = VTIsHardwareDecodeSupported(sub)
                let codecName: String = switch sub {
                case kCMVideoCodecType_HEVC, 0x64766831, 0x64766865: "HEVC"
                case kCMVideoCodecType_H264, 0x64766131, 0x64766176: "H.264"
                case kCMVideoCodecType_AV1: "AV1"
                case kCMVideoCodecType_VP9: "VP9"
                default: sub.fourCCString.trimmingCharacters(in: .whitespaces).uppercased()
                }
                self.videoDecoding = VideoDecodingInfo(hardware: hw, codec: codecName, decoder: hw ? "VideoToolbox (AVPlayer)" : "AVFoundation software decoder")
            }
            if let a = try? await asset.loadTracks(withMediaType: .audio).first, let fd = (try? await a.load(.formatDescriptions))?.first {
                let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fd)?.pointee
                let id = asbd?.mFormatID ?? 0
                let name: String = switch id {
                case kAudioFormatMPEG4AAC, kAudioFormatMPEG4AAC_HE, kAudioFormatMPEG4AAC_HE_V2: "AAC"
                case kAudioFormatAC3: "AC-3"
                case kAudioFormatEnhancedAC3: "E-AC-3"
                case kAudioFormatAppleLossless: "ALAC"
                case kAudioFormatFLAC: "FLAC"
                case kAudioFormatOpus: "Opus"
                case kAudioFormatMPEGLayer3: "MP3"
                case kAudioFormatLinearPCM: "PCM"
                default: id.fourCCString
                }
                let ch = Int(asbd?.mChannelsPerFrame ?? 0)
                self.audioDecoding = ("\(name) " + (ch == 6 ? "5.1" : ch == 8 ? "7.1" : ch == 2 ? "stereo" : ch == 1 ? "mono" : "\(ch) ch"), "Core Audio (AudioToolbox)")
            }
            await self.loadAudioOptionsAndChapters(asset: asset, item: item)
            await self.buildMediaInfo(asset: asset, url: url)
            if let g = try? await asset.loadMediaSelectionGroup(for: .legible) { item.select(nil, in: g) }
            // HLS (YouTube live, Twitch): the asset has no tracks to read the size from; the item reports it once
            // playing, and it can change as the stream switches quality.
            self.observers.append(item.observe(\.presentationSize, options: [.new]) { [weak self] item, _ in
                DispatchQueue.main.async {
                    guard let self else { return }
                    let sz = item.presentationSize
                    guard sz.width > 0, sz.height > 0, abs(sz.width - self._naturalSize.width) > 1 || abs(sz.height - self._naturalSize.height) > 1 else { return }
                    self._naturalSize = sz
                    self.onEvent?(.videoSizeChanged)
                }
            })
            self.observers.append(item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
                DispatchQueue.main.async {
                    guard let self else { return }
                    switch item.status {
                    case .readyToPlay: if !self.readySent { self.readySent = true; self.onEvent?(.ready) }
                    case .failed:
                        // Media Extension missing/disabled/failed: let the built-in engine take over.
                        if self.kind == .avplayerExt { self.onEvent?(.needsFallback) }
                        else { self.onEvent?(.failed(item.error?.localizedDescription ?? "unknown error")) }
                    default: break
                    }
                }
            })
        }
        observers.append(playerLayer.observe(\.isReadyForDisplay, options: [.new]) { [weak self] layer, _ in
            if layer.isReadyForDisplay { DispatchQueue.main.async { self?.onEvent?(.firstFrame) } }
        })
        endObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main) { [weak self] _ in
            self?.onEvent?(.ended)
        }
        player.replaceCurrentItem(with: item)
    }
    private var readySent = false
    private var _mediaInfo = MediaInfo()
    var mediaInfo: MediaInfo { _mediaInfo }

    @MainActor private func buildMediaInfo(asset: AVAsset, url: URL) async {
        var m = MediaInfo()
        m.engine = kind == .avplayerExt ? "AVFoundation (AVPlayer) + Media Extensions" : "AVFoundation (AVPlayer, QuickTime engine)"
        let tracks = (try? await asset.load(.tracks)) ?? []
        let duration = (try? await asset.load(.duration))?.seconds ?? 0
        for t in tracks {
            let fd = (try? await t.load(.formatDescriptions))?.first
            let sub = fd.map { CMFormatDescriptionGetMediaSubType($0) } ?? 0
            let cc = InfoFormat.fourCC(sub)
            let name = InfoFormat.codecNames[cc] ?? cc
            let rate = Double((try? await t.load(.estimatedDataRate)) ?? 0)
            let lang = try? await t.load(.languageCode)
            let enabled = (try? await t.load(.isEnabled)) ?? false
            var rows: [MediaInfo.Row] = [("Codec", name)]
            if let lang { rows.append(("Language", lang)) }
            switch t.mediaType {
            case .video:
                let size = (try? await t.load(.naturalSize)) ?? .zero
                let fps = Double((try? await t.load(.nominalFrameRate)) ?? 0)
                let ext = fd.flatMap { CMFormatDescriptionGetExtensions($0) as? [String: Any] }
                let depth = (ext?[kCMFormatDescriptionExtension_BitsPerComponent as String] as? Int).map { "\($0)-bit" } ?? "—"
                rows.append(("Size", "\(Int(size.width))×\(Int(size.height))"))
                if m.video.isEmpty {
                    m.video = [("Format", cc), ("Codec", name), ("Decoder", fd.map(InfoFormat.videoDecoder) ?? "—"),
                               ("Renderer", "AVPlayerLayer"), ("Bit depth", depth),
                               ("Size", "\(Int(size.width))×\(Int(size.height))")]
                        + InfoFormat.colorRows(ext) + [("Bit rate", InfoFormat.bitrate(rate)), ("FPS", InfoFormat.fps(fps))]
                }
            case .audio:
                let asbd = fd.flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee }
                let ch = Int(asbd?.mChannelsPerFrame ?? 0)
                rows.append(("Channels", InfoFormat.channels(ch)))
                if m.audio.isEmpty {
                    m.audio = [("Format", cc), ("Codec", name),
                               ("Decoder", cc == "lpcm" && kind == .avplayerExt ? "Decoded to PCM by the format reader extension" : "Core Audio (AudioToolbox)"),
                               ("Renderer", "AVPlayer audio"), ("Channels", InfoFormat.channels(ch)),
                               ("Sample rate", "\(Int(asbd?.mSampleRate ?? 0)) Hz"), ("Bit rate", InfoFormat.bitrate(rate))]
                }
            default: break
            }
            if rate > 0 { rows.append(("Bit rate", InfoFormat.bitrate(rate))) }
            let kindName = t.mediaType == .video ? "Video" : t.mediaType == .audio ? "Audio" : (t.mediaType == .subtitle || t.mediaType == .text || t.mediaType == .closedCaption) ? "Subtitle" : "Data"
            m.tracks.append(.init(id: Int(t.trackID), kind: kindName, title: "#\(t.trackID) \(cc)", rows: rows, active: enabled && kindName != "Subtitle"))
        }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        m.file = [(url.isFileURL ? "Path" : "URL", InfoFormat.safeURL(url))]
        if size > 0 { m.file.append(("Size", InfoFormat.bytes(size))) }
        m.file.append(("Container", url.pathExtension.uppercased()))
        if let ext = (asset as? AVURLAsset)?.mediaExtensionProperties {
            m.file.append(("Format reader", "\(ext.extensionName) (\(ext.containingBundleName)) — Media Extension"))
        } else {
            m.file.append(("Format reader", "AVFoundation built-in"))
        }
        m.file.append(("Duration", formatTime(duration)))
        if size > 0, duration > 0 { m.file.append(("Overall bit rate", InfoFormat.bitrate(Double(size) * 8 / duration))) }
        m.file.append(("Streams", "\(tracks.count)"))
        for item in (try? await asset.load(.commonMetadata)) ?? [] {
            if let key = item.commonKey?.rawValue, let v = try? await item.load(.stringValue) { m.metadata.append((key, v)) }
        }
        _mediaInfo = m
    }

    /// One frame for black-bar detection.
    /// Local files: decoded by a separate image generator, so the playing item is never touched — attaching a
    /// video output to an item that has a video composition (HDR off) makes AVFoundation briefly show
    /// unconverted, brighter frames (a visible flash every time auto-crop samples).
    /// Streams (HLS): attach an output only for the moment we need one frame (an attached output makes AVPlayer
    /// keep extra decoded frames around, so it's never left on).
    func snapshotFrame(_ completion: @escaping (CVPixelBuffer?) -> Void) {
        guard let item = player.currentItem else { completion(nil); return }
        if let url = (asset as? AVURLAsset)?.url, url.isFileURL {
            let gen = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            gen.appliesPreferredTrackTransform = true            // same orientation as on screen
            gen.maximumSize = CGSize(width: 1280, height: 1280)  // the detector works on a small copy anyway
            let tolerance = CMTime(seconds: 0.5, preferredTimescale: 600)
            gen.requestedTimeToleranceBefore = tolerance; gen.requestedTimeToleranceAfter = tolerance
            gen.generateCGImageAsynchronously(for: item.currentTime()) { cg, _, _ in
                let pb = cg.flatMap(Self.pixelBuffer(from:))
                DispatchQueue.main.async { _ = gen; completion(pb) }
            }
            return
        }
        let out = AVPlayerItemVideoOutput(pixelBufferAttributes: nil)
        item.add(out)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            let t = out.itemTime(forHostTime: CACurrentMediaTime())
            let pb = out.copyPixelBuffer(forItemTime: t, itemTimeForDisplay: nil)
            item.remove(out)
            completion(pb)
        }
    }

    /// BGRA pixel buffer (IOSurface-backed, so the detector's GPU downscale can read it) holding the image.
    private static func pixelBuffer(from cg: CGImage) -> CVPixelBuffer? {
        var pb: CVPixelBuffer?
        let attrs: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary, kCVPixelBufferCGImageCompatibilityKey: true,
                                      kCVPixelBufferCGBitmapContextCompatibilityKey: true]
        guard CVPixelBufferCreate(nil, cg.width, cg.height, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pb) == kCVReturnSuccess, let pb else { return nil }
        CVPixelBufferLockBaseAddress(pb, []); defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        guard let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pb), width: cg.width, height: cg.height, bitsPerComponent: 8,
                                  bytesPerRow: CVPixelBufferGetBytesPerRow(pb), space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        return pb
    }

    func statusRows() -> [MediaInfo.Row] {
        guard let item = player.currentItem else { return [] }
        var rows: [MediaInfo.Row] = []
        if let ahead = item.loadedTimeRanges.map(\.timeRangeValue).first(where: { $0.containsTime(item.currentTime()) }) {
            rows.append(("Buffered ahead", String(format: "%.1f s", (ahead.end - item.currentTime()).seconds)))
        }
        if let e = item.accessLog()?.events.last {
            rows.append(("Dropped frames", "\(e.numberOfDroppedVideoFrames)"))
            if e.observedBitrate > 0 { rows.append(("Observed bit rate", InfoFormat.bitrate(e.observedBitrate))) }
        }
        rows.append(("Player status", player.timeControlStatus == .waitingToPlayAtSpecifiedRate ? "buffering" : player.timeControlStatus == .playing ? "playing" : "paused"))
        return rows
    }

    func selectSubtitle(_ id: Int?) {
        subtitleLoad?.cancel()
        cues.clear()
        guard let id, let track = subtitleAssetTracks[Int32(id)], let asset else { return }
        let store = cues
        // Text tracks are tiny: read the whole track once on a background thread.
        subtitleLoad = Task.detached(priority: .utility) {
            guard let reader = try? AVAssetReader(asset: asset) else { return }
            let out = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            out.alwaysCopiesSampleData = false
            reader.add(out)
            guard reader.startReading() else { return }
            var cues: [SubtitleCue] = []
            while !Task.isCancelled, let sb = out.copyNextSampleBuffer() {
                guard let block = sb.dataBuffer, let fd = sb.formatDescription else { continue }
                let data = (try? block.dataBytes()) ?? Data()
                let start = sb.presentationTimeStamp.seconds
                let dur = sb.duration.isValid ? sb.duration.seconds : 4
                let codec = CMFormatDescriptionGetMediaSubType(fd) == FourCharCode(0x77767474) /* wvtt */ ? "webvtt-mp4" : "mov_text"
                let text = SubtitleText.fromPacket(codec: codec, data: data)
                if !text.isEmpty, start.isFinite { cues.append(SubtitleCue(start: start, end: start + dur, text: text)) }
            }
            if !Task.isCancelled { store.replaceAll(cues) }
        }
    }

    func makePiPController(sampleBufferDelegate: AVPictureInPictureSampleBufferPlaybackDelegate) -> AVPictureInPictureController? {
        AVPictureInPictureController(playerLayer: playerLayer)
    }

    func play() { player.play() }
    func pause() { player.pause() }

    func seek(to seconds: Double, accurate: Bool) {
        let t = CMTime(seconds: max(0, seconds), preferredTimescale: 600)
        if accurate {
            player.seek(to: t, toleranceBefore: .zero, toleranceAfter: .zero)
        } else {
            player.seek(to: t)
        }
    }

    // Held-arrow scrubbing: chain keyframe-tolerant seeks so each one renders before the next (Apple QA1820).
    private var scrubbing = false
    private var pendingScrub: (Double, Bool)?
    func scrub(to seconds: Double, forward: Bool) {
        if scrubbing { pendingScrub = (seconds, forward); return }
        scrubbing = true
        let t = CMTime(seconds: max(0, seconds), preferredTimescale: 600)
        player.seek(to: t, toleranceBefore: forward ? .zero : .positiveInfinity, toleranceAfter: forward ? .positiveInfinity : .zero) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.scrubbing = false
                if let (s, f) = self.pendingScrub { self.pendingScrub = nil; self.scrub(to: s, forward: f) }
            }
        }
    }

    func close() {
        player.pause()
        player.replaceCurrentItem(with: nil)
        observers.removeAll()
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
    }

    private(set) var isHDRVideo = false
    private(set) var hdrFormat: String?
    private(set) var videoDecoding: VideoDecodingInfo?
    private(set) var audioDecoding: (codec: String, decoder: String)?
    private(set) var audioTracks: [AudioTrackInfo] = []
    private(set) var selectedAudioTrack: Int?
    private(set) var chapters: [ChapterInfo] = []
    private var audioGroup: AVMediaSelectionGroup?

    @MainActor private func loadAudioOptionsAndChapters(asset: AVAsset, item: AVPlayerItem) async {
        if let g = try? await asset.loadMediaSelectionGroup(for: .audible) {
            audioGroup = g
            let selected = item.currentMediaSelection.selectedMediaOption(in: g)
            audioTracks = g.options.enumerated().map { i, o in
                AudioTrackInfo(id: i, title: o.displayName == o.locale?.localizedString(forIdentifier: o.locale?.identifier ?? "") ? "" : o.displayName,
                               language: o.extendedLanguageTag ?? o.locale?.language.languageCode?.identifier, detail: "", isDefault: o == g.defaultOption)
            }
            selectedAudioTrack = selected.flatMap { g.options.firstIndex(of: $0) } ?? (audioTracks.isEmpty ? nil : 0)
        }
        // Chapters tagged "und" don't match any preferred language: fall back to the file's own chapter locales.
        var groups = (try? await asset.loadChapterMetadataGroups(bestMatchingPreferredLanguages: Locale.preferredLanguages)) ?? []
        if groups.isEmpty, let locale = (try? await asset.load(.availableChapterLocales))?.first {
            groups = (try? await asset.loadChapterMetadataGroups(withTitleLocale: locale, containingItemsWithCommonKeys: [])) ?? []
        }
        if !groups.isEmpty {
            var out: [ChapterInfo] = []
            for (i, g) in groups.enumerated() {
                let titleItem = AVMetadataItem.metadataItems(from: g.items, filteredByIdentifier: .commonIdentifierTitle).first
                let title = (try? await titleItem?.load(.stringValue)) ?? nil
                out.append(ChapterInfo(start: g.timeRange.start.seconds, title: title ?? "Chapter \(i + 1)"))
            }
            chapters = out.sorted { $0.start < $1.start }
        }
    }

    func selectAudioTrack(_ id: Int) {
        guard let g = audioGroup, g.options.indices.contains(id), let item = player.currentItem else { return }
        item.select(g.options[id], in: g)
        selectedAudioTrack = id
    }

    func stepFrame(forward: Bool) {
        player.pause()
        player.currentItem?.step(byCount: forward ? 1 : -1)
    }

    /// HDR off: render through a video composition whose output is BT.709 SDR (AVFoundation tone-maps).
    ///
    /// Swapping the composition in while playing makes AVFoundation rebuild its pipeline: a few frames stall,
    /// then ~3 frames show unconverted (about twice as bright) — a visible flash. So when switching to SDR
    /// mid-playback, the picture is covered for that moment with an SDR still of the current frame (decoded by
    /// a separate image generator), which fades out once the converted frames are flowing. The composition is
    /// built ahead of time so the switch doesn't wait ~1 s for it. (Switching back to HDR has no flash.)
    private var sdrComposition = false
    private var preparedSDR: AVVideoComposition?
    private var cover: NSView?

    private func sdrVideoComposition() async -> AVVideoComposition? {
        if let preparedSDR { return preparedSDR }
        guard let asset, let c = try? await AVMutableVideoComposition.videoComposition(withPropertiesOf: asset) else { return nil }
        c.colorPrimaries = AVVideoColorPrimaries_ITU_R_709_2
        c.colorTransferFunction = AVVideoTransferFunction_ITU_R_709_2
        c.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_709_2
        preparedSDR = c
        return c
    }

    func setHDR(_ on: Bool) {
        guard asset != nil, let item = player.currentItem, sdrComposition == on else { return }
        sdrComposition = !on
        Task { @MainActor [weak self] in
            guard let self, let asset = self.asset else { return }
            let hdrTracks = (try? await asset.loadTracks(withMediaCharacteristic: .containsHDRVideo)) ?? []
            if hdrTracks.isEmpty { return }
            if on { self.removeCover(); item.videoComposition = nil; return }
            guard let c = await self.sdrVideoComposition(), self.sdrComposition, self.player.currentItem === item else { return }
            let covered = await self.coverWithStill(item)
            guard self.sdrComposition, self.player.currentItem === item else { self.removeCover(); return }
            item.videoComposition = c
            // AVPlayer would keep showing ~1 s of frames it already prepared, then glitch to the new pipeline.
            // Seeking to where we are flushes them so SDR takes effect now; the still covers the seek.
            guard covered else { return }
            let t = item.currentTime()
            self.player.seek(to: t, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
                DispatchQueue.main.async { self?.removeCover(after: 0.12) }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.removeCover() }   // never stuck
        }
    }

    /// Lays an SDR still of (about) the frame on screen over the video. False when there's nothing to cover
    /// (nothing shown yet, or not a local file).
    private func coverWithStill(_ item: AVPlayerItem) async -> Bool {
        guard playerLayer.isReadyForDisplay, let url = (asset as? AVURLAsset)?.url, url.isFileURL else { return false }
        let gen = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        gen.appliesPreferredTrackTransform = true
        gen.dynamicRangePolicy = .forceSDR
        let px = playerLayer.bounds.size, scale = playerLayer.contentsScale
        gen.maximumSize = CGSize(width: px.width * scale, height: px.height * scale)
        // Decoding takes a moment while the video keeps playing: ask for a frame slightly ahead.
        let ahead = player.rate > 0 ? 0.2 * Double(player.rate) : 0
        let t = item.currentTime() + CMTime(seconds: ahead, preferredTimescale: 600)
        gen.requestedTimeToleranceBefore = CMTime(seconds: 0.05, preferredTimescale: 600)
        gen.requestedTimeToleranceAfter = CMTime(seconds: 0.05, preferredTimescale: 600)
        guard let image = try? await gen.image(at: t).image else { return false }
        removeCover()
        // Its own view on top of the video: a plain layer above the AVPlayerLayer isn't drawn over HDR video.
        let v = NSView(frame: view.bounds)
        v.wantsLayer = true
        v.autoresizingMask = [.width, .height]
        v.layer?.backgroundColor = NSColor.black.cgColor
        // Same placement as the video (the player layer is enlarged and offset when black bars are cropped).
        let l = CALayer()
        l.contents = image
        l.contentsGravity = .resizeAspect                  // same as the player layer's videoGravity
        l.frame = playerLayer.frame
        v.layer?.addSublayer(l)
        view.addSubview(v)
        cover = v
        return true
    }

    private func removeCover(after delay: Double = 0) {
        guard let v = cover else { return }
        if delay == 0 { cover = nil; v.removeFromSuperview(); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.cover === v else { return }
            self.cover = nil
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.15; v.animator().alphaValue = 0 }, completionHandler: { v.removeFromSuperview() })
        }
    }

    func diagnostics() -> [String: String] {
        var d: [String: String] = [:]
        if let ext = (asset as? AVURLAsset)?.mediaExtensionProperties { d["mediaExtension"] = ext.extensionIdentifier }
        if let tracks = player.currentItem?.tracks {
            for t in tracks {
                guard let at = t.assetTrack, let fd = at.formatDescriptions.first else { continue }
                let fourcc = CMFormatDescriptionGetMediaSubType(fd as! CMFormatDescription).fourCCString
                d[at.mediaType.rawValue] = fourcc
            }
        }
        if let log = player.currentItem?.accessLog()?.events.last {
            d["droppedFrames"] = String(log.numberOfDroppedVideoFrames)
        }
        return d
    }
}

/// An NSView that hosts a single CALayer filling its bounds (no implicit animations on resize).
final class LayerHostView: NSView {
    let hosted: CALayer
    init(hosted: CALayer) {
        self.hosted = hosted
        super.init(frame: .zero)
        let root = CALayer()
        root.backgroundColor = NSColor.black.cgColor
        layer = root
        wantsLayer = true
        layerUsesCoreImageFilters = true
        layerContentsRedrawPolicy = .never
        root.addSublayer(hosted)
    }

    /// HDR on: the video layer may use extended dynamic range. Off: HDR content is tone-mapped to SDR.
    /// Video size + optional crop (normalized, origin top-left). With a crop, the hosted layer is enlarged and
    /// offset so only the cropped part is visible (the root layer clips).
    var videoSize: CGSize = .zero { didSet { if videoSize != oldValue { needsLayout = true } } }
    var crop: CGRect? {
        didSet {
            guard crop != oldValue else { return }
            // No masksToBounds: the overflow is exactly the black bars and lies outside the window, which clips it
            // anyway. Masking would force the window server to composite the video every frame (judder risk).
            CATransaction.begin()
            CATransaction.setAnimationDuration(0.3)
            hosted.frame = layoutFrame()
            CATransaction.commit()
        }
    }

    private func layoutFrame() -> CGRect {
        guard crop != nil, videoSize.width > 0 else { return bounds }
        return VideoGeometry.frameRect(bounds: bounds, videoSize: videoSize, crop: crop)
    }

    /// Brightness/contrast/gamma as Core Image layer filters. Filters are removed entirely at default
    /// values so the normal (zero-copy, direct-to-display) path has no extra cost.
    func setColorAdjustments(brightness: Double, contrast: Double, gamma: Double) {
        let neutral = abs(brightness) < 0.001 && abs(contrast - 1) < 0.001 && abs(gamma - 1) < 0.001
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if neutral {
            hosted.filters = nil
        } else {
            var filters: [CIFilter] = []
            if abs(gamma - 1) >= 0.001, let g = CIFilter(name: "CIGammaAdjust") {
                // UI gamma > 1 brightens midtones; CIGammaAdjust's power works the other way.
                g.setValue(1 / gamma, forKey: "inputPower")
                filters.append(g)
            }
            if abs(brightness) >= 0.001 || abs(contrast - 1) >= 0.001, let c = CIFilter(name: "CIColorControls") {
                c.setValue(brightness, forKey: kCIInputBrightnessKey)
                c.setValue(contrast, forKey: kCIInputContrastKey)
                c.setValue(1.0, forKey: kCIInputSaturationKey)
                filters.append(c)
            }
            hosted.filters = filters
        }
        CATransaction.commit()
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        hosted.frame = layoutFrame()
        CATransaction.commit()
    }
}

extension Double {
    var finiteOrZero: Double { isFinite ? self : 0 }
}

extension FourCharCode {
    var fourCCString: String {
        let bytes = [UInt8((self >> 24) & 0xff), UInt8((self >> 16) & 0xff), UInt8((self >> 8) & 0xff), UInt8(self & 0xff)]
        return String(bytes: bytes, encoding: .macOSRoman) ?? "\(self)"
    }
}
