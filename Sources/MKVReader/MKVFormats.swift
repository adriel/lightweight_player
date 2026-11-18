import Foundation
import CoreMedia
import AudioToolbox
import VideoToolbox

/// Builds CoreMedia format descriptions from Matroska track headers (no FFmpeg in the sandboxed extension).
enum MKVFormats {
    static func formatDescription(for t: MKVTrack) -> CMFormatDescription? {
        if t.unsupportedEncoding { return nil }
        if t.isVideo { return video(t) }
        if t.isAudio { return audio(t) }
        return nil
    }

    // MARK: Video

    private static func video(_ t: MKVTrack) -> CMFormatDescription? {
        var ext = colorExtensions(t.colour)
        var atoms: [String: Data] = [:]
        let codec: CMVideoCodecType
        switch t.codecID {
        case "V_MPEG4/ISO/AVC": codec = kCMVideoCodecType_H264; atoms["avcC"] = t.codecPrivate
        case "V_MPEGH/ISO/HEVC": codec = kCMVideoCodecType_HEVC; atoms["hvcC"] = t.codecPrivate
        case "V_AV1":
            codec = kCMVideoCodecType_AV1; VTRegisterSupplementalVideoDecoderIfAvailable(codec)
            if !t.codecPrivate.isEmpty { atoms["av1C"] = t.codecPrivate }
        case "V_VP9":
            codec = kCMVideoCodecType_VP9; VTRegisterSupplementalVideoDecoderIfAvailable(codec)
            atoms["vpcC"] = vpcC(t)
        case "V_MPEG2": codec = kCMVideoCodecType_MPEG2Video
        case "V_PRORES": codec = kCMVideoCodecType_AppleProRes422
        default: return nil
        }
        if !atoms.isEmpty { ext[kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms] = atoms }
        if t.displayWidth > 0, t.displayHeight > 0, t.width > 0, t.height > 0,
           t.displayWidth * t.height != t.displayHeight * t.width {
            ext[kCMFormatDescriptionExtension_PixelAspectRatio] = [
                kCMFormatDescriptionKey_PixelAspectRatioHorizontalSpacing: t.displayWidth * t.height,
                kCMFormatDescriptionKey_PixelAspectRatioVerticalSpacing: t.displayHeight * t.width,
            ]
        }
        var fd: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreate(allocator: nil, codecType: codec, width: Int32(t.width), height: Int32(t.height), extensions: ext as CFDictionary, formatDescriptionOut: &fd)
        return fd
    }

    private static func colorExtensions(_ c: MKVColour?) -> [CFString: Any] {
        guard let c else { return [:] }
        var e: [CFString: Any] = [:]
        // Matroska uses ITU-T H.273 code points.
        switch c.primaries {
        case 1: e[kCMFormatDescriptionExtension_ColorPrimaries] = kCMFormatDescriptionColorPrimaries_ITU_R_709_2
        case 9: e[kCMFormatDescriptionExtension_ColorPrimaries] = kCMFormatDescriptionColorPrimaries_ITU_R_2020
        case 5: e[kCMFormatDescriptionExtension_ColorPrimaries] = kCMFormatDescriptionColorPrimaries_EBU_3213
        case 6, 7: e[kCMFormatDescriptionExtension_ColorPrimaries] = kCMFormatDescriptionColorPrimaries_SMPTE_C
        case 12: e[kCMFormatDescriptionExtension_ColorPrimaries] = kCMFormatDescriptionColorPrimaries_P3_D65
        default: break
        }
        switch c.transfer {
        case 1, 6, 14, 15: e[kCMFormatDescriptionExtension_TransferFunction] = kCMFormatDescriptionTransferFunction_ITU_R_709_2
        case 16: e[kCMFormatDescriptionExtension_TransferFunction] = kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ
        case 18: e[kCMFormatDescriptionExtension_TransferFunction] = kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG
        case 13: e[kCMFormatDescriptionExtension_TransferFunction] = kCMFormatDescriptionTransferFunction_sRGB
        default: break
        }
        switch c.matrix {
        case 1: e[kCMFormatDescriptionExtension_YCbCrMatrix] = kCMFormatDescriptionYCbCrMatrix_ITU_R_709_2
        case 9, 10: e[kCMFormatDescriptionExtension_YCbCrMatrix] = kCMFormatDescriptionYCbCrMatrix_ITU_R_2020
        case 5, 6: e[kCMFormatDescriptionExtension_YCbCrMatrix] = kCMFormatDescriptionYCbCrMatrix_ITU_R_601_4
        default: break
        }
        if c.range == 2 { e[kCMFormatDescriptionExtension_FullRangeVideo] = true }
        let ch = c.chromaticities
        if ch.allSatisfy({ $0 != nil }), let lmax = c.lumMax, let lmin = c.lumMin {
            var d = Data()
            func u16(_ v: Double) { let x = UInt16(clamping: Int(v * 50000 + 0.5)); d.append(UInt8(x >> 8)); d.append(UInt8(x & 0xff)) }
            func u32(_ v: Double) { withUnsafeBytes(of: UInt32(clamping: Int(v * 10000 + 0.5)).bigEndian) { d.append(contentsOf: $0) } }
            // mdcv order: G, B, R, white point
            u16(ch[2]!); u16(ch[3]!); u16(ch[4]!); u16(ch[5]!); u16(ch[0]!); u16(ch[1]!); u16(ch[6]!); u16(ch[7]!)
            u32(lmax); u32(lmin)
            e[kCMFormatDescriptionExtension_MasteringDisplayColorVolume] = d
        }
        if let cll = c.maxCLL, let fall = c.maxFALL {
            let a = UInt16(clamping: cll), b = UInt16(clamping: fall)
            e[kCMFormatDescriptionExtension_ContentLightLevelInfo] = Data([UInt8(a >> 8), UInt8(a & 0xff), UInt8(b >> 8), UInt8(b & 0xff)])
        }
        return e
    }

    private static func vpcC(_ t: MKVTrack) -> Data {
        // CodecPrivate for VP9 is optional ID/value pairs: 1 profile, 2 level, 3 bit depth, 4 chroma subsampling.
        var profile: UInt8 = 0, level: UInt8 = 0, depth: UInt8 = UInt8(t.colour?.bitsPerChannel ?? 8), chroma: UInt8 = 1
        var p = t.codecPrivate.startIndex
        while p + 2 < t.codecPrivate.endIndex {
            let id = t.codecPrivate[p], len = Int(t.codecPrivate[p + 1])
            if len == 1, p + 2 < t.codecPrivate.endIndex {
                let v = t.codecPrivate[p + 2]
                switch id { case 1: profile = v; case 2: level = v; case 3: depth = v; case 4: chroma = v; default: break }
            }
            p += 2 + len
        }
        let full: UInt8 = t.colour?.range == 2 ? 1 : 0
        return Data([1, 0, 0, 0, profile, level, (depth << 4) | (chroma << 1) | full,
                     UInt8(t.colour?.primaries ?? 2), UInt8(t.colour?.transfer ?? 2), UInt8(t.colour?.matrix ?? 2), 0, 0])
    }

    // MARK: Audio

    private static func audio(_ t: MKVTrack) -> CMFormatDescription? {
        var asbd = AudioStreamBasicDescription()
        asbd.mSampleRate = t.sampleRate
        asbd.mChannelsPerFrame = UInt32(t.channels)
        var cookie: Data?
        switch t.codecID {
        case let id where id.hasPrefix("A_AAC"):
            asbd.mFormatID = kAudioFormatMPEG4AAC
            asbd.mFramesPerPacket = 1024
            if t.outputSampleRate > t.sampleRate { asbd.mFormatID = kAudioFormatMPEG4AAC_HE }
            var asc = t.codecPrivate
            if asc.isEmpty { asc = makeASC(t) }
            cookie = esds(asc)
        case "A_AC3": asbd.mFormatID = kAudioFormatAC3; asbd.mFramesPerPacket = 1536
        case "A_EAC3": asbd.mFormatID = kAudioFormatEnhancedAC3; asbd.mFramesPerPacket = 1536
        case "A_MPEG/L3": asbd.mFormatID = kAudioFormatMPEGLayer3; asbd.mFramesPerPacket = 1152
        case "A_MPEG/L2": asbd.mFormatID = kAudioFormatMPEGLayer2; asbd.mFramesPerPacket = 1152
        case "A_OPUS": asbd.mFormatID = kAudioFormatOpus; asbd.mFramesPerPacket = 960; asbd.mSampleRate = 48000; cookie = t.codecPrivate
        case "A_FLAC":
            asbd.mFormatID = kAudioFormatFLAC
            var d = Data([0, 0, 0, 0])
            d.append(t.codecPrivate.starts(with: Array("fLaC".utf8)) ? t.codecPrivate.dropFirst(4) : t.codecPrivate)
            cookie = d
        case "A_ALAC": asbd.mFormatID = kAudioFormatAppleLossless; asbd.mFramesPerPacket = 4096; cookie = t.codecPrivate
        case "A_PCM/INT/LIT", "A_PCM/FLOAT/IEEE":
            let bits = UInt32(t.bitDepth > 0 ? t.bitDepth : 16)
            asbd.mFormatID = kAudioFormatLinearPCM
            asbd.mFormatFlags = (t.codecID == "A_PCM/FLOAT/IEEE" ? kAudioFormatFlagIsFloat : kAudioFormatFlagIsSignedInteger) | kAudioFormatFlagIsPacked
            asbd.mBitsPerChannel = bits
            asbd.mBytesPerFrame = bits / 8 * asbd.mChannelsPerFrame
            asbd.mFramesPerPacket = 1
            asbd.mBytesPerPacket = asbd.mBytesPerFrame
        default:
            return nil // DTS, TrueHD, Vorbis, ... : not decodable by Core Audio
        }
        var layout = AudioChannelLayout()
        layout.mChannelLayoutTag = switch t.channels {
            case 1: kAudioChannelLayoutTag_Mono
            case 2: kAudioChannelLayoutTag_Stereo
            case 6: kAudioChannelLayoutTag_MPEG_5_1_A
            case 8: kAudioChannelLayoutTag_MPEG_7_1_C
            default: kAudioChannelLayoutTag_DiscreteInOrder | AudioChannelLayoutTag(t.channels)
        }
        var fd: CMAudioFormatDescription?
        if let cookie, !cookie.isEmpty {
            _ = cookie.withUnsafeBytes { raw in
                CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: MemoryLayout<AudioChannelLayout>.size, layout: &layout, magicCookieSize: cookie.count, magicCookie: raw.baseAddress, extensions: nil, formatDescriptionOut: &fd)
            }
        } else {
            CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: MemoryLayout<AudioChannelLayout>.size, layout: &layout, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &fd)
        }
        return fd
    }

    private static func makeASC(_ t: MKVTrack) -> Data {
        let rates: [Double] = [96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000, 7350]
        let idx = UInt8(rates.firstIndex(of: t.sampleRate) ?? 4)
        let obj: UInt8 = t.codecID.contains("MAIN") ? 1 : t.codecID.contains("SSR") ? 3 : 2
        let ch = UInt8(t.channels & 0x0f)
        return Data([(obj << 3) | (idx >> 1), ((idx & 1) << 7) | (ch << 3)])
    }

    private static func esds(_ asc: Data) -> Data {
        func desc(_ tag: UInt8, _ body: Data) -> Data {
            var d = Data([tag]); let n = body.count
            d.append(contentsOf: [UInt8(0x80 | ((n >> 21) & 0x7f)), UInt8(0x80 | ((n >> 14) & 0x7f)), UInt8(0x80 | ((n >> 7) & 0x7f)), UInt8(n & 0x7f)])
            d.append(body); return d
        }
        var dcd = Data([0x40, (0x05 << 2) | 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0])
        dcd.append(desc(0x05, asc))
        var es = Data([0, 0, 0])
        es.append(desc(0x04, dcd))
        es.append(desc(0x06, Data([0x02])))
        var out = Data([0, 0, 0, 0])
        out.append(desc(0x03, es))
        return out
    }
}
