import AppKit

/// ⌃⌥F: saves a screenshot (with the overlay visible), a zoomed crop and a note,
/// so UI problems can be reported by just saying "check feedback".
final class FeedbackReporter {
    static var folder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FastNarrate/feedback", isDirectory: true)
    }

    private var busy = false

    func report(reader: ReaderController) {
        guard !busy else { return }
        busy = true
        reader.pauseIfReading()

        let front = NSWorkspace.shared.frontmostApplication
        let word = reader.currentWord
        let pointer = NSEvent.mouseLocation
        let focus = word?.rect.map { CGPoint(x: $0.midX, y: $0.midY) } ?? pointer
        let screen = Coords.screen(containing: focus).map(ScreenInfo.init)

        Task { @MainActor in
            var image: CGImage?
            if Permissions.shared.sr, let screen {
                reader.overlay.setCapturable(true)
                try? await Task.sleep(nanoseconds: 120_000_000)
                image = try? await ScreenCapture.image(of: screen.frame, screen: screen, excludeSelf: false)
                reader.overlay.setCapturable(false)
            }

            let note = askNote(hasScreenshot: image != nil)
            defer { busy = false }
            guard let note else { return }

            let stamp = ISO8601DateFormatter.string(from: Date(), timeZone: .current,
                                                    formatOptions: [.withFullDate, .withTime, .withColonSeparatorInTime])
                .replacingOccurrences(of: ":", with: "-")
            let dir = Self.folder.appendingPathComponent(stamp, isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                if let image, let screen {
                    try png(image).write(to: dir.appendingPathComponent("screen.png"))
                    if let crop = crop(image, screen: screen, around: focus) {
                        try png(crop).write(to: dir.appendingPathComponent("crop.png"))
                    }
                }
                let md = reportText(note: note, reader: reader, word: word, pointer: pointer,
                                    front: front, screenshot: image != nil)
                try md.write(to: dir.appendingPathComponent("report.md"), atomically: true, encoding: .utf8)
                let latest = Self.folder.appendingPathComponent("latest")
                try? FileManager.default.removeItem(at: latest)
                try? FileManager.default.createSymbolicLink(at: latest, withDestinationURL: dir)
                reader.hud.show("Feedback saved. Tell Claude “check feedback”.")
            } catch {
                reader.hud.show("Couldn't save feedback: \(error.localizedDescription)")
            }
        }
    }

    private func askNote(hasScreenshot: Bool) -> String? {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Report a UI problem"
        alert.informativeText = hasScreenshot
            ? "What looks wrong? A screenshot with the highlight was captured."
            : "What looks wrong? (No screenshot: Screen Recording isn't allowed.)"
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 380, height: 96))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        let tv = NSTextView(frame: scroll.bounds)
        tv.font = .systemFont(ofSize: 13)
        tv.isRichText = false
        tv.autoresizingMask = [.width]
        scroll.documentView = tv
        alert.accessoryView = scroll
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = tv
        let ok = alert.runModal() == .alertFirstButtonReturn
        return ok ? tv.string : nil
    }

    private func png(_ img: CGImage) throws -> Data {
        guard let d = NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return d
    }

    private func crop(_ img: CGImage, screen: ScreenInfo, around p: CGPoint) -> CGImage? {
        let w: CGFloat = 520, h: CGFloat = 260
        let f = screen.frame
        let x = min(max(p.x - w / 2, f.minX), f.maxX - w)
        let y = min(max(p.y - h / 2, f.minY), f.maxY - h)
        let px = CGRect(x: (x - f.minX) * screen.scale, y: (f.maxY - (y + h)) * screen.scale,
                        width: w * screen.scale, height: h * screen.scale)
        return img.cropping(to: px.integral)
    }

    private func reportText(note: String, reader: ReaderController, word: ReadWord?, pointer: CGPoint,
                            front: NSRunningApplication?, screenshot: Bool) -> String {
        let s = Settings.shared
        let perms = Permissions.shared
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        let screens = NSScreen.screens.map { "\(Int($0.frame.width))×\(Int($0.frame.height)) @\(Int($0.backingScaleFactor))x at \(Int($0.frame.minX)),\(Int($0.frame.minY))" }
        func r(_ rect: CGRect?) -> String {
            guard let rect else { return "none" }
            return "x \(Int(rect.minX)) y \(Int(rect.minY)) w \(Int(rect.width)) h \(Int(rect.height))"
        }
        return """
        # Fast Narrate feedback

        **Note:** \(note.isEmpty ? "(none)" : note)

        | | |
        |---|---|
        | Date | \(Date()) |
        | Version | \(version) |
        | Front app | \(front?.localizedName ?? "?") (\(front?.bundleIdentifier ?? "?")) |
        | State | \(reader.state) |
        | Source | \(reader.sourceName) |
        | Last latency | \(reader.lastLatency) |
        | Current word | \(word.map { "“\($0.text)” (\(reader.index + 1)/\(reader.words.count))" } ?? "none") |
        | Word rect | \(r(word?.rect)) |
        | Pointer | \(Int(pointer.x)), \(Int(pointer.y)) |
        | Mode | silent |
        | Speed | \(ReaderController.speedLabel(s.speed)) |
        | Style | \(s.style.title) |
        | Highlight / follow | \(s.showHighlight) / \(s.followMouse) |
        | Accessibility / Screen Recording | \(perms.ax) / \(perms.sr) |
        | Screens | \(screens.joined(separator: "; ")) |
        | Screenshot | \(screenshot ? "screen.png, crop.png" : "not captured") |

        Coordinates are macOS screen points, origin bottom-left of the main display.
        """
    }
}
