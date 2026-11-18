import AppKit

protocol ControlBarDelegate: AnyObject {
    func controlBarTogglePlay()
    func controlBarSkip(_ seconds: Double)
    func controlBarSeek(fraction: Double, final: Bool)
    func controlBarVolume(_ v: Double)
    func controlBarToggleMute()
    func controlBarShowSubtitleMenu(from: NSView)
    func controlBarShowVideoAdjust(from: NSView)
    func controlBarTogglePiP()
    func controlBarShowSettings()
    func controlBarTimeString(at fraction: Double) -> String
}

/// IINA-style floating controls: glass panel with volume / transport / tools on top, timeline below.
final class ControlBar: NSView {
    weak var delegate: ControlBarDelegate?
    private let glass = NSGlassEffectView()
    private let content = NSView()
    let seek = HUDSlider()
    let volume = HUDSlider()
    private let elapsed = NSTextField(labelWithString: "0:00")
    private let total = NSTextField(labelWithString: "0:00")
    private var playButton: HUDButton!
    private var volumeButton: HUDButton!
    private var subButton: HUDButton!
    private var adjustButton: HUDButton!
    private var pipButton: HUDButton!
    private let hoverLabel = NSTextField(labelWithString: "")
    private let hoverBox = NSView()
    private var hoverX: NSLayoutConstraint!
    var showRemaining = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        glass.cornerRadius = 12
        glass.style = .clear
        glass.tintColor = NSColor.black.withAlphaComponent(0.35)
        glass.contentView = content
        glass.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glass)

        let rew = HUDButton(symbol: "backward.fill", size: 15, target: self, action: #selector(rewind))
        playButton = HUDButton(symbol: "play.fill", size: 21, target: self, action: #selector(togglePlay))
        let fwd = HUDButton(symbol: "forward.fill", size: 15, target: self, action: #selector(forward))
        volumeButton = HUDButton(symbol: "speaker.wave.2.fill", size: 12, target: self, action: #selector(toggleMute))
        subButton = HUDButton(symbol: "captions.bubble", size: 13, target: self, action: #selector(subs(_:)))
        adjustButton = HUDButton(symbol: "slider.horizontal.3", size: 12, target: self, action: #selector(adjust(_:)))
        pipButton = HUDButton(symbol: "pip.enter", size: 13, target: self, action: #selector(pip))
        let gear = HUDButton(symbol: "gearshape.fill", size: 13, target: self, action: #selector(settings))
        subButton.toolTip = "Subtitles"; adjustButton.toolTip = "Brightness & gamma"; pipButton.toolTip = "Picture in Picture"; gear.toolTip = "Settings"

        for l in [elapsed, total] {
            l.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            l.textColor = NSColor.white.withAlphaComponent(0.85)
        }
        total.alignment = .right
        let totalClick = NSClickGestureRecognizer(target: self, action: #selector(toggleRemaining))
        total.addGestureRecognizer(totalClick)

        seek.knobStyle = .bar
        seek.onChange = { [weak self] v, final in self?.delegate?.controlBarSeek(fraction: v, final: final) }
        seek.onHover = { [weak self] f in self?.hover(f) }
        volume.knobStyle = .pill
        volume.onChange = { [weak self] v, _ in self?.delegate?.controlBarVolume(v); self?.updateVolumeIcon(v) }

        hoverLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .semibold)
        hoverLabel.textColor = .white
        hoverBox.wantsLayer = true
        hoverBox.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.6).cgColor
        hoverBox.layer?.cornerRadius = 5
        hoverBox.isHidden = true

        let views: [NSView] = [rew, playButton, fwd, volumeButton, volume, subButton, adjustButton, pipButton, gear, elapsed, total, seek, hoverBox]
        views.forEach { $0.translatesAutoresizingMaskIntoConstraints = false; content.addSubview($0) }
        hoverLabel.translatesAutoresizingMaskIntoConstraints = false
        hoverBox.addSubview(hoverLabel)

        let topY: CGFloat = 26, bottomY: CGFloat = 57
        hoverX = hoverBox.centerXAnchor.constraint(equalTo: seek.leadingAnchor)
        NSLayoutConstraint.activate([
            glass.leadingAnchor.constraint(equalTo: leadingAnchor), glass.trailingAnchor.constraint(equalTo: trailingAnchor),
            glass.topAnchor.constraint(equalTo: topAnchor), glass.bottomAnchor.constraint(equalTo: bottomAnchor),

            playButton.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            playButton.centerYAnchor.constraint(equalTo: content.topAnchor, constant: topY),
            rew.trailingAnchor.constraint(equalTo: playButton.leadingAnchor, constant: -26),
            rew.centerYAnchor.constraint(equalTo: playButton.centerYAnchor),
            fwd.leadingAnchor.constraint(equalTo: playButton.trailingAnchor, constant: 26),
            fwd.centerYAnchor.constraint(equalTo: playButton.centerYAnchor),

            volumeButton.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            volumeButton.centerYAnchor.constraint(equalTo: playButton.centerYAnchor),
            volumeButton.widthAnchor.constraint(equalToConstant: 20),
            volume.leadingAnchor.constraint(equalTo: volumeButton.trailingAnchor, constant: 4),
            volume.centerYAnchor.constraint(equalTo: playButton.centerYAnchor),
            volume.widthAnchor.constraint(equalToConstant: 76), volume.heightAnchor.constraint(equalToConstant: 18),
            volume.trailingAnchor.constraint(lessThanOrEqualTo: rew.leadingAnchor, constant: -10),

            gear.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            gear.centerYAnchor.constraint(equalTo: playButton.centerYAnchor),
            pipButton.trailingAnchor.constraint(equalTo: gear.leadingAnchor, constant: -10),
            pipButton.centerYAnchor.constraint(equalTo: playButton.centerYAnchor),
            adjustButton.trailingAnchor.constraint(equalTo: pipButton.leadingAnchor, constant: -10),
            adjustButton.centerYAnchor.constraint(equalTo: playButton.centerYAnchor),
            subButton.trailingAnchor.constraint(equalTo: adjustButton.leadingAnchor, constant: -10),
            subButton.centerYAnchor.constraint(equalTo: playButton.centerYAnchor),
            subButton.leadingAnchor.constraint(greaterThanOrEqualTo: fwd.trailingAnchor, constant: 10),

            elapsed.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            elapsed.centerYAnchor.constraint(equalTo: content.topAnchor, constant: bottomY),
            elapsed.widthAnchor.constraint(greaterThanOrEqualToConstant: 40),
            total.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            total.centerYAnchor.constraint(equalTo: elapsed.centerYAnchor),
            total.widthAnchor.constraint(greaterThanOrEqualToConstant: 40),
            seek.leadingAnchor.constraint(equalTo: elapsed.trailingAnchor, constant: 6),
            seek.trailingAnchor.constraint(equalTo: total.leadingAnchor, constant: -6),
            seek.centerYAnchor.constraint(equalTo: elapsed.centerYAnchor),
            seek.heightAnchor.constraint(equalToConstant: 18),

            hoverX, hoverBox.bottomAnchor.constraint(equalTo: seek.topAnchor, constant: -2),
            hoverLabel.leadingAnchor.constraint(equalTo: hoverBox.leadingAnchor, constant: 6),
            hoverLabel.trailingAnchor.constraint(equalTo: hoverBox.trailingAnchor, constant: -6),
            hoverLabel.topAnchor.constraint(equalTo: hoverBox.topAnchor, constant: 2),
            hoverLabel.bottomAnchor.constraint(equalTo: hoverBox.bottomAnchor, constant: -2),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    static let preferredHeight: CGFloat = 78
    static let preferredWidth: CGFloat = 460

    // MARK: Updates from the player

    func update(time: Double, duration: Double, playing: Bool, buffered: [ClosedRange<Double>]) {
        if !seek.isDragging { seek.value = duration > 0 ? time / duration : 0 }
        if seek.buffered != buffered { seek.buffered = buffered }
        elapsed.stringValue = formatTime(time)
        total.stringValue = showRemaining ? "-" + formatTime(max(0, duration - time)) : formatTime(duration)
        playButton.setSymbol(playing ? "pause.fill" : "play.fill", size: 21)
    }

    func setVolume(_ v: Double, muted: Bool) {
        volume.value = muted ? 0 : v
        updateVolumeIcon(muted ? 0 : v)
    }

    func setSubtitlesActive(_ on: Bool) { subButton.setSymbol(on ? "captions.bubble.fill" : "captions.bubble", size: 13) }
    func setPiPAvailable(_ on: Bool) { pipButton.isEnabled = on; pipButton.alphaValue = on ? 1 : 0.4 }

    private func updateVolumeIcon(_ v: Double) {
        let name = v <= 0.001 ? "speaker.slash.fill" : v < 0.34 ? "speaker.wave.1.fill" : v < 0.67 ? "speaker.wave.2.fill" : "speaker.wave.3.fill"
        volumeButton.setSymbol(name, size: 12)
    }

    private func hover(_ f: Double?) {
        guard let f, let d = delegate else { hoverBox.isHidden = true; return }
        hoverLabel.stringValue = d.controlBarTimeString(at: f)
        hoverX.constant = 4 + (seek.bounds.width - 8) * f
        hoverBox.isHidden = false
    }

    // MARK: Actions

    @objc private func togglePlay() { delegate?.controlBarTogglePlay() }
    @objc private func rewind() { delegate?.controlBarSkip(-Settings.shared.seekStep) }
    @objc private func forward() { delegate?.controlBarSkip(Settings.shared.seekStep) }
    @objc private func toggleMute() { delegate?.controlBarToggleMute() }
    @objc private func subs(_ s: NSView) { delegate?.controlBarShowSubtitleMenu(from: subButton) }
    @objc private func adjust(_ s: NSView) { delegate?.controlBarShowVideoAdjust(from: adjustButton) }
    @objc private func pip() { delegate?.controlBarTogglePiP() }
    @objc private func settings() { delegate?.controlBarShowSettings() }
    @objc private func toggleRemaining() { showRemaining.toggle() }

    // Swallow clicks so they don't reach the video (double-click = fullscreen).
    override func mouseDown(with event: NSEvent) {}
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

func formatTime(_ t: Double) -> String {
    guard t.isFinite, t >= 0 else { return "0:00" }
    let s = Int(t)
    let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
}
