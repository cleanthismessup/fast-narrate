import AppKit
import Carbon.HIToolbox

/// Orchestrates capture → layout → speech → highlight, plus follow-the-mouse and scroll re-sync.
@MainActor
final class ReaderController {
    var onStateChange: (() -> Void)?
    /// Called (at most once per launch) when a read needs Screen Recording permission.
    var onPermissionNeeded: (() -> Void)?
    private var reportedPermission = false

    private(set) var isSpeaking = false
    private(set) var isPaused = false
    private(set) var isFollowing = false
    private(set) var ocrReady = false

    private let capture = TextCapture()
    private let apple = AppleSpeaker()
    private let natural = ElevenLabsSpeaker()
    private let silent = SilentPacer()
    private lazy var engine: SpeechEngine = apple
    private let overlay = HighlightOverlay()
    private let subtitles = SubtitleBar()
    private let settings = Settings.shared

    // Current reading session
    private var screen: NSScreen?
    private var blocks: [Block] = []
    private var blockIndex = 0
    private var words: [Word] = []
    private var currentIndex = 0
    private var speakStart = 0
    private var prefetchedNext = false
    private var naturalFailed = false
    private var readToken = 0

    // Screen scan cache (shared by hotkey, follow mode and scroll re-sync)
    private var scanTask: Task<[Block], Error>?
    private var scanDisplay: CGDirectDisplayID = 0
    private var scanStarted = Date.distantPast
    private var cache: (display: CGDirectDisplayID, blocks: [Block], time: Date)?
    private var invalidatedAt = Date.distantPast

    private var highlightSuspended = false
    private var scrollWork: DispatchWorkItem?
    private var monitors: [Any] = []

    // Follow-mouse state
    private var followTimer: Timer?
    private var lastMouse = CGPoint(x: -1, y: -1)
    private var stillSince = Date()
    private var dwellArmed = false
    private var moving = false

    private static let dwell: TimeInterval = 0.3

    init() {
        for e in [apple, natural, silent] as [SpeechEngine] {
            e.onWord = { [weak self] i in self?.spoke(i) }
            e.onFinish = { [weak self] in self?.finishedBlock() }
            e.onError = { [weak self] err in self?.speechFailed(err) }
        }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel, handler: { [weak self] _ in
            self?.userScrolled()
        }) { monitors.append(m) }
        // Clicks usually change what's on screen (new page, opened menu, typed text).
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in
            self?.invalidate()
        }) { monitors.append(m) }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.warmUp() }
        }
    }

    // MARK: Commands

    /// Prepares OCR for every display size and loads the offline voice, in the background.
    func warmUp() {
        let start = Date()
        var sizes: [CGSize] = []
        for s in NSScreen.screens {
            let px = CGSize(width: s.frame.width * s.backingScaleFactor, height: s.frame.height * s.backingScaleFactor)
            if !sizes.contains(px) { sizes.append(px) }
        }
        Task.detached(priority: .utility) {
            for s in sizes { OCR.warmUp(pixelSize: s) }
            await MainActor.run {
                self.ocrReady = true
                Log.timing("OCR warm-up", since: start)
            }
        }
        apple.warmUp()
    }

    /// Hotkey: read from the word under the pointer, or stop if already reading.
    func toggleRead() {
        if isSpeaking { stop(); return }
        let p = NSEvent.mouseLocation
        Task { await read(at: p, fromFollow: false) }
    }

    func togglePause() {
        guard isSpeaking else { return }
        if isPaused { engine.resume() } else { engine.pause() }
        isPaused.toggle()
        onStateChange?()
    }

    func stop() {
        readToken += 1
        engine.stop()
        endSession()
    }

    func setFollow(_ on: Bool) {
        isFollowing = on
        settings.followMouse = on
        followTimer?.invalidate()
        followTimer = nil
        if on {
            lastMouse = NSEvent.mouseLocation
            stillSince = Date()
            dwellArmed = false
            followTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.followTick() }
            }
            if ScreenPermission.isGranted, let s = NSScreen.containing(lastMouse) { startScan(s) }
        }
        onStateChange?()
    }

    func refreshAppearance() {
        guard isSpeaking else { return }
        render()
    }

    /// Speaks a short sample with the current voice settings (used after choosing a voice).
    func preview(_ text: String) {
        stop()
        naturalFailed = false
        words = text.split(separator: " ").map { Word(text: String($0), rects: []) }
        blocks = []
        screen = NSScreen.containing(NSEvent.mouseLocation)
        currentIndex = 0
        speakStart = 0
        isSpeaking = true
        engine = pickEngine()
        render()
        engine.speak(words.map(\.text), speed: settings.speed)
        onStateChange?()
    }

    // MARK: Feedback snapshots

    /// Pauses reading so a snapshot shows a frozen frame. Returns true if it paused.
    func pauseForSnapshot() -> Bool {
        guard isSpeaking, !isPaused else { return false }
        togglePause()
        return true
    }

    /// Screenshot of the display under the pointer (or being read), including our overlay and captions.
    func captureForFeedback() async throws -> (image: CGImage, screen: NSScreen) {
        guard let scr = screen.flatMap({ s in isSpeaking ? s : nil }) ?? NSScreen.containing(NSEvent.mouseLocation)
        else { throw CaptureError.noDisplay }
        overlay.setCapturable(true)
        subtitles.setCapturable(true)
        defer {
            overlay.setCapturable(false)
            subtitles.setCapturable(false)
        }
        try await Task.sleep(nanoseconds: 120_000_000) // let the window server apply the change
        return (try await capture.captureImage(of: scr, includeOwnWindows: true), scr)
    }

    /// The area worth zooming into: the paragraph being read.
    var focusRect: CGRect? {
        let r = words.flatMap(\.rects)
        return isSpeaking && !r.isEmpty ? r.reduce(CGRect.null) { $0.union($1) } : nil
    }

    /// Markdown describing what Fast Narrate was doing, for the feedback report.
    func stateReport() -> String {
        var out = "- Reading: \(isSpeaking ? (isPaused ? "paused" : "yes") : "no")\n"
        out += "- Follow mouse: \(isFollowing)\n"
        out += "- Engine: \(isSpeaking ? String(describing: type(of: engine)) : settings.engine.rawValue)\n"
        out += "- Highlight suspended (scrolling): \(highlightSuspended)\n"
        if isSpeaking, words.indices.contains(currentIndex) {
            let w = words[currentIndex]
            out += "- Current word: `\(w.text)` (#\(currentIndex) of \(words.count)), rects: \(w.rects.map { "\($0.integral)" })\n"
            out += "- Paragraph \(blockIndex + 1) of \(blocks.count), rect: \(focusRect.map { "\($0.integral)" } ?? "none")\n\n"
            let marked = words.enumerated().map { $0.offset == currentIndex ? "**[\($0.element.text)]**" : $0.element.text }
            out += "Paragraph text (current word in brackets):\n\n> \(marked.joined(separator: " "))\n"
        }
        return out
    }

    // MARK: Scanning

    private func invalidate() {
        invalidatedAt = Date()
    }

    private func isFresh(_ time: Date, maxAge: TimeInterval) -> Bool {
        time > invalidatedAt && Date().timeIntervalSince(time) < maxAge
    }

    /// Blocks for a screen: a fresh cached scan, the scan already in flight, or a new one.
    private func scan(_ scr: NSScreen, maxAge: TimeInterval) async throws -> [Block] {
        let id = scr.displayID ?? 0
        if let c = cache, c.display == id, isFresh(c.time, maxAge: maxAge) { return c.blocks }
        if let t = scanTask, scanDisplay == id, scanStarted > invalidatedAt { return try await t.value }
        return try await startScan(scr).value
    }

    @discardableResult
    private func startScan(_ scr: NSScreen) -> Task<[Block], Error> {
        let started = Date()
        let id = scr.displayID ?? 0
        let task = Task<[Block], Error> {
            let lines = try await self.capture.recognizeLines(on: scr)
            return Layout.blocks(from: lines)
        }
        scanTask = task
        scanDisplay = id
        scanStarted = started
        Task {
            guard let r = try? await task.value else { return }
            Log.timing("screen scan", since: started)
            if started > self.invalidatedAt, (self.cache?.time ?? .distantPast) < started {
                self.cache = (id, r, started)
            }
        }
        return task
    }

    // MARK: Reading

    private func read(at p: CGPoint, fromFollow: Bool) async {
        guard let scr = NSScreen.containing(p) else { return }
        guard ScreenPermission.isGranted else {
            if !fromFollow { subtitles.showStatus(CaptureError.permissionDenied.localizedDescription, on: scr, autoHide: 3) }
            if !reportedPermission { reportedPermission = true; onPermissionNeeded?() }
            return
        }
        readToken += 1
        let token = readToken
        let t0 = Date()
        if pickEngine() === natural {
            natural.warmUp()
            natural.preconnect()
        }
        if !fromFollow, !isSpeaking {
            subtitles.showStatus(ocrReady ? "Scanning…" : "Getting text recognition ready (first launch only)…", on: scr)
        }
        do {
            let found = try await scan(scr, maxAge: fromFollow ? 4 : 2)
            guard token == readToken else { return }
            guard let hit = Layout.locate(p, in: found, tolerance: fromFollow ? 2 : 24) else {
                if !fromFollow { subtitles.showStatus("No text under the pointer", on: scr, autoHide: 1.5) }
                return
            }
            // In follow mode, drop the result if the pointer has already moved on.
            if fromFollow, hypot(NSEvent.mouseLocation.x - p.x, NSEvent.mouseLocation.y - p.y) > 24 { return }
            if fromFollow, isSpeaking, hit.block == blockIndex, abs(hit.word - currentIndex) <= 3,
               blocks.count == found.count { return }
            screen = scr
            blocks = found
            Log.timing("pointer → speaking", since: t0)
            begin(block: hit.block, at: hit.word)
        } catch {
            guard token == readToken else { return }
            subtitles.showStatus(error.localizedDescription, on: scr, autoHide: 4)
        }
    }

    private func pickEngine() -> SpeechEngine {
        if settings.engine == .silent { return silent }
        return settings.engine == .natural && ElevenLabsSpeaker.isConfigured && !naturalFailed ? natural : apple
    }

    private func begin(block b: Int, at w: Int) {
        guard let scr = screen, blocks.indices.contains(b), blocks[b].words.indices.contains(w) else { return }
        blockIndex = b
        words = blocks[b].words
        currentIndex = w
        speakStart = w
        prefetchedNext = false
        highlightSuspended = false
        isSpeaking = true
        isPaused = false

        let next = pickEngine()
        if next !== engine { engine.stop() }
        engine = next

        overlay.show(on: scr)
        render()
        engine.speak(words[w...].map(\.text), speed: settings.speed)
        HotKeys.shared.register(HotKeyID.escape.rawValue, keyCode: kVK_Escape, modifiers: 0) { [weak self] in
            self?.stop()
        }
        onStateChange?()
    }

    private func spoke(_ i: Int) {
        guard isSpeaking, !words.isEmpty else { return }
        currentIndex = min(speakStart + i, words.count - 1)
        render()

        // Start generating the next paragraph's audio halfway through this one, so the
        // hand-over is seamless.
        if !prefetchedNext, settings.continueReading, currentIndex >= words.count / 2,
           let next = Layout.nextBlock(after: blockIndex, in: blocks) {
            prefetchedNext = true
            engine.prefetch(blocks[next].words.map(\.text))
        }
    }

    private func render() {
        overlay.update(words: words, current: currentIndex,
                       visible: settings.showHighlight && !highlightSuspended)
        if settings.showSubtitles {
            subtitles.update(words: words.map(\.text), current: currentIndex, on: screen)
        } else {
            subtitles.hide()
        }
    }

    private func finishedBlock() {
        if settings.continueReading, let next = Layout.nextBlock(after: blockIndex, in: blocks) {
            begin(block: next, at: 0)
        } else {
            endSession()
        }
    }

    /// Natural voice failed (network, quota, bad key): say so, then carry on with the Apple voice.
    private func speechFailed(_ error: Error) {
        guard isSpeaking else { return }
        Log.info("speech failed: \(error.localizedDescription)")
        naturalFailed = true
        subtitles.showStatus("Natural voice unavailable — \(error.localizedDescription) Using the offline voice.",
                             on: screen)
        let resumeAt = currentIndex
        let token = readToken
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, self.isSpeaking, token == self.readToken, self.words.indices.contains(resumeAt) else { return }
            self.engine = self.apple
            self.speakStart = resumeAt
            self.render()
            self.apple.speak(self.words[resumeAt...].map(\.text), speed: self.settings.speed)
        }
    }

    private func endSession() {
        let wasSpeaking = isSpeaking
        isSpeaking = false
        isPaused = false
        naturalFailed = false
        scrollWork?.cancel()
        HotKeys.shared.unregister(HotKeyID.escape.rawValue)
        overlay.hide()
        subtitles.hide(after: 0.3)
        if wasSpeaking { onStateChange?() }
    }

    // MARK: Follow mode

    private func followTick() {
        let p = NSEvent.mouseLocation
        if hypot(p.x - lastMouse.x, p.y - lastMouse.y) > 3 {
            // Scan as soon as the pointer starts moving, so the result is ready when it stops.
            if !moving || (cache.map { !isFresh($0.time, maxAge: 3) } ?? true) {
                if ScreenPermission.isGranted, let s = NSScreen.containing(p), !(scanStarted > invalidatedAt && Date().timeIntervalSince(scanStarted) < 1) {
                    startScan(s)
                }
            }
            moving = true
            lastMouse = p
            stillSince = Date()
            dwellArmed = true
            return
        }
        guard dwellArmed, Date().timeIntervalSince(stillSince) >= Self.dwell else { return }
        dwellArmed = false
        moving = false
        Task { await read(at: p, fromFollow: true) }
    }

    // MARK: Scroll re-sync

    /// When the page scrolls, hide the (now wrong) highlight, keep talking, and once scrolling
    /// settles, re-scan and re-anchor the remaining words to their new positions.
    private func userScrolled() {
        invalidate()
        guard isSpeaking, !words.isEmpty, !blocks.isEmpty else { return }
        if !highlightSuspended {
            highlightSuspended = true
            render()
        }
        scrollWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in await self?.resync() }
        }
        scrollWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    private func resync() async {
        guard isSpeaking, let scr = screen else { return }
        guard let fresh = try? await scan(scr, maxAge: 0.2), isSpeaking, highlightSuspended else { return }
        var updated = words
        if Layout.realign(&updated, from: currentIndex, to: fresh) {
            words = updated
            blocks = fresh
            if let r = words[currentIndex].rects.first,
               let b = Layout.blockIndex(containing: CGPoint(x: r.midX, y: r.midY), in: fresh) {
                blockIndex = b
            }
            highlightSuspended = false
        }
        render()
    }
}
