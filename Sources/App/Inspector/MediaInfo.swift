import Foundation
import AppKit
import CoreMedia
import VideoToolbox
import Darwin

/// What is playing and how it's being decoded — filled in by each engine for the ⌘I inspector.
struct MediaInfo {
    typealias Row = (label: String, value: String)
    struct Track: Identifiable {
        let id: Int
        var kind: String          // Video / Audio / Subtitle / Data
        var title: String
        var rows: [Row]
        var active: Bool
    }
    var engine = ""
    var video: [Row] = []
    var audio: [Row] = []
    var tracks: [Track] = []
    var file: [Row] = []
    var metadata: [Row] = []
}

/// Live numbers for the Status tab.
struct PlaybackStatus {
    var rows: [MediaInfo.Row] = []
}

enum InfoFormat {
    static func bitrate(_ bps: Double) -> String {
        guard bps > 0 else { return "—" }
        return bps >= 1_000_000 ? String(format: "%.2f Mbps", bps / 1_000_000) : String(format: "%.0f kbps", bps / 1000)
    }
    static func bytes(_ b: Int64) -> String { ByteCountFormatter.string(fromByteCount: b, countStyle: .file) }
    static func fps(_ f: Double) -> String {
        guard f > 0, f.isFinite else { return "—" }
        let r = (f * 1000).rounded() / 1000
        return r == r.rounded() ? String(format: "%.0f", r) : String(format: "%.3f", r)
    }
    static func channels(_ n: Int) -> String {
        switch n { case 1: "mono"; case 2: "stereo"; case 6: "5.1"; case 8: "7.1"; default: "\(n) channels" }
    }
    static func fourCC(_ c: FourCharCode) -> String { c.fourCCString.trimmingCharacters(in: .whitespaces) }

    static let codecNames: [String: String] = [
        "avc1": "H.264 / AVC", "avc3": "H.264 / AVC", "hvc1": "H.265 / HEVC", "hev1": "H.265 / HEVC", "dvh1": "Dolby Vision (HEVC)",
        "av01": "AV1", "vp09": "VP9", "vp08": "VP8", "apch": "ProRes 422 HQ", "apcn": "ProRes 422", "apcs": "ProRes 422 LT",
        "apco": "ProRes 422 Proxy", "ap4h": "ProRes 4444", "mp4v": "MPEG-4 Part 2", "mp2v": "MPEG-2",
        "aac ": "AAC", "mp4a": "AAC", ".mp3": "MP3", "ac-3": "Dolby Digital (AC-3)", "ec-3": "Dolby Digital Plus (E-AC-3)",
        "alac": "Apple Lossless", "flac": "FLAC", "opus": "Opus", "lpcm": "Linear PCM", "tx3g": "3GPP timed text", "wvtt": "WebVTT",
    ]

    /// Human description of how a compressed video format will be decoded on this Mac.
    static func videoDecoder(for fd: CMFormatDescription) -> String {
        let sub = CMFormatDescriptionGetMediaSubType(fd)
        if let p = try? VTVideoDecoderExtensionProperties(fd), !p.isEmpty {
            let name = (p[.extensionName] as? String) ?? "extension"
            let host = (p[.containingBundleName] as? String).map { " (\($0))" } ?? ""
            return "\(name)\(host) — Media Extension, software"
        }
        return VTIsHardwareDecodeSupported(sub) ? "VideoToolbox (hardware)" : "VideoToolbox (software)"
    }

    static func colorRows(_ ext: [String: Any]?) -> [MediaInfo.Row] {
        let p = ext?[kCVImageBufferColorPrimariesKey as String] as? String
        let t = ext?[kCVImageBufferTransferFunctionKey as String] as? String
        let m = ext?[kCVImageBufferYCbCrMatrixKey as String] as? String
        var rows: [MediaInfo.Row] = []
        rows.append(("Primaries", p.map(prettyColor) ?? "N/A"))
        rows.append(("Transfer", t.map(prettyColor) ?? "N/A"))
        if let m { rows.append(("Matrix", prettyColor(m))) }
        rows.append(("Dynamic range", dynamicRange(transfer: t)))
        return rows
    }

    static func dynamicRange(transfer: String?) -> String {
        if transfer == kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ as String { return "HDR10 (PQ)" }
        if transfer == kCVImageBufferTransferFunction_ITU_R_2100_HLG as String { return "HDR (HLG)" }
        return "SDR"
    }

    static func prettyColor(_ s: String) -> String {
        s.replacingOccurrences(of: "ITU_R_", with: "BT.").replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "BT.709 2", with: "BT.709").replacingOccurrences(of: "BT.601 4", with: "BT.601")
            .replacingOccurrences(of: "SMPTE ST 2084 PQ", with: "PQ (ST 2084)").replacingOccurrences(of: "BT.2100 HLG", with: "HLG")
    }

    /// URL without user:password for display.
    static func safeURL(_ u: URL) -> String {
        guard !u.isFileURL, var c = URLComponents(url: u, resolvingAgainstBaseURL: false) else { return u.path }
        if c.user != nil { c.user = "•••"; c.password = nil }
        return c.string ?? u.absoluteString
    }

    /// The window's display, the way IINA shows "Colorspace".
    static func displayRows(_ screen: NSScreen?) -> [MediaInfo.Row] {
        guard let s = screen else { return [] }
        let headroom = s.maximumPotentialExtendedDynamicRangeColorComponentValue
        return [("Display", s.localizedName),
                ("Display colorspace", s.colorSpace?.localizedName ?? "—"),
                ("EDR headroom", headroom > 1.01 ? String(format: "%.1f× (HDR capable)", headroom) : "1× (SDR)")]
    }

    static func processFootprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) } }
        return kr == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : 0
    }

    static func processCPUSeconds() -> Double {
        var u = rusage(); getrusage(RUSAGE_SELF, &u)
        return Double(u.ru_utime.tv_sec + u.ru_stime.tv_sec) + Double(u.ru_utime.tv_usec + u.ru_stime.tv_usec) / 1e6
    }
}
