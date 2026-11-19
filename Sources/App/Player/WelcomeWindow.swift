import AppKit
import SwiftUI

/// Start window (like IINA's): app icon, name and version, Open… / Open URL…, and recently played items.
final class WelcomeWindowController: NSWindowController, NSWindowDelegate {
    var onOpenURL: ((URL) -> Void)?
    var onOpenFile: (() -> Void)?
    var onOpenLocation: (() -> Void)?

    init() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 440),
                         styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView], backing: .buffered, defer: false)
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.isMovableByWindowBackground = true
        w.title = "Welcome to LightPlayer"
        w.appearance = NSAppearance(named: .darkAqua)
        w.isReleasedWhenClosed = false
        w.isExcludedFromWindowsMenu = true          // it has its own Window menu item
        super.init(window: w)
        w.delegate = self
        let view = WelcomeView(open: { [weak self] in self?.onOpenFile?() },
                               openLocation: { [weak self] in self?.onOpenLocation?() },
                               openRecent: { [weak self] u in self?.onOpenURL?(u) })
        let host = NSHostingView(rootView: view)
        let fx = NSVisualEffectView()
        fx.material = .underWindowBackground; fx.blendingMode = .behindWindow; fx.state = .active
        host.translatesAutoresizingMaskIntoConstraints = false
        fx.addSubview(host)
        NSLayoutConstraint.activate([host.leadingAnchor.constraint(equalTo: fx.leadingAnchor), host.trailingAnchor.constraint(equalTo: fx.trailingAnchor),
                                     host.topAnchor.constraint(equalTo: fx.topAnchor), host.bottomAnchor.constraint(equalTo: fx.bottomAnchor)])
        w.contentView = fx
        w.center()
    }
    required init?(coder: NSCoder) { fatalError() }
}

struct WelcomeView: View {
    let open: () -> Void
    let openLocation: () -> Void
    let openRecent: (URL) -> Void
    @ObservedObject private var history = PlaybackHistory.shared
    @State private var hovered: String?

    private var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "" }
    private var recent: [PlaybackHistory.Entry] {
        history.entries.filter { e in
            guard let u = URL(string: e.url) else { return false }
            return !u.isFileURL || FileManager.default.fileExists(atPath: u.path)
        }.prefix(9).map { $0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 18) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 84, height: 84)
                VStack(alignment: .leading, spacing: 2) {
                    Text("LightPlayer").font(.system(size: 26, weight: .semibold))
                    Text(version).font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Open…", action: open).buttonStyle(WelcomeButtonStyle())
                Button("Open URL…", action: openLocation).buttonStyle(WelcomeButtonStyle())
            }
            .padding(.horizontal, 32).padding(.top, 44).padding(.bottom, 26)

            if recent.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "film.stack").font(.system(size: 28)).foregroundStyle(.tertiary)
                    Text("Recently played videos show up here.").foregroundStyle(.secondary)
                    Text("Drop a video on this window or use Open…").font(.caption).foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 2) {
                    ForEach(recent) { e in row(e) }
                }
                .padding(.horizontal, 22)
                Spacer(minLength: 16)
            }
        }
        .frame(width: 560, height: 440)
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            _ = providers.first?.loadObject(ofClass: URL.self) { url, _ in if let url { DispatchQueue.main.async { openRecent(url) } } }
            return true
        }
    }

    private func row(_ e: PlaybackHistory.Entry) -> some View {
        Button { if let u = URL(string: e.url) { openRecent(u) } } label: {
            HStack(spacing: 10) {
                Image(nsImage: icon(for: e)).resizable().frame(width: 18, height: 18)
                MediaNameView(fileName: e.name)
                Spacer(minLength: 8)
                if e.progress > 0.01 && e.progress < 0.97 {
                    ProgressView(value: e.progress).progressViewStyle(.linear).frame(width: 48).controlSize(.mini)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 7).fill(hovered == e.id ? Color.white.opacity(0.10) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 ? e.id : (hovered == e.id ? nil : hovered) }
        .help(URL(string: e.url).map { $0.isFileURL ? $0.path : InfoFormat.safeURL($0) } ?? e.name)
    }

    private func icon(for e: PlaybackHistory.Entry) -> NSImage {
        let ext = (e.name as NSString).pathExtension.lowercased()
        let map = ["mkv": "doc-mkv", "mp4": "doc-mp4", "m4v": "doc-m4v", "mov": "doc-mov", "webm": "doc-webm", "avi": "doc-avi",
                   "ts": "doc-ts", "m2ts": "doc-ts", "mts": "doc-ts", "flv": "doc-flv"]
        if !e.isFile { return NSImage(systemSymbolName: "globe", accessibilityDescription: nil) ?? NSImage() }
        return Bundle.main.image(forResource: map[ext] ?? "doc-video") ?? NSImage()
    }
}

/// Rounded translucent pill buttons like IINA's start window.
struct WelcomeButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .medium))
            .padding(.horizontal, 16).padding(.vertical, 9)
            .background(Capsule().fill(Color.white.opacity(configuration.isPressed ? 0.22 : 0.12)))
            .contentShape(Capsule())
    }
}
