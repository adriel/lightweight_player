import AppKit
import CoreGraphics
import CoreMedia
import QuartzCore

/// Display-synchronised presentation for engine C (what mpv calls display-resample, what TVs call 24p mode).
///
/// Problem: 23.976 fps on a 60 Hz panel is 2.5025 refreshes per frame, so each frame's position relative to
/// vsync drifts ~1 ms/s. Every ~8 s a frame lands right on a refresh boundary and clock noise flips it
/// between two refreshes: bursts of 3-3-2-2 instead of 2-3-2-3 (judder). IINA/mpv have the same by default.
///
/// Fix, only when the display rate is within 0.2% of a half-integer multiple of the frame rate:
///  1. Speed: the audio clock runs at s = refresh/(n·fps) (e.g. ×1.001, 23.976 → 24.000 fps); audio is
///     resampled (varispeed, +1.7 cents — inaudible).
///  2. The video layer does NOT follow that clock directly: measured on screen, AVSampleBufferDisplayLayer
///     paces frames 2-2-2-4 whenever its timebase rate isn't exactly 1. So video gets its own timebase at
///     exactly 1× host time, with timestamps scaled by 1/s, slaved to the audio clock: V = C/s + d.
///  3. Phase: d (a few ms of A/V offset) is chosen so frames sit a quarter-refresh away from any boundary,
///     re-checked every 2 s; it's only nudged when the phase or the audio-vs-host clock drift (tens of ppm)
///     gets close to the limits. Nudges of a few ms are invisible; a half-refresh wrap (one cadence step) is
///     needed only every few minutes at most.
final class DisplaySync: NSObject {
    /// Clock ratio to use, or nil when the refresh rate isn't a clean multiple of the frame rate.
    static func scale(fps: Double, refreshHz: Double) -> Double? {
        guard fps > 0, refreshHz > 0 else { return nil }
        let ratio = refreshHz / fps
        let multiple = (ratio * 2).rounded() / 2          // 1, 1.5, 2, 2.5, 3, …
        let r = ratio / multiple
        guard multiple >= 1, abs(r - 1) < 0.0021 else { return nil }
        return r
    }

    /// Nominal refresh rate of the main display (60 on a MacBook Air panel).
    static var mainDisplayRefreshHz: Double {
        guard let mode = CGDisplayCopyDisplayMode(CGMainDisplayID()) else { return 60 }
        return mode.refreshRate > 0 ? mode.refreshRate : 60
    }

    private weak var view: NSView?
    private var link: CADisplayLink?
    private var timer: Timer?
    private var periods: [Double] = []
    private var callbacks = 0
    private let fps: Double
    private let base: Double
    let scale: Double
    /// (audio/content clock, video clock) at a host time; nil while paused.
    private let measure: (_ hostSeconds: Double) -> (content: Double, video: Double)?
    /// Re-anchor the video clock so that V = C/s + offset from now on.
    private let setOffset: (_ offset: Double) -> Void
    private(set) var offset: Double = 0
    private(set) var refreshHz: Double = 0
    private var needsPhase = true
    private var lastErr: Double = 0

    init(view: NSView, fps: Double, base: Double, scale: Double,
         measure: @escaping (Double) -> (content: Double, video: Double)?, setOffset: @escaping (Double) -> Void) {
        self.view = view; self.fps = fps; self.base = base; self.scale = scale
        self.measure = measure; self.setOffset = setOffset
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

    /// The video clock was re-anchored (play, seek): re-place the phase at the next check.
    func resync() { needsPhase = true }

    var summary: String {
        guard refreshHz > 0 else { return "measuring…" }
        if fps <= 0 { return String(format: "video clock follows audio · A/V offset %+.1f ms (frame rate unknown, no phase lock)", offset * 1000) }
        return String(format: "%.3f → %.3f fps on %.2f Hz (×%.4f) · A/V offset %+.1f ms · phase margin %.1f ms",
                      fps, fps * scale, refreshHz, scale, offset * 1000, 250 / refreshHz - abs(lastErr) * 1000)
    }

    @objc private func vsync(_ l: CADisplayLink) {
        let p = l.targetTimestamp - l.timestamp
        guard p > 0.002, p < 0.05 else { return }
        periods.append(p)
        if periods.count > 16 { periods.removeFirst() }
        // A few callbacks per check are enough; then sleep until the next timer tick.
        callbacks += 1
        if callbacks % 3 != 0 { return }
        l.isPaused = true
        let period = periods.reduce(0, +) / Double(periods.count)
        refreshHz = 1 / period
        update(vsyncHost: l.timestamp, period: period)
    }

    private func update(vsyncHost: Double, period: Double) {
        guard let m = measure(vsyncHost) else { needsPhase = true; return }   // paused
        let s = scale
        let half = period / 2
        // Is this display still a clean multiple (the window may have moved to another screen)?
        // fps 0 = unknown frame rate: no phase lock, only keep video in step with the audio clock.
        let multiple = fps > 0 ? ((1 / period) / (fps * s) * 2).rounded() / 2 : 0
        let lockable = fps > 0 && multiple >= 1 && abs((1 / period) / (fps * s) / multiple - 1) < 0.0005

        var perr = 0.0
        if lockable {
            // Frame grid in video time: (base + k/fps)/s. Phase of the next frame relative to this vsync.
            let fdv = 1 / (fps * s), b = base / s
            let k = ((m.video - b) / fdv).rounded(.up)
            var x = (b + k * fdv - m.video).truncatingRemainder(dividingBy: half)
            if x < 0 { x += half }
            perr = x - half / 2                            // 0 = frames ¼ refresh from any boundary
        }
        let e = m.video - m.content / s                    // A/V offset actually in effect
        lastErr = perr
        let debug = ProcessInfo.processInfo.environment["LP_SYNC_DEBUG"] != nil
        if debug { NSLog("displaysync: phase err %+.2f ms, A/V %+.2f ms", perr * 1000, e * 1000) }

        guard needsPhase || abs(perr) > half / 2 - 0.0015 || abs(e) > half + 0.001 else { return }
        // Moving the video clock forward by Δ moves the phase by −Δ.
        var d = e + perr
        while d > half { d -= half }                       // half-refresh steps keep the phase
        while d < -half { d += half }
        needsPhase = false
        offset = d
        lastErr = 0
        if debug { NSLog("displaysync: A/V offset → %+.2f ms", d * 1000) }
        setOffset(d)
    }
}
