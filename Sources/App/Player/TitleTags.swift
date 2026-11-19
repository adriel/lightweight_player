import AppKit
import SwiftUI

/// Small tags on the right of the player's title bar — playback engine, hardware/software decoding, HDR format,
/// black-bar crop. Hovering a tag immediately drops down a panel with details; it stays open while the pointer is
/// on the tag or inside the panel (so its buttons can be clicked).
final class TitleTagsModel: ObservableObject {
    @Published var engine: (name: String, detail: String)?
    @Published var decoding: VideoDecodingInfo?
    @Published var audio: (codec: String, decoder: String)?
    @Published var hdr: String?
    @Published var hdrOutput = true          // false when HDR is turned off (tone-mapped to SDR)
    @Published var edrHeadroom: Double = 1
    @Published var crop: String?             // e.g. "1920×800 — letterbox removed"
    @Published var hovering = false          // a tag or its panel is under the pointer
    var onRemoveCrop: (() -> Void)?
    var onCropSettings: (() -> Void)?
}

struct TitleTagsView: View {
    @ObservedObject var model: TitleTagsModel
    var body: some View {
        HStack(spacing: 6) {
            if let c = model.crop {
                InfoTag(model: model, text: "Crop", icon: "crop", tint: Color(red: 0.4, green: 0.7, blue: 1.0),
                        title: "Black bars cropped", rows: [("Showing", c)]) {
                    HStack {
                        Button("Don't Crop This Video") { model.onRemoveCrop?() }
                        Button("Settings…") { model.onCropSettings?() }
                    }
                    .controlSize(.small)
                }
            }
            if let e = model.engine {
                InfoTag(model: model, text: e.name, icon: "square.stack.3d.up", tint: Color(white: 0.72),
                        title: "Playback engine", rows: [
                            ("Engine", e.name),
                            ("Pipeline", e.detail),
                            ("Used for", e.name == "FFmpeg" ? "MKV, WebM, TS, network streams and fragmented MP4" : "Local MP4, M4V and MOV files, HLS (YouTube, Twitch)"),
                        ])
            }
            if let d = model.decoding {
                InfoTag(model: model, text: d.hardware ? "HW" : "SW", icon: d.hardware ? "cpu" : "gearshape.2",
                        tint: d.hardware ? Color(red: 0.25, green: 0.75, blue: 0.45) : Color.orange,
                        title: d.hardware ? "Hardware decoding" : "Software decoding", rows: [
                            ("Video", d.codec),
                            ("Decoder", d.decoder),
                            ("Runs on", d.hardware ? "Apple media engine (low power)" : "CPU"),
                        ] + (model.audio.map { [("Audio", $0.codec), ("Decoder", $0.decoder)] } ?? []))
            }
            if let h = model.hdr {
                InfoTag(model: model, text: model.hdrOutput ? h : "\(h) → SDR", icon: "sun.max.fill",
                        tint: h == "Dolby Vision" ? Color(red: 0.55, green: 0.45, blue: 1.0) : Color(red: 1.0, green: 0.72, blue: 0.2),
                        title: "\(h) video", rows: [
                            ("Format", h == "Dolby Vision" ? "Dolby Vision (HDR10 base layer)" : h == "HLG" ? "HLG (hybrid log-gamma)" : "HDR10 (PQ)"),
                            ("Output", model.hdrOutput ? "Extended dynamic range" : "Tone-mapped to SDR"),
                            ("Display", model.edrHeadroom > 1.01 ? String(format: "HDR capable, %.1f× headroom", model.edrHeadroom) : "SDR"),
                        ] + (model.hdrOutput ? [] : [("", "HDR is off — turn it on in the brightness controls or Settings › Video.")]))
                    .opacity(model.hdrOutput ? 1 : 0.75)
            }
        }
        .padding(.trailing, 10)
        .frame(height: 28)
        .fixedSize()
    }
}

/// A tag that shows a details panel while the pointer is over the tag or the panel.
private struct InfoTag<Extra: View>: View {
    @ObservedObject var model: TitleTagsModel
    let text: String, icon: String, tint: Color
    let title: String
    let rows: [(String, String)]
    @ViewBuilder var extra: () -> Extra
    @State private var overTag = false
    @State private var overPanel = false
    @State private var shown = false
    @State private var closeWork: DispatchWorkItem?

    init(model: TitleTagsModel, text: String, icon: String, tint: Color, title: String, rows: [(String, String)],
         @ViewBuilder extra: @escaping () -> Extra = { EmptyView() }) {
        self.model = model; self.text = text; self.icon = icon; self.tint = tint; self.title = title; self.rows = rows; self.extra = extra
    }

    private func update() {
        closeWork?.cancel()
        let want = overTag || overPanel
        model.hovering = want
        if want { shown = true; return }
        // Short grace period so the pointer can travel from the tag into the panel.
        let w = DispatchWorkItem { if !overTag && !overPanel { shown = false } }
        closeWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: w)
    }

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: icon).font(.system(size: 8, weight: .bold))
            Text(text).font(.system(size: 10, weight: .semibold))
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(RoundedRectangle(cornerRadius: 5).fill(tint.opacity(shown ? 0.28 : 0.16)))
        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(tint.opacity(0.35), lineWidth: 0.5))
        .fixedSize()
        .contentShape(Rectangle())
        .onHover { overTag = $0; update() }
        .popover(isPresented: $shown, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                Label(title, systemImage: icon).font(.headline).foregroundStyle(tint)
                // Fixed label column; values get all the remaining width and only wrap when they're really long.
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, r in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text(r.0).foregroundStyle(.secondary).frame(width: 64, alignment: .trailing)
                            Text(r.1).frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .font(.callout)
                extra()
            }
            .padding(14)
            .frame(width: 300, alignment: .leading)
            .onHover { overPanel = $0; update() }
        }
    }
}
