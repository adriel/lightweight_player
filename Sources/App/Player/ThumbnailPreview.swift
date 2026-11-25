import AppKit

/// The seek-bar preview frame: a rounded image with a hairline rim and soft shadow, floating above the
/// control bar at the hovered position. Never takes mouse events (the slider underneath keeps tracking).
final class ThumbnailPreview: NSView {
    private let imageLayer = CALayer()
    private(set) var image: CGImage?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.45
        layer?.shadowRadius = 8
        layer?.shadowOffset = CGSize(width: 0, height: -2)
        imageLayer.cornerRadius = 6
        imageLayer.masksToBounds = true
        imageLayer.borderWidth = 1
        imageLayer.borderColor = NSColor.white.withAlphaComponent(0.22).cgColor
        imageLayer.backgroundColor = NSColor.black.cgColor
        imageLayer.contentsGravity = .resizeAspectFill
        layer?.addSublayer(imageLayer)
        isHidden = true
    }
    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var isFlipped: Bool { false }

    func setImage(_ img: CGImage?) {
        guard img !== image else { return }
        image = img
        CATransaction.begin(); CATransaction.setDisableActions(true)
        imageLayer.contents = img
        CATransaction.commit()
    }

    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        imageLayer.frame = bounds
        layer?.shadowPath = CGPath(roundedRect: bounds, cornerWidth: 6, cornerHeight: 6, transform: nil)
        CATransaction.commit()
    }
}
