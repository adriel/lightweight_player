import AppKit
import CoreMedia
import QuartzCore

/// Display-synchronised presentation for engine C (what mpv calls display-resample, what TVs call 24p mode).
///
/// Problem: 23.976 fps on a 60 Hz panel is 2.5025 refreshes per frame, so each frame's position relative to
/// vsync drifts ~1 ms/s. Every few seconds a frame lands right on a refresh boundary and clock noise flips it
/// between two refreshes: bursts of 3-3-2-2 instead of 2-3-2-3 (judder). IINA/mpv have the same by default.
///
/// Fix, only when the display rate is within 0.2% of a half-integer multiple of the frame rate:
///  1. rate-lock: play at refresh/(n·fps) (e.g. ×1.001, 23.976 → 24.000) so the phase stops drifting; audio is
///     resampled (varispeed, +1.7 cents — inaudible).
///  2. phase-lock: offset video timestamps by a few ms so frames sit a quarter-refresh away from any boundary
///     (safe whichever way the renderer rounds), re-checked every 2 s with hysteresis.
final class DisplaySync: NSObject {
    private weak var view: NSView?
    private var link: CADisplayLink?
    private var timer: Timer?
    private var periods: [Double] = []
    private let fps: Double
    private let base: Double
    private let apply: (_ rate: Float, _ videoOffset: Double) -> Void
    private let mediaTimeAtHost: (_ hostSeconds: Double) -> Double?
    private(set) var rate: Float = 1
    private(set) var offset: Double = 0
    private(set) var refreshHz: Double = 0

    init(view: NSView, fps: Double, base: Double,
         mediaTimeAtHost: @escaping (Double) -> Double?, apply: @escaping (Float, Double) -> Void) {
        self.view = view; self.fps = fps; self.base = base
        self.mediaTimeAtHost = mediaTimeAtHost; self.apply = apply
    }

    func start() {
        guard let view, link == nil else { return }
        let l = view.displayLink(target: self, selector: #selector(vsync(_:)))
        l.add(to: .main, forMode: .common)
        link = l
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.link?.isPaused = false }
    }

    func stop() {
        timer?.invalidate(); timer = nil
        link?.invalidate(); link = nil
    }

    var summary: String {
        guard refreshHz > 0 else { return "measuring…" }
        if rate == 1 { return String(format: "off (%.3f fps on %.2f Hz isn't a clean multiple)", fps, refreshHz) }
        return String(format: "%.3f → %.3f fps on %.2f Hz (×%.4f), phase offset %+.1f ms", fps, fps * Double(rate), refreshHz, rate, offset * 1000)
    }

    @objc private func vsync(_ l: CADisplayLink) {
        let p = l.targetTimestamp - l.timestamp
        guard p > 0.002, p < 0.05 else { return }
        periods.append(p)
        if periods.count > 16 { periods.removeFirst() }
        // A few callbacks per check are enough; then sleep until the next timer tick.
        if periods.count % 3 != 0 { return }
        l.isPaused = true
        let period = periods.reduce(0, +) / Double(periods.count)
        refreshHz = 1 / period
        update(vsyncHost: l.timestamp, period: period)
    }

    // Phase-locked loop state: the playback clock follows the audio device clock, which differs from the
    // display clock by up to a few hundred ppm, so a computed rate alone still drifts. Measure the phase drift
    // between checks and trim the rate to cancel it.
    private var lastPhase: (host: Double, x: Double, offset: Double)?
    private var trim: Double = 1

    private func update(vsyncHost: Double, period: Double) {
        let ratio = (1 / period) / fps
        let multiple = (ratio * 2).rounded() / 2          // 2, 2.5, 3, …
        let r = ratio / multiple
        guard multiple >= 1, abs(r - 1) < 0.0021, let mv = mediaTimeAtHost(vsyncHost) else {
            lastPhase = nil; trim = 1
            if rate != 1 || offset != 0 { rate = 1; offset = 0; apply(1, 0) }
            return
        }
        let p = period * r                                // media time per refresh
        let half = p / 2
        let fd = 1 / fps
        let k = ((mv - base - offset) / fd).rounded(.up)
        let t = base + k * fd + offset                    // next frame's presentation time
        var x = (t - mv).truncatingRemainder(dividingBy: half)
        if x < 0 { x += half }

        // Drift since last check (unwrapped within ±¼ refresh, excluding our own offset changes).
        if let last = lastPhase, vsyncHost - last.host > 0.5 {
            var dx = (x - last.x) - (offset - last.offset)
            while dx > half / 2 { dx -= half }
            while dx < -half / 2 { dx += half }
            let drift = dx / (vsyncHost - last.host)      // media seconds per second
            trim = min(max(trim * (1 + drift * 0.8), 0.997), 1.003)
        }
        let newRate = Float(r * trim)

        let err = x - half / 2                            // want frames ¼ refresh away from any boundary
        var newOffset = offset
        if abs(err) > p / 8 || lastPhase == nil { newOffset = offset - err }
        while newOffset > half { newOffset -= p }
        while newOffset < -half { newOffset += p }
        lastPhase = (vsyncHost, x + (newOffset - offset), newOffset)

        if abs(newRate - rate) > 0.000_002 || abs(newOffset - offset) > 0.0001 {
            if ProcessInfo.processInfo.environment["LP_SYNC_DEBUG"] != nil {
                NSLog("displaysync: rate %.6f (trim %+.0f ppm) offset %.2f ms err %.2f ms (refresh %.3f Hz)", newRate, (trim - 1) * 1e6, newOffset * 1000, err * 1000, refreshHz)
            }
            rate = newRate; offset = newOffset
            apply(rate, offset)
        }
    }
}
