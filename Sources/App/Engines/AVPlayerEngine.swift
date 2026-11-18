import AppKit
import AVFoundation
import AVKit
import MediaToolbox

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
    private var asset: AVURLAsset?
    private var subtitleAssetTracks: [Int32: AVAssetTrack] = [:]
    private var subtitleLoad: Task<Void, Never>?
    private var _subtitleTracks: [SubtitleTrackInfo] = []
    private var _naturalSize = CGSize.zero
    private static var registeredReaders = false

    init(useMediaExtensions: Bool) {
        kind = useMediaExtensions ? .avplayerExt : .avplayer
        if useMediaExtensions && !Self.registeredReaders {
            MTRegisterProfessionalVideoWorkflowFormatReaders()
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
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: false])
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
            if let g = try? await asset.loadMediaSelectionGroup(for: .legible) { item.select(nil, in: g) }
            self.observers.append(item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
                DispatchQueue.main.async {
                    guard let self else { return }
                    switch item.status {
                    case .readyToPlay: if !self.readySent { self.readySent = true; self.onEvent?(.ready) }
                    case .failed: self.onEvent?(.failed(item.error?.localizedDescription ?? "unknown error"))
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

    func close() {
        player.pause()
        player.replaceCurrentItem(with: nil)
        observers.removeAll()
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
    }

    func diagnostics() -> [String: String] {
        var d: [String: String] = [:]
        if let ext = asset?.mediaExtensionProperties { d["mediaExtension"] = ext.extensionIdentifier }
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
        hosted.frame = bounds
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
