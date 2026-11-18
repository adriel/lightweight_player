// Measures on-screen frame cadence of an app's window with ScreenCaptureKit.
// usage: swift Bench/cadence.swift <pid> <seconds>
// Prints how many display refreshes each new video frame stayed on screen. 23.976 fps on 60 Hz should be a
// strict 2,3,2,3 pattern; 1s / 4s / runs of 2,2 or 3,3 are judder.
import Foundation
import AppKit
_ = NSApplication.shared
import ScreenCaptureKit
import CoreMedia
import CoreVideo

let pid = pid_t(CommandLine.arguments[1])!
let seconds = Double(CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "8")!

final class Sink: NSObject, SCStreamOutput {
    var times: [Double] = []
    var lastSig: UInt64 = 0
    func stream(_ s: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen,
              let atts = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = atts.first?[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete,
              let pb = sb.imageBuffer else { return }
        // Signature of a central region (ignores HUD/title changes at the edges).
        CVPixelBufferLockBaseAddress(pb, .readOnly); defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb), bpr = CVPixelBufferGetBytesPerRow(pb)
        let base = CVPixelBufferGetBaseAddress(pb)!
        var sig: UInt64 = 1469598103934665603
        for y in stride(from: h / 5, to: h * 3 / 5, by: 3) {
            let row = base + y * bpr
            for x in stride(from: w / 5, to: w * 4 / 5, by: 3) {
                sig = (sig ^ UInt64(row.load(fromByteOffset: x * 4 + 1, as: UInt8.self))) &* 1099511628211
            }
        }
        guard sig != lastSig else { return }
        lastSig = sig
        times.append(sb.presentationTimeStamp.seconds)
    }
}

let sink = Sink()
let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
guard let win = content.windows.filter({ $0.owningApplication?.processID == pid && $0.windowLayer == 0 })
        .max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }) else {
    print("window not found"); exit(1)
}
let filter = SCContentFilter(desktopIndependentWindow: win)
let cfg = SCStreamConfiguration()
cfg.width = 480; cfg.height = Int(480 * win.frame.height / win.frame.width)
cfg.minimumFrameInterval = CMTime(value: 1, timescale: 120)
cfg.pixelFormat = kCVPixelFormatType_32BGRA
cfg.queueDepth = 8
cfg.showsCursor = false
let stream = SCStream(filter: filter, configuration: cfg, delegate: nil)
try stream.addStreamOutput(sink, type: .screen, sampleHandlerQueue: DispatchQueue(label: "cap"))
try await stream.startCapture()
try await Task.sleep(for: .seconds(seconds))
try await stream.stopCapture()

let refresh = 1.0 / 60.0
let holds = zip(sink.times.dropFirst(), sink.times).map { Int((($0 - $1) / refresh).rounded()) }
var hist: [Int: Int] = [:]
for h in holds { hist[h, default: 0] += 1 }
let useful = holds.filter { $0 >= 1 && $0 <= 6 }
var repeats = 0
for i in 1..<max(useful.count, 1) where useful.count > 1 && useful[i] == useful[i - 1] { repeats += 1 }
print("frames \(sink.times.count)  hist \(hist.sorted { $0.key < $1.key }.map { "\($0.key)×\($0.value)" }.joined(separator: " "))")
print(String(format: "cadence breaks (same hold twice in a row): %d of %d  |  1-or-4+ refresh holds: %d", repeats, useful.count,
             useful.filter { $0 == 1 || $0 >= 4 }.count))
// For 3:2 content: breaks only where two consecutive holds are both 2 or both 3 (static shots ignored).
var pulldownBreaks = 0, pulldownPairs = 0
for i in 1..<max(holds.count, 1) where holds.count > 1 && [2, 3].contains(holds[i]) && [2, 3].contains(holds[i - 1]) {
    pulldownPairs += 1
    if holds[i] == holds[i - 1] { pulldownBreaks += 1 }
}
print("3:2 cadence breaks: \(pulldownBreaks) of \(pulldownPairs) pairs")
print("sequence:", useful.prefix(60).map(String.init).joined(separator: ""))
