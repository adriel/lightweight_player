import AppKit
import Darwin
import IOSurface
import CoreVideo

/// `LightPlayer --bench --engine C --media <path|url> --seconds 45`
/// Plays the media in a 1280x720 window, exercises seeks, and prints one JSON line per second plus a summary.
final class BenchRunner: NSObject, NSApplicationDelegate {
    let engineKind: EngineKind
    let media: URL
    let seconds: Double
    var engine: PlayerEngine!
    var window: NSWindow!
    var start = Date()
    var firstFrameAt: Double?
    var samples: [(mem: Double, cpu: Double)] = []
    var lastCPU = BenchRunner.cpuSeconds()
    var lastWall = Date()
    var timer: Timer?
    var failure: String?
    var seekLog: [String] = []
    let loopTest = ProcessInfo.processInfo.environment["LP_BENCH_LOOP"] != nil

    init(engine: EngineKind, media: URL, seconds: Double) {
        engineKind = engine; self.media = media; self.seconds = seconds
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 1280, height: 720), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Bench \(engineKind.label)"
        engine = makeEngine(engineKind)
        window.contentView = engine.view
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        engine.onEvent = { [weak self] ev in
            guard let self else { return }
            switch ev {
            case .ready: self.engine.play()
            case .firstFrame: if self.firstFrameAt == nil { self.firstFrameAt = Date().timeIntervalSince(self.start) }
            case .failed(let m): self.failure = m; self.emit(["event": "failed", "message": m])
            case .ended:
                self.emit(["event": "ended", "pos": round1(self.engine.currentTime)])
                // LP_BENCH_LOOP: what the player's Loop option does at the end.
                if self.loopTest { self.engine.seek(to: 0, accurate: true); self.engine.play(); self.emit(["event": "looped"]) }
            case .needsFallback: self.emit(["event": "needsFallback"])
            default: break
            }
        }
        start = Date()
        engine.open(media)
        if loopTest { engine.volume = 0 }      // silent
        if ProcessInfo.processInfo.environment["LP_PACING"] != nil, engine is SampleBufferEngine {
            let link = engine.view.displayLink(target: self, selector: #selector(vsync(_:)))
            link.add(to: .main, forMode: .common)
            displayLink = link
        }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
    }

    // Frame pacing: count how many vsyncs each displayed frame stays on screen.
    var displayLink: CADisplayLink?
    var lastShown: UInt32 = 0
    var holds = 0
    var holdHist: [Int: Int] = [:]
    @objc func vsync(_ link: CADisplayLink) {
        guard let e = engine as? SampleBufferEngine, e.isPlaying else { return }
        guard let pb = e.debugRenderer.displayedPixelBuffer(), let surf = CVPixelBufferGetIOSurface(pb)?.takeUnretainedValue() else { return }
        let id = IOSurfaceGetID(surf)
        holds += 1
        if id != lastShown {
            if lastShown != 0 { holdHist[holds, default: 0] += 1 }
            lastShown = id; holds = 0
        }
    }

    func tick() {
        let el = Date().timeIntervalSince(start)
        let cpuNow = Self.cpuSeconds(), wallNow = Date()
        let cpuPct = (cpuNow - lastCPU) / wallNow.timeIntervalSince(lastWall) * 100
        lastCPU = cpuNow; lastWall = wallNow
        let mem = Double(Self.physFootprint()) / 1_048_576
        if el > 5 { samples.append((mem, cpuPct)) } // skip startup
        var line: [String: Any] = ["t": round(el), "mem": round1(mem), "cpu": round1(cpuPct), "pos": round1(engine.currentTime)]
        if ProcessInfo.processInfo.environment["LP_DEBUG"] != nil { line["diag"] = engine.diagnostics() }
        emit(line)

        let e = Int(el)
        // Loop test: jump to 3 s before the end once, then just watch the position.
        if loopTest {
            if e == 3, engine.duration > 0 { engine.seek(to: engine.duration - 3, accurate: true) }
            if el >= seconds { finish() }
            return
        }
        // Seek script: three +5s accurate skips, then a jump to 50%, then a jump back to 10%.
        if [15, 16, 17].contains(e) { seekLog.append("+5@\(round1(engine.currentTime))"); engine.seek(to: engine.currentTime + 5, accurate: true) }
        if e == 22, engine.duration > 0 { engine.seek(to: engine.duration * 0.5, accurate: false) }
        if e == 30, engine.duration > 0 { engine.seek(to: engine.duration * 0.1, accurate: false) }
        if Int(el) % 5 == 0, !holdHist.isEmpty {
            let fps = displayLink.map { 1 / ($0.targetTimestamp - $0.timestamp) } ?? 0
            print("PACING display \(Int(fps.rounded())) Hz, vsyncs-per-frame histogram:", holdHist.sorted { $0.key < $1.key }.map { "\($0.key)×\($0.value)" }.joined(separator: " "))
            fflush(stdout); holdHist.removeAll()
        }
        if el >= seconds { finish() }
    }

    func finish() {
        timer?.invalidate()
        let mems = samples.map(\.mem), cpus = samples.map(\.cpu)
        var summary: [String: Any] = [
            "event": "summary", "engine": engineKind.rawValue, "label": engineKind.label, "media": media.lastPathComponent,
            "pid": getpid(),
            "memAvgMB": round1(mems.avg), "memPeakMB": round1(mems.max() ?? 0),
            "cpuAvgPct": round1(cpus.avg), "cpuPeakPct": round1(cpus.max() ?? 0),
            "firstFrameSec": firstFrameAt.map(round2) ?? -1,
            "finalPos": round1(engine.currentTime), "duration": round1(engine.duration),
            "warnings": engine.warnings.map(\.message),
            "diag": engine.diagnostics(),
        ]
        if let failure { summary["failure"] = failure }
        emit(summary)
        engine.close()
        exit(0)
    }

    func emit(_ obj: [String: Any]) {
        if let d = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]), let s = String(data: d, encoding: .utf8) {
            print("BENCH " + s); fflush(stdout)
        }
    }

    static func physFootprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return kr == KERN_SUCCESS ? info.phys_footprint : 0
    }

    static func cpuSeconds() -> Double {
        var u = rusage(); getrusage(RUSAGE_SELF, &u)
        return Double(u.ru_utime.tv_sec + u.ru_stime.tv_sec) + Double(u.ru_utime.tv_usec + u.ru_stime.tv_usec) / 1e6
    }
}

func round1(_ v: Double) -> Double { (v * 10).rounded() / 10 }
func round2(_ v: Double) -> Double { (v * 100).rounded() / 100 }
extension Array where Element == Double { var avg: Double { isEmpty ? 0 : reduce(0, +) / Double(count) } }
