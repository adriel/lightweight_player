import AppKit
import SwiftUI

/// Small tags on the right of the player's title bar: hardware/software decoding and the HDR format.
final class TitleTagsModel: ObservableObject {
    @Published var decoding: VideoDecodingInfo?
    @Published var hdr: String?
    @Published var hdrOutput = true          // false when HDR is turned off (tone-mapped to SDR)
}

struct TitleTagsView: View {
    @ObservedObject var model: TitleTagsModel
    var body: some View {
        HStack(spacing: 6) {
            if let d = model.decoding {
                Tag(text: d.hardware ? "HW" : "SW", icon: d.hardware ? "cpu" : "gearshape.2",
                    tint: d.hardware ? Color(red: 0.25, green: 0.75, blue: 0.45) : Color.orange)
                    .help((d.hardware ? "Hardware decoding: " : "Software decoding: ") + d.detail)
            }
            if let h = model.hdr {
                Tag(text: model.hdrOutput ? h : "\(h) → SDR", icon: "sun.max.fill",
                    tint: h == "Dolby Vision" ? Color(red: 0.55, green: 0.45, blue: 1.0) : Color(red: 1.0, green: 0.72, blue: 0.2))
                    .opacity(model.hdrOutput ? 1 : 0.7)
                    .help(model.hdrOutput ? "\(h) video, shown with extended dynamic range" : "\(h) video, tone-mapped to SDR (HDR is off)")
            }
        }
        .padding(.trailing, 10)
        .frame(height: 28)
    }

    private struct Tag: View {
        let text: String, icon: String, tint: Color
        var body: some View {
            HStack(spacing: 3) {
                Image(systemName: icon).font(.system(size: 8, weight: .bold))
                Text(text).font(.system(size: 10, weight: .semibold))
            }
            .foregroundStyle(tint)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 5).fill(tint.opacity(0.16)))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(tint.opacity(0.35), lineWidth: 0.5))
            .fixedSize()
        }
    }
}
