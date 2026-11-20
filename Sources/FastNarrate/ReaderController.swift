import AppKit
import FastNarrateCore

/// Runs a reading session: finds text at the pointer, steps through words in time with the
/// display refresh, and drives the word highlight.
final class ReaderController: NSObject {
    enum State { case idle, locating, reading, paused }

    private(set) var state: State = .idle { didSet { if oldValue != state { onStateChange?() } } }
    var onStateChange: (() -> Void)?

    let overlay = OverlayManager()
    let hud = HUD()
    private let locator = TextLocator()
    private let providerQueue = DispatchQueue(label: "fastnarrate.provider", qos: .userInitiated)

    private(set) var words: [ReadWord] = []
    private(set) var index = 0
    private(set) var sourceName = "–"
    private(set) var lastLatency = "–"
    private var provider: WordProvider?
    private var providerDone = false
    private var loadingMore = false
    private var elapsed = 0.0
    private var lastFrame: CFTimeInterval?
    private var link: CADisplayLink?
    private var locateID = 0
    private var readID = 0
    private var t0: CFTimeInterval = 0

    // Scrolling
    private var rectGen = 0
    private var scrollingUntil: CFTimeInterval = 0
    private var hiddenForScroll = false
    private var scrollMonitor: Any?
    private var scrollIdleWork: DispatchWorkItem?
    private var lastKnownRect: CGRect?
    private var lastOCRAt: CFTimeInterval = 0

    var currentWord: ReadWord? { words.indices.contains(index) ? words[index] : nil }

    // MARK: Commands

    /// `follow`: triggered by follow-mouse (quiet: no prompts, no "no text" messages, OCR throttled).
    func readAtPointer(follow: Bool = false, at point: CGPoint? = nil) {
        let p = point ?? NSEvent.mouseLocation
        t0 = CACurrentMediaTime()
        let perms = Permissions.shared
        let allowOCR = !follow || (perms.sr && t0 - lastOCRAt > 1.5)
        if allowOCR && !perms.ax { lastOCRAt = t0 }
        if !follow && state == .idle { state = .locating }
        if !follow && perms.sr && !OCREngine.isWarm && !perms.ax {
            hud.show("Preparing text recognition (first run only)…")
        }

        locateID += 1
        let lid = locateID
        if !follow { Trace.log("read at \(Int(p.x)),\(Int(p.y)) ax=\(perms.ax) sr=\(perms.sr) allowOCR=\(allowOCR)") }
        locator.locate(at: p, allowOCR: allowOCR) { [weak self] outcome in
            guard let self, lid == self.locateID else { return }
            self.handle(outcome, follow: follow, noTextMessage: "No text found under the pointer")
        }
    }

    /// Reads text the user selected (from the right-click Services menu), highlighting it in place.
    func readSelection(_ text: String) {
        let p = NSEvent.mouseLocation
        t0 = CACurrentMediaTime()
        if state == .idle { state = .locating }
        locateID += 1
        let lid = locateID
        Trace.log("read selection (\(text.count) chars) ax=\(Permissions.shared.ax) sr=\(Permissions.shared.sr)")
        locator.locateSelection(text, near: p) { [weak self] outcome in
            guard let self, lid == self.locateID else { return }
            self.handle(outcome, follow: false, noTextMessage: "Couldn't find the selected text on screen")
        }
    }

    private func handle(_ outcome: LocateOutcome, follow: Bool, noTextMessage: String) {
        let perms = Permissions.shared
        if !follow || { if case .found = outcome { return true }; return false }() {
            Trace.log("locate → \(outcome.summary) in \(Int((CACurrentMediaTime() - t0) * 1000)) ms")
        }
        if state == .locating { state = .idle }
        switch outcome {
        case .found(let prov, let ws):
            if prov is OCRProvider { lastOCRAt = CACurrentMediaTime() }
            begin(prov, ws)
        case .needsAccessibility:
            guard !follow else { return }
            let asked = perms.askedAX
            perms.requestAXOnce()
            hud.show(asked
                ? "Fast Narrate needs Accessibility permission. Open the menu bar icon → Grant Accessibility."
                : "Allow Fast Narrate in System Settings → Accessibility, then press ⌃⌥R again.", seconds: 5)
        case .needsScreenRecording:
            guard !follow else { return }
            let asked = perms.askedSR
            perms.requestSROnce()
            hud.show(asked
                ? "This text isn't readable directly. Screen Recording (menu bar icon) lets Fast Narrate read images and PDFs."
                : "To read images and PDFs, allow Screen Recording in System Settings, then restart Fast Narrate from its menu.", seconds: 5)
        case .noText:
            if !follow { hud.show(noTextMessage) }
        }
    }

    func togglePause() {
        switch state {
        case .reading: state = .paused
        case .paused: lastFrame = nil; state = .reading
        default: break
        }
    }

    func pauseIfReading() { if state == .reading { state = .paused } }

    func stop() {
        locateID += 1
        readID += 1
        link?.invalidate()
        link = nil
        lastFrame = nil
        if let m = scrollMonitor { NSEvent.removeMonitor(m); scrollMonitor = nil }
        scrollIdleWork?.cancel()
        overlay.hide()
        words = []
        index = 0
        provider = nil
        state = .idle
    }

    func changeSpeed(by delta: Int) {
        let speeds = Settings.speeds
        let cur = speeds.enumerated().min { abs($0.element - Settings.shared.speed) < abs($1.element - Settings.shared.speed) }?.offset ?? 2
        let next = speeds[max(0, min(speeds.count - 1, cur + delta))]
        Settings.shared.speed = next
        hud.show("Speed \(Self.speedLabel(next)) · ~\(Int(SilentTiming.baseWPM * next)) wpm", seconds: 1.2)
    }

    static func speedLabel(_ s: Double) -> String {
        s == s.rounded() ? "\(Int(s))×" : "\(s)×"
    }

    /// Re-applies style / visibility settings to what's on screen.
    func refreshAppearance() {
        guard state == .reading || state == .paused else { return }
        showCurrent(animated: false)
    }

    // MARK: Session

    private func begin(_ prov: WordProvider, _ ws: [ReadWord]) {
        readID += 1
        provider = prov
        providerDone = prov.isExhausted
        loadingMore = false
        sourceName = prov.sourceName
        rectGen = 0
        words = ws.map { var w = $0; w.rectGen = 0; return w }
        index = 0
        elapsed = 0
        hiddenForScroll = false
        overlay.hide()
        state = .reading
        startLink()
        installScrollMonitor()
        showCurrent(animated: false)

        let ms = (CACurrentMediaTime() - t0) * 1000
        lastLatency = String(format: "%.0f ms via %@", ms, sourceName)
        perfLog.info("first highlight \(Int(ms)) ms source=\(self.sourceName, privacy: .public) words=\(ws.count)")
        maybeLoadMore()
    }

    private func startLink() {
        guard link == nil else { return }
        let l = (NSScreen.main ?? NSScreen.screens[0]).displayLink(target: self, selector: #selector(tick(_:)))
        l.add(to: .main, forMode: .common)
        link = l
        lastFrame = nil
    }

    @objc private func tick(_ l: CADisplayLink) {
        let now = l.timestamp
        defer { lastFrame = now }
        guard let last = lastFrame else { return }
        let dt = min(now - last, 0.1)
        defer { overlay.step(dt) }

        if state == .reading, words.indices.contains(index) {
            elapsed += dt
            var changed = false
            while true {
                let dur = SilentTiming.duration(of: words[index].text, speed: Settings.shared.speed)
                guard elapsed >= dur else { break }
                if index + 1 < words.count {
                    elapsed -= dur
                    index += 1
                    changed = true
                } else if !providerDone {
                    elapsed = dur          // hold on the last word until more arrive
                    maybeLoadMore()
                    break
                } else {
                    finish()
                    return
                }
            }
            if changed { maybeLoadMore() }
            showCurrent(animated: true)   // every frame: the box flows at reading pace
        }

        // While scrolling, follow the text live (Accessibility sources only).
        if now < scrollingUntil, provider?.supportsLiveRects == true, words.indices.contains(index) {
            if let r = provider?.liveRect(for: words[index]) {
                words[index].rect = r
                words[index].rectGen = rectGen
                showCurrent(animated: false)
            }
        }
    }

    private func finish() {
        let rid = readID
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, rid == self.readID else { return }
            self.stop()
        }
        state = .paused
    }

    private func maybeLoadMore() {
        guard !loadingMore, !providerDone, let prov = provider, words.count - index < 60 else { return }
        loadingMore = true
        let rid = readID
        let genAtStart = rectGen
        providerQueue.async { [weak self] in
            let more = prov.fetchMore(max: 80)
            let done = prov.isExhausted || more.isEmpty
            DispatchQueue.main.async {
                guard let self, rid == self.readID else { return }
                self.loadingMore = false
                self.providerDone = done
                // If the page scrolled while fetching, these rects are stale and get re-queried later.
                self.words += more.map { var w = $0; w.rectGen = genAtStart; return w }
                self.maybeLoadMore()
            }
        }
    }

    private func showCurrent(animated: Bool) {
        guard words.indices.contains(index) else { return }
        let s = Settings.shared

        if words[index].rectGen != rectGen, let prov = provider, prov.supportsLiveRects {
            words[index].rect = prov.liveRect(for: words[index])
            words[index].rectGen = rectGen
        }

        if let r = words[index].rect { lastKnownRect = r }
        if s.showHighlight, !hiddenForScroll, let f = flowBox() {
            overlay.show(box: f.box, line: s.style == .focus ? f.line : nil, style: s.style, animated: animated)
        } else {
            overlay.hide()
        }
    }

    /// The reading window: one fixed size per line (about 2–3 words wide, since people take in
    /// several words at a glance), sliding continuously along the line at reading pace.
    private func flowBox() -> (box: CGRect, line: CGRect)? {
        guard let r = words[index].rect, words[index].rectGen == rectGen || provider?.supportsLiveRects != true else { return nil }
        let line = lineRect() ?? r
        let h = max(line.height, r.height)
        var width = max(72, h * 6.5)
        if line.width + 8 < width { width = line.width + 8 }

        // Where the eye is: moves from this word's centre to the next one's as its time runs out.
        let dur = SilentTiming.duration(of: words[index].text, speed: Settings.shared.speed)
        let f = CGFloat(max(0, min(1, elapsed / max(dur, 0.001))))
        var x = r.midX + (r.maxX - r.midX) * f
        if words.indices.contains(index + 1), let n = words[index + 1].rect, words[index + 1].rectGen == rectGen,
           abs(n.midY - r.midY) < r.height * 0.5, n.minX > r.minX {
            x = r.midX + (n.midX - r.midX) * f
        }
        // Lead a little: the window shows the current word and what comes right after it.
        var cx = x + width * 0.18
        let lo = line.minX - 4 + width / 2, hi = line.maxX + 4 - width / 2
        cx = lo <= hi ? min(max(cx, lo), hi) : line.midX
        let box = CGRect(x: cx - width / 2, y: line.midY - h / 2 - 3, width: width, height: h + 6)
        return (box, line)
    }

    private var lineCache: (index: Int, gen: Int, count: Int, rect: CGRect?)?

    private func lineRect() -> CGRect? {
        if let c = lineCache, c.index == index, c.gen == rectGen, c.count == words.count { return c.rect }
        let lo = max(0, index - 40), hi = min(words.count, index + 40)
        let rects: [CGRect?] = words[lo..<hi].map { $0.rectGen == rectGen ? $0.rect : nil }
        let r = Layout.lineRect(rects: rects, index: index - lo)
        lineCache = (index, rectGen, words.count, r)
        return r
    }

    // MARK: Scrolling

    private func installScrollMonitor() {
        guard scrollMonitor == nil else { return }
        scrollMonitor = NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel) { [weak self] e in
            guard abs(e.scrollingDeltaY) + abs(e.scrollingDeltaX) > 0 else { return }
            self?.didScroll()
        }
    }

    private func didScroll() {
        guard state == .reading || state == .paused else { return }
        scrollingUntil = CACurrentMediaTime() + 0.25
        rectGen += 1
        if provider?.supportsLiveRects != true {
            hiddenForScroll = true
            overlay.hide()
        }
        scrollIdleWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.scrollEnded() }
        scrollIdleWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: w)
    }

    private func scrollEnded() {
        guard state == .reading || state == .paused else { return }
        if provider?.supportsLiveRects == true {
            refreshUpcomingRects()
            showCurrent(animated: false)
            return
        }
        reanchorAfterScroll()
    }

    /// Accessibility: re-query positions of the next words in the background (for Focus style).
    private func refreshUpcomingRects() {
        guard let prov = provider else { return }
        let gen = rectGen, rid = readID, start = index
        let slice = Array(words[start..<min(words.count, start + 40)])
        providerQueue.async { [weak self] in
            let rects = slice.map { prov.liveRect(for: $0) }
            DispatchQueue.main.async {
                guard let self, rid == self.readID, gen == self.rectGen else { return }
                for (k, r) in rects.enumerated() where self.words.indices.contains(start + k) {
                    self.words[start + k].rect = r
                    self.words[start + k].rectGen = gen
                }
                self.showCurrent(animated: false)
            }
        }
    }

    /// OCR: scan the screen again and find where the remaining words went.
    private func reanchorAfterScroll() {
        guard Permissions.shared.sr, let anchor = lastKnownRect,
              let screen = Coords.screen(containing: CGPoint(x: anchor.midX, y: anchor.midY)).map(ScreenInfo.init) else { return }
        let rid = readID, gen = rectGen, i0 = index
        let remaining = words[i0..<min(words.count, i0 + 6)].map(\.text)
        Task { @MainActor [weak self] in
            let fresh = await OCRLocator.scanScreen(screen)
            guard let self, rid == self.readID, gen == self.rectGen else { return }
            guard let k = Reanchor.find(remaining: remaining, in: fresh.map(\.text)) else {
                perfLog.info("re-anchor failed after scroll")
                return
            }
            let newWords = fresh[k...].map { ReadWord(text: $0.text, rect: $0.rect, rectGen: gen) }
            guard self.index - i0 < newWords.count else { return }
            self.words.replaceSubrange(i0..<self.words.count, with: newWords)
            self.hiddenForScroll = false
            self.showCurrent(animated: false)
        }
    }
}
