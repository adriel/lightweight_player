import AppKit
import AVFoundation
import AVKit

/// Engine C: libavformat demuxes; compressed samples go straight to AVSampleBufferDisplayLayer /
/// AVSampleBufferAudioRenderer, which decode with VideoToolbox / AudioToolbox. A/V sync by
/// AVSampleBufferRenderSynchronizer. The app never touches decoded pixels.
final class SampleBufferEngine: PlayerEngine {
    let kind = EngineKind.sampleBuffer
    let view: NSView
    var onEvent: ((EngineEvent) -> Void)?
    private(set) var warnings: [EngineWarning] = []
    private(set) var notices: [String] = []

    private let displayLayer = AVSampleBufferDisplayLayer()
    private var videoRenderer: AVSampleBufferVideoRenderer { displayLayer.sampleBufferRenderer }
    private let audioRenderer = AVSampleBufferAudioRenderer()
    private let synchronizer = AVSampleBufferRenderSynchronizer()
    private let queue = DispatchQueue(label: "engine.c.feed", qos: .userInitiated)

    private var demuxer: FFDemuxer?
    // Packets demuxed for one renderer while feeding the other. Bounded by the renderers' own lead.
    private var videoPending: [CMSampleBuffer] = []
    private var audioPending: [CMSampleBuffer] = []
    private var audioThrottled = false
    private var lastAudioPTS = 0.0, lastVideoPTS = 0.0
    /// Audio before an accurate-seek target is dropped (video uses DoNotDisplay instead).
    private var audioCutoff: Double?
    private var eof = false
    private var seekTarget: Double?       // accurate seek: hide frames / drop audio before this
    private var generation = 0
    private var wantsPlay = false
    private var _duration: Double = 0
    private var firstFrameSignaled = false
    private var observers: [NSObjectProtocol] = []
    private static let maxPending = 600

    init() {
        displayLayer.videoGravity = .resizeAspect
        displayLayer.backgroundColor = NSColor.black.cgColor
        displayLayer.preventsDisplaySleepDuringVideoPlayback = true
        view = LayerHostView(hosted: displayLayer)
        // The video layer joins the synchronizer in open(), or gets its own clock when display sync applies.
        synchronizer.addRenderer(audioRenderer)
        // Display sync may run the clock at ×1.001; plain resampling is cheapest and inaudible at that ratio.
        audioRenderer.audioTimePitchAlgorithm = .varispeed
    }

    var currentTime: Double { synchronizer.currentTime().seconds.finiteOrZero }
    var duration: Double { _duration }
    var isPlaying: Bool { wantsPlay }
    var volume: Float {
        get { audioRenderer.volume }
        set { audioRenderer.volume = newValue }
    }

    let cues = CueStore()
    private var _mediaInfo = MediaInfo()
    var mediaInfo: MediaInfo { _mediaInfo }

    func snapshotFrame(_ completion: @escaping (CVPixelBuffer?) -> Void) {
        completion(videoRenderer.displayedPixelBuffer())
    }

    /// Renderer's own counters (frames shown, dropped for missing their deadline, accumulated lateness).
    private var lastMetrics = "—"
    private func refreshMetrics(log: Bool = false) {
        videoRenderer.loadVideoPerformanceMetrics { [weak self] m in
            guard let m else { return }
            let avgDelay = m.totalNumberOfFrames > 0 ? m.totalAccumulatedFrameDelay / Double(m.totalNumberOfFrames) * 1000 : 0
            let str = String(format: "%d frames · %d dropped · %d corrupted · avg delay %.1f ms · optimized %d",
                             m.totalNumberOfFrames, m.numberOfDroppedFrames, m.numberOfCorruptedFrames, avgDelay, m.numberOfFramesDisplayedUsingOptimizedCompositing)
            DispatchQueue.main.async { self?.lastMetrics = str }
            if log { DispatchQueue.main.async { guard let self else { return }; let pb = self.videoRenderer.displayedPixelBuffer()
                let tf = pb.flatMap { CVBufferCopyAttachment($0, kCVImageBufferTransferFunctionKey, nil) as? String } ?? "-"
                NSLog("metrics: %@ · lead %.2f s · audio lead %.2f s · frame %@ %@", str, self.lastVideoPTS - self.currentTime, self.lastAudioPTS - self.currentTime, pb.map { CVPixelBufferGetPixelFormatType($0).fourCCString } ?? "-", tf) } }
        }
    }
    private var metricsTimer: Timer?

    func statusRows() -> [MediaInfo.Row] {
        refreshMetrics()
        var rows: [MediaInfo.Row] = [("Display sync", displaySync?.summary ?? "off"), ("Renderer", lastMetrics), ("A/V read-ahead", String(format: "video %.1f s · audio %.1f s", max(0, lastVideoPTS - currentTime), max(0, lastAudioPTS - currentTime)))]
        if let s = source?.stats {
            let bps = s.length > 0 && _duration > 0 ? Double(s.length) / _duration : 0
            rows.append(("Buffered ahead", InfoFormat.bytes(s.aheadBytes) + (bps > 0 ? String(format: " (%.0f s)", Double(s.aheadBytes) / bps) : "")))
            rows.append(("Disk cache", InfoFormat.bytes(s.cachedBytes) + " of " + InfoFormat.bytes(s.length)))
            rows.append(("Download", s.downloading ? InfoFormat.bitrate(s.bytesPerSecond * 8) : "paused (buffer full)"))
        }
        return rows
    }
    private var source: CachedHTTPSource?
    private var _naturalSize = CGSize.zero
    private var _subtitleTracks: [SubtitleTrackInfo] = []
    var naturalSize: CGSize { _naturalSize }
    var subtitleTracks: [SubtitleTrackInfo] { _subtitleTracks }
    func makePiPController(sampleBufferDelegate: AVPictureInPictureSampleBufferPlaybackDelegate) -> AVPictureInPictureController? {
        AVPictureInPictureController(contentSource: .init(sampleBufferDisplayLayer: displayLayer, playbackDelegate: sampleBufferDelegate))
    }
    var bufferedFractions: [ClosedRange<Double>] { source?.bufferedFractions() ?? [] }
    func appendWarning(_ message: String) { warnings.append(EngineWarning(message: message)) }

    func selectSubtitle(_ id: Int?) {
        queue.async { [self] in demuxer?.selectSubtitle(id.map(Int32.init)) }
    }

    func open(_ url: URL) {
        let path = url.isFileURL ? url.path : url.absoluteString
        queue.async { [self] in
            do {
                var src: CachedHTTPSource?
                if let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" {
                    let st = Settings.shared
                    let s = try CachedHTTPSource(url: url, cacheDirectory: st.cacheDirectory)
                    s.timeout = st.networkTimeout
                    s.maxDiskBytes = Int64(st.maxCacheGB * 1_073_741_824)
                    try s.open()
                    src = s
                    source = s
                }
                let d = try FFDemuxer(url: path, source: src)
                if let src, d.duration > 0 {
                    // Read-ahead target = N minutes at the file's average bitrate.
                    let bps = d.bitRate > 0 ? Double(d.bitRate) / 8 : Double(src.length) / d.duration
                    src.readAheadBytes = Int64(bps * Settings.shared.bufferMinutes * 60)
                }
                _naturalSize = d.naturalSize
                var info = d.mediaInfo()
                info.engine = "FFmpeg demux (libavformat) → AVSampleBuffer renderers" + (src != nil ? " · disk-cached HTTP" : "")
                info.file.insert((url.isFileURL ? "Path" : "URL", InfoFormat.safeURL(url)), at: 0)
                let size = src?.length ?? ((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0)
                if size > 0 { info.file.insert(("Size", InfoFormat.bytes(size)), at: 1) }
                let infoCopy = info
                DispatchQueue.main.async { self._mediaInfo = infoCopy }
                _subtitleTracks = d.subtitleStreams
                demuxer = d
                _duration = d.duration
                let hdr = d.videoFormat.map(FFDemuxer.isHDR) ?? false
                let tracks = d.audioStreams, chapters = d.chapters, audioIdx = Int(d.audioIndex)
                let frame = d.frameRateInfo.map { (1 / $0.fps, $0.base) }
                DispatchQueue.main.async {
                    self.isHDRVideo = hdr
                    self.audioTracks = tracks; self.chapters = chapters
                    self.selectedAudioTrack = audioIdx >= 0 ? audioIdx : nil
                    if let frame { self.frameDuration = frame.0; self.frameBase = frame.1 }
                }
                let w = d.warnings.map(EngineWarning.init)
                let n = d.notices
                let fr = d.frameRateInfo
                // Display sync needs video + audio (the audio clock is the master) and a clean refresh multiple.
                var decouple = false
                if let fr, d.videoIndex >= 0, d.audioIndex >= 0, ProcessInfo.processInfo.environment["LP_NO_DISPLAY_SYNC"] == nil,
                   let sc = DisplaySync.scale(fps: fr.fps, refreshHz: DisplaySync.mainDisplayRefreshHz) {
                    timeScale = sc
                    playRate = Float(sc)
                    decouple = true
                }
                DispatchQueue.main.async {
                    self.warnings = w; self.notices = n
                    if decouple, let fr {
                        self.displayLayer.controlTimebase = self.videoTimebase
                        self.decoupled = true
                        self.startDisplaySync(fps: fr.fps, base: fr.base)
                    } else {
                        self.synchronizer.addRenderer(self.displayLayer)
                    }
                    self.onEvent?(.ready)
                    if ProcessInfo.processInfo.environment["LP_VIDEO_METRICS"] != nil {
                        self.metricsTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.refreshMetrics(log: true) }
                    }
                    self.queue.async { if d.videoIndex >= 0 || d.audioIndex >= 0 { self.startFeeding() } }
                }
                if d.videoIndex < 0 && d.audioIndex < 0 {
                    DispatchQueue.main.async { self.onEvent?(.failed("No playable streams")) }
                    return
                }
                observers.append(NotificationCenter.default.addObserver(forName: AVSampleBufferVideoRenderer.didFailToDecodeNotification, object: videoRenderer, queue: .main) { n in
                    let err = n.userInfo?[AVSampleBufferVideoRenderer.didFailToDecodeNotificationErrorKey]
                    self.onEvent?(.failed("video decode failed: \(String(describing: err))"))
                })
            } catch {
                DispatchQueue.main.async { self.onEvent?(.failed("\(error)")) }
            }
        }
    }

    // Rate changes go through the feed queue so they're ordered with seeks (a seek queued just before play()
    // must not end up restoring the old paused state).
    func play() {
        wantsPlay = true
        queue.async { [self] in
            guard wantsPlay else { return }
            synchronizer.setRate(playRate, time: synchronizer.currentTime())
        }
    }

    // MARK: Display sync (see DisplaySync)
    private var displaySync: DisplaySync?
    /// Audio clock speed s (×1.001 for 23.976 on 60 Hz). Set in open() before feeding starts, then constant.
    private var timeScale = 1.0
    private var playRate: Float = 1
    /// Decoupled mode: the video layer runs on its own timebase at exactly 1× host time, slaved to the audio
    /// clock as V = C/s + avOffset (AVSampleBufferDisplayLayer judders 2-2-2-4 on a timebase rate ≠ 1).
    private let videoTimebase: CMTimebase = {
        var tb: CMTimebase?
        CMTimebaseCreateWithSourceClock(allocator: nil, sourceClock: CMClockGetHostTimeClock(), timebaseOut: &tb)
        return tb!
    }()
    private var decoupled = false
    private let clockLock = NSLock()
    private var avOffset = 0.0

    private func startDisplaySync(fps: Double, base: Double) {
        let hostClock = CMClockGetHostTimeClock()
        let ds = DisplaySync(view: view, fps: fps, base: base, scale: timeScale, measure: { [weak self] host in
            guard let self, CMTimebaseGetRate(self.synchronizer.timebase) != 0, CMTimebaseGetRate(self.videoTimebase) != 0 else { return nil }
            let h = CMTime(seconds: host, preferredTimescale: 1_000_000_000)
            let c = CMSyncConvertTime(h, from: hostClock, to: self.synchronizer.timebase)
            let v = CMSyncConvertTime(h, from: hostClock, to: self.videoTimebase)
            guard c.isValid, v.isValid else { return nil }
            return (c.seconds, v.seconds)
        }, setOffset: { [weak self] d in
            guard let self else { return }
            self.clockLock.lock(); self.avOffset = d; self.clockLock.unlock()
            self.syncVideoClock()
        })
        displaySync = ds
        // Follow every change of the audio clock (play, pause, seek, start after preroll, stalls).
        for name in [CMTimebase.effectiveRateChanged, CMTimebase.timeJumped] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: synchronizer.timebase, queue: nil) { [weak self] n in
                guard let self else { return }
                if ProcessInfo.processInfo.environment["LP_SYNC_DEBUG"] != nil { NSLog("displaysync: audio clock %@ rate %.4f", n.name.rawValue, CMTimebaseGetRate(self.synchronizer.timebase)) }
                self.syncVideoClock()
                DispatchQueue.main.async { self.displaySync?.resync() }
            })
        }
        syncVideoClock()
        ds.start()
    }

    /// Re-anchor the video clock to the audio clock now: V = C/s + avOffset, running at exactly 1× (or stopped).
    private func syncVideoClock() {
        guard decoupled else { return }
        clockLock.lock(); defer { clockLock.unlock() }
        let hostClock = CMClockGetHostTimeClock()
        let host = CMClockGetTime(hostClock)
        let c = CMSyncConvertTime(host, from: hostClock, to: synchronizer.timebase)
        guard c.isValid else { return }
        let v = CMTime(seconds: c.seconds / timeScale + avOffset, preferredTimescale: 1_000_000_000)
        if CMTimebaseGetRate(synchronizer.timebase) == 0 {
            CMTimebaseSetRate(videoTimebase, rate: 0)
            CMTimebaseSetTime(videoTimebase, time: v)
        } else {
            CMTimebaseSetRateAndAnchorTime(videoTimebase, rate: 1, anchorTime: v, immediateSourceTime: host)
        }
    }

    /// Content timestamps → video-clock timestamps (decoupled mode with s ≠ 1).
    private func scaledForVideoClock(_ sb: CMSampleBuffer) -> CMSampleBuffer {
        let s = timeScale
        let pts = sb.presentationTimeStamp, dts = sb.decodeTimeStamp, dur = sb.duration
        var timing = CMSampleTimingInfo(
            duration: dur.isValid ? CMTime(seconds: dur.seconds / s, preferredTimescale: 1_000_000_000) : .invalid,
            presentationTimeStamp: CMTime(seconds: pts.seconds / s, preferredTimescale: 1_000_000_000),
            decodeTimeStamp: dts.isValid ? CMTime(seconds: dts.seconds / s, preferredTimescale: 1_000_000_000) : .invalid)
        var out: CMSampleBuffer?
        CMSampleBufferCreateCopyWithNewTiming(allocator: nil, sampleBuffer: sb, sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleBufferOut: &out)
        guard let out else { return sb }
        // Attachments (NotSync, DoNotDisplay) live in the sample attachments array, copied with the buffer.
        if let src = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [NSDictionary],
           let dst = CMSampleBufferGetSampleAttachmentsArray(out, createIfNecessary: true) as? [NSMutableDictionary],
           let a = src.first, let b = dst.first, b.count == 0 {
            b.addEntries(from: a as! [AnyHashable: Any])
        }
        return out
    }

    /// Recreates the decoder with/without SDR tone mapping and re-shows the current frame.
    func setHDR(_ on: Bool) {
        let t = currentTime
        queue.async { [self] in
            guard let demuxer, demuxer.setToneMapToSDR(!on) else { return }
            DispatchQueue.main.async { self.seek(to: t, accurate: true) }
        }
    }

    private(set) var isHDRVideo = false
    private(set) var audioTracks: [AudioTrackInfo] = []
    private(set) var selectedAudioTrack: Int?
    private(set) var chapters: [ChapterInfo] = []
    private var frameDuration = 1.0 / 30, frameBase = 0.0

    func selectAudioTrack(_ id: Int) {
        guard id != selectedAudioTrack else { return }
        let t = currentTime
        queue.async { [self] in
            guard let demuxer, demuxer.selectAudio(Int32(id)) else { return }
            DispatchQueue.main.async {
                self.selectedAudioTrack = id
                self.seek(to: t, accurate: true)       // refill both renderers from here with the new track
            }
        }
    }

    /// Frame step (paused): forward moves the clock to the next frame (already decoded ahead); backward is a
    /// frame-accurate seek to the previous frame.
    func stepFrame(forward: Bool) {
        pause()
        let fd = frameDuration
        let cur = frameBase + ((currentTime - frameBase) / fd + 1e-3).rounded(.down) * fd
        if forward {
            let next = cur + fd
            queue.async { [self] in
                synchronizer.setRate(0, time: CMTime(seconds: next + 1e-4, preferredTimescale: 1_000_000))
            }
        } else {
            seek(to: max(0, cur - fd + 1e-4), accurate: true)
        }
    }

    func pause() {
        wantsPlay = false
        queue.async { [self] in
            guard !wantsPlay else { return }
            synchronizer.rate = 0
        }
    }

    func seek(to seconds: Double, accurate: Bool) {
        pendingScrub = nil
        scrubEnd?.cancel(); scrubEnd = nil
        performSeek(seconds, accurate: accurate, forward: false, scrub: false)
    }

    // Held-arrow scrubbing (like mpv/IINA): keyframe seeks, each one shown before the next starts. Requests
    // that arrive meanwhile collapse into the latest target. Main thread.
    private var scrubInFlight: Int?            // generation of the seek being waited on
    private var pendingScrub: (Double, Bool)?
    private var seekGenerationRequested = 0
    private static let seekDebug = ProcessInfo.processInfo.environment["LP_SEEK_DEBUG"] != nil
    private var seekStarted = Date()

    func scrub(to seconds: Double, forward: Bool) {
        scrubEnd?.cancel(); scrubEnd = nil
        if scrubInFlight != nil { pendingScrub = (seconds, forward); return }
        let gen = performSeek(seconds, accurate: false, forward: forward, scrub: true)
        scrubInFlight = gen
        // Safety net (end of file, decode error): don't wait forever for a frame.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.seekShown(gen) }
    }

    /// First frame of seek `gen` was handed to the renderer.
    private func seekShown(_ gen: Int) {
        guard scrubInFlight == gen else { return }
        if Self.seekDebug { NSLog("seek: frame after %.0f ms", Date().timeIntervalSince(seekStarted) * 1000) }
        scrubInFlight = nil
        if let (t, f) = pendingScrub { pendingScrub = nil; scrub(to: t, forward: f); return }
        // No more jumps queued: resume normal playback from the frame on screen shortly after the key stops.
        let end = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.scrubEnd = nil
            self.queue.async {
                guard self.scrubHold, gen == self.generation else { return }
                self.scrubHold = false
                self.synchronizer.setRate(self.wantsPlay ? self.playRate : 0, time: self.synchronizer.currentTime())
                self.startFeeding()
            }
        }
        scrubEnd = end
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: end)
    }
    private var scrubEnd: DispatchWorkItem?
    /// Feed queue: while scrubbing, only the landed keyframe is decoded and shown; clock and audio stay paused,
    /// so the next jump has almost nothing to flush.
    private var scrubHold = false

    @discardableResult
    private func performSeek(_ seconds: Double, accurate: Bool, forward: Bool, scrub: Bool) -> Int {
        let target = max(0, min(seconds, _duration > 0 ? _duration - 0.5 : seconds))
        seekGenerationRequested += 1
        let gen = seekGenerationRequested
        seekStarted = Date()
        queue.async { [self] in
            guard let demuxer else { return }
            generation = gen
            let playing = wantsPlay
            synchronizer.setRate(0, time: CMTime(seconds: target, preferredTimescale: 90000))
            videoRenderer.flush()
            audioRenderer.flush()
            freePending()
            eof = false
            demuxer.seek(to: target, forward: forward && !accurate)
            seekTarget = accurate ? target : nil
            audioCutoff = accurate ? target : nil
            firstFrameSignaled = false
            // Keyframe seek: start the clock at the keyframe actually landed on, so it shows immediately.
            var start = target
            if !accurate, hasVideo, let first = next(video: true) {
                if first.presentationTimeStamp.isValid { start = first.presentationTimeStamp.seconds }
                videoPending.insert(first, at: 0)
            }
            scrubHold = scrub
            let rate = playing && !scrub ? playRate : 0
            synchronizer.setRate(rate, time: CMTime(seconds: start, preferredTimescale: 90000))
            startFeeding()
        }
        displaySync?.resync()
        return gen
    }

    func close() {
        metricsTimer?.invalidate()
        displaySync?.stop()
        demuxer?.interrupt()
        source?.close()
        queue.sync {
            videoRenderer.stopRequestingMediaData()
            audioRenderer.stopRequestingMediaData()
            synchronizer.rate = 0
            videoRenderer.flush(removingDisplayedImage: true, completionHandler: nil)
            audioRenderer.flush()
            freePending()
            demuxer = nil
        }
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    func diagnostics() -> [String: String] {
        var d: [String: String] = ["video": demuxer?.videoCodecName ?? "-", "audio": demuxer?.audioCodecName ?? "-"]
        let now = currentTime
        d["lead"] = String(format: "v%.1f a%.1f pend v%d a%d", lastVideoPTS - now, lastAudioPTS - now, videoPending.count, audioPending.count)
        if let sw = demuxer?.swVideo { d["videoDecoder"] = "software:" + sw.decoderName }
        if demuxer?.swAudio != nil { d["audioDecoder"] = "software" }
        if let fd = demuxer?.videoFormat {
            d["hwDecodeSupported"] = String(VTIsHardwareDecodeSupported(CMFormatDescriptionGetMediaSubType(fd)))
        }
        return d
    }

    // MARK: Feeding

    /// Audio may run at most this far ahead of the newest enqueued video frame. AVSampleBufferAudioRenderer
    /// would otherwise pull ~2.5 s ahead and force a matching stash of (large) video packets.
    private static let audioLeadOverVideo = 0.25

    private func startFeeding() {
        let gen = generation
        audioThrottled = false
        if demuxer?.videoIndex ?? -1 >= 0 {
            videoRenderer.requestMediaDataWhenReady(on: queue) { [weak self] in self?.feedVideo(gen) }
        }
        if demuxer?.audioIndex ?? -1 >= 0 { requestAudio(gen) }
    }

    private func requestAudio(_ gen: Int) {
        audioRenderer.requestMediaDataWhenReady(on: queue) { [weak self] in self?.feedAudio(gen) }
    }

    private var hasVideo: Bool { (demuxer?.videoIndex ?? -1) >= 0 }

    private func feedVideo(_ gen: Int) {
        guard gen == generation else { return }
        while videoRenderer.isReadyForMoreMediaData {
            guard let sb = nextVideo() else {
                if eof { videoRenderer.stopRequestingMediaData(); resumeAudioIfThrottled(gen); checkEnded() }
                else if !videoRenderer.isReadyForMoreMediaData { return }
                return
            }
            let pts = sb.presentationTimeStamp.seconds
            // Kept until the next seek: reordered B-frames after the target can still precede it.
            let hide = seekTarget.map { pts + 0.001 < $0 } ?? false
            if hide { sb.setAttachment(kCMSampleAttachmentKey_DoNotDisplay, true) }
            lastVideoPTS = max(lastVideoPTS, pts)
            if Self.videoDebug { debugVideo(sb) }
            videoRenderer.enqueue(decoupled && timeScale != 1 ? scaledForVideoClock(sb) : sb)
            if !firstFrameSignaled && !hide {
                firstFrameSignaled = true
                DispatchQueue.main.async { self.seekShown(gen) }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { self.onEvent?(.firstFrame) }
                if scrubHold { videoRenderer.stopRequestingMediaData(); return }
            }
            resumeAudioIfThrottled(gen)
        }
    }

    /// Sample-accurate audio clock. Container timestamps are rounded (Matroska: 1 ms), so consecutive
    /// audio buffers would otherwise start up to ±1.7 ms off where the previous one ended, and the renderer
    /// honours that literally (tiny gaps/overlaps = crackle/stutter). We chain buffers back-to-back and only
    /// resync to the container clock on a real discontinuity (seek, gap > 100 ms).
    private var audioNext: CMTime?

    private func continuousAudio(_ sb: CMSampleBuffer) -> CMSampleBuffer {
        guard let asbd = sb.formatDescription.flatMap({ CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee }),
              asbd.mSampleRate > 0 else { return sb }
        let rate = CMTimeScale(asbd.mSampleRate.rounded())
        let isPCM = asbd.mFormatID == kAudioFormatLinearPCM
        let perPacket = Int64(isPCM ? 1 : asbd.mFramesPerPacket)
        guard perPacket > 0 else { audioNext = nil; return sb }   // variable-size packets: keep container timing
        let frames = Int64(CMSampleBufferGetNumSamples(sb)) * perPacket
        let pts = sb.presentationTimeStamp.convertScale(rate, method: .roundHalfAwayFromZero)
        var start = pts
        if ProcessInfo.processInfo.environment["LP_NO_AUDIO_RETIME"] != nil { return sb }
        if let next = audioNext, abs((pts - next).seconds) < 0.1 { start = next } else if audioNext != nil { dbgResyncs += 1 }
        dbgDrift = max(dbgDrift, abs((start - pts).seconds) * 1000)
        audioNext = start + CMTime(value: frames, timescale: rate)
        guard start != sb.presentationTimeStamp else { return sb }
        var timing = CMSampleTimingInfo(duration: CMTime(value: perPacket, timescale: rate), presentationTimeStamp: start, decodeTimeStamp: .invalid)
        var out: CMSampleBuffer?
        CMSampleBufferCreateCopyWithNewTiming(allocator: nil, sampleBuffer: sb, sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleBufferOut: &out)
        return out ?? sb
    }

    static let videoDebug = ProcessInfo.processInfo.environment["LP_VIDEO_DEBUG"] != nil
    private var vdbg: (n: Int, offGrid: Int, nonMono: Int, lastDTS: CMTime, maxErr: Double) = (0, 0, 0, .invalid, 0)
    private func debugVideo(_ sb: CMSampleBuffer) {
        let pts = sb.presentationTimeStamp, dts = sb.decodeTimeStamp, d = sb.duration
        if d.isValid, d.seconds > 0 {
            let idx = (pts.seconds / d.seconds).rounded()
            let err = abs(pts.seconds - idx * d.seconds) * 1000
            vdbg.maxErr = max(vdbg.maxErr, err)
            if err > 0.001 { vdbg.offGrid += 1 }   // (assumes the stream starts at 0)
        }
        if dts.isValid, vdbg.lastDTS.isValid, dts < vdbg.lastDTS { vdbg.nonMono += 1 }
        if dts.isValid { vdbg.lastDTS = dts }
        vdbg.n += 1
        if vdbg.n == 300 {
            print(String(format: "VIDEODBG 300 frames: off-grid %d (max err %.3f ms), non-monotonic DTS %d, frame %.4f ms", vdbg.offGrid, vdbg.maxErr, vdbg.nonMono, d.seconds * 1000))
            fflush(stdout); vdbg = (0, 0, 0, vdbg.lastDTS, 0)
        }
    }

    static let audioDebug = ProcessInfo.processInfo.environment["LP_AUDIO_DEBUG"] != nil
    private var dbgExpected: Double?
    private var dbgDrift = 0.0, dbgResyncs = 0
    /// Bench-only: lets the harness sample what's on screen to measure frame pacing.
    var debugRenderer: AVSampleBufferVideoRenderer { videoRenderer }
    private var dbgGaps: [Double] = []
    private func debugAudio(_ sb: CMSampleBuffer) {
        guard let asbd = sb.formatDescription.flatMap({ CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee }) else { return }
        let n = Double(CMSampleBufferGetNumSamples(sb)) * Double(max(asbd.mFramesPerPacket, 1))
        let pts = sb.presentationTimeStamp.seconds
        if let e = dbgExpected { dbgGaps.append((pts - e) * 1000) }
        dbgExpected = pts + n / asbd.mSampleRate
        if dbgGaps.count == 400 {
            let nonzero = dbgGaps.filter { abs($0) > 0.01 }
            print(String(format: "AUDIODBG fmt=%@ n=%.0f gaps>0.01ms: %d/400, min %.3f max %.3f ms, drift vs container max %.2f ms, resyncs %d", asbd.mFormatID.fourCCString, n, nonzero.count, dbgGaps.min()!, dbgGaps.max()!, dbgDrift, dbgResyncs))
            dbgDrift = 0
            fflush(stdout); dbgGaps.removeAll()
        }
    }

    /// Re-times a video sample by the display-sync phase offset (a few ms).
    private func resumeAudioIfThrottled(_ gen: Int) {
        guard audioThrottled, eof || lastAudioPTS < lastVideoPTS + Self.audioLeadOverVideo else { return }
        audioThrottled = false
        requestAudio(gen)
    }

    private func feedAudio(_ gen: Int) {
        guard gen == generation else { return }
        if scrubHold { audioRenderer.stopRequestingMediaData(); return }
        while audioRenderer.isReadyForMoreMediaData {
            if hasVideo && !eof && lastAudioPTS > lastVideoPTS + Self.audioLeadOverVideo {
                audioThrottled = true
                audioRenderer.stopRequestingMediaData()
                return
            }
            guard let sb = nextAudio() else {
                if eof { audioRenderer.stopRequestingMediaData() }
                return
            }
            let pts = sb.presentationTimeStamp.seconds
            if let t = audioCutoff {
                if pts + sb.duration.seconds.finiteOrZero < t { continue }
                audioCutoff = nil
            }
            let timed = continuousAudio(sb)
            lastAudioPTS = timed.presentationTimeStamp.seconds
            if Self.audioDebug { debugAudio(timed) }
            audioRenderer.enqueue(timed)
        }
    }

    // Software-decoded output waiting for the renderer. Decoding happens only when the renderer asks
    // for data, so at most one packet's worth of decoded frames ever sits here.
    private var decodedVideo: [CMSampleBuffer] = []
    private var decodedAudio: [CMSampleBuffer] = []
    private var videoDrained = false, audioDrained = false

    private func nextVideo() -> CMSampleBuffer? {
        if let hw = demuxer?.hwVideo { return hw.nextFrame(pull: { next(video: true) }, atEnd: { eof }) }
        guard let sw = demuxer?.swVideo else { return next(video: true) }
        while decodedVideo.isEmpty {
            if let sb = next(video: true) { decodedVideo = sw.decode(sb) }
            else if eof && !videoDrained { videoDrained = true; decodedVideo = sw.decode(nil); if decodedVideo.isEmpty { return nil } }
            else { return nil }
        }
        return decodedVideo.removeFirst()
    }

    private func nextAudio() -> CMSampleBuffer? {
        guard let sw = demuxer?.swAudio else { return next(video: false) }
        while decodedAudio.isEmpty {
            if let sb = next(video: false) { decodedAudio = sw.decode(sb) }
            else if eof && !audioDrained { audioDrained = true; decodedAudio = sw.decode(nil); if decodedAudio.isEmpty { return nil } }
            else { return nil }
        }
        return decodedAudio.removeFirst()
    }

    /// Pops the next sample for one renderer, demuxing (and stashing the other stream's samples) as needed.
    private func next(video: Bool) -> CMSampleBuffer? {
        if video, !videoPending.isEmpty { return videoPending.removeFirst() }
        if !video, !audioPending.isEmpty { return audioPending.removeFirst() }
        guard let demuxer, !eof else { return nil }
        while true {
            // Don't let one side run away if the other renderer is stalled.
            if (video ? audioPending.count : videoPending.count) > Self.maxPending { return nil }
            guard let item = demuxer.readItem() else { eof = true; return nil }
            switch item {
            case .video(let sb): if video { return sb } else { videoPending.append(sb) }
            case .audio(let sb): if !video { return sb } else { audioPending.append(sb) }
            case .subtitle(let cue): cues.append(cue)
            case .bitmaps(let start, let end, let items): cues.appendBitmaps(start: start, end: end, items)
            }
        }
    }

    private func freePending() {
        videoPending.removeAll(); audioPending.removeAll()
        decodedVideo.removeAll(); decodedAudio.removeAll()
        audioNext = nil
        videoDrained = false; audioDrained = false
        lastVideoPTS = 0; lastAudioPTS = 0
    }

    private func checkEnded() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, self.eof, self._duration > 0, self.currentTime >= self._duration - 1 else { return }
            self.onEvent?(.ended)
        }
    }
}
