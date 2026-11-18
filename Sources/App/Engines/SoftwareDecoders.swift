import Foundation
import CoreMedia
import CoreVideo
import AudioToolbox
import Accelerate
import CFFmpeg

/// Shared helpers: feed a (pooled, compressed) CMSampleBuffer to libavcodec without copying it again.
private func withPacket(_ sb: CMSampleBuffer?, _ pkt: UnsafeMutablePointer<AVPacket>, _ body: (UnsafeMutablePointer<AVPacket>?) -> Void) {
    guard let sb else { body(nil); return }   // nil = drain
    guard let block = sb.dataBuffer else { return }
    var len = 0
    var ptr: UnsafeMutablePointer<CChar>?
    guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &len, dataPointerOut: &ptr) == noErr, let ptr else { return }
    av_packet_unref(pkt)
    pkt.pointee.data = UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: UInt8.self)
    pkt.pointee.size = Int32(len)
    let pts = sb.presentationTimeStamp, dts = sb.decodeTimeStamp
    pkt.pointee.pts = pts.isValid ? pts.convertScale(90000, method: .default).value : lp_av_nopts()
    pkt.pointee.dts = dts.isValid ? dts.convertScale(90000, method: .default).value : lp_av_nopts()
    pkt.pointee.duration = sb.duration.isValid ? sb.duration.convertScale(90000, method: .default).value : 0
    body(pkt)
    // Payload belongs to the CMSampleBuffer; detach before the next unref.
    pkt.pointee.data = nil; pkt.pointee.size = 0
}

// MARK: - Audio

/// Decodes formats Core Audio can't (DTS, TrueHD, Vorbis, WMA, …) to interleaved Float32 LPCM.
/// Runs single-threaded on the feed queue; output goes to AVSampleBufferAudioRenderer like any other audio.
final class SWAudioDecoder {
    private var ctx: UnsafeMutablePointer<AVCodecContext>?
    private var frame: UnsafeMutablePointer<AVFrame>? = av_frame_alloc()
    private var pkt: UnsafeMutablePointer<AVPacket>? = av_packet_alloc()
    private var format: CMAudioFormatDescription?
    private var formatKey = (0, 0)
    private let pool = CMMemoryPoolCreate(options: nil)

    init?(par: UnsafeMutablePointer<AVCodecParameters>, coreOnly: Bool) {
        guard let codec = avcodec_find_decoder(par.pointee.codec_id), let c = avcodec_alloc_context3(codec) else { return nil }
        ctx = c
        avcodec_parameters_to_context(c, par)
        c.pointee.pkt_timebase = AVRational(num: 1, den: 90000)
        c.pointee.thread_count = 1
        c.pointee.request_sample_fmt = AV_SAMPLE_FMT_FLT
        var opts: OpaquePointer?
        if coreOnly { av_dict_set(&opts, "core_only", "1", 0) } // DTS-HD MA: lossy core only (~4x cheaper)
        let r = avcodec_open2(c, codec, &opts)
        av_dict_free(&opts)
        if r < 0 { avcodec_free_context(&ctx); return nil }
    }

    deinit { avcodec_free_context(&ctx); av_frame_free(&frame); av_packet_free(&pkt) }

    func flush() { if let ctx { avcodec_flush_buffers(ctx) } }

    /// Feeds one compressed sample (nil = end of stream) and returns any decoded PCM buffers.
    func decode(_ sb: CMSampleBuffer?) -> [CMSampleBuffer] {
        guard let ctx, let frame, let pkt else { return [] }
        withPacket(sb, pkt) { p in _ = avcodec_send_packet(ctx, p) }
        var out: [CMSampleBuffer] = []
        while avcodec_receive_frame(ctx, frame) == 0 {
            if let b = makeBuffer(frame) { out.append(b) }
            av_frame_unref(frame)
        }
        return out
    }

    private func makeBuffer(_ f: UnsafeMutablePointer<AVFrame>) -> CMSampleBuffer? {
        let ch = Int(f.pointee.ch_layout.nb_channels), n = Int(f.pointee.nb_samples), rate = Int(f.pointee.sample_rate)
        guard ch > 0, n > 0 else { return nil }
        if format == nil || formatKey != (ch, rate) { format = makeFormat(f); formatKey = (ch, rate) }
        guard let format else { return nil }
        let bytes = n * ch * 4
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: bytes, blockAllocator: CMMemoryPoolGetAllocator(pool),
                                                 customBlockSource: nil, offsetToData: 0, dataLength: bytes, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block) == noErr,
              let block else { return nil }
        var raw: UnsafeMutablePointer<CChar>?
        CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: nil, dataPointerOut: &raw)
        let dst = UnsafeMutableRawPointer(raw!).assumingMemoryBound(to: Float.self)
        let fmt = AVSampleFormat(rawValue: f.pointee.format)
        let planar = av_sample_fmt_is_planar(fmt) != 0
        // Interleave / convert with Accelerate (strided copies, no per-sample Swift loops).
        for c in 0..<ch {
            let src = UnsafeRawPointer(planar ? f.pointee.extended_data[c]! : f.pointee.extended_data[0]!)
            let srcStride = planar ? 1 : ch
            let srcOff = planar ? 0 : c
            switch fmt {
            case AV_SAMPLE_FMT_FLT, AV_SAMPLE_FMT_FLTP:
                cblas_scopy(Int32(n), src.assumingMemoryBound(to: Float.self) + srcOff, Int32(srcStride), dst + c, Int32(ch))
            case AV_SAMPLE_FMT_S32, AV_SAMPLE_FMT_S32P:
                vDSP_vflt32(src.assumingMemoryBound(to: Int32.self) + srcOff, srcStride, dst + c, ch, vDSP_Length(n))
                var scale = Float(1.0 / 2147483648.0)
                vDSP_vsmul(dst + c, ch, &scale, dst + c, ch, vDSP_Length(n))
            case AV_SAMPLE_FMT_S16, AV_SAMPLE_FMT_S16P:
                vDSP_vflt16(src.assumingMemoryBound(to: Int16.self) + srcOff, srcStride, dst + c, ch, vDSP_Length(n))
                var scale = Float(1.0 / 32768.0)
                vDSP_vsmul(dst + c, ch, &scale, dst + c, ch, vDSP_Length(n))
            case AV_SAMPLE_FMT_DBL, AV_SAMPLE_FMT_DBLP:
                vDSP_vdpsp(src.assumingMemoryBound(to: Double.self) + srcOff, srcStride, dst + c, ch, vDSP_Length(n))
            default:
                return nil
            }
        }
        let ts = f.pointee.best_effort_timestamp != lp_av_nopts() ? f.pointee.best_effort_timestamp : f.pointee.pts
        var sb: CMSampleBuffer?
        CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: n,
                                                             presentationTimeStamp: CMTime(value: ts, timescale: 90000), packetDescriptions: nil, sampleBufferOut: &sb)
        return sb
    }

    private func makeFormat(_ f: UnsafeMutablePointer<AVFrame>) -> CMAudioFormatDescription? {
        let ch = Int(f.pointee.ch_layout.nb_channels)
        var asbd = AudioStreamBasicDescription(mSampleRate: Double(f.pointee.sample_rate), mFormatID: kAudioFormatLinearPCM,
                                               mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, mBytesPerPacket: UInt32(4 * ch),
                                               mFramesPerPacket: 1, mBytesPerFrame: UInt32(4 * ch), mChannelsPerFrame: UInt32(ch), mBitsPerChannel: 32, mReserved: 0)
        // Describe each channel so 5.1 / 7.1 map to the right speakers (FFmpeg and Core Audio orders differ).
        var layout = f.pointee.ch_layout
        let labels: [AudioChannelLabel] = (0..<ch).map { i in
            let chan = av_channel_layout_channel_from_index(&layout, UInt32(i))
            let hasSide = av_channel_layout_index_from_channel(&layout, AV_CHAN_SIDE_LEFT) >= 0
            switch chan {
            case AV_CHAN_FRONT_LEFT: return kAudioChannelLabel_Left
            case AV_CHAN_FRONT_RIGHT: return kAudioChannelLabel_Right
            case AV_CHAN_FRONT_CENTER: return kAudioChannelLabel_Center
            case AV_CHAN_LOW_FREQUENCY: return kAudioChannelLabel_LFEScreen
            case AV_CHAN_BACK_LEFT: return hasSide ? kAudioChannelLabel_RearSurroundLeft : kAudioChannelLabel_LeftSurround
            case AV_CHAN_BACK_RIGHT: return hasSide ? kAudioChannelLabel_RearSurroundRight : kAudioChannelLabel_RightSurround
            case AV_CHAN_SIDE_LEFT: return kAudioChannelLabel_LeftSurround
            case AV_CHAN_SIDE_RIGHT: return kAudioChannelLabel_RightSurround
            case AV_CHAN_BACK_CENTER: return kAudioChannelLabel_CenterSurround
            case AV_CHAN_FRONT_LEFT_OF_CENTER: return kAudioChannelLabel_LeftCenter
            case AV_CHAN_FRONT_RIGHT_OF_CENTER: return kAudioChannelLabel_RightCenter
            default: return kAudioChannelLabel_Discrete_0 | AudioChannelLabel(i)
            }
        }
        let size = MemoryLayout<AudioChannelLayout>.size + max(0, ch - 1) * MemoryLayout<AudioChannelDescription>.size
        let raw = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: MemoryLayout<AudioChannelLayout>.alignment)
        defer { raw.deallocate() }
        raw.initializeMemory(as: UInt8.self, repeating: 0, count: size)
        let acl = raw.assumingMemoryBound(to: AudioChannelLayout.self)
        acl.pointee.mChannelLayoutTag = kAudioChannelLayoutTag_UseChannelDescriptions
        acl.pointee.mNumberChannelDescriptions = UInt32(ch)
        let descs = (raw + MemoryLayout<AudioChannelLayout>.offset(of: \AudioChannelLayout.mChannelDescriptions)!).assumingMemoryBound(to: AudioChannelDescription.self)
        for i in 0..<ch { descs[i].mChannelLabel = labels[i] }
        var fd: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: size, layout: acl, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &fd)
        return fd
    }
}

// MARK: - Video

/// Software video decoding for codecs without a VideoToolbox decoder on this Mac (AV1 on M1/M2, VP8, VC-1, …).
/// Frames are copied once into IOSurface-backed NV12/P010 pixel buffers from a pool and handed to
/// AVSampleBufferDisplayLayer, so display/scaling/HDR still happen on the GPU.
final class SWVideoDecoder {
    private var ctx: UnsafeMutablePointer<AVCodecContext>?
    private var frame: UnsafeMutablePointer<AVFrame>? = av_frame_alloc()
    private var pkt: UnsafeMutablePointer<AVPacket>? = av_packet_alloc()
    private var pool: CVPixelBufferPool?
    private var poolKey = (0, 0, OSType(0))
    private var format: CMVideoFormatDescription?
    let decoderName: String
    var threads: Int { Int(ctx?.pointee.thread_count ?? 0) }

    init?(par: UnsafeMutablePointer<AVCodecParameters>) {
        let id = par.pointee.codec_id
        let codec = (id == AV_CODEC_ID_AV1 ? avcodec_find_decoder_by_name("libdav1d") : nil) ?? avcodec_find_decoder(id)
        guard let codec, let c = avcodec_alloc_context3(codec) else { return nil }
        ctx = c
        decoderName = String(cString: codec.pointee.name)
        avcodec_parameters_to_context(c, par)
        c.pointee.pkt_timebase = AVRational(num: 1, den: 90000)
        // Leave efficiency cores some room; a small frame delay keeps few decoded frames in flight (RAM).
        c.pointee.thread_count = Int32(min(6, max(2, ProcessInfo.processInfo.activeProcessorCount - 2)))
        var opts: OpaquePointer?
        // Measured on M2 (1080p AV1): delay 1 = 72 MB / 23% CPU vs delay 2 = 100 MB / 33%. Larger frames need
        // the extra frame-level parallelism to keep up in real time.
        if decoderName == "libdav1d" {
            let big = Int(par.pointee.width) * Int(par.pointee.height) > 2_100_000
            av_dict_set(&opts, "max_frame_delay", big ? "2" : "1", 0)
        }
        let r = avcodec_open2(c, codec, &opts)
        av_dict_free(&opts)
        if r < 0 { avcodec_free_context(&ctx); return nil }
    }

    deinit { avcodec_free_context(&ctx); av_frame_free(&frame); av_packet_free(&pkt) }

    func flush() { if let ctx { avcodec_flush_buffers(ctx) } }

    func decode(_ sb: CMSampleBuffer?) -> [CMSampleBuffer] {
        guard let ctx, let frame, let pkt else { return [] }
        withPacket(sb, pkt) { p in _ = avcodec_send_packet(ctx, p) }
        var out: [CMSampleBuffer] = []
        while avcodec_receive_frame(ctx, frame) == 0 {
            if let b = makeBuffer(frame) { out.append(b) }
            av_frame_unref(frame)
        }
        return out
    }

    private func makeBuffer(_ f: UnsafeMutablePointer<AVFrame>) -> CMSampleBuffer? {
        let w = Int(f.pointee.width), h = Int(f.pointee.height)
        let fmt = AVPixelFormat(rawValue: f.pointee.format)
        let tenBit: Bool
        switch fmt {
        case AV_PIX_FMT_YUV420P, AV_PIX_FMT_YUVJ420P: tenBit = false
        case AV_PIX_FMT_YUV420P10LE: tenBit = true
        default: return nil
        }
        let full = f.pointee.color_range == AVCOL_RANGE_JPEG || fmt == AV_PIX_FMT_YUVJ420P
        let cvFormat: OSType = tenBit ? (full ? kCVPixelFormatType_420YpCbCr10BiPlanarFullRange : kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange)
                                      : (full ? kCVPixelFormatType_420YpCbCr8BiPlanarFullRange : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
        if pool == nil || poolKey != (w, h, cvFormat) {
            let attrs: [CFString: Any] = [kCVPixelBufferPixelFormatTypeKey: cvFormat, kCVPixelBufferWidthKey: w, kCVPixelBufferHeightKey: h,
                                          kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary, kCVPixelBufferMetalCompatibilityKey: true]
            CVPixelBufferPoolCreate(nil, [kCVPixelBufferPoolMinimumBufferCountKey: 3] as CFDictionary, attrs as CFDictionary, &pool)
            poolKey = (w, h, cvFormat)
            format = nil
        }
        var pbOut: CVPixelBuffer?
        guard let pool, CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pbOut) == kCVReturnSuccess, let pb = pbOut else { return nil }
        CVPixelBufferLockBaseAddress(pb, [])
        let ys = Int(f.pointee.linesize.0), us = Int(f.pointee.linesize.1), vs = Int(f.pointee.linesize.2)
        let dY = CVPixelBufferGetBaseAddressOfPlane(pb, 0)!, dYs = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
        let dC = CVPixelBufferGetBaseAddressOfPlane(pb, 1)!, dCs = CVPixelBufferGetBytesPerRowOfPlane(pb, 1)
        let sY = UnsafeRawPointer(f.pointee.data.0!), sU = UnsafeRawPointer(f.pointee.data.1!), sV = UnsafeRawPointer(f.pointee.data.2!)
        let cw = (w + 1) / 2, chh = (h + 1) / 2
        if !tenBit {
            for y in 0..<h { (dY + y * dYs).copyMemory(from: sY + y * ys, byteCount: w) }
            // Interleave U and V into the NV12 chroma plane with vImage.
            for y in 0..<chh {
                var srcU = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: sU + y * us), height: 1, width: vImagePixelCount(cw), rowBytes: us)
                var srcV = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: sV + y * vs), height: 1, width: vImagePixelCount(cw), rowBytes: vs)
                withUnsafePointer(to: &srcU) { pu in
                    withUnsafePointer(to: &srcV) { pv in
                        var planes: [UnsafePointer<vImage_Buffer>?] = [pu, pv]
                        var dests: [UnsafeMutableRawPointer?] = [dC + y * dCs, dC + y * dCs + 1]
                        _ = vImageConvert_PlanarToChunky8(&planes, &dests, 2, 2, vImagePixelCount(cw), 1, dCs, vImage_Flags(kvImageNoFlags))
                    }
                }
            }
        } else {
            // P010: 10-bit samples in the high bits of 16-bit words.
            for y in 0..<h {
                let s = (sY + y * ys).assumingMemoryBound(to: UInt16.self), d = (dY + y * dYs).assumingMemoryBound(to: UInt16.self)
                for x in 0..<w { d[x] = s[x] << 6 }
            }
            for y in 0..<chh {
                let u = (sU + y * us).assumingMemoryBound(to: UInt16.self), v = (sV + y * vs).assumingMemoryBound(to: UInt16.self)
                let d = (dC + y * dCs).assumingMemoryBound(to: UInt16.self)
                for x in 0..<cw { d[2 * x] = u[x] << 6; d[2 * x + 1] = v[x] << 6 }
            }
        }
        CVPixelBufferUnlockBaseAddress(pb, [])
        attachColor(pb, f)
        if format == nil { CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: pb, formatDescriptionOut: &format) }
        guard let format else { return nil }
        let ts = f.pointee.best_effort_timestamp != lp_av_nopts() ? f.pointee.best_effort_timestamp : f.pointee.pts
        var timing = CMSampleTimingInfo(duration: f.pointee.duration > 0 ? CMTime(value: f.pointee.duration, timescale: 90000) : .invalid,
                                        presentationTimeStamp: CMTime(value: ts, timescale: 90000), decodeTimeStamp: .invalid)
        var sb: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: pb, formatDescription: format, sampleTiming: &timing, sampleBufferOut: &sb)
        return sb
    }

    private func attachColor(_ pb: CVPixelBuffer, _ f: UnsafeMutablePointer<AVFrame>) {
        func set(_ k: CFString, _ v: CFString) { CVBufferSetAttachment(pb, k, v, .shouldPropagate) }
        switch f.pointee.colorspace {
        case AVCOL_SPC_BT2020_NCL, AVCOL_SPC_BT2020_CL: set(kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_2020)
        case AVCOL_SPC_SMPTE170M, AVCOL_SPC_BT470BG: set(kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_601_4)
        default: set(kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2)
        }
        switch f.pointee.color_primaries {
        case AVCOL_PRI_BT2020: set(kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_2020)
        case AVCOL_PRI_SMPTE432: set(kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_P3_D65)
        default: set(kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2)
        }
        switch f.pointee.color_trc {
        case AVCOL_TRC_SMPTE2084: set(kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ)
        case AVCOL_TRC_ARIB_STD_B67: set(kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_2100_HLG)
        default: set(kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2)
        }
    }
}

// MARK: - Bitmap subtitles

/// One positioned subtitle image; `rect` is normalized (0...1, origin top-left) to the subtitle canvas.
struct SubtitleBitmap: Equatable {
    let image: CGImage
    let rect: CGRect
    static func == (a: SubtitleBitmap, b: SubtitleBitmap) -> Bool { a.image === b.image && a.rect == b.rect }
}

/// PGS (Blu-ray), VobSub (DVD) and DVB subtitles via libavcodec's subtitle decoders.
final class SWSubtitleDecoder {
    private var ctx: UnsafeMutablePointer<AVCodecContext>?
    private let fallbackCanvas: CGSize

    init?(par: UnsafeMutablePointer<AVCodecParameters>, videoSize: CGSize) {
        guard let codec = avcodec_find_decoder(par.pointee.codec_id), let c = avcodec_alloc_context3(codec) else { return nil }
        ctx = c
        avcodec_parameters_to_context(c, par)
        c.pointee.pkt_timebase = AVRational(num: 1, den: 90000)
        fallbackCanvas = videoSize
        if avcodec_open2(c, codec, nil) < 0 { avcodec_free_context(&ctx); return nil }
    }
    deinit { avcodec_free_context(&ctx) }
    func flush() { if let ctx { avcodec_flush_buffers(ctx) } }

    /// Returns (start, end?, bitmaps). An empty bitmap list means "clear the screen at `start`".
    func decode(_ pkt: UnsafeMutablePointer<AVPacket>, start: Double) -> (Double, Double?, [SubtitleBitmap])? {
        guard let ctx else { return nil }
        var sub = AVSubtitle()
        var got: Int32 = 0
        guard avcodec_decode_subtitle2(ctx, &sub, &got, pkt) >= 0, got != 0 else { return nil }
        defer { avsubtitle_free(&sub) }
        let canvas = ctx.pointee.width > 0 && ctx.pointee.height > 0 ? CGSize(width: Int(ctx.pointee.width), height: Int(ctx.pointee.height)) : fallbackCanvas
        var bitmaps: [SubtitleBitmap] = []
        for i in 0..<Int(sub.num_rects) {
            guard let r = sub.rects[i]?.pointee, r.type == SUBTITLE_BITMAP, r.w > 0, r.h > 0, let idx = r.data.0, let pal = r.data.1 else { continue }
            let w = Int(r.w), h = Int(r.h), ls = Int(r.linesize.0)
            let palette = UnsafeRawPointer(pal).assumingMemoryBound(to: UInt32.self)  // AARRGGBB (native endian)
            var rgba = [UInt32](repeating: 0, count: w * h)
            for y in 0..<h {
                for x in 0..<w {
                    let c = palette[Int(idx[y * ls + x])]
                    let a = (c >> 24) & 0xff, red = (c >> 16) & 0xff, g = (c >> 8) & 0xff, b = c & 0xff
                    // premultiplied RGBA, little-endian packing => ABGR in the UInt32
                    let pr = red * a / 255, pg = g * a / 255, pb = b * a / 255
                    rgba[y * w + x] = (a << 24) | (pb << 16) | (pg << 8) | pr
                }
            }
            let data = Data(bytes: rgba, count: rgba.count * 4) as CFData
            guard let provider = CGDataProvider(data: data),
                  let img = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                    bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                    provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else { continue }
            bitmaps.append(SubtitleBitmap(image: img, rect: CGRect(x: Double(r.x) / canvas.width, y: Double(r.y) / canvas.height,
                                                                   width: Double(w) / canvas.width, height: Double(h) / canvas.height)))
        }
        let s = start + Double(sub.start_display_time) / 1000
        let end: Double? = sub.end_display_time > 0 && sub.end_display_time != UInt32.max ? start + Double(sub.end_display_time) / 1000 : nil
        return (s, end, bitmaps)
    }
}
