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
        synchronizer.addRenderer(displayLayer)
        synchronizer.addRenderer(audioRenderer)
    }

    var currentTime: Double { synchronizer.currentTime().seconds.finiteOrZero }
    var duration: Double { _duration }
    var isPlaying: Bool { synchronizer.rate != 0 }
    var volume: Float {
        get { audioRenderer.volume }
        set { audioRenderer.volume = newValue }
    }

    let cues = CueStore()
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
                _subtitleTracks = d.subtitleStreams
                demuxer = d
                _duration = d.duration
                let w = d.warnings.map(EngineWarning.init)
                let n = d.notices
                DispatchQueue.main.async { self.warnings = w; self.notices = n; self.onEvent?(.ready) }
                if d.videoIndex < 0 && d.audioIndex < 0 {
                    DispatchQueue.main.async { self.onEvent?(.failed("No playable streams")) }
                    return
                }
                observers.append(NotificationCenter.default.addObserver(forName: AVSampleBufferVideoRenderer.didFailToDecodeNotification, object: videoRenderer, queue: .main) { n in
                    let err = n.userInfo?[AVSampleBufferVideoRenderer.didFailToDecodeNotificationErrorKey]
                    self.onEvent?(.failed("video decode failed: \(String(describing: err))"))
                })
                startFeeding()
            } catch {
                DispatchQueue.main.async { self.onEvent?(.failed("\(error)")) }
            }
        }
    }

    func play() {
        wantsPlay = true
        synchronizer.setRate(1, time: synchronizer.currentTime())
    }

    func pause() {
        wantsPlay = false
        synchronizer.rate = 0
    }

    func seek(to seconds: Double, accurate: Bool) {
        let target = max(0, min(seconds, _duration > 0 ? _duration - 0.5 : seconds))
        queue.async { [self] in
            guard let demuxer else { return }
            generation += 1
            let playing = wantsPlay
            synchronizer.setRate(0, time: CMTime(seconds: target, preferredTimescale: 90000))
            videoRenderer.flush()
            audioRenderer.flush()
            freePending()
            eof = false
            demuxer.seek(to: target)
            seekTarget = accurate ? target : nil
            audioCutoff = accurate ? target : nil
            firstFrameSignaled = false
            synchronizer.setRate(playing ? 1 : 0, time: CMTime(seconds: target, preferredTimescale: 90000))
            startFeeding()
        }
    }

    func close() {
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
            videoRenderer.enqueue(sb)
            if !firstFrameSignaled && !hide {
                firstFrameSignaled = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { self.onEvent?(.firstFrame) }
            }
            resumeAudioIfThrottled(gen)
        }
    }

    private func resumeAudioIfThrottled(_ gen: Int) {
        guard audioThrottled, eof || lastAudioPTS < lastVideoPTS + Self.audioLeadOverVideo else { return }
        audioThrottled = false
        requestAudio(gen)
    }

    private func feedAudio(_ gen: Int) {
        guard gen == generation else { return }
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
            lastAudioPTS = pts
            audioRenderer.enqueue(sb)
        }
    }

    // Software-decoded output waiting for the renderer. Decoding happens only when the renderer asks
    // for data, so at most one packet's worth of decoded frames ever sits here.
    private var decodedVideo: [CMSampleBuffer] = []
    private var decodedAudio: [CMSampleBuffer] = []
    private var videoDrained = false, audioDrained = false

    private func nextVideo() -> CMSampleBuffer? {
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
