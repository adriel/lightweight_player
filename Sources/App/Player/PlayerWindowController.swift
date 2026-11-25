import AppKit
import SwiftUI
import AVKit
import CoreImage
import UniformTypeIdentifiers
import Combine

/// One player window: owns the engine, the view hierarchy, keyboard/mouse handling and timers.
final class PlayerWindowController: NSWindowController, NSWindowDelegate, PlayerViewDelegate, ControlBarDelegate, NSMenuItemValidation {
    let playerView = PlayerView()
    private(set) var engine: PlayerEngine?
    private(set) var currentURL: URL?
    private let settings = Settings.shared
    private var uiTimer: Timer?
    private var hideTimer: Timer?
    private var controlsVisible = true
    private var muted = false
    private var subtitleTracks: [SubtitleTrackInfo] = []
    private var selectedSubtitle: Int?
    private var externalCues: [Int: [SubtitleCue]] = [:]
    private var pip: AVPictureInPictureController?
    private var pipDelegate: PiPDelegate?
    private var settingsObservers: [Any] = []
    private var lastResumeSave = Date()
    private var pendingResume: Double?
    var onClose: ((PlayerWindowController) -> Void)?
    private var openStarted = Date()
    private let titleTags = TitleTagsModel()
    private var tagObserver: AnyCancellable?
    /// Set by web links with `full_screen=1`.
    var enterFullScreenWhenReady = false
    private static let openDebug = ProcessInfo.processInfo.environment["LP_OPEN_DEBUG"] != nil

    init() {
        let window = PlayerWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 540),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                  backing: .buffered, defer: false)
        // IINA-style: filename + proxy icon on a dark translucent title bar over the video, hidden with the controls.
        window.titlebarAppearsTransparent = false
        window.titleVisibility = .visible
        window.appearance = NSAppearance(named: .darkAqua)
        window.isMovableByWindowBackground = false
        window.backgroundColor = .black
        window.collectionBehavior = [.fullScreenPrimary, .managed]
        window.minSize = NSSize(width: 480, height: 270)
        window.contentView = playerView
        window.center()
        window.setFrameAutosaveName("PlayerWindow")
        super.init(window: window)
        window.delegate = self
        window.keyHandler = { [weak self] e in self?.handleKey(e) ?? false }
        let tags = NSTitlebarAccessoryViewController()
        tags.layoutAttribute = .trailing
        tags.view = NSHostingView(rootView: TitleTagsView(model: titleTags))
        tags.view.frame.size = NSSize(width: 220, height: 28)
        window.addTitlebarAccessoryViewController(tags)
        tagsAccessory = tags
        titleTags.onRemoveCrop = { [weak self] in self?.removeCropForThisVideo() }
        let sb = playerView.sidebar.model
        sb.onPickAudio = { [weak self] id in self?.setAudioTrack(id) }
        sb.onPickSubtitle = { [weak self] id in self?.selectSubtitle(id) }
        sb.onLoadSubtitle = { [weak self] in self?.loadSubtitleFile() }
        sb.onClose = { [weak self] in self?.playerView.setSidebarShown(false) }
        titleTags.onCropSettings = { (NSApp.delegate as? AppDelegate)?.showSettings(nil) }
        // Re-fit the title and the tag area whenever a tag changes (so nothing runs off the right edge).
        tagObserver = titleTags.objectWillChange.sink { [weak self] _ in DispatchQueue.main.async { self?.fitTitle() } }
        window.fullScreenHandler = { [weak self] in self?.toggleFullScreen() }
        playerView.delegate = self
        playerView.controlBar.delegate = self
        playerView.controlBar.setVolume(settings.volume, muted: false)
        playerView.controlBar.setPiPAvailable(false)
        playerView.subtitleScale = settings.subtitleFontSize
        observeSettings()
        showControls()
    }
    required init?(coder: NSCoder) { fatalError() }

    // MARK: Opening

    func open(_ url: URL, forceSampleBufferEngine: Bool = false) {
        saveResumePosition()
        closeEngine()
        let reconnecting = liveReconnect && url == currentURL
        liveReconnect = false
        currentURL = url
        isLive = false
        playerView.controlBar.isLive = false
        if reconnecting {
            // Back to the live edge of the same camera: keep the window as the user left it.
            keepWindowSizeOnReady = true
            openStarted = Date()
            startEngine(SampleBufferEngine(), playing: url)
            return
        }
        titleTags.decoding = nil; titleTags.hdr = nil; titleTags.engine = nil; titleTags.audio = nil; titleTags.crop = nil
        let name = Self.isRTSP(url) ? Self.cameraTitle(url) : url.lastPathComponent.removingPercentEncoding ?? url.lastPathComponent
        PlaybackHistory.shared.didOpen(url, key: resumeKey(url), name: name)
        color = settings.colorAdjustment(for: resumeKey(url)) ?? (0, 1, 1)
        claimColorSliders()
        fullTitle = url.isFileURL ? url.lastPathComponent : Self.isRTSP(url) ? name : (url.lastPathComponent.removingPercentEncoding ?? url.absoluteString)
        fitTitle()
        window?.representedURL = url.isFileURL ? url : nil
        if url.isFileURL { NSDocumentController.shared.noteNewRecentDocumentURL(url) }

        openStarted = Date()
        pendingResume = settings.resumePlayback ? settings.resumePosition(for: resumeKey(url)) : nil
        window?.makeKeyAndOrderFront(nil)

        // YouTube / Twitch page: resolve the real stream with yt-dlp first (history keeps the page link).
        if SiteStreamResolver.handles(url) {
            resolving = url
            playerView.setBuffering((0, 0))
            playerView.flash("Opening \(url.host?.contains("twitch") == true ? "Twitch" : "YouTube") link…")
            SiteStreamResolver.resolve(url) { [weak self] result in
                guard let self, self.resolving == url, self.currentURL == url else { return }
                self.resolving = nil
                self.playerView.setBuffering(nil)
                switch result {
                case .success(let r):
                    self.fullTitle = r.title; self.fitTitle()
                    PlaybackHistory.shared.didOpen(url, key: self.resumeKey(url), name: r.title)
                    if r.isLive { self.pendingResume = nil }
                    let e: PlayerEngine
                    if r.isHLS {
                        // Twitch / live: HLS, which AVPlayer plays natively.
                        let a = AVPlayerEngine(useMediaExtensions: false)
                        a.httpHeaders = r.headers
                        e = a
                    } else {
                        // Direct files; YouTube's separate video + audio files go to the FFmpeg engine as two inputs.
                        let c = SampleBufferEngine()
                        c.separateAudioURL = r.audioURL
                        e = c
                    }
                    self.startEngine(e, playing: r.streamURL)
                case .failure(let f):
                    let a = NSAlert()
                    a.messageText = "Can't play this link"
                    a.informativeText = f.description
                    if let w = self.window { a.beginSheetModal(for: w) } else { a.runModal() }
                }
            }
            showControls()
            return
        }
        let e = forceSampleBufferEngine || ProcessInfo.processInfo.environment["LP_FORCE_C"] != nil ? SampleBufferEngine() : makeEngine(for: url)
        startEngine(e, playing: url)
    }

    private var resolving: URL?

    /// Live stream with no timeline (IP camera, live HLS): no seeking; resuming an RTSP camera reconnects.
    private var isLive = false
    private var liveReconnect = false
    private var keepWindowSizeOnReady = false

    static func isRTSP(_ url: URL) -> Bool { ["rtsp", "rtsps"].contains(url.scheme?.lowercased() ?? "") }

    /// "10.0.0.200 · Streaming/Channels/2" — the camera's address and stream path, never the sign-in.
    static func cameraTitle(_ url: URL) -> String {
        let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let host = url.host ?? "Camera"
        return path.isEmpty ? host : "\(host) · \(path.removingPercentEncoding ?? path)"
    }

    /// Reopen the current RTSP stream to jump back to real time (after a pause, or when the camera drops).
    private func reconnectLive(_ message: String) {
        guard let u = currentURL else { return }
        liveReconnect = true
        open(u)
        playerView.flash(message)
    }

    private func startEngine(_ e: PlayerEngine, playing url: URL) {
        engine = e
        startThumbnails(for: url, engine: e)
        e.volume = Float(muted ? 0 : settings.volume)
        playerView.setVideoView(e.view)
        applyColorAdjustments()
        e.onEvent = { [weak self] ev in self?.handle(ev) }
        e.cues.clear()
        e.open(url)
        startUITimer()
        showControls()
    }

    private func handle(_ ev: EngineEvent) {
        guard let engine else { return }
        switch ev {
        case .ready:
            if Self.openDebug { NSLog("open: ready after %.0f ms (%@)", Date().timeIntervalSince(openStarted) * 1000, String(describing: type(of: engine))) }
            (engine.view as? LayerHostView)?.videoSize = engine.naturalSize
            if keepWindowSizeOnReady { keepWindowSizeOnReady = false } else { sizeWindowToVideo() }
            if let u = currentURL, !u.isFileURL, !(engine.duration > 0) {
                isLive = true
                pendingResume = nil
                playerView.controlBar.isLive = true
            }
            startCropDetection()
            setupSubtitles()
            engine.setHDR(settings.hdrEnabled)
            settings.nowPlayingHDR = engine.isHDRVideo
            updateChapterMarkers()
            updateTitleTags()
            if enterFullScreenWhenReady { enterFullScreenWhenReady = false; if !isFullScreen { toggleFullScreen() } }
            if let t = pendingResume, t < engine.duration - 10 {
                engine.seek(to: t, accurate: false)
                playerView.flash("Resumed at \(formatTime(t))")
            }
            pendingResume = nil
            engine.play()
            for w in engine.warnings { playerView.flash("⚠︎ " + w.message); NSLog("warning: %@", w.message) }
            if engine.warnings.isEmpty, !engine.notices.isEmpty {
                playerView.flash(engine.notices.joined(separator: " · "))
                engine.notices.forEach { NSLog("notice: %@", $0) }
            }
            if !engine.warnings.isEmpty { showWarnings(engine.warnings) }
            setupPiP()
        case .firstFrame:
            if Self.openDebug { NSLog("open: first frame after %.0f ms", Date().timeIntervalSince(openStarted) * 1000) }
        case .failed(let msg):
            let a = NSAlert()
            a.messageText = "Can't play this file"
            a.informativeText = msg
            a.beginSheetModal(for: window!)
        case .needsFallback:
            if let u = currentURL {
                open(u, forceSampleBufferEngine: true)
                playerView.flash("Using built-in engine")
            }
        case .videoSizeChanged:
            (engine.view as? LayerHostView)?.videoSize = engine.naturalSize
            sizeWindowToVideo()
            startCropDetection()
        case .ended:
            if isLive, let u = currentURL, Self.isRTSP(u) {
                // The camera closed the stream (reboot, network blip): reconnect.
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                    guard let self, self.currentURL == u, self.isLive else { return }
                    self.reconnectLive("Reconnecting…")
                }
                return
            }
            if playerView.sidebar.model.loop, engine.duration > 0 {
                engine.seek(to: 0, accurate: true)
                engine.play()
                return
            }
            if let u = currentURL { settings.setResumePosition(nil, for: resumeKey(u)) }
            // Stay on the last frame, paused (like IINA), so the controls come back and Space plays it again.
            engine.pause()
            playerView.controlBar.update(time: engine.duration, duration: engine.duration, playing: false, buffered: engine.bufferedFractions)
            showControls()
        }
    }

    private func showWarnings(_ w: [EngineWarning]) {
        let a = NSAlert()
        a.alertStyle = .warning
        a.messageText = "Some parts of this file aren't supported"
        a.informativeText = w.map { "• " + $0.message }.joined(separator: "\n")
        a.addButton(withTitle: "OK")
        a.beginSheetModal(for: window!)
    }

    private func sizeWindowToVideo() {
        guard let window, let engine, !isFullScreen else { return }
        let size = displaySize(engine.naturalSize)
        guard size.width > 0, size.height > 0 else { return }
        // fullSizeContentView: the content view covers the whole frame, so frame size == video size.
        window.aspectRatio = size
        let screen = (window.screen ?? NSScreen.main)!.visibleFrame
        var w = min(size.width, screen.width * 0.8)
        var h = w * size.height / size.width
        if h > screen.height * 0.8 { h = screen.height * 0.8; w = h * size.width / size.height }
        let frame = NSRect(x: 0, y: 0, width: w.rounded(), height: h.rounded())
        var origin = NSPoint(x: window.frame.midX - frame.width / 2, y: window.frame.midY - frame.height / 2)
        origin.x = min(max(origin.x, screen.minX), screen.maxX - frame.width)
        origin.y = min(max(origin.y, screen.minY), screen.maxY - frame.height)
        window.setFrame(NSRect(origin: origin, size: frame.size), display: true, animate: false)
    }

    // MARK: Window size (⌘0 half, ⌘1 normal, ⌘2 double, ⌘3 fit — like IINA)
    // "Normal" = one video pixel per screen pixel (Retina-aware), clamped to the visible screen area.

    @objc func halfSize(_ sender: Any?) { setVideoScale(0.5, "Half size") }
    @objc func normalSize(_ sender: Any?) { setVideoScale(1, "Normal size") }
    @objc func doubleSize(_ sender: Any?) { setVideoScale(2, "Double size") }
    @objc func fitToScreen(_ sender: Any?) { setVideoScale(nil, "Fit to screen") }

    private func setVideoScale(_ k: Double?, _ label: String) {
        guard let window, let engine, !isFullScreen else { return }
        let px = displaySize(engine.naturalSize)
        guard px.width > 0, px.height > 0, let screen = window.screen ?? NSScreen.main else { return }
        let vf = screen.visibleFrame
        let fit = min(vf.width / px.width, vf.height / px.height)
        var f = k.map { $0 / screen.backingScaleFactor } ?? fit
        f = min(f, fit)
        var size = NSSize(width: (px.width * f).rounded(), height: (px.height * f).rounded())
        if size.width < window.minSize.width { size = NSSize(width: window.minSize.width, height: (window.minSize.width * px.height / px.width).rounded()) }
        var origin = NSPoint(x: window.frame.midX - size.width / 2, y: window.frame.midY - size.height / 2)
        if k == nil { origin = NSPoint(x: vf.midX - size.width / 2, y: vf.midY - size.height / 2) }
        origin.x = min(max(origin.x, vf.minX), vf.maxX - size.width)
        origin.y = min(max(origin.y, vf.minY), vf.maxY - size.height)
        window.setFrame(NSRect(origin: origin, size: size), display: true, animate: true)
        let shownScale = size.width / (px.width / screen.backingScaleFactor)
        playerView.flash(k == nil || abs(shownScale - (k ?? 0)) > 0.01 ? "\(label) (\(Int((shownScale * 100).rounded()))%)" : label)
    }

    // MARK: Black-bar crop

    private var cropDecider = CropDecider()
    private var cropTimer: Timer?
    private var cropSamples = 0
    private(set) var appliedCrop: CGRect?

    /// Video size as shown (after crop).
    private func displaySize(_ s: CGSize) -> CGSize {
        guard let c = appliedCrop else { return s }
        return CGSize(width: s.width * c.width, height: s.height * c.height)
    }

    var cropDescription: String {
        guard let c = appliedCrop, let size = engine?.naturalSize else { return settings.autoCrop ? "auto (no bars found)" : "off" }
        let kind = c.width < 0.98 && c.height < 0.98 ? "windowbox" : c.width < 0.98 ? "pillarbox" : "letterbox"
        return "\(Int(size.width * c.width))×\(Int(size.height * c.height)) — \(kind) removed"
    }

    private func startCropDetection() {
        cropTimer?.invalidate()
        cropDecider.reset()
        cropSamples = 0
        cropRemembered = false
        if let url = currentURL {
            // "Don't crop this video" from the Crop tag: leave it alone entirely.
            if settings.cropDisabled(for: resumeKey(url)) { cropRemembered = true; applyCrop(nil); return }
            // Known file: apply the remembered crop at once, but keep sampling — more picture can show up later.
            if let known = settings.rememberedCrop(for: resumeKey(url)) {
                if let k = known { cropDecider.seed(k) } else { cropDecider.seed(CGRect(x: 0, y: 0, width: 1, height: 1)) }
                applyCrop(settings.autoCrop ? known : nil)
                cropSamples = 4                      // skip the quick start-up samples
                scheduleCropSample()
                return
            }
        }
        applyCrop(nil)
        scheduleCropSample()
    }
    private var cropRemembered = false

    /// Samples at ~2, 6, 15, 40 s after start, then every 2 minutes (scene changes can reveal more picture).
    private func scheduleCropSample(confirmSoon: Bool = false) {
        let delays: [Double] = [2, 4, 9, 25, 45]
        let d = confirmSoon ? 4 : cropSamples < delays.count ? delays[cropSamples] : 120
        cropTimer?.invalidate()
        cropTimer = Timer.scheduledTimer(withTimeInterval: d, repeats: false) { [weak self] _ in self?.sampleCrop() }
    }

    private func sampleCrop() {
        guard let engine, settings.autoCrop, engine.isPlaying else { scheduleCropSample(); return }
        engine.snapshotFrame { [weak self] pb in
            guard let pb else { self?.cropSamples += 1; self?.scheduleCropSample(); return }
            DispatchQueue.global(qos: .utility).async {
                let r = BlackBarDetector.contentRect(pb)
                if let dir = ProcessInfo.processInfo.environment["LP_CROP_DEBUG"], let small = BlackBarDetector.downscaled(pb) {
                    let ci = CIImage(cvPixelBuffer: small)
                    let url = URL(fileURLWithPath: dir).appendingPathComponent(String(format: "crop_%.1f.png", engine.currentTime))
                    try? CIContext().writePNGRepresentation(of: ci, to: url, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
                    NSLog("crop sample at %.1f: %@", engine.currentTime, r.map { NSStringFromRect($0) } ?? "nil")
                }
                DispatchQueue.main.async {
                    guard let self, self.engine === engine else { return }
                    var newShape = false
                    if let r { newShape = self.cropDecider.add(r, at: engine.currentTime) }
                    self.cropSamples += 1
                    self.updateCrop()
                    // A bigger picture area than the current crop: check again shortly to confirm it.
                    self.scheduleCropSample(confirmSoon: newShape)
                }
            }
        }
    }

    private func updateCrop() {
        if cropRemembered { applyCrop(nil); return }        // cropping turned off for this video
        let decided = cropDecider.decision
        let d = settings.autoCrop ? decided : nil
        // Remember the decision once there's evidence (samples or a seed), so reopening applies it at once.
        if let url = currentURL, cropDecider.validSamples >= 2 {
            let stored = settings.rememberedCrop(for: resumeKey(url))
            if stored == nil || stored! != decided { settings.rememberCrop(decided, for: resumeKey(url)) }
        }
        func close(_ a: CGRect?, _ b: CGRect?) -> Bool {
            switch (a, b) {
            case (nil, nil): return true
            case let (x?, y?): return abs(x.minX - y.minX) < 0.005 && abs(x.minY - y.minY) < 0.005 && abs(x.width - y.width) < 0.005 && abs(x.height - y.height) < 0.005
            default: return false
            }
        }
        guard !close(d, appliedCrop) else { return }
        NSLog("crop: %@ after %d valid samples", d.map { NSStringFromRect($0) } ?? "none", cropDecider.validSamples)
        applyCrop(d)
        if d != nil { playerView.flash("Cropped black bars") }
    }

    private func applyCrop(_ c: CGRect?) {
        appliedCrop = c
        (engine?.view as? LayerHostView)?.crop = c
        playerView.crop = c
        adjustWindowAspect()
        titleTags.crop = c == nil ? nil : cropDescription
    }

    /// From the title bar's Crop tag: show the whole picture for this video and remember that choice.
    private func removeCropForThisVideo() {
        cropTimer?.invalidate()
        if let u = currentURL { settings.setCropDisabled(true, for: resumeKey(u)) }
        cropRemembered = true
        applyCrop(nil)
        playerView.flash("Showing the full picture")
    }

    /// Keep the window height and change its width to the (cropped) video aspect.
    private func adjustWindowAspect() {
        guard let window, let engine, !isFullScreen else { return }
        let size = displaySize(engine.naturalSize)
        guard size.width > 0, size.height > 0 else { return }
        window.aspectRatio = size
        let screen = (window.screen ?? NSScreen.main)!.visibleFrame
        var f = window.frame
        let w = min(f.height * size.width / size.height, screen.width)
        let h = w * size.height / size.width
        f.origin.x += (f.width - w) / 2
        f.origin.y += (f.height - h) / 2
        f.size = NSSize(width: w.rounded(), height: h.rounded())
        f.origin.x = min(max(f.origin.x, screen.minX), screen.maxX - f.width)
        window.animator().setFrame(f, display: true)
    }

    private func closeEngine() {
        cropTimer?.invalidate()
        pip?.stopPictureInPicture()
        pip = nil
        engine?.close()
        engine = nil
        stopThumbnails()
        playerView.setVideoView(nil)
        playerView.showSubtitle(nil)
        uiTimer?.invalidate(); uiTimer = nil
    }

    // MARK: UI timer (4 Hz while visible, subtitles 10 Hz while active)

    private func startUITimer() {
        uiTimer?.invalidate()
        let t = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in self?.tick() }
        t.tolerance = 0.03
        RunLoop.main.add(t, forMode: .common)
        uiTimer = t
    }

    private var tickCount = 0
    private func tick() {
        guard let engine else { return }
        tickCount += 1
        let now = engine.currentTime
        playerView.setBuffering(engine.buffering)
        if selectedSubtitle != nil {
            playerView.showSubtitle(engine.cues.text(at: now))
            playerView.showBitmaps(engine.cues.bitmaps(at: now), videoSize: engine.naturalSize)
        }
        // Control bar only needs ~4 Hz, and nothing at all while hidden.
        if controlsVisible && tickCount % 2 == 0 {
            playerView.controlBar.update(time: now, duration: engine.duration, playing: engine.isPlaying, buffered: engine.bufferedFractions)
        }
        if Date().timeIntervalSince(lastResumeSave) > 15 { saveResumePosition() }
    }

    private func resumeKey(_ url: URL) -> String { url.isFileURL ? url.path : url.absoluteString.components(separatedBy: "@").last ?? url.absoluteString }

    private func saveResumePosition() {
        lastResumeSave = Date()
        guard let engine, let url = currentURL, engine.duration > 0 else { return }
        let t = engine.currentTime
        PlaybackHistory.shared.updateProgress(key: resumeKey(url), position: t, duration: engine.duration)
        guard settings.resumePlayback else { return }
        settings.setResumePosition(t > 5 && t < engine.duration - 10 ? t : nil, for: resumeKey(url))
    }

    // MARK: Controls visibility

    func playerViewMouseActivity() { showControls() }

    /// Pointer left the player: hide the controls straight away, playing or paused (like IINA).
    func playerViewMouseExited() {
        guard engine != nil, !titleTags.hovering, !isFullScreen else { return }
        hideTimer?.invalidate()
        hideTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: false) { [weak self] _ in
            guard let self, let window = self.window else { return }
            // Still outside (not just passing over the title bar or a tag panel)?
            if !window.frame.contains(NSEvent.mouseLocation) && !self.titleTags.hovering { self.hideControlsNow() }
        }
    }

    private func hideControlsNow() {
        guard controlsVisible else { return }
        controlsVisible = false
        playerView.setControlsVisible(false, animated: true)
        setTitlebarVisible(false)
    }

    /// Trackpad pinch: scale the window around its centre, keeping the video's aspect and staying on screen.
    func playerViewMagnify(_ factor: CGFloat, ended: Bool) {
        guard let window, !isFullScreen, engine != nil, let screen = window.screen ?? NSScreen.main else { return }
        let f = window.frame
        let vf = screen.visibleFrame
        var w = f.width * factor
        let aspect = f.height / max(f.width, 1)
        w = min(max(w, window.minSize.width), vf.width)
        var h = w * aspect
        if h > vf.height { h = vf.height; w = h / aspect }
        var r = NSRect(x: f.midX - w / 2, y: f.midY - h / 2, width: w.rounded(), height: h.rounded())
        r.origin.x = min(max(r.origin.x, vf.minX), vf.maxX - r.width)
        r.origin.y = min(max(r.origin.y, vf.minY), vf.maxY - r.height)
        window.setFrame(r, display: true)
    }

    private func showControls() {
        if !controlsVisible {
            controlsVisible = true
            playerView.setControlsVisible(true, animated: true)
            setTitlebarVisible(true)
            if let engine { playerView.controlBar.update(time: engine.currentTime, duration: engine.duration, playing: engine.isPlaying, buffered: engine.bufferedFractions) }
        }
        hideTimer?.invalidate()
        hideTimer = Timer.scheduledTimer(withTimeInterval: settings.controlsHideDelay, repeats: false) { [weak self] _ in self?.hideControlsIfIdle() }
    }

    private func hideControlsIfIdle() {
        guard let window, engine != nil else { return }
        // Keep visible while the pointer is over the bar or a title tag (playing or paused).
        let p = playerView.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        if playerView.controlBar.frame.contains(p) || titleTags.hovering {
            hideTimer = Timer.scheduledTimer(withTimeInterval: settings.controlsHideDelay, repeats: false) { [weak self] _ in self?.hideControlsIfIdle() }
            return
        }
        controlsVisible = false
        playerView.setControlsVisible(false, animated: true)
        setTitlebarVisible(false)
        if isFullScreen { NSCursor.setHiddenUntilMouseMoves(true) }
    }

    private func setTitlebarVisible(_ v: Bool) {
        guard let bar = window?.standardWindowButton(.closeButton)?.superview?.superview else { return }
        NSAnimationContext.runAnimationGroup { $0.duration = 0.25; bar.animator().alphaValue = v ? 1 : 0 }
    }

    // MARK: Keyboard

    private func handleKey(_ e: NSEvent) -> Bool {
        let mods = e.modifierFlags.intersection([.command, .option, .control])
        guard mods.isEmpty else { return false }
        let shift = e.modifierFlags.contains(.shift)
        switch e.keyCode {
        case 123: skip(-(shift ? settings.longSeekStep : settings.seekStep), held: e.isARepeat); return true   // ←
        case 124: skip(shift ? settings.longSeekStep : settings.seekStep, held: e.isARepeat); return true      // →
        case 126: changeVolume(settings.volumeStep / 100); return true                       // ↑
        case 125: changeVolume(-settings.volumeStep / 100); return true                      // ↓
        case 49: togglePlay(); return true                                                    // space
        case 53:                                                                              // esc
            if playerView.isSidebarShown { playerView.setSidebarShown(false); return true }
            if isFullScreen { toggleFullScreen(); return true }
            return false
        default: break
        }
        switch e.charactersIgnoringModifiers?.lowercased() {
        case "f": toggleFullScreen(); return true
        case "m": controlBarToggleMute(); return true
        case "c": toggleAutoCrop(nil); return true
        case "l": toggleLoop(nil); return true
        case "s": cycleSubtitles(); return true
        case "a": cycleAudioTrack(nil); return true
        case ".": stepForward(nil); return true
        case ",": stepBackward(nil); return true
        default: break
        }
        switch e.keyCode {
        case 116: previousChapter(nil); return true     // Page Up (fn+↑)
        case 121: nextChapter(nil); return true         // Page Down (fn+↓)
        default: return false
        }
    }

    /// IINA-style OSD time: "05:18", "1:02:03".
    private func osdTime(_ t: Double) -> String {
        let s = Int(max(0, t.isFinite ? t : 0))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%02d:%02d", s / 60, s % 60)
    }

    /// Target of the last skip; consecutive skips build on it (the engine's clock lags behind requests).
    private var skipBase: Double?
    private var skipBaseTimer: Timer?

    func skip(_ s: Double, held: Bool = false) {
        guard let engine, !isLive else { return }
        let now = engine.currentTime
        // Forward keyframe seeks may land past the target: never step back behind where we already are.
        let base = skipBase.map { s > 0 ? max($0, now) : $0 } ?? now
        let target = min(max(0, base + s), max(0, engine.duration - 0.5))
        skipBase = target
        skipBaseTimer?.invalidate()
        skipBaseTimer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: false) { [weak self] _ in self?.skipBase = nil }
        if held { engine.scrub(to: target, forward: s > 0) }
        else { engine.seek(to: target, accurate: settings.accurateSeek) }
        playerView.flash(primary: osdTime(target), secondary: osdTime(engine.duration),
                         progress: engine.duration > 0 ? target / engine.duration : 0)
    }

    private func changeVolume(_ delta: Double) {
        muted = false
        settings.volume = min(max(settings.volume + delta, 0), 1)
        engine?.volume = Float(settings.volume)
        playerView.controlBar.setVolume(settings.volume, muted: false)
        playerView.flash(primary: "Volume: \(Int((settings.volume * 100).rounded()))", secondary: "", progress: settings.volume)
    }

    @objc func togglePlay() {
        guard let engine else { return }
        if engine.isPlaying { engine.pause() }
        else if isLive, let u = currentURL, Self.isRTSP(u) {
            // A paused camera would resume from where it stopped, minutes behind: jump back to now.
            reconnectLive("Live")
            return
        }
        else {
            // At the end: start again from the beginning.
            if engine.duration > 0, engine.currentTime >= engine.duration - 0.25 { engine.seek(to: 0, accurate: true) }
            engine.play()
        }
        playerView.controlBar.update(time: engine.currentTime, duration: engine.duration, playing: engine.isPlaying, buffered: engine.bufferedFractions)
        showControls()
    }

    // MARK: ControlBarDelegate

    func controlBarTogglePlay() { togglePlay() }
    func controlBarSkip(_ seconds: Double) { skip(seconds) }
    func controlBarSeek(fraction: Double, final: Bool) {
        guard let engine, engine.duration > 0 else { return }
        // While dragging: fast keyframe seeks (throttled); on release: accurate seek.
        let t = fraction * engine.duration
        if final { engine.seek(to: t, accurate: settings.accurateSeek) }
        else if Date().timeIntervalSince(lastScrub) > 0.12 { lastScrub = Date(); engine.seek(to: t, accurate: false) }
    }
    private var lastScrub = Date.distantPast
    func controlBarVolume(_ v: Double) {
        muted = false
        settings.volume = v
        engine?.volume = Float(v)
    }
    func controlBarToggleMute() {
        muted.toggle()
        engine?.volume = muted ? 0 : Float(settings.volume)
        playerView.controlBar.setVolume(settings.volume, muted: muted)
        playerView.flash(muted ? "Muted" : "🔊 \(Int(settings.volume * 100))%")
    }
    func controlBarTimeString(at fraction: Double) -> String {
        let t = fraction * (engine?.duration ?? 0)
        guard let ch = engine?.chapters.last(where: { $0.start <= t + 0.01 }) else { return formatTime(t) }
        return formatTime(t) + "  " + ch.title
    }
    func controlBarHover(fraction: Double?) {
        guard let f = fraction, let gen = thumbnails, settings.thumbnailsEnabled,
              currentURL?.isFileURL == true || settings.thumbnailsForStreams,
              let d = engine?.duration, d > 0 else {
            hoverFraction = nil
            playerView.hideThumbnail()
            thumbnails?.forgetLastDelivered()
            return
        }
        hoverFraction = f
        playerView.moveThumbnail(to: f)
        let scale = settings.thumbnailSharp ? (window?.backingScaleFactor ?? 2) : 1
        gen.request(time: f * d, maxPixels: Int(CGFloat(settings.thumbnailSize) * scale))
    }

    // MARK: Seek-bar thumbnails

    private var thumbnails: ThumbnailGenerator?
    private var hoverFraction: Double?

    private func startThumbnails(for url: URL, engine e: PlayerEngine) {
        stopThumbnails()
        // HLS (Twitch / live) has no file to seek in; everything else goes through FFmpeg demux + VideoToolbox.
        let hls = url.pathExtension.lowercased() == "m3u8" || (!url.isFileURL && e is AVPlayerEngine)
        guard !hls, url.isFileURL || url.scheme?.hasPrefix("http") == true else { return }
        let gen = ThumbnailGenerator(url: url, applyRotation: e is AVPlayerEngine)
        gen.onThumbnail = { [weak self] image, _ in
            guard let self, let f = self.hoverFraction, self.settings.thumbnailsEnabled else { return }
            self.playerView.showThumbnail(image, at: f, points: CGFloat(self.settings.thumbnailSize))
        }
        thumbnails = gen
    }

    private func stopThumbnails() {
        guard let gen = thumbnails else { return }
        gen.close()
        thumbnails = nil
        hoverFraction = nil
        playerView.hideThumbnail()
        ThumbnailCache.trimToSettings()
    }

    func controlBarShowSettings() { (NSApp.delegate as? AppDelegate)?.showSettings(nil) }
    func controlBarTogglePiP() {
        guard let pip else { return }
        if pip.isPictureInPictureActive { pip.stopPictureInPicture() } else { pip.startPictureInPicture() }
    }

    func controlBarShowSubtitleMenu(from view: NSView) {
        let menu = NSMenu()
        if let tracks = engine?.audioTracks, tracks.count > 1 {
            menu.addItem(NSMenuItem.sectionHeader(title: "Audio"))
            for item in audioTrackItems() { menu.addItem(item) }
            menu.addItem(.separator())
            menu.addItem(NSMenuItem.sectionHeader(title: "Subtitles"))
        }
        let off = NSMenuItem(title: "Off", action: #selector(pickSubtitle(_:)), keyEquivalent: "")
        off.tag = -1; off.target = self; off.state = selectedSubtitle == nil ? .on : .off
        menu.addItem(off)
        menu.addItem(.separator())
        for t in subtitleTracks {
            let item = NSMenuItem(title: t.displayName, action: t.kind != .unsupported ? #selector(pickSubtitle(_:)) : nil, keyEquivalent: "")
            item.tag = t.id; item.target = self
            item.state = selectedSubtitle == t.id ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let load = NSMenuItem(title: "Load Subtitle File…", action: #selector(loadSubtitleFile), keyEquivalent: "")
        load.target = self
        menu.addItem(load)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: view.bounds.height + 4), in: view)
    }

    /// Sliders button: toggles the sidebar on its Video tab (switches to it if another tab is showing).
    func controlBarShowVideoAdjust(from view: NSView) {
        let sb = playerView.sidebar.model
        if playerView.isSidebarShown && sb.tab == .video { playerView.setSidebarShown(false); return }
        sb.tab = .video
        showSidebar()
    }

    private func showSidebar() {
        refreshSidebar()
        playerView.setSidebarShown(true)
    }

    @objc func toggleSettingsSidebar(_ sender: Any?) {
        if playerView.isSidebarShown { playerView.setSidebarShown(false) } else { showSidebar() }
    }

    /// Keeps the sidebar's track lists in step with the engine and the current selections.
    private func refreshSidebar() {
        let sb = playerView.sidebar.model
        sb.audioTracks = (engine?.audioTracks ?? []).map { .init(id: $0.id, name: $0.displayName, detail: "") }
        sb.selectedAudio = engine?.selectedAudioTrack
        sb.subtitleTracks = subtitleTracks.map { .init(id: $0.id, name: $0.displayName, detail: $0.codec.uppercased(), enabled: $0.kind != .unsupported) }
        sb.selectedSubtitle = selectedSubtitle
    }

    // MARK: Subtitles

    private func setupSubtitles() {
        guard let engine else { return }
        subtitleTracks = engine.subtitleTracks
        externalCues.removeAll()
        if let url = currentURL, settings.loadSidecarSubtitles {
            for (i, f) in SubtitleFileParser.sidecars(for: url).enumerated() {
                let name = f.deletingPathExtension().lastPathComponent.lowercased()
                let id = 10_000 + i
                externalCues[id] = SubtitleFileParser.parse(f)
                subtitleTracks.append(SubtitleTrackInfo(id: id, title: f.lastPathComponent, language: nil, codec: f.pathExtension,
                                                        isForced: name.contains("forced"), isDefault: false, kind: .text, externalURL: f))
            }
        }
        // Default: hidden unless a forced track exists (per settings).
        let text = subtitleTracks.filter { $0.kind != .unsupported }
        var pick: SubtitleTrackInfo?
        switch settings.subtitleMode {
        case .forcedOnly: pick = text.first { $0.isForced } ?? text.first { $0.title.localizedCaseInsensitiveContains("forced") }
        case .always: pick = text.first { $0.isDefault } ?? text.first
        case .never: pick = nil
        }
        selectSubtitle(pick?.id)

    }

    private func selectSubtitle(_ id: Int?) {
        selectedSubtitle = id
        defer { refreshSidebar() }
        playerView.showSubtitle(nil)
        playerView.showBitmaps([], videoSize: .zero)
        playerView.controlBar.setSubtitlesActive(id != nil)
        guard let engine else { return }
        if let id, let cues = externalCues[id] {
            engine.selectSubtitle(nil)
            engine.cues.replaceAll(cues)
        } else {
            engine.cues.clear()
            engine.selectSubtitle(id)
        }
    }

    @objc private func pickSubtitle(_ item: NSMenuItem) { selectSubtitle(item.tag < 0 ? nil : item.tag) }

    // MARK: Title bar tags

    /// AppKit doesn't shorten the title to leave room for trailing accessories, so do it here (middle ellipsis):
    /// the title gets everything between the proxy icon and the tags.
    private var fullTitle = ""
    private var tagsAccessory: NSTitlebarAccessoryViewController?
    private func fitTitle() {
        guard let window, !fullTitle.isEmpty else { return }
        // Size the accessory to its tags, then keep the centred title clear of it (and of the traffic lights).
        if let v = tagsAccessory?.view { let w = max(1, v.fittingSize.width); if abs(v.frame.width - w) > 1 { v.frame.size.width = w } }
        // The title is leading-aligned (after the traffic lights and proxy icon) and runs up to the tags.
        let leading = (window.standardWindowButton(.zoomButton)?.frame.maxX ?? 70) + 34     // buttons + proxy icon
        let trailing = (tagsAccessory?.view.frame.width ?? 0) + 16
        let available = window.frame.width - leading - trailing
        let font = NSFont.titleBarFont(ofSize: NSFont.systemFontSize)
        func width(_ s: String) -> CGFloat { (s as NSString).size(withAttributes: [.font: font]).width }
        var title = fullTitle
        if width(title) > available, available > 60 {
            var keep = fullTitle.count
            while keep > 8, width(title) > available {
                keep -= 2
                title = String(fullTitle.prefix(keep / 2)) + "…" + String(fullTitle.suffix(keep - keep / 2))
            }
        }
        if window.title != title { window.title = title }
    }
    func windowDidResize(_ notification: Notification) { fitTitle() }

    private func updateTitleTags() {
        titleTags.decoding = engine?.videoDecoding; titleTags.hdr = engine?.hdrFormat; titleTags.hdrOutput = settings.hdrEnabled
        titleTags.audio = engine?.audioDecoding
        if let e = engine { titleTags.engine = (e.kind.tagName, e.mediaInfo.engine.isEmpty ? e.kind.label : e.mediaInfo.engine) }
        titleTags.edrHeadroom = Double(window?.screen?.maximumPotentialExtendedDynamicRangeColorComponentValue ?? 1)
        DispatchQueue.main.async { [weak self] in self?.fitTitle() }
        // AVFoundation fills these in asynchronously; refresh once more shortly after.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            guard let self, let e = self.engine else { return }
            self.titleTags.decoding = e.videoDecoding; self.titleTags.hdr = e.hdrFormat; self.titleTags.audio = e.audioDecoding
            if !e.mediaInfo.engine.isEmpty { self.titleTags.engine = (e.kind.tagName, e.mediaInfo.engine) }
            self.fitTitle()
        }
    }

    // MARK: Auto-crop toggle (C, View menu, brightness popover)

    /// Loop the current video (Playback › Loop, L, or the sidebar switch).
    @objc func toggleLoop(_ sender: Any?) {
        let sb = playerView.sidebar.model
        sb.loop.toggle()
        playerView.flash(sb.loop ? "Loop: on" : "Loop: off")
    }

    @objc func toggleAutoCrop(_ sender: Any?) {
        settings.autoCrop.toggle()          // applied to every window by the settings observer
        playerView.flash(settings.autoCrop ? "Crop black bars: on" : "Crop black bars: off")
    }

    private func autoCropChanged() {
        if settings.autoCrop && !cropRemembered && cropDecider.validSamples < 2 { sampleCrop() }
        updateCrop()
    }

    // MARK: File menu

    /// "Show Current File in Finder" only for local files; everything else stays enabled.
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(showCurrentFileInFinder(_:)) { return currentURL?.isFileURL == true }
        if item.action == #selector(toggleAutoCrop(_:)) { item.state = settings.autoCrop ? .on : .off }
        if item.action == #selector(toggleLoop(_:)) { item.state = playerView.sidebar.model.loop ? .on : .off; return engine != nil }
        return true
    }

    @objc func showCurrentFileInFinder(_ sender: Any?) {
        guard let u = currentURL, u.isFileURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([u])
    }

    // MARK: Audio tracks

    func audioTrackItems() -> [NSMenuItem] {
        guard let engine else { return [] }
        return engine.audioTracks.map { t in
            let i = NSMenuItem(title: t.displayName, action: #selector(pickAudioTrack(_:)), keyEquivalent: "")
            i.tag = t.id; i.target = self
            i.state = engine.selectedAudioTrack == t.id ? .on : .off
            return i
        }
    }
    @objc private func pickAudioTrack(_ item: NSMenuItem) { setAudioTrack(item.tag) }
    @objc func cycleAudioTrack(_ sender: Any?) {
        guard let engine, engine.audioTracks.count > 1 else { playerView.flash("Only one audio track"); return }
        let ids = engine.audioTracks.map(\.id)
        let i = ids.firstIndex(of: engine.selectedAudioTrack ?? -1) ?? -1
        setAudioTrack(ids[(i + 1) % ids.count])
    }
    private func setAudioTrack(_ id: Int) {
        guard let engine, let t = engine.audioTracks.first(where: { $0.id == id }) else { return }
        engine.selectAudioTrack(id)
        playerView.flash("Audio: " + t.displayName)
        refreshSidebar()
    }

    // MARK: Frame step & chapters

    private func updateChapterMarkers() {
        guard let engine, engine.duration > 0 else { return }
        playerView.controlBar.seek.markers = engine.chapters.map { $0.start / engine.duration }.filter { $0 > 0.001 && $0 < 0.999 }
        // AVFoundation loads chapters asynchronously; refresh once more shortly after.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self, let e = self.engine, e.duration > 0 else { return }
            self.playerView.controlBar.seek.markers = e.chapters.map { $0.start / e.duration }.filter { $0 > 0.001 && $0 < 0.999 }
        }
    }

    @objc func stepForward(_ sender: Any?) { step(true) }
    @objc func stepBackward(_ sender: Any?) { step(false) }
    private func step(_ forward: Bool) {
        guard let engine else { return }
        engine.stepFrame(forward: forward)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            guard let self, let e = self.engine else { return }
            self.playerView.flash(primary: self.osdTime(e.currentTime) + String(format: ".%02d", Int((e.currentTime.truncatingRemainder(dividingBy: 1)) * 100)),
                                  secondary: self.osdTime(e.duration), progress: e.duration > 0 ? e.currentTime / e.duration : 0)
        }
    }

    @objc func nextChapter(_ sender: Any?) {
        guard let engine else { return }
        let t = engine.currentTime
        guard let ch = engine.chapters.first(where: { $0.start > t + 0.5 }) else { playerView.flash("Last chapter"); return }
        jumpToChapter(ch)
    }
    @objc func previousChapter(_ sender: Any?) {
        guard let engine else { return }
        let t = engine.currentTime
        // Like a CD player: back to the start of this chapter, or the previous one if we're near its start.
        let before = engine.chapters.filter { $0.start < t - 2 }
        guard let ch = before.last ?? engine.chapters.first else { playerView.flash("No chapters"); return }
        jumpToChapter(ch)
    }
    @objc func pickChapter(_ item: NSMenuItem) {
        guard let engine, engine.chapters.indices.contains(item.tag) else { return }
        jumpToChapter(engine.chapters[item.tag])
    }
    private func jumpToChapter(_ ch: ChapterInfo) {
        guard let engine else { return }
        engine.seek(to: ch.start, accurate: true)
        playerView.flash(ch.title)
    }
    func chapterItems() -> [NSMenuItem] {
        guard let engine else { return [] }
        let t = engine.currentTime
        let current = engine.chapters.lastIndex { $0.start <= t + 0.01 }
        return engine.chapters.enumerated().map { i, ch in
            let item = NSMenuItem(title: "\(formatTime(ch.start))  \(ch.title)", action: #selector(pickChapter(_:)), keyEquivalent: "")
            item.tag = i; item.target = self; item.state = i == current ? .on : .off
            return item
        }
    }

    private func cycleSubtitles() {
        let ids: [Int?] = [nil] + subtitleTracks.filter { $0.kind == .text }.map(\.id)
        let i = ids.firstIndex(of: selectedSubtitle) ?? 0
        let next = ids[(i + 1) % ids.count]
        selectSubtitle(next)
        playerView.flash("Subtitles: " + (next.flatMap { id in subtitleTracks.first { $0.id == id }?.displayName } ?? "Off"))
    }

    @objc func loadSubtitleFile() {
        let p = NSOpenPanel()
        p.allowedContentTypes = ["srt", "vtt", "ass", "ssa"].compactMap { UTType(filenameExtension: $0) }
        p.beginSheetModal(for: window!) { [weak self] r in
            guard r == .OK, let u = p.url, let self else { return }
            let id = 10_000 + self.externalCues.count + 100
            self.externalCues[id] = SubtitleFileParser.parse(u)
            self.subtitleTracks.append(SubtitleTrackInfo(id: id, title: u.lastPathComponent, language: nil, codec: u.pathExtension, isForced: false, isDefault: false, kind: .text, externalURL: u))
            self.selectSubtitle(id)
        }
    }

    // MARK: Color adjustments (Core Image filters on the video layer — only attached when non-default)

    private func observeSettings() {
        let s = settings
        settingsObservers = [
            s.$brightness.sink { [weak self] _ in DispatchQueue.main.async { self?.colorSettingChanged() } },
            s.$gamma.sink { [weak self] _ in DispatchQueue.main.async { self?.colorSettingChanged() } },
            s.$contrast.sink { [weak self] _ in DispatchQueue.main.async { self?.colorSettingChanged() } },
            s.$subtitleFontSize.sink { [weak self] v in self?.playerView.subtitleScale = v },
            s.$autoCrop.dropFirst().sink { [weak self] _ in DispatchQueue.main.async { self?.autoCropChanged() } },
            s.$hdrEnabled.dropFirst().sink { [weak self] v in
                DispatchQueue.main.async { self?.engine?.setHDR(v); self?.titleTags.hdrOutput = v; self?.playerView.flash(v ? "HDR on" : "HDR off (tone-mapped to SDR)") }
            },
        ]
    }

    // Per-file colour adjustments: the shared sliders edit the frontmost player's file; each player keeps its own
    // values and saves them under its file.
    private var color = (brightness: 0.0, contrast: 1.0, gamma: 1.0)
    private var loadingColor = false

    /// Make the sliders show (and edit) this player's file.
    private func claimColorSliders() {
        if Self.openDebug { NSLog("color: %@ → b %.2f c %.2f g %.2f", currentURL?.lastPathComponent ?? "-", color.brightness, color.contrast, color.gamma) }
        settings.colorOwner = self
        loadingColor = true
        settings.brightness = color.brightness; settings.contrast = color.contrast; settings.gamma = color.gamma
        loadingColor = false
    }

    private func colorSettingChanged() {
        guard !loadingColor, settings.colorOwner === self else { return }
        color = (settings.brightness, settings.contrast, settings.gamma)
        if let u = currentURL { settings.setColorAdjustment(color, for: resumeKey(u)) }
        applyColorAdjustments()
    }

    private func applyColorAdjustments() {
        guard let host = engine?.view as? LayerHostView else { return }
        host.setColorAdjustments(brightness: color.brightness, contrast: color.contrast, gamma: color.gamma)
    }

    // MARK: PiP

    private func setupPiP() {
        guard AVPictureInPictureController.isPictureInPictureSupported() else { return }
        let d = PiPDelegate(owner: self)
        pipDelegate = d
        pip = engine?.makePiPController(sampleBufferDelegate: d)
        playerView.controlBar.setPiPAvailable(pip != nil)
    }

    final class PiPDelegate: NSObject, AVPictureInPictureSampleBufferPlaybackDelegate {
        weak var owner: PlayerWindowController?
        init(owner: PlayerWindowController) { self.owner = owner }
        func pictureInPictureController(_ c: AVPictureInPictureController, setPlaying playing: Bool) {
            if playing { owner?.engine?.play() } else { owner?.engine?.pause() }
        }
        func pictureInPictureControllerTimeRangeForPlayback(_ c: AVPictureInPictureController) -> CMTimeRange {
            CMTimeRange(start: .zero, duration: CMTime(seconds: owner?.engine?.duration ?? 0, preferredTimescale: 600))
        }
        func pictureInPictureControllerIsPlaybackPaused(_ c: AVPictureInPictureController) -> Bool { !(owner?.engine?.isPlaying ?? false) }
        func pictureInPictureController(_ c: AVPictureInPictureController, didTransitionToRenderSize newRenderSize: CMVideoDimensions) {}
        func pictureInPictureController(_ c: AVPictureInPictureController, skipByInterval skipInterval: CMTime) async {
            await MainActor.run { owner?.skip(skipInterval.seconds) }
        }
    }

    // MARK: Window

    func playerViewDoubleClicked() { toggleFullScreen() }

    // MARK: Full screen
    // Default ("live") full screen: the window becomes borderless and animates to fill the screen on the current
    // desktop, menu bar and Dock auto-hidden (IINA's "legacy" full screen). macOS's own full screen moves the
    // window to a new Space, and during that transition the system shows a frozen snapshot (~0.5 s, measured
    // with an on-screen timer) — here the real window animates, so the video keeps playing throughout.
    // "Full screen covers the camera notch" decides whether the picture extends beside the camera housing.

    private var liveFullScreen: (frame: NSRect, style: NSWindow.StyleMask, aspect: NSSize)?
    private var fullScreenAnimating = false
    var isFullScreen: Bool { liveFullScreen != nil || window?.styleMask.contains(.fullScreen) == true }

    func toggleFullScreen() {
        guard let window = window as? PlayerWindow, !fullScreenAnimating else { return }
        if let saved = liveFullScreen { exitLiveFullScreen(saved); return }
        if window.styleMask.contains(.fullScreen) || settings.nativeFullScreen { window.nativeToggleFullScreen(); return }
        if let screen = window.screen ?? NSScreen.main { enterLiveFullScreen(screen) }
    }

    private func enterLiveFullScreen(_ screen: NSScreen) {
        guard let window else { return }
        liveFullScreen = (window.frame, window.styleMask, window.aspectRatio)
        NSApp.presentationOptions = [.autoHideMenuBar, .autoHideDock]
        window.styleMask = [.borderless, .fullSizeContentView]
        window.resizeIncrements = NSSize(width: 1, height: 1)     // clears the aspect-ratio constraint
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(playerView)
        // Keep the picture below the camera housing unless the notch option is on (the strip stays black).
        playerView.videoTopInset = settings.fullScreenCoversNotch ? 0 : screen.safeAreaInsets.top
        animate(window, to: screen.frame) { [weak self] in self?.showControls() }
    }

    private func exitLiveFullScreen(_ saved: (frame: NSRect, style: NSWindow.StyleMask, aspect: NSSize)) {
        guard let window else { return }
        liveFullScreen = nil
        NSApp.presentationOptions = []
        playerView.videoTopInset = 0
        animate(window, to: saved.frame) { [weak self] in
            window.styleMask = saved.style
            // Going borderless for full screen drops the title bar's accessories, and restoring the title bar
            // doesn't bring them back: re-attach the tags.
            if let tags = self?.tagsAccessory, !window.titlebarAccessoryViewControllers.contains(tags) {
                window.addTitlebarAccessoryViewController(tags)
            }
            self?.fitTitle()
            if saved.aspect.width > 0 { window.aspectRatio = saved.aspect }
            window.makeFirstResponder(self?.playerView)
            self?.showControls()
        }
    }

    private func animate(_ window: NSWindow, to frame: NSRect, completion: @escaping () -> Void) {
        fullScreenAnimating = true
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.25
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            window.animator().setFrame(frame, display: true)
        }, completionHandler: { [weak self] in
            window.setFrame(frame, display: true)
            self?.fullScreenAnimating = false
            completion()
        })
    }
    func playerViewDropped(_ urls: [URL]) {
        if let sub = urls.first(where: { ["srt", "vtt", "ass", "ssa"].contains($0.pathExtension.lowercased()) }), engine != nil {
            let id = 20_000 + externalCues.count
            externalCues[id] = SubtitleFileParser.parse(sub)
            subtitleTracks.append(SubtitleTrackInfo(id: id, title: sub.lastPathComponent, language: nil, codec: sub.pathExtension, isForced: false, isDefault: false, kind: .text, externalURL: sub))
            selectSubtitle(id)
            playerView.flash("Loaded \(sub.lastPathComponent)")
        } else if let u = urls.first { open(u) }
    }

    func windowDidBecomeKey(_ notification: Notification) {
        if settings.colorOwner !== self { claimColorSliders() }
        if let engine { settings.nowPlayingHDR = engine.isHDRVideo }
    }

    func windowWillClose(_ notification: Notification) {
        settings.nowPlayingHDR = nil
        if liveFullScreen != nil { NSApp.presentationOptions = []; liveFullScreen = nil }
        saveResumePosition()
        closeEngine()
        hideTimer?.invalidate()
        onClose?(self)
    }
    func windowDidEnterFullScreen(_ notification: Notification) { showControls() }
    func windowDidExitFullScreen(_ notification: Notification) { showControls() }


}

/// Routes keys to the player before AppKit's default handling (so arrows don't beep).
final class PlayerWindow: NSWindow {
    var keyHandler: ((NSEvent) -> Bool)?
    override func keyDown(with event: NSEvent) {
        if keyHandler?(event) != true { super.keyDown(with: event) }
    }
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    /// Set by the controller so the menu item / green button also honour the notch setting.
    var fullScreenHandler: (() -> Void)?
    override func toggleFullScreen(_ sender: Any?) {
        if let fullScreenHandler { fullScreenHandler() } else { super.toggleFullScreen(sender) }
    }
    func nativeToggleFullScreen() { super.toggleFullScreen(nil) }
}
