import Foundation
import CoreVideo
import CoreGraphics
import VideoToolbox

/// Finds black bars (letterbox / pillarbox) in a decoded frame by scanning inward from each edge on a sparse
/// grid of luma samples. Works on the frame already on screen (IOSurface), so it costs no extra decoding;
/// one analysis reads ~10k pixels (~0.1 ms).
enum BlackBarDetector {
    /// Returns the content rect normalized to the frame (origin top-left), `CGRect(0,0,1,1)` for no bars,
    /// or nil when the frame is too dark/flat to judge.
    static func contentRect(_ source: CVPixelBuffer) -> CGRect? {
        // Hardware decoders hand out losslessly-compressed surfaces ('&8v0', '&xv0') the CPU can't read.
        // Convert (and shrink) on the GPU to a small standard NV12 frame first — one tiny transfer per sample.
        guard let pb = downscaled(source) else { return nil }
        let fmt = CVPixelBufferGetPixelFormatType(pb)
        let bytesPerSample: Int
        let full: Bool
        switch fmt {
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange: bytesPerSample = 1; full = false
        case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange: bytesPerSample = 1; full = true
        case kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange: bytesPerSample = 2; full = false
        case kCVPixelFormatType_420YpCbCr10BiPlanarFullRange: bytesPerSample = 2; full = true
        default: return nil   // other layouts (e.g. packed RGB): skip
        }
        guard CVPixelBufferLockBaseAddress(pb, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(pb, 0) else { return nil }
        let w = CVPixelBufferGetWidthOfPlane(pb, 0), h = CVPixelBufferGetHeightOfPlane(pb, 0)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
        guard w >= 64, h >= 64 else { return nil }

        // 8-bit luma value (P010 keeps the 10 bits in the top of each 16-bit word → take the high byte).
        @inline(__always) func luma(_ x: Int, _ y: Int) -> Int {
            let row = base + y * stride
            return bytesPerSample == 1 ? Int(row.load(fromByteOffset: x, as: UInt8.self))
                                       : Int(row.load(fromByteOffset: x * 2 + 1, as: UInt8.self))
        }
        let black = full ? 0 : 16
        let threshold = black + 20      // used for the "is the picture bright enough" check
        let barMax = black + 10         // every sample on a bar line must be at most this…
        let barMean = black + 4         // …and the line must average almost exactly black (dark picture has texture)

        // Is the picture bright enough to tell bars from content?
        var centreSum = 0, centreN = 0
        for y in Swift.stride(from: h / 4, to: h * 3 / 4, by: max(1, h / 32)) {
            for x in Swift.stride(from: w / 4, to: w * 3 / 4, by: max(1, w / 32)) { centreSum += luma(x, y); centreN += 1 }
        }
        guard centreN > 0, centreSum / centreN > threshold + 12 else { return nil }

        let samples = 48
        /// A line is "black" when almost all samples along it are below threshold.
        func columnIsBlack(_ x: Int) -> Bool {
            var sum = 0
            for i in 0..<samples { let v = luma(x, (h - 1) * i / (samples - 1)); if v > barMax { return false }; sum += v }
            return sum / samples <= barMean
        }
        func rowIsBlack(_ y: Int) -> Bool {
            var sum = 0
            for i in 0..<samples { let v = luma((w - 1) * i / (samples - 1), y); if v > barMax { return false }; sum += v }
            return sum / samples <= barMean
        }
        let step = 1
        var left = 0; while left < w / 3, columnIsBlack(left) { left += step }
        var right = w - 1; while right > w * 2 / 3, columnIsBlack(right) { right -= step }
        var top = 0; while top < h / 3, rowIsBlack(top) { top += step }
        var bottom = h - 1; while bottom > h * 2 / 3, rowIsBlack(bottom) { bottom -= step }

        // Ignore slivers (< 1%) and refuse to keep less than 40% of either dimension.
        if Double(left) < Double(w) * 0.01 { left = 0 }
        if Double(w - 1 - right) < Double(w) * 0.01 { right = w - 1 }
        if Double(top) < Double(h) * 0.01 { top = 0 }
        if Double(h - 1 - bottom) < Double(h) * 0.01 { bottom = h - 1 }
        let cw = right - left + 1, ch = bottom - top + 1
        guard Double(cw) >= Double(w) * 0.4, Double(ch) >= Double(h) * 0.4 else { return CGRect(x: 0, y: 0, width: 1, height: 1) }
        return CGRect(x: Double(left) / Double(w), y: Double(top) / Double(h), width: Double(cw) / Double(w), height: Double(ch) / Double(h))
    }
}

extension BlackBarDetector {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var session: VTPixelTransferSession?

    static func downscaled(_ src: CVPixelBuffer) -> CVPixelBuffer? {
        let sw = CVPixelBufferGetWidth(src), sh = CVPixelBufferGetHeight(src)
        guard sw > 0, sh > 0 else { return nil }
        let w = min(640, sw) & ~1, h = max(64, Int(Double(w) * Double(sh) / Double(sw))) & ~1
        var out: CVPixelBuffer?
        let attrs: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary]
        guard CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, attrs as CFDictionary, &out) == kCVReturnSuccess, let out else { return nil }
        lock.lock(); defer { lock.unlock() }
        if session == nil { VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &session) }
        guard let session, VTPixelTransferSessionTransferImage(session, from: src, to: out) == noErr else { return nil }
        return out
    }
}

/// Accumulates samples over time and decides on a stable crop: the *least* crop among the samples (so a dark
/// scene can never cut into the picture), ignoring a single outlier once there are 3+ samples (so one odd frame
/// can't undo a crop the others agree on).
struct CropDecider {
    private(set) var samples: [CGRect] = []
    var validSamples: Int { samples.count }

    mutating func add(_ r: CGRect) { samples.append(r) }

    /// Crop to apply (nil = none). Needs two agreeing samples; tiny crops (< 2%) are ignored.
    var decision: CGRect? {
        guard samples.count >= 2 else { return nil }
        var pool = samples.sorted { $0.width * $0.height > $1.width * $1.height }   // least crop first
        if pool.count >= 3 {
            let a = pool[0], b = pool[1]
            let agree = abs(a.width - b.width) < 0.01 && abs(a.height - b.height) < 0.01
            if !agree { pool.removeFirst() }    // lone outlier
        }
        let u = pool.dropFirst().reduce(pool[0]) { $0.union($1) }
        if u.width > 0.98 && u.height > 0.98 { return nil }
        return u
    }

    mutating func reset() { samples.removeAll() }
}

enum VideoGeometry {
    /// Where the *full* video frame must be placed (view coordinates, origin bottom-left) so that the
    /// `crop` part of it is aspect-fitted to `bounds`. Without crop this is the normal aspect-fit rect.
    static func frameRect(bounds: CGRect, videoSize: CGSize, crop: CGRect?) -> CGRect {
        guard videoSize.width > 0, videoSize.height > 0 else { return bounds }
        let c = crop ?? CGRect(x: 0, y: 0, width: 1, height: 1)
        let visible = CGSize(width: videoSize.width * c.width, height: videoSize.height * c.height)
        let scale = min(bounds.width / visible.width, bounds.height / visible.height)
        let fw = videoSize.width * scale, fh = videoSize.height * scale
        // crop.y is from the top; view coordinates grow upward.
        let cropCenterX = (c.midX) * fw, cropCenterYFromTop = (c.midY) * fh
        let x = bounds.midX - cropCenterX
        let y = bounds.midY - (fh - cropCenterYFromTop)
        return CGRect(x: x, y: y, width: fw, height: fh)
    }
}
