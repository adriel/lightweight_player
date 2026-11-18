import Foundation
import Combine

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
    @Published var brightness: Double { didSet { d.set(brightness, forKey: "brightness") } }   // -0.5 ... 0.5
    @Published var gamma: Double { didSet { d.set(gamma, forKey: "gamma") } }                  // 0.5 ... 2.0
    @Published var contrast: Double { didSet { d.set(contrast, forKey: "contrast") } }         // 0.5 ... 1.5

    // Subtitles
    @Published var subtitleMode: SubtitleMode { didSet { d.set(subtitleMode.rawValue, forKey: "subtitleMode") } }
    @Published var subtitleFontSize: Double { didSet { d.set(subtitleFontSize, forKey: "subtitleFontSize") } }
    @Published var loadSidecarSubtitles: Bool { didSet { d.set(loadSidecarSubtitles, forKey: "loadSidecarSubtitles") } }

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
            "brightness": 0.0, "gamma": 1.0, "contrast": 1.0,
            "subtitleMode": SubtitleMode.forcedOnly.rawValue, "subtitleFontSize": 1.0, "loadSidecarSubtitles": true, "dtsCoreOnly": false,
            "bufferMinutes": 10.0, "maxCacheGB": 8.0, "networkTimeout": 30.0,
        ])
        seekStep = d.double(forKey: "seekStep")
        longSeekStep = d.double(forKey: "longSeekStep")
        volumeStep = d.double(forKey: "volumeStep")
        accurateSeek = d.bool(forKey: "accurateSeek")
        resumePlayback = d.bool(forKey: "resumePlayback")
        volume = d.double(forKey: "volume")
        controlsHideDelay = d.double(forKey: "controlsHideDelay")
        brightness = d.double(forKey: "brightness")
        gamma = d.double(forKey: "gamma")
        contrast = d.double(forKey: "contrast")
        subtitleMode = SubtitleMode(rawValue: d.string(forKey: "subtitleMode") ?? "") ?? .forcedOnly
        subtitleFontSize = d.double(forKey: "subtitleFontSize")
        loadSidecarSubtitles = d.bool(forKey: "loadSidecarSubtitles")
        dtsCoreOnly = d.bool(forKey: "dtsCoreOnly")
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

    var cacheDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("LightPlayer/Streams", isDirectory: true)
    }
}
