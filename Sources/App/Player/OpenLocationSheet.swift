import AppKit
import SwiftUI

/// File › Open URL… as a standard sheet on the player window (like QuickTime's Open Location): one scrolling
/// address field (long URLs never wrap or get clipped), a readable summary of where it points, and
/// Cancel / Open with the usual Esc / Return shortcuts.
enum OpenLocationSheet {
    static func present(on parent: NSWindow?, open: @escaping (URL) -> Void) {
        var sheetWindow: NSWindow?
        let close = { if let w = sheetWindow { (w.sheetParent ?? parent)?.endSheet(w); w.orderOut(nil) } }
        let clip = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let initial = clip.flatMap { OpenLocationView.validURL($0) != nil ? $0 : nil } ?? ""
        // Never wider than the window it hangs from (minus a margin), so it doesn't overhang narrow players.
        let width = min(520, max(380, (parent?.frame.width ?? 560) - 40))
        let view = OpenLocationView(text: initial, width: width, onOpen: { url in close(); open(url) }, onCancel: { close() })
        let host = NSHostingController(rootView: view)
        host.sizingOptions = [.preferredContentSize]
        let w = NSWindow(contentViewController: host)
        w.styleMask = [.titled]
        sheetWindow = w
        if let parent, parent.isVisible { parent.beginSheet(w) } else { w.center(); w.makeKeyAndOrderFront(nil) }
    }
}

struct OpenLocationView: View {
    @State var text: String
    var width: CGFloat = 520
    let onOpen: (URL) -> Void
    let onCancel: () -> Void
    @FocusState private var focused: Bool

    static func validURL(_ s: String) -> URL? {
        guard let u = URL(string: s.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = u.scheme?.lowercased(), ["http", "https", "rtsp", "rtsps"].contains(scheme),
              let host = u.host, !host.isEmpty else { return nil }
        return u
    }
    private var url: URL? { Self.validURL(text) }

    /// The site's registrable domain: "cdn3.media.example.com" → "example.com", "www.tvnz.co.nz" → "tvnz.co.nz".
    /// IP addresses and single-label hosts are shown as they are.
    static func siteName(_ host: String) -> String {
        let labels = host.lowercased().split(separator: ".").map(String.init)
        guard labels.count > 2, labels.contains(where: { $0.contains(where: \.isLetter) }) else { return host.lowercased() }
        // Country domains with a second-level category (co.nz, com.au, org.uk, …) keep one more label.
        let secondLevel: Set<String> = ["co", "com", "org", "net", "gov", "govt", "ac", "edu", "school", "geek", "gen", "ltd", "plc", "nhs", "mil", "or", "ne", "go"]
        let n = labels.last!.count == 2 && secondLevel.contains(labels[labels.count - 2]) ? 3 : 2
        return labels.suffix(n).joined(separator: ".")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 52, height: 52)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Open Location").font(.headline)
                    Text("Enter the address of a video file (.mp4, .mkv, .webm, …) or an rtsp:// camera stream. Files play while they download.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            TextField("https://example.com/video.mkv", text: $text)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1)
                .focused($focused)
                .onSubmit { if let url { onOpen(url) } }
            summary
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel).keyboardShortcut(.cancelAction)
                Button("Open") { if let url { onOpen(url) } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(url == nil)
            }
        }
        .padding(20)
        .frame(width: width)
        .onAppear { focused = true }
    }

    /// One line describing the link: padlock, server, file name, sign-in user (never the password).
    @ViewBuilder private var summary: some View {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        HStack(spacing: 6) {
            if let u = url {
                let secure = ["https", "rtsps"].contains(u.scheme?.lowercased() ?? "")
                Image(systemName: secure ? "lock.fill" : "lock.open").foregroundStyle(secure ? Color.secondary : Color.orange)
                Text(Self.siteName(u.host ?? "")).fontWeight(.medium).lineLimit(1).fixedSize()
                let file = (u.lastPathComponent.removingPercentEncoding ?? u.lastPathComponent)
                if !file.isEmpty && file != "/" {
                    Text("›").foregroundStyle(.tertiary)
                    MediaNameView(fileName: file)
                }
            } else if trimmed.isEmpty {
                Text("Paste or type a link. user:password@host is sent as Basic authentication.")
            } else {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text("Enter a full http://, https:// or rtsp:// address.")
            }
            Spacer(minLength: 0)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(height: 16)
    }
}
