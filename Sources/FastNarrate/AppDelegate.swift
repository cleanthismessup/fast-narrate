import AppKit
import AVFoundation
import Carbon.HIToolbox
import UniformTypeIdentifiers

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

        HotKeys.shared.register(HotKeyID.feedback.rawValue, keyCode: kVK_ANSI_S, modifiers: ctrlOpt) { [weak self] in
            self?.sendFeedback()
        }

        reader.onStateChange = { [weak self] in self?.updateIcon() }
        reader.warmUp()
        if settings.followMouse { reader.setFollow(true) }
        updateIcon()

        reader.onPermissionNeeded = { [weak self] in self?.showPermissionSetup() }
        if !ScreenPermission.isGranted {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.showPermissionSetup() }
        }
        if ElevenLabsSpeaker.isConfigured, settings.elevenVoices.isEmpty { refreshNaturalVoices() }
    }

    private func updateIcon() {
        let symbol = reader.isSpeaking ? (reader.isPaused ? "pause.circle" : "waveform")
            : reader.isFollowing ? "cursorarrow.rays" : "text.viewfinder"
        statusItem.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Fast Narrate")
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
        let appearance = NSMenuItem(title: "Appearance", action: nil, keyEquivalent: "")
        appearance.submenu = appearanceMenu()
        menu.addItem(appearance)
        menu.addItem(.separator())

        let silentMode = settings.engine == .silent
        let speed = NSMenuItem(title: silentMode ? "Pace" : "Speed", action: nil, keyEquivalent: "")
        let speedMenu = NSMenu()
        for s in [0.8, 1.0, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0] {
            let wpm = silentMode ? String(format: "  (%d wpm)", Int(SilentPacer.baseWPM * s)) : ""
            let i = item(String(format: "%g×", s) + wpm, #selector(setSpeed(_:)), on: abs(settings.speed - s) < 0.01)
            i.representedObject = s
            speedMenu.addItem(i)
        }
        speed.submenu = speedMenu
        menu.addItem(speed)

        let voice = NSMenuItem(title: "Voice", action: nil, keyEquivalent: "")
        voice.submenu = voiceMenu()
        menu.addItem(voice)

        if !ScreenPermission.isGranted {
            menu.addItem(.separator())
            menu.addItem(item("⚠︎ Allow Screen Recording…", #selector(openScreenRecordingSettings)))
        }

        menu.addItem(.separator())
        menu.addItem(item("Send UI Feedback…", #selector(sendFeedback), key: "s"))
        menu.addItem(item("Open Feedback Folder", #selector(openFeedbackFolder)))
        menu.addItem(.separator())
        menu.addItem(item("Quit Fast Narrate", #selector(quit), key: "q", plainKey: true))
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
    @objc private func setVoice(_ sender: NSMenuItem) {
        settings.engine = .apple
        settings.voiceID = sender.representedObject as? String
        reader.preview("This is how the offline voice sounds.")
    }

    @objc private func setNaturalVoice(_ sender: NSMenuItem) {
        settings.engine = .natural
        settings.elevenVoiceID = sender.representedObject as? String
        reader.preview("Hi! This is how I sound when I read for you.")
    }

    @objc private func setNaturalModel(_ sender: NSMenuItem) {
        settings.elevenModel = sender.representedObject as? String ?? settings.elevenModel
    }

    @objc private func removeNaturalKey() {
        ElevenLabsSpeaker.apiKey = nil
        settings.engine = .apple
        settings.elevenVoices = []
    }

    @objc private func setUpNaturalVoices() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Natural voices (ElevenLabs)"
        alert.informativeText = """
        Paste your ElevenLabs API key. It's stored in your macOS Keychain.

        With natural voices on, the text Fast Narrate reads is sent to ElevenLabs to generate speech \
        and uses your ElevenLabs character credits. The offline voice is used as a fallback.
        """
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 340, height: 24))
        field.placeholderString = "ElevenLabs API key"
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Get a Key…")
        alert.window.initialFirstResponder = field
        let response = alert.runModal()
        if response == .alertThirdButtonReturn {
            open("https://elevenlabs.io/app/settings/api-keys")
            return
        }
        let key = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard response == .alertFirstButtonReturn, !key.isEmpty else { return }
        ElevenLabsSpeaker.apiKey = key
        settings.engine = .natural
        refreshNaturalVoices(previewWhenDone: true)
    }

    private func refreshNaturalVoices(previewWhenDone: Bool = false) {
        guard let key = ElevenLabsSpeaker.apiKey else { return }
        Task {
            var voices: [ElevenLabsVoice]
            do {
                voices = try await ElevenLabsAPI.voices(apiKey: key)
            } catch ElevenLabsError.http(401, let msg) where !msg.lowercased().contains("permission") {
                showError("ElevenLabs rejected that API key.", msg)
                return
            } catch {
                // Keys scoped to text-to-speech only can't list voices; use the stock ones.
                voices = []
            }
            if voices.isEmpty { voices = ElevenLabsAPI.fallbackVoices }
            settings.elevenVoices = voices
            if settings.elevenVoiceID == nil || !voices.contains(where: { $0.id == settings.elevenVoiceID }) {
                settings.elevenVoiceID = voices.first(where: { $0.id == ElevenLabsAPI.fallbackVoices[0].id })?.id
                    ?? voices.first?.id
            }
            if previewWhenDone { reader.preview("Natural voice is ready. Point at any text and press Control Option R.") }
        }
    }

    private func showError(_ title: String, _ detail: String) {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = title
        a.informativeText = detail
        a.runModal()
    }

    private func appearanceMenu() -> NSMenu {
        let m = NSMenu()
        m.addItem(item("Highlight Words on Screen", #selector(toggleHighlight), on: settings.showHighlight))
        m.addItem(item("Paragraph Outline", #selector(toggleOutline), on: settings.showParagraphOutline))
        m.addItem(item("Show Subtitles", #selector(toggleSubtitles), on: settings.showSubtitles))

        m.addItem(.sectionHeader(title: "Highlight Style"))
        for s in Settings.HighlightStyle.allCases {
            let i = item(s.label, #selector(setHighlightStyle(_:)), on: settings.highlightStyle == s)
            i.representedObject = s.rawValue
            m.addItem(i)
        }
        m.addItem(.sectionHeader(title: "Color"))
        for c in Settings.HighlightColor.allCases {
            let i = item(c.label, #selector(setHighlightColor(_:)), on: settings.highlightColor == c)
            i.representedObject = c.rawValue
            i.image = swatch(c.color)
            m.addItem(i)
        }
        m.addItem(.sectionHeader(title: "Subtitles"))
        for s in Settings.SubtitleSize.allCases {
            let i = item(s.label, #selector(setSubtitleSize(_:)), on: settings.subtitleSize == s)
            i.representedObject = s.rawValue
            m.addItem(i)
        }
        for p in Settings.SubtitlePosition.allCases {
            let i = item("At \(p.label)", #selector(setSubtitlePosition(_:)), on: settings.subtitlePosition == p)
            i.representedObject = p.rawValue
            m.addItem(i)
        }
        return m
    }

    private func swatch(_ color: NSColor) -> NSImage {
        NSImage(size: NSSize(width: 12, height: 12), flipped: false) { r in
            color.setFill()
            NSBezierPath(ovalIn: r.insetBy(dx: 1, dy: 1)).fill()
            return true
        }
    }

    @objc private func toggleOutline() { settings.showParagraphOutline.toggle(); reader.refreshAppearance() }
    @objc private func setHighlightStyle(_ s: NSMenuItem) {
        settings.highlightStyle = Settings.HighlightStyle(rawValue: s.representedObject as? String ?? "") ?? .marker
        reader.refreshAppearance()
    }
    @objc private func setHighlightColor(_ s: NSMenuItem) {
        settings.highlightColor = Settings.HighlightColor(rawValue: s.representedObject as? String ?? "") ?? .yellow
        reader.refreshAppearance()
    }
    @objc private func setSubtitleSize(_ s: NSMenuItem) {
        settings.subtitleSize = Settings.SubtitleSize(rawValue: s.representedObject as? String ?? "") ?? .medium
        reader.refreshAppearance()
    }
    @objc private func setSubtitlePosition(_ s: NSMenuItem) {
        settings.subtitlePosition = Settings.SubtitlePosition(rawValue: s.representedObject as? String ?? "") ?? .bottom
        reader.refreshAppearance()
    }
    @objc private func setSilent() {
        settings.engine = .silent
        reader.preview("Silent mode: words light up at your reading pace, with no sound at all.")
    }

    // MARK: UI feedback snapshots

    private var sendingFeedback = false

    /// Freezes reading, screenshots the screen *with* the overlay and captions, asks for a note,
    /// and saves screenshot + zoomed crop + report.md into the feedback folder.
    @objc private func sendFeedback() {
        guard !sendingFeedback else { return }
        sendingFeedback = true
        let paused = reader.pauseForSnapshot()
        let focus = reader.focusRect
        let state = reader.stateReport()
        Task {
            defer { sendingFeedback = false }
            var shot: (image: CGImage, screen: NSScreen)?
            var captureError: String?
            do { shot = try await reader.captureForFeedback() } catch { captureError = error.localizedDescription }

            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "Send UI feedback"
            alert.informativeText = shot == nil
                ? "Couldn't take a screenshot (\(captureError ?? "unknown")). Your note will still be saved."
                : "The screenshot (with the highlight and subtitles) is taken. What looks wrong or could be better?"
            let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 420, height: 120))
            let text = NSTextView(frame: scroll.bounds)
            text.font = .systemFont(ofSize: 13)
            text.isRichText = false
            text.autoresizingMask = [.width]
            scroll.documentView = text
            scroll.hasVerticalScroller = true
            scroll.borderType = .bezelBorder
            alert.accessoryView = scroll
            alert.window.initialFirstResponder = text
            alert.addButton(withTitle: "Save")
            alert.addButton(withTitle: "Cancel")
            let saved = alert.runModal() == .alertFirstButtonReturn
            if saved {
                do {
                    let folder = try saveFeedback(note: text.string, state: state, shot: shot, focus: focus)
                    Log.info("feedback saved: \(folder.path)")
                } catch {
                    showError("Couldn't save feedback", error.localizedDescription)
                }
            }
            if paused { reader.togglePause() }
        }
    }

    private func saveFeedback(note: String, state: String, shot: (image: CGImage, screen: NSScreen)?,
                              focus: CGRect?) throws -> URL {
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let name = stamp.string(from: Date())
        let dir = settings.feedbackFolder.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        var images: [String] = []
        if let shot {
            try writePNG(shot.image, to: dir.appendingPathComponent("screen.png"))
            images.append("screen.png")
            if let focus, let crop = crop(shot.image, to: focus.insetBy(dx: -120, dy: -90), on: shot.screen) {
                try writePNG(crop, to: dir.appendingPathComponent("zoom.png"))
                images.append("zoom.png")
            }
        }

        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        let s = settings
        var md = "# UI feedback \(name)\n\n"
        md += "## Note\n\n\(note.isEmpty ? "_(no note)_" : note)\n\n"
        md += "## Screenshots\n\n" + (images.isEmpty ? "_(none)_\n" : images.map { "![\($0)](\($0))\n" }.joined()) + "\n"
        md += "## Settings\n\n"
        md += "- Version: \(version), macOS \(ProcessInfo.processInfo.operatingSystemVersionString)\n"
        md += "- Voice: \(s.engine.rawValue), speed \(s.speed)×\n"
        md += "- Highlight: \(s.showHighlight ? s.highlightStyle.rawValue : "off"), color \(s.highlightColor.rawValue), paragraph outline \(s.showParagraphOutline)\n"
        md += "- Subtitles: \(s.showSubtitles ? "\(s.subtitleSize.rawValue), \(s.subtitlePosition.rawValue)" : "off")\n"
        if let scr = shot?.screen {
            md += "- Screen: \(Int(scr.frame.width))×\(Int(scr.frame.height)) pt @\(Int(scr.backingScaleFactor))x\n"
        }
        md += "\n## Reading state\n\n\(state)"
        try md.write(to: dir.appendingPathComponent("report.md"), atomically: true, encoding: .utf8)
        return dir
    }

    /// Crops a global-coordinate rect (Cocoa, bottom-left origin) out of a screenshot of `screen`.
    private func crop(_ image: CGImage, to rect: CGRect, on screen: NSScreen) -> CGImage? {
        let f = screen.frame
        let scale = CGFloat(image.width) / f.width
        let r = rect.intersection(f)
        guard !r.isNull else { return nil }
        let px = CGRect(x: (r.minX - f.minX) * scale, y: (f.maxY - r.maxY) * scale,
                        width: r.width * scale, height: r.height * scale)
        return image.cropping(to: px.integral)
    }

    private func writePNG(_ image: CGImage, to url: URL) throws {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { throw CocoaError(.fileWriteUnknown) }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw CocoaError(.fileWriteUnknown) }
    }

    @objc private func openFeedbackFolder() {
        try? FileManager.default.createDirectory(at: settings.feedbackFolder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(settings.feedbackFolder)
    }

    private func voiceMenu() -> NSMenu {
        let m = NSMenu()
        m.addItem(.sectionHeader(title: "Silent"))
        m.addItem(item("Highlight Only — No Sound", #selector(setSilent), on: settings.engine == .silent))
        m.addItem(.separator())
        m.addItem(.sectionHeader(title: "Natural — ElevenLabs"))
        if ElevenLabsSpeaker.isConfigured {
            let voices = settings.elevenVoices.isEmpty ? ElevenLabsAPI.fallbackVoices : settings.elevenVoices
            for v in voices {
                let on = settings.engine == .natural && settings.elevenVoiceID == v.id
                let i = item(v.name, #selector(setNaturalVoice(_:)), on: on)
                i.representedObject = v.id
                m.addItem(i)
            }
            let quality = NSMenuItem(title: "Quality", action: nil, keyEquivalent: "")
            let qm = NSMenu()
            for model in ElevenLabsAPI.models {
                let i = item(model.label, #selector(setNaturalModel(_:)), on: settings.elevenModel == model.id)
                i.representedObject = model.id
                qm.addItem(i)
            }
            quality.submenu = qm
            m.addItem(quality)
            m.addItem(item("Change API Key…", #selector(setUpNaturalVoices)))
            m.addItem(item("Remove API Key", #selector(removeNaturalKey)))
        } else {
            m.addItem(item("Set Up Natural Voices…", #selector(setUpNaturalVoices)))
        }

        m.addItem(.separator())
        m.addItem(.sectionHeader(title: "Offline — Apple"))
        m.addItem(item("Auto (best for the text's language)", #selector(setVoice(_:)),
                       on: settings.engine == .apple && settings.voiceID == nil))
        for v in AppleSpeaker.menuVoices() {
            let q = v.quality == .premium ? " · Premium" : v.quality == .enhanced ? " · Enhanced" : ""
            let on = settings.engine == .apple && settings.voiceID == v.identifier
            let i = item("\(v.name) — \(v.language)\(q)", #selector(setVoice(_:)), on: on)
            i.representedObject = v.identifier
            m.addItem(i)
        }
        m.addItem(item("Download Better Offline Voices…", #selector(openVoiceSettings)))
        return m
    }
    @objc private func quit() { NSApp.terminate(nil) }

    @objc private func openVoiceSettings() {
        open("x-apple.systempreferences:com.apple.preference.universalaccess?SpokenContent")
    }

    @objc private func openScreenRecordingSettings() { showPermissionSetup() }

    private var showingPermissionSetup = false

    /// One clear dialog instead of a stream of system prompts.
    private func showPermissionSetup() {
        guard !showingPermissionSetup, !ScreenPermission.isGranted else { return }
        showingPermissionSetup = true
        defer { showingPermissionSetup = false }
        ScreenPermission.requestOnce()
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Allow Fast Narrate to see your screen"
        alert.informativeText = """
        Fast Narrate reads the text on your screen, on this Mac, so it can speak it and highlight each word.

        1. Click "Open Settings".
        2. Turn on Fast Narrate under Screen & System Audio Recording. If Fast Narrate is already listed but \
        on, remove it with − and add it again; an older build is still listed.
        3. Come back and click "Relaunch Fast Narrate".
        """
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Relaunch Fast Narrate")
        alert.addButton(withTitle: "Later")
        while true {
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                open("x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
                continue
            case .alertSecondButtonReturn:
                relaunch()
                return
            default:
                return
            }
        }
    }

    private func relaunch() {
        let path = Bundle.main.bundlePath
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 0.7; /usr/bin/open \"$0\"", path]
        try? p.run()
        NSApp.terminate(nil)
    }

    private func open(_ s: String) {
        if let url = URL(string: s) { NSWorkspace.shared.open(url) }
    }
}
