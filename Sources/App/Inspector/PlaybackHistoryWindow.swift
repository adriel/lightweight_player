import AppKit
import SwiftUI

/// Window › Playback History (⇧⌘H), like IINA's: everything played, grouped by day or folder, with progress,
/// search, double-click to resume, and removal.
final class PlaybackHistoryWindowController: NSWindowController {
    var onOpen: ((URL) -> Void)?

    init() {
        let host = NSHostingController(rootView: AnyView(EmptyView()))
        host.sceneBridgingOptions = [.toolbars, .title]
        let w = NSWindow(contentViewController: host)
        w.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        w.toolbarStyle = .unified
        w.title = "Playback History"
        w.isReleasedWhenClosed = false
        w.setContentSize(NSSize(width: 780, height: 480))
        w.contentMinSize = NSSize(width: 520, height: 280)
        super.init(window: w)
        host.rootView = AnyView(PlaybackHistoryView(open: { [weak self] u in self?.onOpen?(u) }))
        w.center()
        w.setFrameAutosaveName("PlaybackHistory")
    }
    required init?(coder: NSCoder) { fatalError() }
}

struct PlaybackHistoryView: View {
    let open: (URL) -> Void
    @ObservedObject private var history = PlaybackHistory.shared
    @State private var selection = Set<String>()
    @State private var search = ""
    @State private var byFolder = false

    private struct HistoryGroup: Identifiable { let id: String; let title: String; let items: [PlaybackHistory.Entry] }

    private var groups: [HistoryGroup] {
        let q = search.trimmingCharacters(in: .whitespaces)
        let items = q.isEmpty ? history.entries : history.entries.filter { $0.name.localizedCaseInsensitiveContains(q) || $0.folder.localizedCaseInsensitiveContains(q) }
        if byFolder {
            var order: [String] = []; var map: [String: [PlaybackHistory.Entry]] = [:]
            for e in items { if map[e.folder] == nil { order.append(e.folder) }; map[e.folder, default: []].append(e) }
            return order.map { f in HistoryGroup(id: "f:" + f, title: f.isEmpty ? "Other" : (f as NSString).abbreviatingWithTildeInPath, items: map[f]!) }
        }
        let cal = Calendar.current
        var order: [Date] = []; var map: [Date: [PlaybackHistory.Entry]] = [:]
        for e in items { let d = cal.startOfDay(for: e.playedAt); if map[d] == nil { order.append(d) }; map[d, default: []].append(e) }
        return order.map { d in HistoryGroup(id: "d:\(d.timeIntervalSince1970)", title: d.formatted(date: .long, time: .omitted), items: map[d]!) }
    }

    var body: some View {
        Group {
            if history.entries.isEmpty {
                ContentUnavailableView("No playback history", systemImage: "clock.arrow.circlepath",
                                       description: Text(Settings.shared.keepHistory ? "Videos you play show up here." : "History is turned off in Settings › Playback."))
            } else {
                Table(of: PlaybackHistory.Entry.self, selection: $selection) {
                    TableColumn("Media") { e in
                        HStack(spacing: 8) {
                            Image(nsImage: icon(e)).resizable().frame(width: 16, height: 16)
                            MediaNameView(fileName: e.name)
                        }
                        .help(e.isFile ? (URL(string: e.url)?.path ?? "") : (URL(string: e.url).map(InfoFormat.safeURL) ?? ""))
                    }
                    TableColumn("Progress") { e in
                        if e.duration > 0 {
                            HStack(spacing: 6) {
                                ProgressView(value: e.progress).progressViewStyle(.linear).controlSize(.small)
                                Text(e.progress > 0.97 ? "Done" : formatTime(e.position)).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                                    .frame(width: 52, alignment: .trailing)
                            }
                        } else if e.position > 1 {
                            Text("at " + formatTime(e.position)).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                        } else { Text("—").foregroundStyle(.tertiary) }
                    }
                    .width(min: 120, ideal: 170, max: 240)
                    TableColumn("Played at") { e in
                        Text(byFolder ? e.playedAt.formatted(date: .abbreviated, time: .shortened) : e.playedAt.formatted(date: .omitted, time: .shortened))
                            .foregroundStyle(.secondary).monospacedDigit()
                    }
                    .width(min: 80, ideal: byFolder ? 150 : 90, max: 200)
                } rows: {
                    ForEach(groups) { g in
                        Section(g.title) { ForEach(g.items) { TableRow($0) } }
                    }
                }
                .contextMenu(forSelectionType: String.self) { ids in
                    Button("Open") { openFirst(ids) }.disabled(ids.isEmpty)
                    Button("Show in Finder") { showInFinder(ids) }.disabled(!ids.contains { id in entry(id)?.isFile == true })
                    Divider()
                    Button("Remove from History") { history.remove(ids); selection.subtract(ids) }.disabled(ids.isEmpty)
                } primaryAction: { ids in openFirst(ids) }
                .onDeleteCommand { history.remove(selection); selection.removeAll() }
            }
        }
        .frame(minWidth: 520, minHeight: 280)
        .searchable(text: $search, placement: .toolbar, prompt: "Search")
        .toolbar {
            ToolbarItem {
                Picker("Group by", selection: $byFolder) {
                    Label("Date", systemImage: "calendar").tag(false)
                    Label("Folder", systemImage: "folder").tag(true)
                }
                .pickerStyle(.segmented)
                .help("Group by date or by folder")
            }
            ToolbarItem {
                Button { history.remove(selection); selection.removeAll() } label: { Label("Remove", systemImage: "trash") }
                    .disabled(selection.isEmpty)
                    .help("Remove the selected items from history")
            }
        }
    }

    private func entry(_ id: String) -> PlaybackHistory.Entry? { history.entries.first { $0.id == id } }
    private func openFirst(_ ids: Set<String>) {
        guard let e = history.entries.first(where: { ids.contains($0.id) }), let u = URL(string: e.url) else { return }
        open(u)
    }
    private func showInFinder(_ ids: Set<String>) {
        let urls = ids.compactMap { entry($0) }.filter(\.isFile).compactMap { URL(string: $0.url) }
        if !urls.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(urls) }
    }
    private func icon(_ e: PlaybackHistory.Entry) -> NSImage {
        if !e.isFile { return NSImage(systemSymbolName: "globe", accessibilityDescription: nil) ?? NSImage() }
        let map = ["mkv": "doc-mkv", "mp4": "doc-mp4", "m4v": "doc-m4v", "mov": "doc-mov", "webm": "doc-webm", "avi": "doc-avi",
                   "ts": "doc-ts", "m2ts": "doc-ts", "mts": "doc-ts", "flv": "doc-flv"]
        return Bundle.main.image(forResource: map[(e.name as NSString).pathExtension.lowercased()] ?? "doc-video") ?? NSImage()
    }
}
