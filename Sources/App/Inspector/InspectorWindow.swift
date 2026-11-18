import AppKit
import SwiftUI

/// ⌘I: IINA-style inspector showing what's playing and how it's decoded. Refreshes at 1 Hz only while visible.
final class InspectorController: NSWindowController, NSWindowDelegate {
    private let model = InspectorModel()
    private var timer: Timer?
    private var lastCPU = (Date(), InfoFormat.processCPUSeconds())
    var currentPlayer: () -> PlayerWindowController? = { nil }

    init() {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 520, height: 600),
                            styleMask: [.titled, .closable, .resizable, .utilityWindow, .hudWindow, .nonactivatingPanel],
                            backing: .buffered, defer: true)
        panel.title = "Inspector"
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.contentView = NSHostingView(rootView: InspectorView(model: model))
        panel.setFrameAutosaveName("Inspector")
        super.init(window: panel)
        panel.delegate = self
    }
    required init?(coder: NSCoder) { fatalError() }

    func toggle() {
        guard let w = window else { return }
        if w.isVisible { w.orderOut(nil); stop() }
        else {
            if w.frame.origin == .zero { w.center() }
            refresh()
            w.orderFront(nil)
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.refresh() }
        }
    }

    func windowWillClose(_ notification: Notification) { stop() }
    private func stop() { timer?.invalidate(); timer = nil }

    private func refresh() {
        let player = currentPlayer()
        guard let engine = player?.engine else {
            model.title = "Nothing playing"
            model.info = MediaInfo(); model.status = []
            return
        }
        model.title = player?.window?.title ?? ""
        model.info = engine.mediaInfo
        let now = Date(), cpu = InfoFormat.processCPUSeconds()
        let cpuPct = (cpu - lastCPU.1) / max(now.timeIntervalSince(lastCPU.0), 0.001) * 100
        lastCPU = (now, cpu)
        var rows: [MediaInfo.Row] = [
            ("Engine", engine.mediaInfo.engine),
            ("Position", "\(formatTime(engine.currentTime)) / \(formatTime(engine.duration))"),
            ("State", engine.isPlaying ? "playing" : "paused"),
        ]
        rows += engine.statusRows()
        if let p = player { rows.append(("Black-bar crop", p.cropDescription)) }
        rows += [("App memory", String(format: "%.0f MB", InfoFormat.processFootprintMB())),
                 ("App CPU", String(format: "%.1f%%", cpuPct)),
                 ("Note", "Hardware-decoded frames live in VTDecoderXPCService (separate process)")]
        rows += InfoFormat.displayRows(player?.window?.screen)
        model.status = rows
    }
}

final class InspectorModel: ObservableObject {
    @Published var title = ""
    @Published var info = MediaInfo()
    @Published var status: [MediaInfo.Row] = []
}

struct InspectorView: View {
    @ObservedObject var model: InspectorModel
    @State private var tab = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(model.title).font(.headline).lineLimit(1).truncationMode(.middle)
                Spacer()
                Picker("", selection: $tab) {
                    Text("General").tag(0); Text("Tracks").tag(1); Text("File").tag(2); Text("Status").tag(3)
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    switch tab {
                    case 0:
                        if !model.info.engine.isEmpty { section("ENGINE", [("Pipeline", model.info.engine)]) }
                        if !model.info.video.isEmpty { section("VIDEO", model.info.video) }
                        if !model.info.audio.isEmpty { section("AUDIO", model.info.audio) }
                    case 1:
                        ForEach(model.info.tracks) { t in
                            section("\(t.kind.uppercased())  \(t.title)\(t.active ? "  ●" : "")", t.rows)
                        }
                    case 2:
                        section("FILE", model.info.file)
                        if !model.info.metadata.isEmpty { section("METADATA", model.info.metadata) }
                    default:
                        section("PLAYBACK", model.status)
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(minWidth: 420, minHeight: 360)
    }

    private func section(_ title: String, _ rows: [MediaInfo.Row]) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.system(size: 13, weight: .bold))
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 6) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, r in
                    GridRow {
                        Text(r.label + ":").font(.system(size: 12, weight: .semibold)).gridColumnAlignment(.trailing)
                        Text(r.value).font(.system(size: 12)).foregroundStyle(r.value == "N/A" || r.value == "—" ? .secondary : .primary)
                            .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            Divider().padding(.top, 4)
        }
    }
}
