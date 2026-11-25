import Foundation
import CoreMedia
import CoreVideo
import VideoToolbox
import ImageIO
import UniformTypeIdentifiers
import CFFmpeg

/// Seek-bar thumbnails for one open video, made on demand while the pointer hovers the timeline.
///
/// - Own light demuxer (video stream only, no audio, no playback decoder) and a non-real-time VideoToolbox
///   session (or FFmpeg's software decoder for codecs without hardware support); works the same whichever
///   engine plays the file.
/// - Each thumbnail is the keyframe at or before the hovered time: one seek + one decoded frame, scaled and
///   tone-mapped to SDR in one VideoToolbox transfer. With a container index (MP4 sample table, Matroska cues)
///   the keyframe is found without touching the file, so moving within one GOP costs nothing.
/// - Requests collapse to the newest one: while one thumbnail is being made, intermediate hover positions are
///   dropped, so the decoder never falls behind the pointer.
/// - Saved as small JPEGs in ThumbnailCache; only a handful of images stay in RAM, and the demuxer and decoder
///   are freed after 30 s without hovering.
final class ThumbnailGenerator {
    /// Main thread: a finished thumbnail for the newest request (image, keyframe time in seconds).
    var onThumbnail: ((CGImage, Double) -> Void)?

    private let url: URL
    private let applyRotation: Bool
    private let queue = DispatchQueue(label: "thumbnails", qos: .userInitiated)
    private let lock = NSLock()
    private var pending: (time: Double, maxPixels: Int)?
    private var running = false
    private var closed = false
    private var cacheCleared = false
    private var liveDemuxer: FFDemuxer?          // for interrupting a blocked network read on close
    private var observer: NSObjectProtocol?

    // Worker state (queue only).
    private var demuxer: FFDemuxer?
    private var openFailed = false
    private var trustIndex = false
    private var session: VTDecompressionSession?
    private var transfer: VTPixelTransferSession?
    private var folder: URL?
    private var folderPixels = 0
    private var onDisk: Set<Int> = []
    private var recent: [(key: Int, image: CGImage)] = []
    private var lastKey: Int?                   // last delivered keyframe (lock)
    private var useCount = 0
    private static let debug = ProcessInfo.processInfo.environment["LP_THUMB_DEBUG"] != nil

    init(url: URL, applyRotation: Bool) {
        self.url = url
        self.applyRotation = applyRotation
        observer = NotificationCenter.default.addObserver(forName: ThumbnailCache.didClear, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.lock.lock(); self.cacheCleared = true; self.lock.unlock()
        }
    }

    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }

    /// Cache folder name in use (so trimming leaves it alone).
    var folderName: String? { lock.lock(); defer { lock.unlock() }; return folder?.lastPathComponent }

    /// Main thread. `maxPixels`: longest side of the thumbnail in pixels.
    func request(time: Double, maxPixels: Int) {
        lock.lock()
        pending = (time, maxPixels)
        let start = !running && !closed
        if start { running = true }
        lock.unlock()
        if start { queue.async { self.drain() } }
    }

    /// The next delivery is sent even if it's the same keyframe as the last one (the preview was hidden).
    func forgetLastDelivered() { lock.lock(); lastKey = nil; lock.unlock() }

    func close() {
        lock.lock()
        closed = true; pending = nil
        let d = liveDemuxer
        lock.unlock()
        d?.interrupt()
        onThumbnail = nil
        queue.async { self.release() }
    }

    // MARK: Worker

    private func drain() {
        while true {
            lock.lock()
            guard let r = pending, !closed else { running = false; lock.unlock(); return }
            pending = nil
            if cacheCleared { cacheCleared = false; onDisk = []; recent = [] }
            lock.unlock()
            let t0 = Date()
            guard let (image, key) = thumbnail(at: r.time, maxPixels: r.maxPixels) else { continue }
            if Self.debug { NSLog("thumb %.1f s → key %d ms, %.1f ms", r.time, key, Date().timeIntervalSince(t0) * 1000) }
            scheduleIdleRelease()
            lock.lock()
            let repeated = key == lastKey
            lastKey = key
            lock.unlock()
            if repeated { continue }
            DispatchQueue.main.async { [weak self] in self?.onThumbnail?(image, Double(key) / 1000) }
        }
    }

    private func scheduleIdleRelease() {
        useCount += 1
        let n = useCount
        queue.asyncAfter(deadline: .now() + 30) { [weak self] in
            guard let self, self.useCount == n else { return }
            self.release()
        }
    }

    /// Frees the demuxer, decoder and cached images (reopened on the next hover).
    private func release() {
        lock.lock(); liveDemuxer = nil; lock.unlock()
        demuxer = nil
        if let session { VTDecompressionSessionInvalidate(session) }
        session = nil
        if let transfer { VTPixelTransferSessionInvalidate(transfer) }
        transfer = nil
        recent = []
        if Self.debug { NSLog("thumb: released") }
    }

    private func thumbnail(at time: Double, maxPixels: Int) -> (CGImage, Int)? {
        if folderPixels != maxPixels || folder == nil { setFolder(maxPixels) }
        guard let d = openDemuxer() else { return nil }
        let st = d.stream(d.videoIndex)
        let tb = av_q2d(st.pointee.time_base)

        // Keyframe from the container index, without reading the file.
        var key: Int?
        var seekTo = max(0, time)
        if trustIndex, let e = avformat_index_get_entry_from_timestamp(st, Int64(max(0, time) / tb), AVSEEK_FLAG_BACKWARD) {
            let s = Double(e.pointee.timestamp) * tb
            key = Int((s * 1000).rounded())
            seekTo = s + 0.0005
            if let hit = cached(key!) { return (hit, key!) }
        }

        d.seek(to: seekTo)
        guard let pkt = nextKeyframePacket(d) else { return nil }
        let raw = pkt.pointee.pts != lp_av_nopts() ? pkt.pointee.pts : pkt.pointee.dts
        if key == nil {
            key = Int((Double(raw) * tb * 1000).rounded())
            if let hit = cached(key!) { var p: UnsafeMutablePointer<AVPacket>? = pkt; av_packet_free(&p); return (hit, key!) }
        }
        guard let frame = decode(first: pkt, d), let image = render(frame, d, maxPixels: maxPixels) else { return nil }
        remember(key!, image)
        save(image, key!)
        return (image, key!)
    }

    private func openDemuxer() -> FFDemuxer? {
        if let demuxer { return demuxer }
        guard !openFailed else { return nil }
        let t0 = Date()
        guard let d = try? FFDemuxer(url: url.isFileURL ? url.path : url.absoluteString, source: nil, videoOnly: true),
              d.videoIndex >= 0, d.videoFormat != nil else { openFailed = true; return nil }
        lock.lock(); liveDemuxer = d; let isClosed = closed; lock.unlock()
        if isClosed { return nil }
        // Matroska reads its cues on the first seek; after that the index tells whether it covers the file
        // (a generic index only grows as packets are read, which would point to the wrong keyframes).
        d.seek(to: 0)
        let st = d.stream(d.videoIndex)
        let n = avformat_index_get_entries_count(st)
        if n > 1, d.duration > 0, let last = avformat_index_get_entry(st, n - 1) {
            trustIndex = Double(last.pointee.timestamp) * av_q2d(st.pointee.time_base) > d.duration * 0.5
        }
        if Self.debug { NSLog("thumb: opened in %.0f ms, %d index entries, trusted %d", Date().timeIntervalSince(t0) * 1000, n, trustIndex ? 1 : 0) }
        demuxer = d
        return d
    }

    private func nextKeyframePacket(_ d: FFDemuxer) -> UnsafeMutablePointer<AVPacket>? {
        for _ in 0..<600 {
            guard let pkt = d.readPacket() else { return nil }
            if pkt.pointee.stream_index == d.videoIndex && pkt.pointee.flags & AV_PKT_FLAG_KEY != 0 { return pkt }
            var p: UnsafeMutablePointer<AVPacket>? = pkt; av_packet_free(&p)
        }
        return nil
    }

    // MARK: Decoding

    private func decode(first pkt: UnsafeMutablePointer<AVPacket>, _ d: FFDemuxer) -> CVPixelBuffer? {
        if let sw = d.swVideo {
            // Software codecs: frame threading delays output by a few packets; the first frame out is the keyframe.
            var next: UnsafeMutablePointer<AVPacket>? = pkt
            for _ in 0..<64 {
                guard let p = next else { break }
                let isVideo = p.pointee.stream_index == d.videoIndex
                let sb = d.makeSampleBuffer(p)       // frees the packet
                if isVideo, let sb, let f = sw.decode(sb).first?.imageBuffer { return f }
                next = d.readPacket()
            }
            return sw.decode(nil).first?.imageBuffer
        }
        guard let sb = d.makeSampleBuffer(pkt), let fd = d.videoFormat else { return nil }
        if session == nil {
            let attrs: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary]
            var s: VTDecompressionSession?
            guard VTDecompressionSessionCreate(allocator: nil, formatDescription: fd, decoderSpecification: nil,
                                               imageBufferAttributes: attrs as CFDictionary, outputCallback: nil,
                                               decompressionSessionOut: &s) == noErr, let s else { return nil }
            VTSessionSetProperty(s, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanFalse)
            session = s
        }
        guard let session else { return nil }
        var out: CVPixelBuffer?
        let st = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sb, flags: [], infoFlagsOut: nil) { status, _, image, _, _ in
            if status == noErr { out = image }
        }
        VTDecompressionSessionWaitForAsynchronousFrames(session)
        if st != noErr {
            // e.g. invalidated after sleep: recreate next time.
            VTDecompressionSessionInvalidate(session); self.session = nil
        }
        return out
    }

    /// Scale + convert to 8-bit BT.709 BGRA in one VideoToolbox transfer (tone-maps HDR), then rotate if the
    /// file asks for it (phone videos; only when the engine shows it rotated).
    private func render(_ src: CVPixelBuffer, _ d: FFDemuxer, maxPixels: Int) -> CGImage? {
        if transfer == nil {
            var t: VTPixelTransferSession?
            guard VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &t) == noErr, let t else { return nil }
            VTSessionSetProperty(t, key: kVTPixelTransferPropertyKey_DestinationColorPrimaries, value: kCVImageBufferColorPrimaries_ITU_R_709_2)
            VTSessionSetProperty(t, key: kVTPixelTransferPropertyKey_DestinationTransferFunction, value: kCVImageBufferTransferFunction_ITU_R_709_2)
            VTSessionSetProperty(t, key: kVTPixelTransferPropertyKey_DestinationYCbCrMatrix, value: kCVImageBufferYCbCrMatrix_ITU_R_709_2)
            transfer = t
        }
        guard let transfer else { return nil }
        let natural = d.naturalSize
        let rotation = applyRotation ? quarterTurns(lp_stream_rotation(d.stream(d.videoIndex).pointee.codecpar)) : 0
        let shown = rotation % 2 == 1 ? CGSize(width: natural.height, height: natural.width) : natural
        let scale = Double(maxPixels) / Double(max(shown.width, shown.height, 1))
        let fw = max(2, Int((shown.width * scale / 2).rounded()) * 2), fh = max(2, Int((shown.height * scale / 2).rounded()) * 2)
        let (bw, bh) = rotation % 2 == 1 ? (fh, fw) : (fw, fh)
        var dst: CVPixelBuffer?
        let attrs: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary]
        guard CVPixelBufferCreate(nil, bw, bh, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &dst) == kCVReturnSuccess, let dst,
              VTPixelTransferSessionTransferImage(transfer, from: src, to: dst) == noErr else { return nil }
        var cg: CGImage?
        VTCreateCGImageFromCVPixelBuffer(dst, options: nil, imageOut: &cg)
        guard let cg else { return nil }
        return rotation == 0 ? cg : rotate(cg, quarterTurns: rotation)
    }

    /// Clockwise quarter turns for a display-matrix rotation (counter-clockwise degrees).
    private func quarterTurns(_ ccw: Double) -> Int {
        let q = Int((-ccw / 90).rounded()) % 4
        return q < 0 ? q + 4 : q
    }

    private func rotate(_ img: CGImage, quarterTurns q: Int) -> CGImage? {
        let w = img.width, h = img.height
        let (nw, nh) = q % 2 == 1 ? (h, w) : (w, h)
        guard let ctx = CGContext(data: nil, width: nw, height: nh, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: img.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        ctx.translateBy(x: CGFloat(nw) / 2, y: CGFloat(nh) / 2)
        ctx.rotate(by: -CGFloat(q) * .pi / 2)
        ctx.draw(img, in: CGRect(x: -CGFloat(w) / 2, y: -CGFloat(h) / 2, width: CGFloat(w), height: CGFloat(h)))
        return ctx.makeImage()
    }

    // MARK: Cache

    private func setFolder(_ maxPixels: Int) {
        let f = ThumbnailCache.folder(for: url, pixelWidth: maxPixels)
        lock.lock(); folder = f; lock.unlock()
        folderPixels = maxPixels
        recent = []
        let names = (try? FileManager.default.contentsOfDirectory(atPath: f.path)) ?? []
        onDisk = Set(names.compactMap { $0.hasSuffix(".jpg") ? Int($0.dropLast(4)) : nil })
        // Mark as recently used (expiry / size trimming go by the folder's date).
        if !onDisk.isEmpty { try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: f.path) }
    }

    private func cached(_ key: Int) -> CGImage? {
        if let i = recent.firstIndex(where: { $0.key == key }) {
            let hit = recent.remove(at: i); recent.append(hit)
            return hit.image
        }
        guard onDisk.contains(key), let folder else { return nil }
        let file = folder.appendingPathComponent("\(key).jpg")
        guard let src = CGImageSourceCreateWithURL(file as CFURL, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else {
            onDisk.remove(key)             // deleted (trimmed / cleared) or a partial file: make it again
            try? FileManager.default.removeItem(at: file)
            return nil
        }
        remember(key, img)
        return img
    }

    private func remember(_ key: Int, _ image: CGImage) {
        recent.append((key, image))
        if recent.count > 8 { recent.removeFirst() }
    }

    private func save(_ image: CGImage, _ key: Int) {
        guard let folder else { return }
        let file = folder.appendingPathComponent("\(key).jpg")
        func write() -> Bool {
            guard let dest = CGImageDestinationCreateWithURL(file as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return false }
            CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.75] as CFDictionary)
            return CGImageDestinationFinalize(dest)
        }
        if !write() {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            guard write() else { return }
        }
        onDisk.insert(key)
    }
}
