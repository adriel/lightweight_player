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

    init() {
        let window = PlayerWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 540),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                  backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
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

        let e = forceSampleBufferEngine ? SampleBufferEngine() : makeEngine(for: url)
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
            sizeWindowToVideo()
            setupSubtitles()
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
        case .firstFrame: break
        case .failed(let msg):
            let a = NSAlert()
            a.messageText = "Can't play this file"
            a.informativeText = msg
            a.beginSheetModal(for: window!)
        case .needsFallback:
            if let u = currentURL { open(u, forceSampleBufferEngine: true) }
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
        guard let window, let engine, !window.styleMask.contains(.fullScreen) else { return }
        let size = engine.naturalSize
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

    private func closeEngine() {
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
        if window.styleMask.contains(.fullScreen) { NSCursor.setHiddenUntilMouseMoves(true) }
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
        case 123: skip(-(shift ? settings.longSeekStep : settings.seekStep)); return true   // ←
        case 124: skip(shift ? settings.longSeekStep : settings.seekStep); return true      // →
        case 126: changeVolume(settings.volumeStep / 100); return true                       // ↑
        case 125: changeVolume(-settings.volumeStep / 100); return true                      // ↓
        case 49: togglePlay(); return true                                                    // space
        case 53:                                                                              // esc
            if window?.styleMask.contains(.fullScreen) == true { window?.toggleFullScreen(nil); return true }
            return false
        default: break
        }
        switch e.charactersIgnoringModifiers?.lowercased() {
        case "f": window?.toggleFullScreen(nil); return true
        case "m": controlBarToggleMute(); return true
        case "s": cycleSubtitles(); return true
        default: return false
        }
    }

    private func skip(_ s: Double) {
        guard let engine else { return }
        let target = min(max(0, engine.currentTime + s), max(0, engine.duration - 0.5))
        engine.seek(to: target, accurate: settings.accurateSeek)
        playerView.flash("\(s > 0 ? "⏩" : "⏪") \(formatTime(target))")
        showControls()
    }

    private func changeVolume(_ delta: Double) {
        muted = false
        settings.volume = min(max(settings.volume + delta, 0), 1)
        engine?.volume = Float(settings.volume)
        playerView.controlBar.setVolume(settings.volume, muted: false)
        playerView.flash("🔊 \(Int((settings.volume * 100).rounded()))%")
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
    func controlBarTimeString(at fraction: Double) -> String { formatTime(fraction * (engine?.duration ?? 0)) }
    func controlBarShowSettings() { (NSApp.delegate as? AppDelegate)?.showSettings(nil) }
    func controlBarTogglePiP() {
        guard let pip else { return }
        if pip.isPictureInPictureActive { pip.stopPictureInPicture() } else { pip.startPictureInPicture() }
    }

    func controlBarShowSubtitleMenu(from view: NSView) {
        let menu = NSMenu()
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

    func playerViewDoubleClicked() { window?.toggleFullScreen(nil) }
    func playerViewDropped(_ urls: [URL]) {
        if let sub = urls.first(where: { ["srt", "vtt", "ass", "ssa"].contains($0.pathExtension.lowercased()) }), engine != nil {
            let id = 20_000 + externalCues.count
            externalCues[id] = SubtitleFileParser.parse(sub)
            subtitleTracks.append(SubtitleTrackInfo(id: id, title: sub.lastPathComponent, language: nil, codec: sub.pathExtension, isForced: false, isDefault: false, kind: .text, externalURL: sub))
            selectSubtitle(id)
            playerView.flash("Loaded \(sub.lastPathComponent)")
        } else if let u = urls.first { open(u) }
    }

    func windowWillClose(_ notification: Notification) {
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
}
