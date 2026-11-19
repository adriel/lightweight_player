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
            if players.isEmpty && !openedAtLaunch { showWelcome(nil) }
            if CommandLine.arguments.contains("--settings") { showSettings(nil) }
            if CommandLine.arguments.contains("--inspector") { DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.toggleInspector(nil) } }
        }
    }

    func application(_ app: NSApplication, open urls: [URL]) {
        openedAtLaunch = true
        openURLs(urls)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { true }

    // MARK: Welcome window & history

    private lazy var welcome: WelcomeWindowController = {
        let w = WelcomeWindowController()
        w.onOpenURL = { [weak self] u in self?.openURLs([u]) }
        w.onOpenFile = { [weak self] in self?.openDocument(nil) }
        w.onOpenLocation = { [weak self] in self?.openURLPrompt(nil) }
        return w
    }()
    private var historyWindow: PlaybackHistoryWindowController?

    @objc func showWelcome(_ sender: Any?) {
        welcome.showWindow(nil)
        NSApp.activate()
    }

    @objc func showPlaybackHistory(_ sender: Any?) {
        if historyWindow == nil {
            let h = PlaybackHistoryWindowController()
            h.onOpen = { [weak self] u in self?.openURLs([u]) }
            historyWindow = h
        }
        historyWindow?.showWindow(nil)
    }

    private func newPlayer() -> PlayerWindowController {
        let p = PlayerWindowController()
        p.onClose = { [weak self] c in
            guard let self else { return }
            self.players.removeAll { $0 === c }
            // Last player closed: back to the start window instead of quitting (like IINA).
            if self.players.isEmpty { DispatchQueue.main.async { self.showWelcome(nil) } }
        }
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
        if WebLink.handles(u) { openWebLink(u); return }
        let p = targetPlayer()
        p.showWindow(nil)
        p.open(u)
        if welcome.window?.isVisible == true { welcome.close() }
    }

    /// `lightplayer://open?url=<percent-encoded http(s) URL>[&full_screen=1][&new_window=1]` — lets a web page
    /// hand a video link to the player (same shape as IINA's `iina://open?url=`).
    private func openWebLink(_ link: URL) {
        guard let req = WebLink(link) else {
            let a = NSAlert()
            a.messageText = "Can't open this link"
            a.informativeText = "LightPlayer links must carry an http or https video address, e.g. lightplayer://open?url=https%3A%2F%2Fexample.com%2Fvideo.mp4"
            a.runModal()
            return
        }
        let p = req.newWindow ? newPlayer() : targetPlayer()
        p.showWindow(nil)
        p.enterFullScreenWhenReady = req.fullScreen
        p.open(req.video)
        NSApp.activate()
    }

    // MARK: Actions

    @objc func openDocument(_ sender: Any?) {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.movie, .audiovisualContent, .video, .audio] + ["mkv", "webm", "ts", "m2ts", "avi", "flv", "ogv"].compactMap { UTType(filenameExtension: $0) }
        p.allowsMultipleSelection = false
        if p.runModal() == .OK, let u = p.url { openURLs([u]) }
    }

    @objc func openURLPrompt(_ sender: Any?) {
        if welcome.window?.isVisible == true, players.isEmpty || welcome.window?.isKeyWindow == true {
            OpenLocationSheet.present(on: welcome.window) { [weak self] url in self?.openURLs([url]) }
            return
        }
        let target = targetPlayer()
        if target.window?.isVisible != true { target.showWindow(nil) }
        OpenLocationSheet.present(on: target.window) { [weak self, weak target] url in
            if WebLink.handles(url) { self?.openURLs([url]) } else { target?.open(url) }
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
        file.addItem(item("Playback History", #selector(showPlaybackHistory(_:)), "h", [.command, .shift], target: self))
        file.addItem(.separator())
        file.addItem(item("Show Current File in Finder", #selector(PlayerWindowController.showCurrentFileInFinder(_:)), ""))
        file.addItem(.separator())
        file.addItem(item("Close", #selector(NSWindow.performClose(_:)), "w"))
        main.addItem(withTitle: "File", action: nil, keyEquivalent: "").submenu = file

        // Standard Edit menu: without it ⌘V / ⌘C / ⌘A / ⌘Z don't work in any text field (e.g. Open Location).
        let edit = NSMenu(title: "Edit")
        edit.addItem(item("Undo", Selector(("undo:")), "z"))
        edit.addItem(item("Redo", Selector(("redo:")), "z", [.command, .shift]))
        edit.addItem(.separator())
        edit.addItem(item("Cut", #selector(NSText.cut(_:)), "x"))
        edit.addItem(item("Copy", #selector(NSText.copy(_:)), "c"))
        edit.addItem(item("Paste", #selector(NSText.paste(_:)), "v"))
        edit.addItem(item("Delete", #selector(NSText.delete(_:)), ""))
        edit.addItem(item("Select All", #selector(NSText.selectAll(_:)), "a"))
        main.addItem(withTitle: "Edit", action: nil, keyEquivalent: "").submenu = edit

        let view = NSMenu(title: "View")
        view.addItem(item("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]))
        view.addItem(.separator())
        view.addItem(item("Half Size", #selector(PlayerWindowController.halfSize(_:)), "0"))
        view.addItem(item("Normal Size", #selector(PlayerWindowController.normalSize(_:)), "1"))
        view.addItem(item("Double Size", #selector(PlayerWindowController.doubleSize(_:)), "2"))
        view.addItem(item("Fit to Screen", #selector(PlayerWindowController.fitToScreen(_:)), "3"))
        main.addItem(withTitle: "View", action: nil, keyEquivalent: "").submenu = view

        let playback = NSMenu(title: "Playback")
        playback.addItem(item("Next Frame   ( . )", #selector(PlayerWindowController.stepForward(_:))))
        playback.addItem(item("Previous Frame   ( , )", #selector(PlayerWindowController.stepBackward(_:))))
        playback.addItem(.separator())
        playback.addItem(item("Next Chapter   ( fn ↓ )", #selector(PlayerWindowController.nextChapter(_:))))
        playback.addItem(item("Previous Chapter   ( fn ↑ )", #selector(PlayerWindowController.previousChapter(_:))))
        let chapters = NSMenuItem(title: "Chapters", action: nil, keyEquivalent: "")
        chapters.submenu = NSMenu(title: "Chapters"); chapters.submenu?.delegate = self; chapters.submenu?.identifier = .init("chapters")
        playback.addItem(chapters)
        main.addItem(withTitle: "Playback", action: nil, keyEquivalent: "").submenu = playback

        let audio = NSMenu(title: "Audio")
        let tracks = NSMenuItem(title: "Audio Track", action: nil, keyEquivalent: "")
        tracks.submenu = NSMenu(title: "Audio Track"); tracks.submenu?.delegate = self; tracks.submenu?.identifier = .init("audioTracks")
        audio.addItem(tracks)
        audio.addItem(item("Next Audio Track   ( A )", #selector(PlayerWindowController.cycleAudioTrack(_:))))
        main.addItem(withTitle: "Audio", action: nil, keyEquivalent: "").submenu = audio

        let window = NSMenu(title: "Window")
        window.addItem(item("Inspector", #selector(toggleInspector(_:)), "i", target: self))
        window.addItem(item("Welcome to LightPlayer", #selector(showWelcome(_:)), "1", [.command, .shift], target: self))
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

extension AppDelegate: NSMenuDelegate {
    /// Fills the Audio Track / Chapters submenus from the frontmost player when they open.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let player = players.first { $0.window?.isKeyWindow == true } ?? players.first { $0.window?.isMainWindow == true }
        let items = menu.identifier?.rawValue == "chapters" ? player?.chapterItems() ?? [] : player?.audioTrackItems() ?? []
        if items.isEmpty { menu.addItem(withTitle: menu.identifier?.rawValue == "chapters" ? "No Chapters" : "No Audio Tracks", action: nil, keyEquivalent: "") }
        items.forEach(menu.addItem)
    }
}

/// Parsed `lightplayer://` link. Only http(s) videos are accepted: a web page must not be able to make the
/// player open local files.
struct WebLink {
    let video: URL
    let fullScreen: Bool
    let newWindow: Bool

    static func handles(_ u: URL) -> Bool {
        guard let s = u.scheme?.lowercased() else { return false }
        return s == "lightplayer"
    }

    init?(_ link: URL) {
        guard WebLink.handles(link), let c = URLComponents(url: link, resolvingAgainstBaseURL: false),
              ["open", "weblink", "play"].contains(c.host?.lowercased() ?? ""),
              let raw = c.queryItems?.first(where: { $0.name == "url" })?.value,
              let v = URL(string: raw), let scheme = v.scheme?.lowercased(), scheme == "http" || scheme == "https", v.host != nil
        else { return nil }
        func flag(_ n: String) -> Bool { ["1", "true", "yes"].contains(c.queryItems?.first(where: { $0.name == n })?.value?.lowercased() ?? "") }
        video = v
        fullScreen = flag("full_screen") || flag("fullscreen")
        newWindow = flag("new_window")
    }
}
