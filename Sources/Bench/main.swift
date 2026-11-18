import AppKit

let args = CommandLine.arguments
func arg(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}
func mediaURL(_ s: String) -> URL { s.contains("://") ? URL(string: s)! : URL(fileURLWithPath: s) }

let app = NSApplication.shared
app.setActivationPolicy(.regular)

if let p = arg("--mkvtest") {
    MKVTest.run(p)
    exit(0)
} else if args.contains("--bench"), let m = arg("--media") {
    let kind = EngineKind(rawValue: arg("--engine") ?? "C") ?? .sampleBuffer
    let runner = BenchRunner(engine: kind, media: mediaURL(m), seconds: Double(arg("--seconds") ?? "45") ?? 45)
    app.delegate = runner
    withExtendedLifetime(runner) { app.run() }
} else {
    print("usage: LightPlayer --bench --engine A|B|C|D --media <path|url> [--seconds N]")
}
