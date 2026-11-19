import AppKit
import AVKit
import CoreImage
import UniformTypeIdentifiers
import Combine

/// One player window: owns the engine, the view hierarchy, keyboard/mouse handling and timers.
final class PlayerWindowController: NSWindowController, NSWindowDelegate, PlayerViewDelegate, ControlBarDelegate {
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
        currentURL = url
        window?.title = url.isFileURL ? url.lastPathComponent : (url.lastPathComponent.removingPercentEncoding ?? url.absoluteString)
        window?.representedURL = url.isFileURL ? url : nil
        if url.isFileURL { NSDocumentController.shared.noteNewRecentDocumentURL(url) }

        openStarted = Date()
        let e = forceSampleBufferEngine || ProcessInfo.processInfo.environment["LP_FORCE_C"] != nil ? SampleBufferEngine() : makeEngine(for: url)
        engine = e
        e.volume = Float(muted ? 0 : settings.volume)
        playerView.setVideoView(e.view)
        applyColorAdjustments()
        e.onEvent = { [weak self] ev in self?.handle(ev) }
        e.cues.clear()
        e.open(url)
        pendingResume = settings.resumePlayback ? settings.resumePosition(for: resumeKey(url)) : nil
        startUITimer()
        window?.makeKeyAndOrderFront(nil)
        showControls()
    }

    private func handle(_ ev: EngineEvent) {
        guard let engine else { return }
        switch ev {
        case .ready:
            if Self.openDebug { NSLog("open: ready after %.0f ms (%@)", Date().timeIntervalSince(openStarted) * 1000, String(describing: type(of: engine))) }
            (engine.view as? LayerHostView)?.videoSize = engine.naturalSize
            sizeWindowToVideo()
            startCropDetection()
            setupSubtitles()
            engine.setHDR(settings.hdrEnabled)
            settings.nowPlayingHDR = engine.isHDRVideo
            updateChapterMarkers()
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
        case .ended:
            if let u = currentURL { settings.setResumePosition(nil, for: resumeKey(u)) }
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
        // Known file: apply the remembered crop immediately and skip sampling entirely.
        if let url = currentURL, let known = settings.rememberedCrop(for: resumeKey(url)) {
            cropRemembered = true
            applyCrop(settings.autoCrop ? known : nil)
            return
        }
        cropRemembered = false
        applyCrop(nil)
        scheduleCropSample()
    }
    private var cropRemembered = false

    /// Samples at ~2, 6, 15, 40 s after start, then every 2 minutes (scene changes can reveal more picture).
    private func scheduleCropSample() {
        let delays: [Double] = [2, 4, 9, 25]
        let d = cropSamples < delays.count ? delays[cropSamples] : 120
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
                    if let r { self.cropDecider.add(r) }
                    self.cropSamples += 1
                    self.updateCrop()
                    self.scheduleCropSample()
                }
            }
        }
    }

    private func updateCrop() {
        if cropRemembered {
            // Toggle (C) on a remembered file: just switch the stored crop on/off.
            let known = currentURL.flatMap { settings.rememberedCrop(for: resumeKey($0)) } ?? nil
            applyCrop(settings.autoCrop ? known : nil)
            return
        }
        let d = settings.autoCrop ? cropDecider.decision : nil
        // Remember once the initial samples (2/6/15/40 s) are in, or whenever the decision changes later.
        if settings.autoCrop, let url = currentURL, cropDecider.validSamples >= 4 || (cropDecider.validSamples >= 2 && d != nil) {
            settings.rememberCrop(d, for: resumeKey(url))
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
        guard settings.resumePlayback, let engine, let url = currentURL, engine.duration > 0 else { return }
        let t = engine.currentTime
        settings.setResumePosition(t > 5 && t < engine.duration - 10 ? t : nil, for: resumeKey(url))
    }

    // MARK: Controls visibility

    func playerViewMouseActivity() { showControls() }

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
        // Keep visible while the pointer is over the bar or the app isn't playing.
        let p = playerView.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        if playerView.controlBar.frame.contains(p) || engine?.isPlaying == false {
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
            if isFullScreen { toggleFullScreen(); return true }
            return false
        default: break
        }
        switch e.charactersIgnoringModifiers?.lowercased() {
        case "f": toggleFullScreen(); return true
        case "m": controlBarToggleMute(); return true
        case "c":
            settings.autoCrop.toggle()
            if settings.autoCrop && !cropRemembered && cropDecider.validSamples < 2 { sampleCrop() }
            updateCrop()
            playerView.flash(settings.autoCrop ? "Auto-crop on" : "Auto-crop off")
            return true
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
        guard let engine else { return }
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
        if engine.isPlaying { engine.pause() } else { engine.play() }
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

    func controlBarShowVideoAdjust(from view: NSView) {
        let pop = NSPopover()
        pop.behavior = .transient
        pop.contentViewController = VideoAdjustViewController()
        pop.show(relativeTo: view.bounds, of: view, preferredEdge: .maxY)
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
            s.$brightness.sink { [weak self] _ in DispatchQueue.main.async { self?.applyColorAdjustments() } },
            s.$gamma.sink { [weak self] _ in DispatchQueue.main.async { self?.applyColorAdjustments() } },
            s.$contrast.sink { [weak self] _ in DispatchQueue.main.async { self?.applyColorAdjustments() } },
            s.$subtitleFontSize.sink { [weak self] v in self?.playerView.subtitleScale = v },
            s.$hdrEnabled.dropFirst().sink { [weak self] v in
                DispatchQueue.main.async { self?.engine?.setHDR(v); self?.playerView.flash(v ? "HDR on" : "HDR off (tone-mapped to SDR)") }
            },
        ]
    }

    private func applyColorAdjustments() {
        guard let host = engine?.view as? LayerHostView else { return }
        host.setColorAdjustments(brightness: settings.brightness, contrast: settings.contrast, gamma: settings.gamma)
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
    // macOS's full screen keeps the strip beside the camera notch black (the window sits below it). With
    // "Full screen covers the camera notch" we instead make the window borderless and exactly screen-sized,
    // with the menu bar and Dock auto-hidden (what IINA calls legacy full screen).

    private var notchFullScreen: (frame: NSRect, style: NSWindow.StyleMask, aspect: NSSize)?
    var isFullScreen: Bool { notchFullScreen != nil || window?.styleMask.contains(.fullScreen) == true }

    func toggleFullScreen() {
        guard let window = window as? PlayerWindow else { return }
        if let saved = notchFullScreen { exitNotchFullScreen(saved); return }
        if window.styleMask.contains(.fullScreen) { window.nativeToggleFullScreen(); return }
        if settings.fullScreenCoversNotch, let screen = window.screen ?? NSScreen.main, screen.safeAreaInsets.top > 0 {
            enterNotchFullScreen(screen)
        } else {
            window.nativeToggleFullScreen()
        }
    }

    private func enterNotchFullScreen(_ screen: NSScreen) {
        guard let window else { return }
        notchFullScreen = (window.frame, window.styleMask, window.aspectRatio)
        NSApp.presentationOptions = [.autoHideMenuBar, .autoHideDock]
        window.styleMask = [.borderless, .fullSizeContentView]
        window.resizeIncrements = NSSize(width: 1, height: 1)     // clears the aspect-ratio constraint
        window.setFrame(screen.frame, display: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(playerView)
        showControls()
    }

    private func exitNotchFullScreen(_ saved: (frame: NSRect, style: NSWindow.StyleMask, aspect: NSSize)) {
        guard let window else { return }
        notchFullScreen = nil
        window.styleMask = saved.style
        window.setFrame(saved.frame, display: true)
        if saved.aspect.width > 0 { window.aspectRatio = saved.aspect }
        NSApp.presentationOptions = []
        window.makeFirstResponder(playerView)
        showControls()
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
        if let engine { settings.nowPlayingHDR = engine.isHDRVideo }
    }

    func windowWillClose(_ notification: Notification) {
        settings.nowPlayingHDR = nil
        if notchFullScreen != nil { NSApp.presentationOptions = []; notchFullScreen = nil }
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
