import AppKit
import SwiftUI

/// IINA-style settings sidebar: slides in over the right edge of the video, with Video / Audio / Subtitles tabs.
/// Opened from the control bar's sliders button; closed by clicking the video, pressing Esc or the button again.
final class SidebarModel: ObservableObject {
    enum Tab: String, CaseIterable, Identifiable { case video = "Video", audio = "Audio", subtitles = "Subtitles"; var id: String { rawValue } }
    struct Track: Identifiable, Equatable { let id: Int; let name: String; let detail: String; var enabled = true }

    @Published var tab: Tab = .video
    @Published var audioTracks: [Track] = []
    @Published var selectedAudio: Int?
    @Published var subtitleTracks: [Track] = []
    @Published var selectedSubtitle: Int?

    var onPickAudio: ((Int) -> Void)?
    var onPickSubtitle: ((Int?) -> Void)?
    var onLoadSubtitle: (() -> Void)?
    var onClose: (() -> Void)?
}

struct SidebarView: View {
    @ObservedObject var model: SidebarModel
    @ObservedObject var settings = Settings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Tabs: plain uppercase labels, the current one bright (like IINA).
            HStack(spacing: 18) {
                ForEach(SidebarModel.Tab.allCases) { t in
                    Button { model.tab = t } label: {
                        Text(t.rawValue.uppercased())
                            .font(.system(size: 11, weight: .semibold)).kerning(0.6)
                            .foregroundStyle(model.tab == t ? Color.primary : Color.secondary.opacity(0.7))
                            .padding(.vertical, 6)
                            .overlay(alignment: .bottom) {
                                if model.tab == t { Capsule().fill(Color.accentColor).frame(height: 2).offset(y: 2) }
                            }
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
                Button { model.onClose?() } label: { Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary) }
                    .buttonStyle(.plain).help("Close (Esc)")
            }
            .padding(.horizontal, 20)
            .padding(.top, 38)            // clear of the title bar
            .padding(.bottom, 10)
            Divider().opacity(0.5)

            ScrollView {
                Group {
                    switch model.tab {
                    case .video: videoTab
                    case .audio: audioTab
                    case .subtitles: subtitlesTab
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.never)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    // MARK: Video

    private var videoTab: some View {
        VStack(alignment: .leading, spacing: 18) {
            section("Picture") {
                toggle("Crop black bars", isOn: $settings.autoCrop, detail: "Removes letterbox / pillarbox bars automatically (C)")
                toggle("HDR", isOn: $settings.hdrEnabled,
                       detail: settings.nowPlayingHDR == false ? "This video is SDR" :
                               settings.hdrEnabled ? "HDR video uses the display's extra brightness" : "HDR video is tone-mapped to SDR")
                    .disabled(settings.nowPlayingHDR == false)
            }
            section("Colour") {
                slider("Brightness", value: $settings.brightness, range: -0.5...0.5, neutral: 0, format: { String(format: "%+.2f", $0) })
                slider("Contrast", value: $settings.contrast, range: 0.5...1.5, neutral: 1, format: { String(format: "%.2f", $0) })
                slider("Gamma", value: $settings.gamma, range: 0.5...2.0, neutral: 1, format: { String(format: "%.2f", $0) })
                HStack {
                    Text("Saved for this video only").font(.caption).foregroundStyle(.tertiary)
                    Spacer()
                    Button("Reset") { settings.resetColor() }.disabled(!settings.hasColorAdjustments).controlSize(.small)
                }
            }
        }
    }

    // MARK: Audio

    private var audioTab: some View {
        VStack(alignment: .leading, spacing: 18) {
            section("Audio track") {
                if model.audioTracks.isEmpty {
                    Text("No audio tracks").foregroundStyle(.secondary)
                } else {
                    trackList(model.audioTracks, selected: model.selectedAudio) { model.onPickAudio?($0) }
                }
            }
        }
    }

    // MARK: Subtitles

    private var subtitlesTab: some View {
        VStack(alignment: .leading, spacing: 18) {
            section("Subtitle track") {
                trackList([SidebarModel.Track(id: -1, name: "Off", detail: "")] + model.subtitleTracks,
                          selected: model.selectedSubtitle ?? -1) { model.onPickSubtitle?($0 < 0 ? nil : $0) }
                Button("Load Subtitle File…") { model.onLoadSubtitle?() }.controlSize(.small).padding(.top, 4)
            }
        }
    }

    // MARK: Pieces

    private func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title.uppercased()).font(.system(size: 10, weight: .semibold)).kerning(0.5).foregroundStyle(.secondary)
            content()
        }
    }

    private func toggle(_ title: String, isOn: Binding<Bool>, detail: String) -> some View {
        // Labels on the left, switches in one column on the right edge.
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Toggle(title, isOn: isOn).labelsHidden().toggleStyle(.switch).controlSize(.small)
        }
    }

    private func slider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, neutral: Double,
                        format: @escaping (Double) -> String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(title)
                Spacer()
                Text(format(value.wrappedValue)).monospacedDigit()
                    .foregroundStyle(abs(value.wrappedValue - neutral) < 0.005 ? Color.secondary : Color.primary)
            }
            Slider(value: value, in: range).controlSize(.small)
        }
        .contextMenu { Button("Reset \(title)") { value.wrappedValue = neutral } }
    }

    private func trackList(_ tracks: [SidebarModel.Track], selected: Int?, pick: @escaping (Int) -> Void) -> some View {
        VStack(spacing: 2) {
            ForEach(tracks) { t in
                Button { pick(t.id) } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: "checkmark").font(.system(size: 10, weight: .bold))
                            .opacity(t.id == selected ? 1 : 0).frame(width: 12)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(t.name).lineLimit(2)
                            if !t.detail.isEmpty { Text(t.detail).font(.caption).foregroundStyle(.secondary) }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 8).padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 6).fill(t.id == selected ? Color.white.opacity(0.10) : .clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!t.enabled)
                .opacity(t.enabled ? 1 : 0.45)
            }
        }
    }
}

/// The sidebar's AppKit container: dark HUD material with a hairline on its left edge.
final class SidebarContainer: NSVisualEffectView {
    static let width: CGFloat = 320
    let model = SidebarModel()

    override init(frame: NSRect) {
        super.init(frame: frame)
        material = .hudWindow
        blendingMode = .withinWindow
        state = .active
        appearance = NSAppearance(named: .darkAqua)
        // Dark tint under the blur so bright video doesn't wash the panel out (IINA's sidebar is near-black).
        let tint = NSView()
        tint.wantsLayer = true
        tint.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
        tint.translatesAutoresizingMaskIntoConstraints = false
        addSubview(tint)
        let host = NSHostingView(rootView: SidebarView(model: model))
        host.translatesAutoresizingMaskIntoConstraints = false
        addSubview(host)
        let edge = NSView()
        edge.wantsLayer = true
        edge.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.12).cgColor
        edge.translatesAutoresizingMaskIntoConstraints = false
        addSubview(edge)
        NSLayoutConstraint.activate([
            tint.leadingAnchor.constraint(equalTo: leadingAnchor), tint.trailingAnchor.constraint(equalTo: trailingAnchor),
            tint.topAnchor.constraint(equalTo: topAnchor), tint.bottomAnchor.constraint(equalTo: bottomAnchor),
            host.leadingAnchor.constraint(equalTo: leadingAnchor), host.trailingAnchor.constraint(equalTo: trailingAnchor),
            host.topAnchor.constraint(equalTo: topAnchor), host.bottomAnchor.constraint(equalTo: bottomAnchor),
            edge.leadingAnchor.constraint(equalTo: leadingAnchor), edge.topAnchor.constraint(equalTo: topAnchor),
            edge.bottomAnchor.constraint(equalTo: bottomAnchor), edge.widthAnchor.constraint(equalToConstant: 0.5),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    // Clicks and drags inside the sidebar must not move the window or reach the video.
    override var mouseDownCanMoveWindow: Bool { false }
    override func mouseDown(with event: NSEvent) {}
}
