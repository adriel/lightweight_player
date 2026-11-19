import AppKit
import SwiftUI
import UniformTypeIdentifiers

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var players: [PlayerWindowController] = []
    private var settingsWindow: SettingsWindowController?
    private lazy var inspector: InspectorController = {
        let c = InspectorController()
        c.currentPlayer = { [weak self] in
            guard let self else { return nil }
            return self.players.first { $0.window?.isMainWindow == true } ?? self.players.last { $0.engine != nil }
        }
        return c
    }()

    @objc func toggleInspector(_ sender: Any?) { inspector.toggle() }
    private var openedAtLaunch = false

    func applicationDidFinishLaunching(_ n: Notification) {
        NSApp.mainMenu = buildMenu()
        // Launch with a path argument (e.g. `open -a LightPlayer file.mkv` goes through application(_:open:)).
        let args = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("-") }
        if let a = args.first { openURLs([a.contains("://") ? URL(string: a)! : URL(fileURLWithPath: a)]) }
        DispatchQueue.main.async { [self] in
            if players.isEmpty && !openedAtLaunch { newPlayer().showWindow(nil) }
            if CommandLine.arguments.contains("--settings") { showSettings(nil) }
            if CommandLine.arguments.contains("--inspector") { DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.toggleInspector(nil) } }
        }
    }

    func application(_ app: NSApplication, open urls: [URL]) {
        openedAtLaunch = true
        openURLs(urls)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { true }

    private func newPlayer() -> PlayerWindowController {
        let p = PlayerWindowController()
        p.onClose = { [weak self] c in self?.players.removeAll { $0 === c } }
        players.append(p)
        return p
    }

    /// Reuse the frontmost empty/idle window, otherwise the key player.
    private func targetPlayer() -> PlayerWindowController {
        if let key = players.first(where: { $0.window?.isKeyWindow == true }) { return key }
        return players.first ?? newPlayer()
    }

    func openURLs(_ urls: [URL]) {
        guard let u = urls.first else { return }
        targetPlayer().open(u)
    }

    // MARK: Actions

    @objc func openDocument(_ sender: Any?) {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.movie, .audiovisualContent, .video, .audio] + ["mkv", "webm", "ts", "m2ts", "avi", "flv", "ogv"].compactMap { UTType(filenameExtension: $0) }
        p.allowsMultipleSelection = false
        if p.runModal() == .OK, let u = p.url { openURLs([u]) }
    }

    @objc func openURLPrompt(_ sender: Any?) {
        let a = NSAlert()
        a.messageText = "Open URL"
        a.informativeText = "Direct link to an .mp4 / .mkv / .webm file (http or https). Credentials in the URL are sent as Basic auth."
        let f = NSTextField(frame: NSRect(x: 0, y: 0, width: 420, height: 24))
        f.placeholderString = "https://example.com/video.mkv"
        if let s = NSPasteboard.general.string(forType: .string), s.hasPrefix("http") { f.stringValue = s }
        a.accessoryView = f
        a.addButton(withTitle: "Open"); a.addButton(withTitle: "Cancel")
        a.window.initialFirstResponder = f
        if a.runModal() == .alertFirstButtonReturn, let u = URL(string: f.stringValue.trimmingCharacters(in: .whitespaces)), u.scheme?.hasPrefix("http") == true {
            openURLs([u])
        }
    }

    @objc func showSettings(_ sender: Any?) {
        if settingsWindow == nil { settingsWindow = SettingsWindowController() }
        settingsWindow?.showWindow(nil)
        NSApp.activate()
    }

    @objc func newWindow(_ sender: Any?) { newPlayer().showWindow(nil) }

    // MARK: Menu

    private func buildMenu() -> NSMenu {
        let main = NSMenu()
        func item(_ title: String, _ action: Selector?, _ key: String = "", _ mods: NSEvent.ModifierFlags = .command, target: AnyObject? = nil) -> NSMenuItem {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
            i.keyEquivalentModifierMask = mods
            i.target = target
            return i
        }
        let appMenu = NSMenu()
        appMenu.addItem(item("About LightPlayer", #selector(NSApplication.orderFrontStandardAboutPanel(_:)), ""))
        appMenu.addItem(.separator())
        appMenu.addItem(item("Settings…", #selector(showSettings(_:)), ",", target: self))
        appMenu.addItem(.separator())
        appMenu.addItem(item("Hide LightPlayer", #selector(NSApplication.hide(_:)), "h"))
        appMenu.addItem(item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]))
        appMenu.addItem(.separator())
        appMenu.addItem(item("Quit LightPlayer", #selector(NSApplication.terminate(_:)), "q"))
        main.addItem(withTitle: "LightPlayer", action: nil, keyEquivalent: "").submenu = appMenu

        let file = NSMenu(title: "File")
        file.addItem(item("New Window", #selector(newWindow(_:)), "n", target: self))
        file.addItem(item("Open…", #selector(openDocument(_:)), "o", target: self))
        file.addItem(item("Open URL…", #selector(openURLPrompt(_:)), "o", [.command, .shift], target: self))
        let recent = NSMenuItem(title: "Open Recent", action: nil, keyEquivalent: "")
        let recentMenu = NSMenu(title: "Open Recent")
        recentMenu.perform(NSSelectorFromString("_setMenuName:"), with: "NSRecentDocumentsMenu")
        recentMenu.addItem(item("Clear Menu", #selector(NSDocumentController.clearRecentDocuments(_:)), ""))
        recent.submenu = recentMenu
        file.addItem(recent)
        file.addItem(.separator())
        file.addItem(item("Close", #selector(NSWindow.performClose(_:)), "w"))
        main.addItem(withTitle: "File", action: nil, keyEquivalent: "").submenu = file

        let view = NSMenu(title: "View")
        view.addItem(item("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]))
        view.addItem(.separator())
        view.addItem(item("Half Size", #selector(PlayerWindowController.halfSize(_:)), "0"))
        view.addItem(item("Normal Size", #selector(PlayerWindowController.normalSize(_:)), "1"))
        view.addItem(item("Double Size", #selector(PlayerWindowController.doubleSize(_:)), "2"))
        view.addItem(item("Fit to Screen", #selector(PlayerWindowController.fitToScreen(_:)), "3"))
        main.addItem(withTitle: "View", action: nil, keyEquivalent: "").submenu = view

        let window = NSMenu(title: "Window")
        window.addItem(item("Inspector", #selector(toggleInspector(_:)), "i", target: self))
        window.addItem(.separator())
        window.addItem(item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"))
        window.addItem(item("Zoom", #selector(NSWindow.performZoom(_:)), ""))
        main.addItem(withTitle: "Window", action: nil, keyEquivalent: "").submenu = window
        NSApp.windowsMenu = window
        return main
    }
}

/// Popover with live brightness / contrast / gamma sliders (bound to Settings).
final class VideoAdjustViewController: NSHostingController<VideoAdjustView> {
    init() { super.init(rootView: VideoAdjustView(settings: Settings.shared)) }
    @MainActor required dynamic init?(coder: NSCoder) { fatalError() }
}

struct VideoAdjustView: View {
    @ObservedObject var settings: Settings
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: $settings.hdrEnabled) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("HDR")
                    Text(settings.nowPlayingHDR == false ? "This video is SDR" :
                         settings.hdrEnabled ? "HDR video uses the display's extra brightness" : "HDR video is tone-mapped to SDR")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)
            .disabled(settings.nowPlayingHDR == false)
            Divider()
            slider("Brightness", value: $settings.brightness, range: -0.5...0.5, format: { String(format: "%+.2f", $0) })
            slider("Contrast", value: $settings.contrast, range: 0.5...1.5, format: { String(format: "%.2f", $0) })
            slider("Gamma", value: $settings.gamma, range: 0.5...2.0, format: { String(format: "%.2f", $0) })
            HStack {
                Spacer()
                Button("Reset") { settings.resetColor() }.disabled(!settings.hasColorAdjustments)
            }
        }
        .padding(14)
        .frame(width: 280)
    }
    private func slider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, format: @escaping (Double) -> String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack { Text(title); Spacer(); Text(format(value.wrappedValue)).monospacedDigit().foregroundStyle(.secondary) }
            Slider(value: value, in: range)
        }
    }
}
