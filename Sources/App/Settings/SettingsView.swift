import SwiftUI
import VideoToolbox
import AudioToolbox

import AppKit

/// Standard macOS settings window: toolbar tabs (icon + label), window title = selected tab.
final class SettingsWindowController: NSWindowController {
    init() {
        let tabs = NSTabViewController()
        tabs.tabStyle = .toolbar
        tabs.canPropagateSelectedChildViewControllerTitle = true
        func add<V: View>(_ title: String, _ symbol: String, _ view: V) {
            let host = NSHostingController(rootView: view.environmentObject(Settings.shared)
                .frame(minWidth: 560, maxWidth: .infinity, minHeight: 380, maxHeight: .infinity))
            host.title = title
            host.sizingOptions = []          // the user sizes the window; switching tabs keeps that size
            let item = NSTabViewItem(viewController: host)
            item.label = title
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
            tabs.addTabViewItem(item)
        }
        add("Playback", "play.rectangle", GeneralTab())
        add("Video", "sun.max", VideoTab())
        add("Subtitles", "captions.bubble", SubtitlesTab())
        add("Streaming", "network", StreamingTab())
        add("Formats", "film.stack", FormatsTab())
        add("File Types", "doc.badge.gearshape", FileTypesTab())
        let w = NSWindow(contentViewController: tabs)
        w.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        w.toolbarStyle = .preference
        w.isReleasedWhenClosed = false
        w.contentMinSize = NSSize(width: 560, height: 380)
        w.setContentSize(NSSize(width: 640, height: 540))
        super.init(window: w)
        if CommandLine.arguments.contains("--settings") { tabs.selectedTabViewItemIndex = 4 }
        w.center()
        w.setFrameAutosaveName("SettingsWindow")      // restores the last size/position (after center as default)
    }
    required init?(coder: NSCoder) { fatalError() }
}

private struct GeneralTab: View {
    @EnvironmentObject var s: Settings
    var body: some View {
        Form {
            Section("Seeking") {
                Stepper(value: $s.seekStep, in: 1...120, step: 1) { LabeledContent("← / → skip", value: "\(Int(s.seekStep)) s") }
                Stepper(value: $s.longSeekStep, in: 5...600, step: 5) { LabeledContent("⇧← / ⇧→ skip", value: "\(Int(s.longSeekStep)) s") }
                Toggle("Frame-accurate seeking (slightly slower)", isOn: $s.accurateSeek)
            }
            Section("Volume") {
                Stepper(value: $s.volumeStep, in: 1...25, step: 1) { LabeledContent("↑ / ↓ volume step", value: "\(Int(s.volumeStep)) %") }
            }
            Section("Behaviour") {
                Toggle("Resume where I left off", isOn: $s.resumePlayback)
                LabeledContent("Hide controls after") {
                    Slider(value: $s.controlsHideDelay, in: 1...6, step: 0.5) { EmptyView() }.frame(width: 180)
                    Text(String(format: "%.1f s", s.controlsHideDelay)).monospacedDigit().frame(width: 44)
                }
            }
            Section {
                Toggle("Use installed Media Extensions for MKV, AVI, … (e.g. QuickLook Video)", isOn: $s.useMediaExtensions)
            } header: { Text("Engine") } footer: {
                Text("Off (recommended): built-in FFmpeg demuxer + VideoToolbox — fastest seeking, lowest memory, disk-buffered streams. On: AVPlayer reads the file through the extension; falls back to the built-in engine if it can't. Network streams always use the built-in engine.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Shortcuts") {
                Text("Double-click video: full screen · Esc: leave full screen · Space: play/pause · ← →: skip (hold to scrub) · ↑ ↓: volume · . / , : next / previous frame · fn↓ / fn↑: next / previous chapter · A: next audio track · S: cycle subtitles · M: mute · C: toggle black-bar crop · F: full screen · ⌘0–⌘3: window size · ⌘I: inspector")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct VideoTab: View {
    @EnvironmentObject var s: Settings
    var body: some View {
        Form {
            Section {
                Toggle("Automatically crop black bars (letterbox / pillarbox)", isOn: $s.autoCrop)
            } footer: {
                Text("Samples a few on-screen frames, crops only when two samples agree, and never more than the least-cropped sample. Toggle with C while playing.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Toggle("HDR (extended dynamic range)", isOn: $s.hdrEnabled)
                    .disabled(s.nowPlayingHDR == false)
                    .help(s.nowPlayingHDR == false ? "The current video is SDR" : "")
                Toggle("Full screen covers the camera notch", isOn: $s.fullScreenCoversNotch)
                    .disabled(s.nativeFullScreen)
                Toggle("Use macOS full screen (separate Space)", isOn: $s.nativeFullScreen)
            } footer: {
                Text((s.nowPlayingHDR == false ? "HDR is unavailable for the current video (it's SDR). " : "") + "HDR off tone-maps HDR10 / HLG video to SDR. Notch: full screen uses the whole display, including the strip beside the camera (the notch hides a small part of the picture); the menu bar and Dock appear when you move the pointer to them. Full screen normally stays on this desktop so the video keeps playing while it animates; macOS full screen moves it to its own Space, and the picture freezes for about half a second during that transition.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                slider("Brightness", $s.brightness, -0.5...0.5, "%+.2f")
                slider("Contrast", $s.contrast, 0.5...1.5, "%.2f")
                slider("Gamma", $s.gamma, 0.5...2.0, "%.2f")
                HStack { Spacer(); Button("Reset") { s.resetColor() }.disabled(!s.hasColorAdjustments) }
            } footer: {
                Text("Applies to the video in the front window and is remembered for that file only; other files start neutral. Applied on the GPU with Core Image only while they differ from the defaults, so normal playback keeps the zero-copy display path.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
    private func slider(_ t: String, _ v: Binding<Double>, _ r: ClosedRange<Double>, _ f: String) -> some View {
        LabeledContent(t) {
            Slider(value: v, in: r).frame(width: 260)
            Text(String(format: f, v.wrappedValue)).monospacedDigit().frame(width: 48)
        }
    }
}

private struct SubtitlesTab: View {
    @EnvironmentObject var s: Settings
    var body: some View {
        Form {
            Picker("Show subtitles", selection: $s.subtitleMode) {
                ForEach(Settings.SubtitleMode.allCases) { Text($0.label).tag($0) }
            }
            Toggle("Load matching .srt / .vtt / .ass files next to the video", isOn: $s.loadSidecarSubtitles)
            Toggle("DTS-HD MA: decode the DTS core only (lossy, slightly less CPU)", isOn: $s.dtsCoreOnly)
            LabeledContent("Text size") {
                Slider(value: $s.subtitleFontSize, in: 0.6...2.0).frame(width: 220)
                Text(String(format: "%.0f%%", s.subtitleFontSize * 100)).monospacedDigit().frame(width: 48)
            }
        }
        .formStyle(.grouped)
    }
}

private struct StreamingTab: View {
    @EnvironmentObject var s: Settings
    @State private var cacheSize = "…"
    var body: some View {
        Form {
            Section {
                Stepper(value: $s.bufferMinutes, in: 1...120, step: 1) { LabeledContent("Read-ahead buffer", value: "\(Int(s.bufferMinutes)) min") }
                Stepper(value: $s.maxCacheGB, in: 1...200, step: 1) { LabeledContent("Max disk cache per stream", value: "\(Int(s.maxCacheGB)) GB") }
                Stepper(value: $s.networkTimeout, in: 5...120, step: 5) { LabeledContent("Network timeout", value: "\(Int(s.networkTimeout)) s") }
            } footer: {
                Text("Streams are buffered to a temporary file on disk, not RAM. The buffer size is estimated from the file's average bitrate; already-downloaded parts are kept so seeking back is instant. Applies to the next stream you open.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Cache") {
                LabeledContent("Location", value: s.cacheDirectory.path)
                LabeledContent("Currently used", value: cacheSize)
                Button("Clear cache") {
                    try? FileManager.default.removeItem(at: s.cacheDirectory)
                    refresh()
                }
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: refresh)
    }
    private func refresh() {
        let files = (try? FileManager.default.contentsOfDirectory(at: s.cacheDirectory, includingPropertiesForKeys: [.totalFileAllocatedSizeKey])) ?? []
        let bytes = files.reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize) ?? 0) }
        cacheSize = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}

// MARK: - Formats

struct FormatRow: Identifiable {
    let id = UUID()
    let name: String
    let detail: String
    let status: Status
    enum Status { case hardware, software, partial, unsupported
        var label: String { switch self { case .hardware: "Hardware"; case .software: "Software"; case .partial: "Partial"; case .unsupported: "Not supported" } }
        var color: Color { switch self { case .hardware: .green; case .software: .blue; case .partial: .orange; case .unsupported: .red } }
    }
}

enum FormatSupport {
    static func videoRows() -> [FormatRow] {
        func hw(_ c: CMVideoCodecType) -> Bool { VTIsHardwareDecodeSupported(c) }
        VTRegisterSupplementalVideoDecoderIfAvailable(kCMVideoCodecType_VP9)
        VTRegisterSupplementalVideoDecoderIfAvailable(kCMVideoCodecType_AV1)
        return [
            FormatRow(name: "H.264 / AVC", detail: "8-bit, up to 4K", status: hw(kCMVideoCodecType_H264) ? .hardware : .software),
            FormatRow(name: "H.265 / HEVC", detail: "Main & Main 10, HDR10 / HLG / Dolby Vision base layer", status: hw(kCMVideoCodecType_HEVC) ? .hardware : .software),
            FormatRow(name: "Apple ProRes", detail: "422 / 4444 family", status: hw(kCMVideoCodecType_AppleProRes422) ? .hardware : .software),
            FormatRow(name: "VP9", detail: "Profile 0 / 2", status: hw(kCMVideoCodecType_VP9) ? .hardware : .software),
            FormatRow(name: "AV1", detail: hw(kCMVideoCodecType_AV1) ? "8 / 10-bit" : "dav1d software decoder (hardware AV1 needs M3 or newer)",
                      status: hw(kCMVideoCodecType_AV1) ? .hardware : .software),
            FormatRow(name: "MPEG-2", detail: "DVD / broadcast", status: .software),
            FormatRow(name: "MPEG-4 Part 2", detail: "DivX / Xvid style", status: .software),
            FormatRow(name: "VP8, VC-1, Theora, WMV, others", detail: "FFmpeg software decoder (4:2:0 formats)", status: .software),
        ]
    }

    static func audioRows() -> [FormatRow] {
        let ids = decodableAudioFormats()
        func row(_ name: String, _ detail: String, _ id: AudioFormatID) -> FormatRow {
            FormatRow(name: name, detail: detail, status: ids.contains(id) ? .software : .unsupported)
        }
        return [
            row("AAC / HE-AAC", "LC, HE, HE v2", kAudioFormatMPEG4AAC),
            row("MP3 / MP2", "", kAudioFormatMPEGLayer3),
            row("Dolby Digital (AC-3)", "up to 5.1", kAudioFormatAC3),
            row("Dolby Digital Plus (E-AC-3)", "incl. Atmos streams as 5.1/7.1", kAudioFormatEnhancedAC3),
            row("FLAC", "", kAudioFormatFLAC),
            row("Opus", "", kAudioFormatOpus),
            row("ALAC", "Apple Lossless", kAudioFormatAppleLossless),
            FormatRow(name: "PCM / LPCM", detail: "16 / 24 / 32-bit, float", status: .software),
            FormatRow(name: "DTS / DTS-HD MA", detail: "FFmpeg decoder → PCM (lossless MA by default)", status: .software),
            FormatRow(name: "Dolby TrueHD (incl. Atmos core)", detail: "FFmpeg decoder → PCM", status: .software),
            FormatRow(name: "Vorbis, WMA, others", detail: "FFmpeg decoder → PCM", status: .software),
        ]
    }

    static let containerRows: [FormatRow] = [
        FormatRow(name: "MP4 / M4V / MOV", detail: "Local files: AVFoundation (QuickTime engine). Streams: FFmpeg demux", status: .hardware),
        FormatRow(name: "Matroska (MKV) / WebM", detail: "FFmpeg demux → VideoToolbox / Core Audio", status: .hardware),
        FormatRow(name: "MPEG-TS / M2TS", detail: "FFmpeg demux (Annex-B converted for VideoToolbox)", status: .hardware),
        FormatRow(name: "AVI, FLV, OGG and other FFmpeg containers", detail: "Plays when the codecs inside are supported", status: .partial),
        FormatRow(name: "HTTP / HTTPS direct files", detail: "Range requests, Basic auth from URL, disk-backed buffer", status: .hardware),
        FormatRow(name: "HLS / DASH playlists", detail: "Not supported yet", status: .unsupported),
    ]

    static let subtitleRows: [FormatRow] = [
        FormatRow(name: "SRT (SubRip)", detail: "Embedded or sidecar file", status: .software),
        FormatRow(name: "WebVTT", detail: "Embedded or sidecar file", status: .software),
        FormatRow(name: "MP4 timed text (tx3g / mov_text)", detail: "Embedded", status: .software),
        FormatRow(name: "ASS / SSA", detail: "Shown as plain text (styling and positioning ignored)", status: .partial),
        FormatRow(name: "PGS (Blu-ray), VobSub (DVD), DVB", detail: "Decoded with FFmpeg, drawn as positioned images", status: .software),
        FormatRow(name: "Teletext, other", detail: "Not supported", status: .unsupported),
    ]

    static func decodableAudioFormats() -> Set<AudioFormatID> {
        var size: UInt32 = 0
        guard AudioFormatGetPropertyInfo(kAudioFormatProperty_DecodeFormatIDs, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioFormatID](repeating: 0, count: Int(size) / MemoryLayout<AudioFormatID>.size)
        guard AudioFormatGetProperty(kAudioFormatProperty_DecodeFormatIDs, 0, nil, &size, &ids) == noErr else { return [] }
        return Set(ids)
    }
}

private struct FormatsTab: View {
    @State private var video: [FormatRow] = []
    @State private var audio: [FormatRow] = []
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Checked live on this Mac. “Hardware” = decoded by the media engine (VideoToolbox); “Software” = decoded on the CPU (by macOS or FFmpeg), only when there's no hardware path.")
                    .font(.callout).foregroundStyle(.secondary)
                section("Containers & sources", FormatSupport.containerRows)
                section("Video codecs", video)
                section("Audio codecs", audio)
                section("Subtitles", FormatSupport.subtitleRows)
            }
            .padding(20)
        }
        .onAppear { video = FormatSupport.videoRows(); audio = FormatSupport.audioRows() }
    }
    private func section(_ title: String, _ rows: [FormatRow]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            ForEach(rows) { r in
                HStack(alignment: .firstTextBaseline) {
                    Text(r.name).frame(width: 220, alignment: .leading)
                    Text(r.detail).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                    Text(r.status.label).font(.caption.weight(.semibold)).foregroundStyle(r.status.color).frame(width: 90, alignment: .trailing)
                }
                Divider()
            }
        }
    }
}
