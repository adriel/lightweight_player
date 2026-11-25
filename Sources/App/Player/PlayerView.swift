import AppKit
import UniformTypeIdentifiers

protocol PlayerViewDelegate: AnyObject {
    func playerViewDoubleClicked()
    func playerViewDropped(_ urls: [URL])
    func playerViewMouseActivity()
    func playerViewMouseExited()
    func playerViewMagnify(_ factor: CGFloat, ended: Bool)
}

/// Root content view: video (engine view), subtitle overlay, placeholder text and the floating control bar.
final class PlayerView: NSView {
    weak var delegate: PlayerViewDelegate?
    let controlBar = ControlBar()
    private let subtitleLabel = NSTextField(wrappingLabelWithString: "")
    private let placeholder = NSTextField(labelWithString: "Drop a video here\n⌘O open file  ·  ⇧⌘O open URL")
    private let osd = OSDView()
    private let bufferingHUD = BufferingHUD()
    let sidebar = SidebarContainer()
    private let thumbnail = ThumbnailPreview()
    private var sidebarTrailing: NSLayoutConstraint!
    private(set) var isSidebarShown = false
    private var videoView: NSView?
    private var tracking: NSTrackingArea?
    private var toastTimer: Timer?
    private var subtitleBottom: NSLayoutConstraint!
    var subtitleScale: Double = 1 { didSet { layoutSubtitleFont() } }
    private let bitmapLayer = CALayer()
    private var shownBitmaps: [SubtitleBitmap] = []
    private var bitmapVideoSize = CGSize.zero
    /// Current black-bar crop (normalized, top-left origin); image subtitles follow it.
    var crop: CGRect? { didSet { if crop != oldValue { layoutBitmaps() } } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        registerForDraggedTypes([.fileURL, .URL])

        placeholder.alignment = .center
        placeholder.textColor = NSColor.white.withAlphaComponent(0.45)
        placeholder.font = .systemFont(ofSize: 15, weight: .medium)
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        addSubview(placeholder)

        subtitleLabel.alignment = .center
        subtitleLabel.textColor = .white
        subtitleLabel.maximumNumberOfLines = 4
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        let shadow = NSShadow()
        shadow.shadowColor = .black
        shadow.shadowBlurRadius = 3
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        subtitleLabel.shadow = shadow
        subtitleLabel.isHidden = true
        addSubview(subtitleLabel)
        bitmapLayer.zPosition = 10
        layer?.addSublayer(bitmapLayer)

        osd.translatesAutoresizingMaskIntoConstraints = false
        osd.alphaValue = 0
        addSubview(osd)
        bufferingHUD.translatesAutoresizingMaskIntoConstraints = false
        bufferingHUD.isHidden = true
        addSubview(bufferingHUD)

        controlBar.translatesAutoresizingMaskIntoConstraints = false
        addSubview(controlBar)
        barCenterX = controlBar.centerXAnchor.constraint(equalTo: centerXAnchor)
        barBottom = controlBar.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Self.barDefaultBottom)
        controlBar.onDrag = { [weak self] phase, p in self?.dragBar(phase, p) }
        controlBar.onResetPosition = { [weak self] in
            Settings.shared.controlBarX = .nan; Settings.shared.controlBarY = .nan
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.2; ctx.allowsImplicitAnimation = true
                self?.applySavedBarPosition(); self?.layoutSubtreeIfNeeded()
            }
        }
        addSubview(thumbnail)                       // frame-positioned in placeThumbnail
        sidebar.translatesAutoresizingMaskIntoConstraints = false
        sidebar.isHidden = true
        addSubview(sidebar)                         // above the control bar, like IINA
        sidebarTrailing = sidebar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: SidebarContainer.width)
        NSLayoutConstraint.activate([
            sidebarTrailing,
            sidebar.topAnchor.constraint(equalTo: topAnchor), sidebar.bottomAnchor.constraint(equalTo: bottomAnchor),
            sidebar.widthAnchor.constraint(equalToConstant: SidebarContainer.width).withPriority(NSLayoutConstraint.Priority(490)),
            sidebar.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, multiplier: 0.8),
        ])

        centerGuide.backgroundColor = NSColor.white.withAlphaComponent(0.55).cgColor
        centerGuide.isHidden = true

        subtitleBottom = subtitleLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -28)
        NSLayoutConstraint.activate([
            placeholder.centerXAnchor.constraint(equalTo: centerXAnchor),
            placeholder.centerYAnchor.constraint(equalTo: centerYAnchor),

            subtitleLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            subtitleLabel.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, multiplier: 0.9),
            subtitleBottom,

            bufferingHUD.centerXAnchor.constraint(equalTo: centerXAnchor),
            bufferingHUD.centerYAnchor.constraint(equalTo: centerYAnchor),
            osd.topAnchor.constraint(equalTo: topAnchor, constant: 40),
            osd.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),

            barCenterX, barBottom,
            controlBar.heightAnchor.constraint(equalToConstant: ControlBar.preferredHeight),
            controlBar.widthAnchor.constraint(lessThanOrEqualToConstant: ControlBar.preferredWidth),
            controlBar.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -24),
            controlBar.widthAnchor.constraint(equalToConstant: ControlBar.preferredWidth).withPriority(NSLayoutConstraint.Priority(490)), // below windowSizeStayPut so the bar never resizes the window
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    func setVideoView(_ v: NSView?) {
        videoView?.removeFromSuperview()
        videoView = v
        placeholder.isHidden = v != nil
        guard let v else { return }
        v.frame = bounds
        v.autoresizingMask = [.width, .height]
        addSubview(v, positioned: .below, relativeTo: subtitleLabel)
    }

    // MARK: Draggable control bar (IINA-style), snapping to the horizontal centre with a guide line

    private var barCenterX: NSLayoutConstraint!
    private var barBottom: NSLayoutConstraint!
    private static let barDefaultBottom: CGFloat = 24
    private static let snapDistance: CGFloat = 10
    private let centerGuide = CALayer()
    private var dragStart: (mouse: NSPoint, x: CGFloat, bottom: CGFloat)?
    private var snapped = true

    private func dragBar(_ phase: NSEvent.EventType, _ windowPoint: NSPoint) {
        let p = convert(windowPoint, from: nil)
        if ProcessInfo.processInfo.environment["LP_DRAG_DEBUG"] != nil { NSLog("drag %@ p=%.0f,%.0f x=%.0f b=%.0f", String(describing: phase.rawValue), p.x, p.y, barCenterX.constant, barBottom.constant) }
        switch phase {
        case .leftMouseDown:
            dragStart = (p, barCenterX.constant, -barBottom.constant)
            snapped = abs(barCenterX.constant) < 0.5
        case .leftMouseDragged:
            guard let s = dragStart else { return }
            delegate?.playerViewMouseActivity()                    // keep the controls up while dragging
            var x = s.x + (p.x - s.mouse.x)
            let bottom = s.bottom + (p.y - s.mouse.y)
            let nowSnapped = abs(x) < Self.snapDistance
            if nowSnapped { x = 0 }
            if nowSnapped && !snapped { NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now) }
            snapped = nowSnapped
            CATransaction.begin(); CATransaction.setDisableActions(true)
            if centerGuide.superlayer == nil, let barLayer = controlBar.layer { layer?.insertSublayer(centerGuide, below: barLayer) }
            centerGuide.isHidden = !nowSnapped
            centerGuide.frame = CGRect(x: bounds.midX - 0.5, y: 0, width: 1, height: bounds.height)
            CATransaction.commit()
            placeBar(x: x, bottom: bottom)
        default:
            guard dragStart != nil else { return }
            dragStart = nil
            centerGuide.isHidden = true
            // Remember as fractions so the bar keeps its place when the window resizes or goes full screen.
            Settings.shared.controlBarX = bounds.width > 0 ? Double(barCenterX.constant / bounds.width) : .nan
            Settings.shared.controlBarY = bounds.height > 0 ? Double(-barBottom.constant / bounds.height) : .nan
        }
    }

    /// Clamp inside the view (and below the title bar) and apply.
    private func placeBar(x: CGFloat, bottom: CGFloat) {
        let w = controlBar.frame.width > 0 ? controlBar.frame.width : ControlBar.preferredWidth
        let h = ControlBar.preferredHeight
        let margin: CGFloat = 8, top: CGFloat = 34
        let maxX = max(0, bounds.width / 2 - w / 2 - margin)
        barCenterX.constant = min(max(x, -maxX), maxX)
        barBottom.constant = -min(max(bottom, margin), max(margin, bounds.height - h - top))
    }

    private func applySavedBarPosition() {
        guard dragStart == nil else { return }
        let fx = Settings.shared.controlBarX, fy = Settings.shared.controlBarY
        placeBar(x: fx.isNaN ? 0 : CGFloat(fx) * bounds.width, bottom: fy.isNaN ? Self.barDefaultBottom : CGFloat(fy) * bounds.height)
    }

    /// Black strip kept above the picture (full screen below the camera housing).
    var videoTopInset: CGFloat = 0 { didSet { if videoTopInset != oldValue { needsLayout = true } } }

    override func layout() {
        super.layout()
        videoView?.frame = NSRect(x: 0, y: 0, width: bounds.width, height: max(0, bounds.height - videoTopInset))
        applySavedBarPosition()
        layoutSubtitleFont()
        layoutBitmaps()
    }

    /// Image subtitles (PGS / VobSub), positioned over the aspect-fit video rect.
    func showBitmaps(_ items: [SubtitleBitmap], videoSize: CGSize) {
        guard items != shownBitmaps || videoSize != bitmapVideoSize else { return }
        shownBitmaps = items
        bitmapVideoSize = videoSize
        layoutBitmaps()
    }

    private func layoutBitmaps() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        bitmapLayer.frame = bounds
        let subs = bitmapLayer.sublayers ?? []
        guard !shownBitmaps.isEmpty, bitmapVideoSize.width > 0, bitmapVideoSize.height > 0 else { subs.forEach { $0.removeFromSuperlayer() }; return }
        let video = VideoGeometry.frameRect(bounds: bounds, videoSize: bitmapVideoSize, crop: crop)
        for (i, b) in shownBitmaps.enumerated() {
            let l = i < subs.count ? subs[i] : { let n = CALayer(); n.contentsGravity = .resize; bitmapLayer.addSublayer(n); return n }()
            l.contents = b.image
            var f = CGRect(x: video.minX + b.rect.minX * video.width, y: video.maxY - b.rect.maxY * video.height,
                           width: b.rect.width * video.width, height: b.rect.height * video.height)
            // Subtitles authored inside a (now cropped) bar: pull them back into view.
            if f.minY < 8 { f.origin.y = 8 }
            if f.maxY > bounds.height - 8 { f.origin.y = bounds.height - 8 - f.height }
            if f.minX < 0 { f.origin.x = 0 }
            if f.maxX > bounds.width { f.origin.x = bounds.width - f.width }
            l.frame = f
        }
        for l in subs.dropFirst(shownBitmaps.count) { l.removeFromSuperlayer() }
    }

    private func layoutSubtitleFont() {
        let size = max(14, bounds.height * 0.045 * CGFloat(subtitleScale))
        if subtitleLabel.font?.pointSize != size { subtitleLabel.font = .systemFont(ofSize: size, weight: .semibold) }
    }

    func showSubtitle(_ text: String?) {
        if let text, !text.isEmpty {
            if subtitleLabel.stringValue != text { subtitleLabel.stringValue = text }
            subtitleLabel.isHidden = false
        } else if !subtitleLabel.isHidden {
            subtitleLabel.isHidden = true
        }
    }

    // MARK: Seek-bar thumbnail

    private var thumbnailFraction = 0.0
    private var thumbnailPoints: CGFloat = 240

    /// Shows `image` above the control bar at seek-bar position `fraction` (longest side `points`).
    func showThumbnail(_ image: CGImage, at fraction: Double, points: CGFloat) {
        thumbnail.setImage(image)
        thumbnailPoints = points
        moveThumbnail(to: fraction)
    }

    /// Follows the pointer with the current image (until the next one is ready); no-op while none is shown.
    func moveThumbnail(to fraction: Double) {
        thumbnailFraction = fraction
        guard let img = thumbnail.image, controlBar.alphaValue > 0.01, !controlBar.isHidden else { thumbnail.isHidden = true; return }
        let aspect = CGFloat(img.height) / CGFloat(max(img.width, 1))
        var w = thumbnailPoints, h = thumbnailPoints * aspect
        if h > w { h = thumbnailPoints; w = thumbnailPoints / aspect }
        // Don't let it outgrow a small window.
        let fit = min(1, (bounds.width - 16) / max(w, 1), (bounds.height * 0.6) / max(h, 1))
        w = (w * fit).rounded(); h = (h * fit).rounded()
        let anchor = convert(controlBar.seekPoint(at: fraction), from: controlBar)
        let bar = controlBar.frame
        let x = min(max(anchor.x - w / 2, 8), bounds.width - w - 8)
        var y = bar.maxY + 8
        if y + h > bounds.height - videoTopInset - 4 { y = bar.minY - 8 - h }    // bar dragged to the top: show below it
        thumbnail.frame = NSRect(x: x, y: max(4, y), width: w, height: h)
        thumbnail.isHidden = false
    }

    func hideThumbnail() {
        thumbnail.isHidden = true
        thumbnail.setImage(nil)
    }

    /// Lift subtitles above the control bar while it's visible.
    func setControlsVisible(_ visible: Bool, animated: Bool) {
        if !visible { hideThumbnail() }
        let apply = {
            self.controlBar.animator().alphaValue = visible ? 1 : 0
            self.subtitleBottom.animator().constant = visible ? -(ControlBar.preferredHeight + 30) : -28
        }
        if animated {
            NSAnimationContext.runAnimationGroup { ctx in ctx.duration = 0.25; apply() }
        } else {
            controlBar.alphaValue = visible ? 1 : 0
            subtitleBottom.constant = visible ? -(ControlBar.preferredHeight + 30) : -28
        }
    }

    // MARK: Sidebar

    /// Slides the sidebar in from the right edge (or out).
    func setSidebarShown(_ show: Bool, animated: Bool = true) {
        guard show != isSidebarShown else { return }
        isSidebarShown = show
        if show { sidebar.isHidden = false; layoutSubtreeIfNeeded() }
        let w = max(sidebar.frame.width, SidebarContainer.width)
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = animated ? 0.22 : 0
            ctx.timingFunction = CAMediaTimingFunction(name: show ? .easeOut : .easeIn)
            ctx.allowsImplicitAnimation = true
            sidebarTrailing.animator().constant = show ? 0 : w
            layoutSubtreeIfNeeded()
        }, completionHandler: { [weak self] in
            guard let self, !self.isSidebarShown else { return }
            self.sidebar.isHidden = true
        })
    }

    func flash(_ message: String) {
        osd.show(text: message)
        presentOSD()
    }

    /// Spinner + progress while a stream buffers (nil hides it).
    func setBuffering(_ b: (progress: Double, bytesPerSecond: Double)?) {
        guard let b else { if !bufferingHUD.isHidden { bufferingHUD.isHidden = true; bufferingHUD.stop() }; return }
        bufferingHUD.update(progress: b.progress, bytesPerSecond: b.bytesPerSecond)
        if bufferingHUD.isHidden { bufferingHUD.isHidden = false; bufferingHUD.start() }
    }

    /// IINA-style OSD: large value, dimmer secondary text, thin progress bar (seek position, volume).
    func flash(primary: String, secondary: String, progress: Double) {
        osd.show(primary: primary, secondary: secondary, progress: progress)
        presentOSD()
    }

    private func presentOSD() {
        osd.alphaValue = 1
        toastTimer?.invalidate()
        toastTimer = Timer.scheduledTimer(withTimeInterval: 1.2, repeats: false) { [weak self] _ in
            NSAnimationContext.runAnimationGroup { $0.duration = 0.3; self?.osd.animator().alphaValue = 0 }
        }
    }

    // MARK: Mouse

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(t); tracking = t
    }
    override func mouseMoved(with e: NSEvent) { delegate?.playerViewMouseActivity() }
    override func mouseEntered(with e: NSEvent) { delegate?.playerViewMouseActivity() }
    override func mouseExited(with e: NSEvent) { delegate?.playerViewMouseExited() }
    /// Trackpad pinch resizes the player window.
    override func magnify(with e: NSEvent) { delegate?.playerViewMagnify(1 + e.magnification, ended: e.phase == .ended || e.phase == .cancelled) }
    override func mouseDown(with e: NSEvent) {
        // A click on the video closes the sidebar (and does nothing else).
        if isSidebarShown { setSidebarShown(false); return }
        if e.clickCount == 2 { delegate?.playerViewDoubleClicked() }
        else { window?.performDrag(with: e) }
    }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: Drag & drop

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] ?? []
        guard !urls.isEmpty else { return false }
        delegate?.playerViewDropped(urls)
        return true
    }
}

extension NSLayoutConstraint {
    func withPriority(_ p: NSLayoutConstraint.Priority) -> NSLayoutConstraint { priority = p; return self }
}

/// On-screen display in IINA's style: dark HUD material, rounded, hairline border; text plus optional bar.
final class OSDView: NSVisualEffectView {
    private let label = NSTextField(labelWithString: "")
    private let track = CALayer(), fill = CALayer()
    private let barHost = NSView()
    private var barHeight: NSLayoutConstraint!
    private var labelBottom: NSLayoutConstraint!
    private var progress = 0.0

    override init(frame: NSRect) {
        super.init(frame: frame)
        material = .hudWindow
        blendingMode = .withinWindow
        state = .active
        appearance = NSAppearance(named: .darkAqua)
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.masksToBounds = true
        layer?.borderWidth = 0.5
        layer?.borderColor = NSColor.white.withAlphaComponent(0.18).cgColor
        label.translatesAutoresizingMaskIntoConstraints = false
        label.lineBreakMode = .byClipping
        barHost.translatesAutoresizingMaskIntoConstraints = false
        barHost.wantsLayer = true
        track.backgroundColor = NSColor.white.withAlphaComponent(0.18).cgColor
        fill.backgroundColor = NSColor.controlAccentColor.cgColor
        track.cornerRadius = 2; fill.cornerRadius = 2
        barHost.layer?.addSublayer(track); barHost.layer?.addSublayer(fill)
        addSubview(label); addSubview(barHost)
        barHeight = barHost.heightAnchor.constraint(equalToConstant: 4)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            barHost.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 6),
            barHost.leadingAnchor.constraint(equalTo: label.leadingAnchor),
            barHost.trailingAnchor.constraint(equalTo: label.trailingAnchor),
            barHost.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            barHeight,
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    func show(text: String) {
        label.attributedStringValue = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 17, weight: .medium), .foregroundColor: NSColor.white])
        barHost.isHidden = true
        barHeight.constant = 0
    }

    func show(primary: String, secondary: String, progress: Double) {
        let s = NSMutableAttributedString(string: primary, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 24, weight: .regular), .foregroundColor: NSColor.white])
        if !secondary.isEmpty { s.append(NSAttributedString(string: " / " + secondary, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 24, weight: .regular), .foregroundColor: NSColor.white.withAlphaComponent(0.55)])) }
        label.attributedStringValue = s
        barHost.isHidden = false
        barHeight.constant = 4
        self.progress = min(max(progress, 0), 1)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let b = barHost.bounds
        track.frame = b
        fill.frame = CGRect(x: 0, y: 0, width: max(b.height, b.width * progress), height: b.height)
        CATransaction.commit()
    }
}

/// Centred "Buffering…" HUD: spinner, percentage of the resume threshold, download speed.
final class BufferingHUD: NSVisualEffectView {
    private let spinner = NSProgressIndicator()
    private let label = NSTextField(labelWithString: "Buffering…")
    private let detail = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        material = .hudWindow; blendingMode = .withinWindow; state = .active
        appearance = NSAppearance(named: .vibrantDark)
        wantsLayer = true
        layer?.cornerRadius = 14; layer?.masksToBounds = true
        layer?.borderWidth = 0.5; layer?.borderColor = NSColor.white.withAlphaComponent(0.18).cgColor
        spinner.style = .spinning; spinner.controlSize = .regular; spinner.isDisplayedWhenStopped = false
        label.font = .systemFont(ofSize: 14, weight: .semibold); label.textColor = .white
        detail.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular); detail.textColor = NSColor.white.withAlphaComponent(0.65)
        let stack = NSStackView(views: [spinner, label, detail])
        stack.orientation = .vertical; stack.spacing = 6; stack.alignment = .centerX
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 22), stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -22),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 16), stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -14),
            widthAnchor.constraint(greaterThanOrEqualToConstant: 150),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    func start() { spinner.startAnimation(nil) }
    func stop() { spinner.stopAnimation(nil) }
    func update(progress: Double, bytesPerSecond: Double) {
        label.stringValue = String(format: "Buffering… %d%%", Int((progress * 100).rounded()))
        detail.stringValue = bytesPerSecond > 0 ? InfoFormat.bitrate(bytesPerSecond * 8) : "connecting…"
    }
}
