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
    /// HDR on: extended dynamic range output. Off: HDR video is tone-mapped to SDR.
    func setHDR(_ on: Bool)
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
func makeEngine(for url: URL) -> PlayerEngine {
    let native: Set<String> = ["mp4", "m4v", "mov", "qt", "3gp"]
    if url.isFileURL && native.contains(url.pathExtension.lowercased()) { return AVPlayerEngine(useMediaExtensions: false) }
    if url.isFileURL && Settings.shared.useMediaExtensions { return AVPlayerEngine(useMediaExtensions: true) }
    return SampleBufferEngine()
}
