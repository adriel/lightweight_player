import AppKit
import CoreMedia
import AVFoundation
import AVKit

/// Identifies one playback backend. The benchmark harness runs every engine through the same protocol.
enum EngineKind: String, CaseIterable {
    case avplayer = "A"        // AVPlayer + AVPlayerLayer (QuickTime's stack)
    case avplayerExt = "B"     // AVPlayer + our Matroska MediaExtension format reader
    case sampleBuffer = "C"    // libavformat demux -> AVSampleBufferDisplayLayer / AudioRenderer (VideoToolbox decode)
    case mpv = "D"             // libmpv (IINA's engine), hwdec=videotoolbox, OpenGL render API

    /// Short name for the title bar tag.
    var tagName: String {
        switch self {
        case .avplayer: "AVFoundation"
        case .avplayerExt: "AVF + Extension"
        case .sampleBuffer: "FFmpeg"
        case .mpv: "mpv"
        }
    }

    var label: String {
        switch self {
        case .avplayer: "AVPlayer"
        case .avplayerExt: "AVPlayer+MKVExt"
        case .sampleBuffer: "FFdemux+AVSBDL"
        case .mpv: "libmpv"
        }
    }
}

struct EngineWarning: Hashable { let message: String }

protocol PlayerEngine: AnyObject {
    var kind: EngineKind { get }
    /// The view that displays video. Layer-backed, sized by the host.
    var view: NSView { get }
    var currentTime: Double { get }
    var duration: Double { get }
    var isPlaying: Bool { get }
    var volume: Float { get set }          // 0...1, app-level
    var warnings: [EngineWarning] { get }
    /// Informational (e.g. "AV1 decoded in software").
    var notices: [String] { get }
    /// Called on the main queue when the engine becomes ready / fails / plays its first frame.
    var onEvent: ((EngineEvent) -> Void)? { get set }

    func open(_ url: URL)
    func play()
    func pause()
    func seek(to seconds: Double, accurate: Bool)
    func close()
    /// Free-form diagnostics shown in the benchmark log (codec, hwdec state, etc).
    func diagnostics() -> [String: String]

    // Player features (engine C implements these; benchmark-only engines use the defaults below).
    var naturalSize: CGSize { get }
    var subtitleTracks: [SubtitleTrackInfo] { get }
    /// Select an embedded subtitle stream (cues are delivered into `cues`); nil disables.
    func selectSubtitle(_ id: Int?)
    var cues: CueStore { get }
    /// Downloaded spans (0...1) for network streams.
    var bufferedFractions: [ClosedRange<Double>] { get }
    func makePiPController(sampleBufferDelegate: AVPictureInPictureSampleBufferPlaybackDelegate) -> AVPictureInPictureController?
    func appendWarning(_ message: String)
    /// File / stream / decoder description for the inspector.
    var mediaInfo: MediaInfo { get }
    /// Live, engine-specific status rows (buffering, A/V lead, dropped frames…).
    func statusRows() -> [MediaInfo.Row]
    /// The decoded frame currently on screen (for black-bar detection); nil if unavailable.
    func snapshotFrame(_ completion: @escaping (CVPixelBuffer?) -> Void)
    /// Network streams: non-nil while playback is paused to buffer (progress 0…1, download bytes/s).
    var buffering: (progress: Double, bytesPerSecond: Double)? { get }
    /// Audio tracks in the file and the one playing.
    var audioTracks: [AudioTrackInfo] { get }
    var selectedAudioTrack: Int? { get }
    func selectAudioTrack(_ id: Int)
    /// Chapters (sorted by start time).
    var chapters: [ChapterInfo] { get }
    /// Pause and show the next / previous frame.
    func stepFrame(forward: Bool)
    /// Fast keyframe seek for a held arrow key; implementations show each landed frame before the next.
    func scrub(to seconds: Double, forward: Bool)
    /// HDR on: extended dynamic range output. Off: HDR video is tone-mapped to SDR.
    func setHDR(_ on: Bool)
    /// The video track is HDR (PQ / HLG); known by the time `.ready` fires.
    var isHDRVideo: Bool { get }
    /// How the video is decoded (nil until known / no video): hardware = VideoToolbox media engine.
    var videoDecoding: VideoDecodingInfo? { get }
    /// "Dolby Vision", "HDR10", "HLG" (nil for SDR).
    var hdrFormat: String? { get }
}

extension PlayerEngine {
    var notices: [String] { [] }
    var naturalSize: CGSize { .zero }
    var subtitleTracks: [SubtitleTrackInfo] { [] }
    func selectSubtitle(_ id: Int?) {}
    var bufferedFractions: [ClosedRange<Double>] { [] }
    func makePiPController(sampleBufferDelegate: AVPictureInPictureSampleBufferPlaybackDelegate) -> AVPictureInPictureController? { nil }
    func appendWarning(_ message: String) {}
    var mediaInfo: MediaInfo { MediaInfo() }
    func statusRows() -> [MediaInfo.Row] { [] }
    func snapshotFrame(_ completion: @escaping (CVPixelBuffer?) -> Void) { completion(nil) }
    func setHDR(_ on: Bool) {}
    var isHDRVideo: Bool { false }
    var videoDecoding: VideoDecodingInfo? { nil }
    var hdrFormat: String? { nil }
    func scrub(to seconds: Double, forward: Bool) { seek(to: seconds, accurate: false) }
    var buffering: (progress: Double, bytesPerSecond: Double)? { nil }
    var audioTracks: [AudioTrackInfo] { [] }
    var selectedAudioTrack: Int? { nil }
    func selectAudioTrack(_ id: Int) {}
    var chapters: [ChapterInfo] { [] }
    func stepFrame(forward: Bool) {}
}


enum EngineEvent {
    case ready
    case firstFrame
    case failed(String)
    case ended
    /// The engine can't decode this file's codecs; the player should reopen it with engine C.
    case needsFallback
}

/// The app's engine choice: AVFoundation's own demuxer for local MP4/MOV (smallest index memory),
/// FFmpeg-demux + VideoToolbox (engine C) for everything else, including every network stream
/// (so streams get the disk-backed buffer).
struct AudioTrackInfo: Identifiable, Equatable {
    let id: Int                 // stream index (FFmpeg) or option index (AVFoundation)
    var title: String
    var language: String?
    var detail: String          // codec / channels, e.g. "AC-3 5.1"
    var isDefault: Bool
    var displayName: String {
        var parts: [String] = []
        if !title.isEmpty { parts.append(title) }
        if let language, !language.isEmpty, language != "und" {
            let name = Locale.current.localizedString(forLanguageCode: language) ?? language
            if !parts.contains(where: { $0.localizedCaseInsensitiveContains(name) }) { parts.append(name) }
        }
        if parts.isEmpty { parts.append("Track \(id + 1)") }
        return parts.joined(separator: " – ") + (detail.isEmpty ? "" : "  (\(detail))")
    }
}

struct VideoDecodingInfo: Equatable {
    let hardware: Bool
    let codec: String           // "HEVC", "AV1", …
    let decoder: String         // "VideoToolbox", "dav1d (8 threads)", …
    var detail: String { "\(codec) · \(hardware ? "hardware" : "software") (\(decoder))" }
}

struct ChapterInfo: Equatable {
    let start: Double
    let title: String
}

func makeEngine(for url: URL) -> PlayerEngine {
    let native: Set<String> = ["mp4", "m4v", "mov", "qt", "3gp"]
    if url.isFileURL && native.contains(url.pathExtension.lowercased()) {
        // Unindexed fragmented MP4 (e.g. Twitch VOD downloads): AVFoundation scans every fragment before playing
        // (~20 s for a 3.8 h VOD); the FFmpeg engine opens it instantly (see FragmentedMP4).
        if FragmentedMP4.isUnindexedFragmented(url.path) { return SampleBufferEngine() }
        return AVPlayerEngine(useMediaExtensions: false)
    }
    if url.isFileURL && Settings.shared.useMediaExtensions { return AVPlayerEngine(useMediaExtensions: true) }
    return SampleBufferEngine()
}
