import Foundation
import Combine
import AppKit

/// App preferences, persisted in UserDefaults. Observable so the SwiftUI settings window and the
/// player stay in sync.
final class Settings: ObservableObject {
    static let shared = Settings()
    private let d = UserDefaults.standard

    enum SubtitleMode: String, CaseIterable, Identifiable {
        case forcedOnly, always, never
        var id: String { rawValue }
        var label: String {
            switch self {
            case .forcedOnly: "Forced subtitles only"
            case .always: "Always show (default track)"
            case .never: "Never show"
            }
        }
    }

    // Playback
    @Published var seekStep: Double { didSet { d.set(seekStep, forKey: "seekStep") } }
    @Published var longSeekStep: Double { didSet { d.set(longSeekStep, forKey: "longSeekStep") } }
    @Published var volumeStep: Double { didSet { d.set(volumeStep, forKey: "volumeStep") } }
    @Published var accurateSeek: Bool { didSet { d.set(accurateSeek, forKey: "accurateSeek") } }
    @Published var resumePlayback: Bool { didSet { d.set(resumePlayback, forKey: "resumePlayback") } }
    @Published var volume: Double { didSet { d.set(volume, forKey: "volume") } }
    @Published var controlsHideDelay: Double { didSet { d.set(controlsHideDelay, forKey: "controlsHideDelay") } }

    // Video
    // Colour adjustments of the *frontmost player's file* (bound to the sliders). Not global: each file keeps its
    // own values (see colorAdjustment(for:)), and a file without saved values starts neutral.
    @Published var brightness: Double = 0   // -0.5 ... 0.5
    @Published var gamma: Double = 1        // 0.5 ... 2.0
    @Published var contrast: Double = 1     // 0.5 ... 1.5

    /// Show HDR video (HDR10/HLG/Dolby Vision base layer) with extended dynamic range. Off: tone-mapped to SDR.
    @Published var hdrEnabled: Bool { didSet { d.set(hdrEnabled, forKey: "hdrEnabled") } }
    /// Floating control bar position (IINA-style, draggable): bar centre's horizontal offset from the window centre
    /// as a fraction of the width, and its bottom edge as a fraction of the height. NaN = default (centred, 24 pt up).
    var controlBarX: Double { get { d.object(forKey: "controlBarX") as? Double ?? .nan } set { d.set(newValue, forKey: "controlBarX") } }
    var controlBarY: Double { get { d.object(forKey: "controlBarY") as? Double ?? .nan } set { d.set(newValue, forKey: "controlBarY") } }

    /// Whether the video in the frontmost player is HDR (nil = nothing playing). Not persisted; greys out the
    /// HDR switch for SDR video.
    @Published var nowPlayingHDR: Bool?
    /// Full screen fills the whole display including the strip beside the camera notch (custom full screen
    /// instead of macOS's, which keeps that strip black). Only affects displays with a notch.
    @Published var fullScreenCoversNotch: Bool { didSet { d.set(fullScreenCoversNotch, forKey: "fullScreenCoversNotch") } }
    /// Use macOS's own full screen (separate Space, system animation that freezes the picture briefly)
    /// instead of the live borderless full screen.
    @Published var nativeFullScreen: Bool { didSet { d.set(nativeFullScreen, forKey: "nativeFullScreen") } }

    /// Detect letterbox / pillarbox bars and crop them away.
    @Published var autoCrop: Bool { didSet { d.set(autoCrop, forKey: "autoCrop") } }

    // Subtitles
    @Published var subtitleMode: SubtitleMode { didSet { d.set(subtitleMode.rawValue, forKey: "subtitleMode") } }
    @Published var subtitleFontSize: Double { didSet { d.set(subtitleFontSize, forKey: "subtitleFontSize") } }
    @Published var loadSidecarSubtitles: Bool { didSet { d.set(loadSidecarSubtitles, forKey: "loadSidecarSubtitles") } }

    /// Play non-native local formats (MKV, AVI, …) through AVPlayer + installed Media Extensions (e.g. QuickLook Video)
    /// instead of the built-in FFmpeg engine. Falls back automatically if the extension can't open the file.
    @Published var useMediaExtensions: Bool { didSet { d.set(useMediaExtensions, forKey: "useMediaExtensions") } }

    /// DTS-HD MA: decode only the lossy DTS core (much cheaper) instead of the lossless extension.
    @Published var dtsCoreOnly: Bool { didSet { d.set(dtsCoreOnly, forKey: "dtsCoreOnly") } }

    // Streaming
    @Published var bufferMinutes: Double { didSet { d.set(bufferMinutes, forKey: "bufferMinutes") } }
    @Published var maxCacheGB: Double { didSet { d.set(maxCacheGB, forKey: "maxCacheGB") } }
    @Published var networkTimeout: Double { didSet { d.set(networkTimeout, forKey: "networkTimeout") } }

    private init() {
        d.register(defaults: [
            "seekStep": 5.0, "longSeekStep": 30.0, "volumeStep": 5.0, "accurateSeek": true, "resumePlayback": true,
            "volume": 1.0, "controlsHideDelay": 2.0,
            "autoCrop": true, "hdrEnabled": true, "fullScreenCoversNotch": false, "nativeFullScreen": false, "brightness": 0.0, "gamma": 1.0, "contrast": 1.0,
            "subtitleMode": SubtitleMode.forcedOnly.rawValue, "subtitleFontSize": 1.0, "loadSidecarSubtitles": true, "dtsCoreOnly": false, "useMediaExtensions": false,
            "bufferMinutes": 10.0, "maxCacheGB": 8.0, "networkTimeout": 30.0,
        ])
        seekStep = d.double(forKey: "seekStep")
        longSeekStep = d.double(forKey: "longSeekStep")
        volumeStep = d.double(forKey: "volumeStep")
        accurateSeek = d.bool(forKey: "accurateSeek")
        resumePlayback = d.bool(forKey: "resumePlayback")
        volume = d.double(forKey: "volume")
        controlsHideDelay = d.double(forKey: "controlsHideDelay")
        autoCrop = d.bool(forKey: "autoCrop")
        hdrEnabled = d.bool(forKey: "hdrEnabled")
        fullScreenCoversNotch = d.bool(forKey: "fullScreenCoversNotch")
        nativeFullScreen = d.bool(forKey: "nativeFullScreen")
        d.removeObject(forKey: "brightness"); d.removeObject(forKey: "gamma"); d.removeObject(forKey: "contrast")   // old global values
        subtitleMode = SubtitleMode(rawValue: d.string(forKey: "subtitleMode") ?? "") ?? .forcedOnly
        subtitleFontSize = d.double(forKey: "subtitleFontSize")
        loadSidecarSubtitles = d.bool(forKey: "loadSidecarSubtitles")
        dtsCoreOnly = d.bool(forKey: "dtsCoreOnly")
        useMediaExtensions = d.bool(forKey: "useMediaExtensions")
        bufferMinutes = d.double(forKey: "bufferMinutes")
        maxCacheGB = d.double(forKey: "maxCacheGB")
        networkTimeout = d.double(forKey: "networkTimeout")
    }

    var hasColorAdjustments: Bool { abs(brightness) > 0.001 || abs(gamma - 1) > 0.001 || abs(contrast - 1) > 0.001 }
    func resetColor() { brightness = 0; gamma = 1; contrast = 1 }

    // MARK: Resume positions (small, capped dictionary)

    func resumePosition(for key: String) -> Double? {
        (d.dictionary(forKey: "resume")?[key] as? Double).flatMap { $0 > 5 ? $0 : nil }
    }

    func setResumePosition(_ t: Double?, for key: String) {
        var dict = d.dictionary(forKey: "resume") ?? [:]
        if let t { dict[key] = t } else { dict.removeValue(forKey: key) }
        if dict.count > 200 { dict = Dictionary(uniqueKeysWithValues: dict.suffix(150).map { ($0.key, $0.value) }) }
        d.set(dict, forKey: "resume")
    }

    // MARK: Remembered black-bar crops (per file), so they're applied instantly next time.

    /// `.some(nil)` = remembered "no bars"; `nil` = unknown.
    /// Per-file brightness / contrast / gamma (nil = never adjusted → neutral).
    func colorAdjustment(for key: String) -> (brightness: Double, contrast: Double, gamma: Double)? {
        guard let raw = d.dictionary(forKey: "colorAdjustments")?[key] as? [Any] else { return nil }
        let a = raw.compactMap { ($0 as? NSNumber)?.doubleValue ?? Double("\($0)") }
        guard a.count == 3 else { return nil }
        return (a[0], a[1], a[2])
    }

    func setColorAdjustment(_ v: (brightness: Double, contrast: Double, gamma: Double), for key: String) {
        var dict = d.dictionary(forKey: "colorAdjustments") ?? [:]
        let neutral = abs(v.brightness) < 0.001 && abs(v.contrast - 1) < 0.001 && abs(v.gamma - 1) < 0.001
        dict[key] = neutral ? nil : [v.brightness, v.contrast, v.gamma]
        if dict.count > 500 { dict = Dictionary(uniqueKeysWithValues: dict.suffix(400).map { ($0.key, $0.value) }) }
        d.set(dict, forKey: "colorAdjustments")
    }

    /// Which player the colour sliders currently belong to.
    weak var colorOwner: AnyObject?

    func rememberedCrop(for key: String) -> CGRect?? {
        guard let v = d.dictionary(forKey: "crops")?[key] as? String else { return nil }
        return .some(v == "none" ? nil : NSRectFromString(v))
    }

    func rememberCrop(_ c: CGRect?, for key: String) {
        var dict = d.dictionary(forKey: "crops") ?? [:]
        dict[key] = c.map { NSStringFromRect($0) } ?? "none"
        if dict.count > 500 { dict = Dictionary(uniqueKeysWithValues: dict.suffix(400).map { ($0.key, $0.value) }) }
        d.set(dict, forKey: "crops")
    }

    var cacheDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("LightPlayer/Streams", isDirectory: true)
    }
}
