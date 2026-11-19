import AppKit

/// Lightweight custom slider for the HUD: thin track, filled portion, optional buffered spans, and a knob.
/// Drawn with plain CoreGraphics (no NSSlider cell machinery, no per-frame layer churn).
final class HUDSlider: NSView {
    enum KnobStyle { case pill, bar }

    var value: Double = 0 { didSet { if !isDragging { needsDisplay = true } } }
    var buffered: [ClosedRange<Double>] = [] { didSet { needsDisplay = true } }
    /// Chapter starts (fractions): drawn as small gaps in the track, like IINA.
    var markers: [Double] = [] { didSet { if markers != oldValue { needsDisplay = true } } }
    var knobStyle: KnobStyle = .pill
    var onChange: ((Double, _ final: Bool) -> Void)?
    /// Called with the hovered fraction (nil when the mouse leaves) — used for the seek-time tooltip.
    var onHover: ((Double?) -> Void)?
    private(set) var isDragging = false
    private var dragValue: Double = 0
    private var tracking: NSTrackingArea?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(t); tracking = t
    }

    private var trackInset: CGFloat { knobStyle == .pill ? 8 : 2 }
    private func fraction(at p: NSPoint) -> Double {
        let w = bounds.width - trackInset * 2
        return Double(min(max((p.x - trackInset) / max(w, 1), 0), 1))
    }

    override func draw(_ dirty: NSRect) {
        let v = isDragging ? dragValue : value
        let midY = bounds.midY
        let trackH: CGFloat = 3
        let x0 = trackInset, w = bounds.width - trackInset * 2
        let track = NSRect(x: x0, y: midY - trackH / 2, width: w, height: trackH)
        NSColor.white.withAlphaComponent(0.16).setFill()
        NSBezierPath(roundedRect: track, xRadius: trackH / 2, yRadius: trackH / 2).fill()
        NSColor.white.withAlphaComponent(0.22).setFill()
        for b in buffered {
            let r = NSRect(x: x0 + w * b.lowerBound, y: track.minY, width: max(1, w * (b.upperBound - b.lowerBound)), height: trackH)
            NSBezierPath(roundedRect: r, xRadius: 2, yRadius: 2).fill()
        }
        // Played part: IINA keeps it a soft grey on the seek bar, brighter on the volume slider.
        NSColor.white.withAlphaComponent(knobStyle == .bar ? 0.42 : 0.7).setFill()
        NSBezierPath(roundedRect: NSRect(x: x0, y: track.minY, width: w * v, height: trackH), xRadius: 1.5, yRadius: 1.5).fill()
        if !markers.isEmpty, let ctx = NSGraphicsContext.current?.cgContext {
            ctx.saveGState()
            ctx.setBlendMode(.clear)
            for m in markers { ctx.fill(CGRect(x: x0 + w * m - 1, y: track.minY - 0.5, width: 2, height: trackH + 1)) }
            ctx.restoreGState()
        }
        let kx = x0 + w * v
        NSColor.white.setFill()
        switch knobStyle {
        case .pill:
            NSBezierPath(roundedRect: NSRect(x: kx - 8, y: midY - 5.5, width: 16, height: 11), xRadius: 5.5, yRadius: 5.5).fill()
        case .bar:
            NSColor.white.withAlphaComponent(0.92).setFill()
            NSBezierPath(roundedRect: NSRect(x: kx - 1.5, y: midY - 7.5, width: 3, height: 15), xRadius: 1.5, yRadius: 1.5).fill()
        }
    }

    override func mouseDown(with e: NSEvent) {
        isDragging = true
        dragValue = fraction(at: convert(e.locationInWindow, from: nil))
        needsDisplay = true
        onChange?(dragValue, false)
    }
    override func mouseDragged(with e: NSEvent) {
        dragValue = fraction(at: convert(e.locationInWindow, from: nil))
        needsDisplay = true
        onChange?(dragValue, false)
        onHover?(dragValue)
    }
    override func mouseUp(with e: NSEvent) {
        dragValue = fraction(at: convert(e.locationInWindow, from: nil))
        value = dragValue
        isDragging = false
        needsDisplay = true
        onChange?(dragValue, true)
    }
    override func mouseMoved(with e: NSEvent) { onHover?(fraction(at: convert(e.locationInWindow, from: nil))) }
    override func mouseExited(with e: NSEvent) { onHover?(nil) }
    override func scrollWheel(with e: NSEvent) {
        guard knobStyle == .pill else { super.scrollWheel(with: e); return }
        let delta = Double(e.scrollingDeltaX - e.scrollingDeltaY) * (e.hasPreciseScrollingDeltas ? 0.004 : 0.04)
        value = min(max(value + delta, 0), 1)
        onChange?(value, true)
    }
}

/// Borderless icon button tinted white, using SF Symbols.
final class HUDButton: NSButton {
    convenience init(symbol: String, size: CGFloat, target: AnyObject?, action: Selector) {
        self.init(frame: .zero)
        isBordered = false
        bezelStyle = .regularSquare
        imagePosition = .imageOnly
        setSymbol(symbol, size: size)
        contentTintColor = HUDButton.glyphColor
        self.target = target
        self.action = action
        setButtonType(.momentaryChange)
        focusRingType = .none
    }
    func setSymbol(_ name: String, size: CGFloat) {
        let cfg = NSImage.SymbolConfiguration(pointSize: size, weight: .regular)
        image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(cfg)
    }
    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    /// Soft white used for all HUD glyphs (IINA's controls aren't pure white).
    static let glyphColor = NSColor.white.withAlphaComponent(0.78)
}
