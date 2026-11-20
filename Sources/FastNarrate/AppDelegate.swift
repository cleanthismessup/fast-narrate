import AppKit
import Carbon

/// Menu item that runs a closure.
final class ActionItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, key: String = "", mods: NSEvent.ModifierFlags = [.control, .option],
         checked: Bool = false, enabled: Bool = true, _ handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: key)
        target = self
        keyEquivalentModifierMask = key.isEmpty ? [] : mods
        state = checked ? .on : .off
        isEnabled = enabled
    }

    required init(coder: NSCoder) { fatalError("not used") }

    @objc private func fire() { handler() }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let reader = ReaderController()
    let follow = FollowMouse()
    let feedback = FeedbackReporter()
    private var statusItem: NSStatusItem!
    private var iconTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        AX.setGlobalTimeout(0.3)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu

        reader.onStateChange = { [weak self] in
            self?.updateIcon()
            self?.updateReadingHotkeys()
        }
        follow.reader = reader
        registerHotkeys()
        updateIcon()

        // Right-click → Services → "Read with Fast Narrate" (see NSServices in Info.plist).
        NSApp.servicesProvider = self
        NSUpdateDynamicServices()

        OCREngine.warmUp(screens: NSScreen.screens.map(ScreenInfo.init))
        iconTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.updateIcon() }
        if Settings.shared.followMouse { follow.start() }

        let p = Permissions.shared
        if !p.ax && !p.sr {
            reader.hud.show("Fast Narrate is in the menu bar. Point at text and press ⌃⌥R.", seconds: 5)
        }
        Trace.log("launched v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] ?? "dev") ax=\(p.ax) sr=\(p.sr) screens=\(NSScreen.screens.map { $0.frame })")
    }

    // MARK: Services

    @objc func readSelection(_ pboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        guard let text = pboard.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            reader.hud.show("No text selected")
            return
        }
        reader.stop()
        reader.readSelection(text)
    }

    // MARK: Hotkeys

    private func registerHotkeys() {
        let hk = HotKeys.shared, m = HotKeys.ctrlOpt
        hk.register(.read, keyCode: kVK_ANSI_R, mods: m) { [weak self] in self?.reader.readAtPointer() }
        hk.register(.pause, keyCode: kVK_ANSI_P, mods: m) { [weak self] in self?.reader.togglePause() }
        hk.register(.stop, keyCode: kVK_ANSI_S, mods: m) { [weak self] in self?.reader.stop() }
        hk.register(.feedback, keyCode: kVK_ANSI_F, mods: m) { [weak self] in self?.reportFeedback() }
        hk.register(.follow, keyCode: kVK_ANSI_M, mods: m) { [weak self] in self?.toggleFollow() }
    }

    /// Esc and ⌃⌥↑/↓ are only grabbed while reading, so they don't steal keys from other apps.
    private func updateReadingHotkeys() {
        let hk = HotKeys.shared
        let active = reader.state == .reading || reader.state == .paused
        if active && !hk.isRegistered(.escape) {
            hk.register(.escape, keyCode: kVK_Escape, mods: 0) { [weak self] in self?.reader.stop() }
            hk.register(.faster, keyCode: kVK_UpArrow, mods: HotKeys.ctrlOpt) { [weak self] in self?.reader.changeSpeed(by: 1) }
            hk.register(.slower, keyCode: kVK_DownArrow, mods: HotKeys.ctrlOpt) { [weak self] in self?.reader.changeSpeed(by: -1) }
        } else if !active && hk.isRegistered(.escape) {
            hk.unregister(.escape)
            hk.unregister(.faster)
            hk.unregister(.slower)
        }
    }

    // MARK: Actions

    private func toggleFollow() {
        Settings.shared.followMouse.toggle()
        if Settings.shared.followMouse {
            follow.start()
            reader.hud.show("Follow mouse on: rest the pointer on text to read it", seconds: 2)
        } else {
            follow.stop()
            reader.hud.show("Follow mouse off", seconds: 1.5)
        }
    }

    private func reportFeedback() {
        feedback.report(reader: reader)
    }

    private func restart() {
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: cfg) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }

    // MARK: Menu bar

    private func updateIcon() {
        let p = Permissions.shared
        let name: String
        switch reader.state {
        case .reading: name = "waveform"
        case .paused: name = "pause.circle"
        case .locating: name = "text.viewfinder"
        case .idle: name = (!p.ax && !p.sr) ? "exclamationmark.triangle" : "text.viewfinder"
        }
        let img = NSImage(systemSymbolName: name, accessibilityDescription: "Fast Narrate")
        img?.isTemplate = true
        statusItem.button?.image = img
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let s = Settings.shared
        let p = Permissions.shared
        let active = reader.state == .reading || reader.state == .paused

        menu.addItem(ActionItem("Read from Pointer", key: "r") { [weak self] in
            // Give the menu time to close so the pointer is back over the text.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { self?.reader.readAtPointer() }
        })
        menu.addItem(ActionItem(reader.state == .paused ? "Resume" : "Pause", key: "p", enabled: active) { [weak self] in
            self?.reader.togglePause()
        })
        menu.addItem(ActionItem("Stop", key: "s", enabled: active) { [weak self] in self?.reader.stop() })
        menu.addItem(.separator())

        let speed = NSMenuItem(title: "Speed: \(ReaderController.speedLabel(s.speed))", action: nil, keyEquivalent: "")
        let speedMenu = NSMenu()
        for v in Settings.speeds {
            speedMenu.addItem(ActionItem("\(ReaderController.speedLabel(v))  (~\(Int(250 * v)) wpm)",
                                         checked: abs(v - s.speed) < 0.01) { Settings.shared.speed = v })
        }
        speedMenu.addItem(.separator())
        let hint = NSMenuItem(title: "⌃⌥↑ / ⌃⌥↓ while reading", action: nil, keyEquivalent: "")
        hint.isEnabled = false
        speedMenu.addItem(hint)
        speed.submenu = speedMenu
        menu.addItem(speed)

        let style = NSMenuItem(title: "Highlight Style: \(s.style.title)", action: nil, keyEquivalent: "")
        let styleMenu = NSMenu()
        for st in HighlightStyle.allCases {
            styleMenu.addItem(ActionItem(st.title, checked: st == s.style) { [weak self] in
                Settings.shared.style = st
                self?.reader.refreshAppearance()
            })
        }
        style.submenu = styleMenu
        menu.addItem(style)

        menu.addItem(ActionItem("Highlight on Text", checked: s.showHighlight) { [weak self] in
            Settings.shared.showHighlight.toggle()
            self?.reader.refreshAppearance()
        })
        menu.addItem(ActionItem("Follow Mouse", key: "m", checked: s.followMouse) { [weak self] in self?.toggleFollow() })
        menu.addItem(.separator())

        // Permissions: always a way forward, never a loop.
        if p.ax {
            menu.addItem(ActionItem("Accessibility: allowed ✓", enabled: false) {})
        } else {
            menu.addItem(ActionItem(p.askedAX ? "Open Accessibility Settings…" : "Grant Accessibility…") {
                let perms = Permissions.shared
                if perms.askedAX { perms.openAXSettings() } else { perms.requestAXOnce() }
            })
        }
        if p.sr {
            menu.addItem(ActionItem("Screen Recording: allowed ✓", enabled: false) {})
        } else {
            menu.addItem(ActionItem(p.askedSR ? "Open Screen Recording Settings…" : "Grant Screen Recording (for images & PDFs)…") {
                let perms = Permissions.shared
                if perms.askedSR { perms.openSRSettings() } else { perms.requestSROnce() }
            })
            if p.askedSR {
                menu.addItem(ActionItem("Restart Fast Narrate (after allowing)") { [weak self] in self?.restart() })
            }
        }
        menu.addItem(.separator())

        menu.addItem(ActionItem("Report UI Problem…", key: "f") { [weak self] in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { self?.reportFeedback() }
        })
        menu.addItem(ActionItem("Open Feedback Folder") {
            let f = FeedbackReporter.folder
            try? FileManager.default.createDirectory(at: f, withIntermediateDirectories: true)
            NSWorkspace.shared.open(f)
        })
        if reader.lastLatency != "–" {
            menu.addItem(ActionItem("Last start: \(reader.lastLatency)", enabled: false) {})
        }
        menu.addItem(.separator())
        menu.addItem(ActionItem("Quit Fast Narrate", key: "q", mods: [.command]) { NSApp.terminate(nil) })
    }
}
