import AppKit
import AVFoundation
import Carbon.HIToolbox

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let reader = ReaderController()
    private let settings = Settings.shared

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        HotKeys.shared.register(HotKeyID.read.rawValue, keyCode: kVK_ANSI_R, modifiers: ctrlOpt) { [weak self] in
            self?.reader.toggleRead()
        }
        HotKeys.shared.register(HotKeyID.pause.rawValue, keyCode: kVK_ANSI_P, modifiers: ctrlOpt) { [weak self] in
            self?.reader.togglePause()
        }
        HotKeys.shared.register(HotKeyID.follow.rawValue, keyCode: kVK_ANSI_F, modifiers: ctrlOpt) { [weak self] in
            guard let self else { return }
            self.reader.setFollow(!self.reader.isFollowing)
        }

        reader.onStateChange = { [weak self] in self?.updateIcon() }
        if settings.followMouse { reader.setFollow(true) }
        updateIcon()

        if !CGPreflightScreenCaptureAccess() { CGRequestScreenCaptureAccess() }
    }

    private func updateIcon() {
        let symbol = reader.isSpeaking ? (reader.isPaused ? "pause.circle" : "waveform")
            : reader.isFollowing ? "cursorarrow.rays" : "text.viewfinder"
        statusItem.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Narrate")
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let read = item(reader.isSpeaking ? "Stop Reading" : "Read Under Pointer", #selector(toggleRead), key: "r")
        menu.addItem(read)
        if reader.isSpeaking {
            menu.addItem(item(reader.isPaused ? "Resume" : "Pause", #selector(togglePause), key: "p"))
        }
        menu.addItem(.separator())

        menu.addItem(item("Follow Mouse", #selector(toggleFollow), key: "f", on: reader.isFollowing))
        menu.addItem(item("Continue to Next Paragraph", #selector(toggleContinue), on: settings.continueReading))
        menu.addItem(item("Highlight Words on Screen", #selector(toggleHighlight), on: settings.showHighlight))
        menu.addItem(item("Show Subtitles", #selector(toggleSubtitles), on: settings.showSubtitles))
        menu.addItem(.separator())

        let speed = NSMenuItem(title: "Speed", action: nil, keyEquivalent: "")
        let speedMenu = NSMenu()
        for s in [0.8, 1.0, 1.25, 1.5, 1.75, 2.0] {
            let i = item(String(format: "%g×", s), #selector(setSpeed(_:)), on: abs(settings.speed - s) < 0.01)
            i.representedObject = s
            speedMenu.addItem(i)
        }
        speed.submenu = speedMenu
        menu.addItem(speed)

        let voice = NSMenuItem(title: "Voice", action: nil, keyEquivalent: "")
        let voiceMenu = NSMenu()
        voiceMenu.addItem(item("Auto (best voice for the text's language)", #selector(setVoice(_:)),
                               on: settings.voiceID == nil))
        voiceMenu.addItem(.separator())
        for v in Speaker.menuVoices() {
            let q = v.quality == .premium ? " · Premium" : v.quality == .enhanced ? " · Enhanced" : ""
            let i = item("\(v.name) — \(v.language)\(q)", #selector(setVoice(_:)), on: settings.voiceID == v.identifier)
            i.representedObject = v.identifier
            voiceMenu.addItem(i)
        }
        voiceMenu.addItem(.separator())
        voiceMenu.addItem(item("Get Better Voices…", #selector(openVoiceSettings)))
        voice.submenu = voiceMenu
        menu.addItem(voice)

        if !CGPreflightScreenCaptureAccess() {
            menu.addItem(.separator())
            menu.addItem(item("⚠︎ Allow Screen Recording…", #selector(openScreenRecordingSettings)))
        }

        menu.addItem(.separator())
        menu.addItem(item("Quit Narrate", #selector(quit), key: "q", plainKey: true))
    }

    private func item(_ title: String, _ action: Selector, key: String = "", on: Bool? = nil,
                      plainKey: Bool = false) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.target = self
        if !key.isEmpty { i.keyEquivalentModifierMask = plainKey ? [.command] : [.control, .option] }
        if let on { i.state = on ? .on : .off }
        return i
    }

    @objc private func toggleRead() { reader.toggleRead() }
    @objc private func togglePause() { reader.togglePause() }
    @objc private func toggleFollow() { reader.setFollow(!reader.isFollowing) }
    @objc private func toggleContinue() { settings.continueReading.toggle() }
    @objc private func toggleHighlight() { settings.showHighlight.toggle(); reader.refreshAppearance() }
    @objc private func toggleSubtitles() { settings.showSubtitles.toggle(); reader.refreshAppearance() }
    @objc private func setSpeed(_ sender: NSMenuItem) { settings.speed = sender.representedObject as? Double ?? 1 }
    @objc private func setVoice(_ sender: NSMenuItem) { settings.voiceID = sender.representedObject as? String }
    @objc private func quit() { NSApp.terminate(nil) }

    @objc private func openVoiceSettings() {
        open("x-apple.systempreferences:com.apple.preference.universalaccess?SpokenContent")
    }

    @objc private func openScreenRecordingSettings() {
        CGRequestScreenCaptureAccess()
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
    }

    private func open(_ s: String) {
        if let url = URL(string: s) { NSWorkspace.shared.open(url) }
    }
}
