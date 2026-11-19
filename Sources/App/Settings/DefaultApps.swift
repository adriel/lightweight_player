import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Settings › File Types: shows which app opens each video format and lets LightPlayer become the default
/// (the same Launch Services setting as Finder's Get Info › Open With › Change All).
@MainActor final class DefaultAppsModel: ObservableObject {
    struct Format: Identifiable {
        let id: String, name: String, extensions: String, typeID: String, icon: String
        var type: UTType? { UTType(typeID) }
    }
    static let formats: [Format] = [
        .init(id: "mkv", name: "Matroska", extensions: ".mkv", typeID: "org.matroska.mkv", icon: "doc-mkv"),
        .init(id: "mp4", name: "MPEG-4", extensions: ".mp4", typeID: UTType.mpeg4Movie.identifier, icon: "doc-mp4"),
        .init(id: "m4v", name: "MPEG-4 (iTunes)", extensions: ".m4v", typeID: "com.apple.m4v-video", icon: "doc-m4v"),
        .init(id: "mov", name: "QuickTime", extensions: ".mov", typeID: UTType.quickTimeMovie.identifier, icon: "doc-mov"),
        .init(id: "webm", name: "WebM", extensions: ".webm", typeID: "org.webmproject.webm", icon: "doc-webm"),
        .init(id: "avi", name: "AVI", extensions: ".avi", typeID: UTType.avi.identifier, icon: "doc-avi"),
        .init(id: "ts", name: "MPEG transport stream", extensions: ".ts .m2ts .mts", typeID: UTType.mpeg2TransportStream.identifier, icon: "doc-ts"),
        .init(id: "flv", name: "Flash Video", extensions: ".flv", typeID: "com.adobe.flash.video", icon: "doc-flv"),
    ]

    @Published private(set) var handlers: [String: URL] = [:]
    @Published private(set) var busy = false
    @Published var message: String?

    func refresh() {
        var h: [String: URL] = [:]
        for f in Self.formats { if let t = f.type, let u = NSWorkspace.shared.urlForApplication(toOpen: t) { h[f.id] = u } }
        handlers = h
    }

    func isLightPlayer(_ f: Format) -> Bool {
        guard let u = handlers[f.id] else { return false }
        return Bundle(url: u)?.bundleIdentifier == Bundle.main.bundleIdentifier
    }

    var allDefault: Bool { Self.formats.allSatisfy(isLightPlayer) }

    func makeDefault(_ formats: [Format]) {
        busy = true; message = nil
        Task {
            var failed: [String] = []
            for f in formats where !isLightPlayer(f) {
                guard let t = f.type else { failed.append(f.name); continue }
                do { try await NSWorkspace.shared.setDefaultApplication(at: Bundle.main.bundleURL, toOpen: t) }
                catch { failed.append(f.name) }
            }
            busy = false
            refresh()
            message = failed.isEmpty ? nil : "Couldn't change: " + failed.joined(separator: ", ")
        }
    }
}

struct FileTypesTab: View {
    @StateObject private var model = DefaultAppsModel()
    var body: some View {
        Form {
            Section {
                ForEach(DefaultAppsModel.formats) { f in
                    HStack(spacing: 10) {
                        Image(nsImage: Bundle.main.image(forResource: f.icon) ?? NSImage()).resizable().frame(width: 28, height: 28)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(f.name)
                            Text(f.extensions).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        currentApp(f)
                        if model.isLightPlayer(f) {
                            Label("Default", systemImage: "checkmark.circle.fill").labelStyle(.titleAndIcon)
                                .foregroundStyle(.green).font(.callout).frame(width: 110, alignment: .trailing)
                        } else {
                            Button("Make Default") { model.makeDefault([f]) }.disabled(model.busy || f.type == nil)
                                .frame(width: 110, alignment: .trailing)
                        }
                    }
                }
            } header: { Text("Open these files with LightPlayer by default") } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    if let m = model.message { Text(m).foregroundStyle(.red) }
                    Text("Same setting as Finder's Get Info › Open With › Change All. You can switch back any time there or from another player.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section {
                HStack {
                    Button(model.allDefault ? "LightPlayer is the default for all of these" : "Make LightPlayer the Default for All") {
                        model.makeDefault(DefaultAppsModel.formats)
                    }
                    .disabled(model.busy || model.allDefault)
                    if model.busy { ProgressView().controlSize(.small) }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { model.refresh() }
        // Pick up changes made in Finder while the window is open.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in model.refresh() }
    }

    @ViewBuilder private func currentApp(_ f: DefaultAppsModel.Format) -> some View {
        if let u = model.handlers[f.id], !model.isLightPlayer(f) {
            HStack(spacing: 4) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: u.path)).resizable().frame(width: 16, height: 16)
                Text(FileManager.default.displayName(atPath: u.path).replacingOccurrences(of: ".app", with: ""))
                    .font(.callout).foregroundStyle(.secondary)
            }
        } else if model.handlers[f.id] == nil {
            Text("No default").font(.callout).foregroundStyle(.secondary)
        }
    }
}
