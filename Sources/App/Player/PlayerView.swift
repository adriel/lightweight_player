import AppKit
import UniformTypeIdentifiers

protocol PlayerViewDelegate: AnyObject {
    func playerViewDoubleClicked()
    func playerViewDropped(_ urls: [URL])
    func playerViewMouseActivity()
}

/// Root content view: video (engine view), subtitle overlay, placeholder text and the floating control bar.
final class PlayerView: NSView {
    weak var delegate: PlayerViewDelegate?
    let controlBar = ControlBar()
    private let subtitleLabel = NSTextField(wrappingLabelWithString: "")
    private let placeholder = NSTextField(labelWithString: "Drop a video here\n⌘O open file  ·  ⇧⌘O open URL")
    private let osd = OSDView()
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

        controlBar.translatesAutoresizingMaskIntoConstraints = false
        addSubview(controlBar)

        subtitleBottom = subtitleLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -28)
        NSLayoutConstraint.activate([
            placeholder.centerXAnchor.constraint(equalTo: centerXAnchor),
            placeholder.centerYAnchor.constraint(equalTo: centerYAnchor),

            subtitleLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            subtitleLabel.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, multiplier: 0.9),
            subtitleBottom,

            osd.topAnchor.constraint(equalTo: topAnchor, constant: 40),
            osd.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),

            controlBar.centerXAnchor.constraint(equalTo: centerXAnchor),
            controlBar.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -24),
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

    override func layout() {
        super.layout()
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

    /// Lift subtitles above the control bar while it's visible.
    func setControlsVisible(_ visible: Bool, animated: Bool) {
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

    func flash(_ message: String) {
        osd.show(text: message)
        presentOSD()
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
    override func mouseDown(with e: NSEvent) {
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
