import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

/// In-app hardware decoding (VTDecompressionSession) for the formats AVSampleBufferDisplayLayer would otherwise
/// decode itself. The layer then only presents finished frames at their timestamps.
///
/// Why: measured on screen (ScreenCaptureKit, distinct frames per second), the layer's internal decoding of
/// real Blu-ray HEVC (4K HDR10, ~50 Mbps, 8-deep B-pyramids) silently repeats ~25–35% of frames — 194–222
/// distinct frames in 12 s instead of ~288 — while its own metrics report almost no drops. That's the jitter.
/// Decoding ourselves, pipelined a few frames ahead like mpv/IINA, shows every frame (299–301 in 12 s).
///
/// Decoding still happens in VTDecoderXPCService (hardware); we hold the reorder window plus a few frames of
/// look-ahead as (usually lossless-compressed) IOSurfaces.
final class HWVideoDecoder {
    private var session: VTDecompressionSession?
    private let cond = NSCondition()
    private var ready: [CMSampleBuffer] = []          // decoded, sorted by PTS
    private var inFlight = 0
    private var reorderDepth = 4
    private let lookahead = 4
    private var lastEmitted = CMTime.negativeInfinity
    private var formats: [OSType: CMVideoFormatDescription] = [:]
    private(set) var failures = 0

    init?(format: CMVideoFormatDescription) {
        let codec = CMFormatDescriptionGetMediaSubType(format)
        if codec == kCMVideoCodecType_VP9 || codec == kCMVideoCodecType_AV1 { VTRegisterSupplementalVideoDecoderIfAvailable(codec) }
        // Native output format (often lossless-compressed '&xv0' surfaces): no conversion, least memory.
        let attrs: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary]
        let spec: [CFString: Any] = [kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder: true]
        var s: VTDecompressionSession?
        guard VTDecompressionSessionCreate(allocator: nil, formatDescription: format, decoderSpecification: spec as CFDictionary,
                                           imageBufferAttributes: attrs as CFDictionary, outputCallback: nil,
                                           decompressionSessionOut: &s) == noErr, let s else { return nil }
        VTSessionSetProperty(s, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        session = s
    }

    deinit { if let session { VTDecompressionSessionInvalidate(session) } }

    /// After a seek: wait for frames in flight, drop everything decoded.
    func flush() {
        if let session { VTDecompressionSessionWaitForAsynchronousFrames(session) }
        cond.lock()
        ready.removeAll(); inFlight = 0; lastEmitted = .negativeInfinity
        cond.unlock()
    }

    /// Next frame in display order. `pull` returns the next compressed sample (nil = none available right now);
    /// `atEnd` says whether that nil means end of stream (then the reorder window is drained).
    func nextFrame(pull: () -> CMSampleBuffer?, atEnd: () -> Bool) -> CMSampleBuffer? {
        guard let session else { return nil }
        var inputDry = false
        while true {
            cond.lock()
            let want = inFlight + ready.count < reorderDepth + lookahead
            cond.unlock()
            if want && !inputDry {
                if let sb = pull() { submit(sb, session); continue }
                inputDry = true
            }
            cond.lock()
            let ended = inputDry && atEnd()
            if ready.count > reorderDepth || (ended && inFlight == 0 && !ready.isEmpty) {
                let f = ready.removeFirst()
                cond.unlock()
                if f.presentationTimeStamp < lastEmitted {
                    reorderDepth = min(reorderDepth + 1, 16)      // deeper reordering than assumed; skip it
                    continue
                }
                lastEmitted = f.presentationTimeStamp
                return f
            }
            if inFlight == 0 { cond.unlock(); return nil }       // need input that isn't there yet (or done)
            // Wait for an in-flight frame to complete (normally a few ms).
            _ = cond.wait(until: Date().addingTimeInterval(0.2))
            cond.unlock()
        }
    }

    private func submit(_ sb: CMSampleBuffer, _ session: VTDecompressionSession) {
        let hide = (CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [NSDictionary])?
            .first?[kCMSampleAttachmentKey_DoNotDisplay] as? Bool ?? false
        let duration = sb.duration
        cond.lock(); inFlight += 1; cond.unlock()
        let st = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sb, flags: [._EnableAsynchronousDecompression], infoFlagsOut: nil) { [weak self] status, _, image, pts, _ in
            guard let self else { return }
            let out = (status == noErr && !hide && pts.isValid) ? image.flatMap { self.wrap($0, pts: pts, duration: duration) } : nil
            self.cond.lock()
            self.inFlight -= 1
            if status != noErr { self.failures += 1 }
            if let out {
                let i = self.ready.firstIndex { $0.presentationTimeStamp > pts } ?? self.ready.endIndex
                self.ready.insert(out, at: i)
            }
            self.cond.signal()
            self.cond.unlock()
        }
        if st != noErr {
            cond.lock(); inFlight = max(0, inFlight - 1); failures += 1; cond.unlock()
        }
    }

    private func wrap(_ image: CVImageBuffer, pts: CMTime, duration: CMTime) -> CMSampleBuffer? {
        let pf = CVPixelBufferGetPixelFormatType(image)
        var fd = formats[pf]
        if fd == nil || !CMVideoFormatDescriptionMatchesImageBuffer(fd!, imageBuffer: image) {
            var f: CMVideoFormatDescription?
            CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: image, formatDescriptionOut: &f)
            fd = f; formats[pf] = f
        }
        guard let fd else { return nil }
        var timing = CMSampleTimingInfo(duration: duration, presentationTimeStamp: pts, decodeTimeStamp: .invalid)
        var out: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: image, formatDescription: fd, sampleTiming: &timing, sampleBufferOut: &out)
        return out
    }
}
