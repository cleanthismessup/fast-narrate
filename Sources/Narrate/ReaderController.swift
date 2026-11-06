import AppKit
import Carbon.HIToolbox

/// Orchestrates capture → layout → speech → highlight, plus follow-the-mouse and scroll re-sync.
@MainActor
final class ReaderController {
    var onStateChange: (() -> Void)?

    private(set) var isSpeaking = false
    private(set) var isPaused = false
    private(set) var isFollowing = false

    private let capture = TextCapture()
    private let speaker = Speaker()
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
    private var captureTime = Date.distantPast

    private var isCapturing = false
    private var highlightSuspended = false
    private var scrollWork: DispatchWorkItem?
    private var scrollMonitor: Any?

    // Follow-mouse state
    private var followTimer: Timer?
    private var lastMouse = CGPoint(x: -1, y: -1)
    private var stillSince = Date()
    private var dwellArmed = false

    private static let dwell: TimeInterval = 0.45

    init() {
        speaker.onWord = { [weak self] i in self?.spoke(i) }
        speaker.onFinish = { [weak self] in self?.finishedBlock() }
        scrollMonitor = NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel) { [weak self] _ in
            self?.userScrolled()
        }
    }

    // MARK: Commands

    /// Hotkey: read from the word under the pointer, or stop if already reading.
    func toggleRead() {
        if isSpeaking { stop(); return }
        let p = NSEvent.mouseLocation
        Task { await read(at: p, fromFollow: false) }
    }

    func togglePause() {
        guard isSpeaking else { return }
        if isPaused { speaker.resume() } else { speaker.pause() }
        isPaused.toggle()
        onStateChange?()
    }

    func stop() {
        speaker.stop()
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
            followTimer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.followTick() }
            }
        }
        onStateChange?()
    }

    func refreshAppearance() {
        guard isSpeaking else { return }
        render()
    }

    // MARK: Reading

    private func read(at p: CGPoint, fromFollow: Bool) async {
        guard !isCapturing, let scr = NSScreen.containing(p) else { return }

        // In follow mode, reuse a very fresh scan instead of re-capturing.
        if fromFollow, scr == screen, Date().timeIntervalSince(captureTime) < 1.0,
           let hit = Layout.locate(p, in: blocks, tolerance: 2) {
            jumpIfNeeded(to: hit)
            return
        }

        isCapturing = true
        defer { isCapturing = false }
        if !isSpeaking, !fromFollow { subtitles.showStatus("Scanning…", on: scr) }

        do {
            let lines = try await capture.recognizeLines(on: scr)
            let found = Layout.blocks(from: lines)
            guard let hit = Layout.locate(p, in: found, tolerance: fromFollow ? 2 : 24) else {
                if !fromFollow { subtitles.showStatus("No text under the pointer", on: scr, autoHide: 1.5) }
                return
            }
            screen = scr
            blocks = found
            captureTime = Date()
            if fromFollow { jumpIfNeeded(to: hit) } else { begin(block: hit.block, at: hit.word) }
        } catch {
            subtitles.showStatus(error.localizedDescription, on: scr, autoHide: 4)
            if case CaptureError.permissionDenied = error { CGRequestScreenCaptureAccess() }
        }
    }

    /// Follow mode: only restart when the pointer rests somewhere other than what's being read.
    private func jumpIfNeeded(to hit: (block: Int, word: Int)) {
        if isSpeaking, hit.block == blockIndex, abs(hit.word - currentIndex) <= 3 { return }
        begin(block: hit.block, at: hit.word)
    }

    private func begin(block b: Int, at w: Int) {
        guard let scr = screen, blocks.indices.contains(b), blocks[b].words.indices.contains(w) else { return }
        blockIndex = b
        words = blocks[b].words
        currentIndex = w
        speakStart = w
        highlightSuspended = false
        isSpeaking = true
        isPaused = false

        overlay.show(on: scr)
        render()
        speaker.speak(words[w...].map(\.text), speed: settings.speed, voiceID: settings.voiceID)
        HotKeys.shared.register(HotKeyID.escape.rawValue, keyCode: kVK_Escape, modifiers: 0) { [weak self] in
            self?.stop()
        }
        onStateChange?()
    }

    private func spoke(_ i: Int) {
        currentIndex = min(speakStart + i, words.count - 1)
        render()
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

    private func endSession() {
        let wasSpeaking = isSpeaking
        isSpeaking = false
        isPaused = false
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
            lastMouse = p
            stillSince = Date()
            dwellArmed = true
            return
        }
        guard dwellArmed, !isCapturing, Date().timeIntervalSince(stillSince) >= Self.dwell else { return }
        dwellArmed = false
        Task { await read(at: p, fromFollow: true) }
    }

    // MARK: Scroll re-sync

    /// When the page scrolls, hide the (now wrong) highlight, keep talking, and once scrolling
    /// settles, re-scan and re-anchor the remaining words to their new positions.
    private func userScrolled() {
        captureTime = .distantPast
        guard isSpeaking else { return }
        if !highlightSuspended {
            highlightSuspended = true
            render()
        }
        scheduleResync(after: 0.35)
    }

    private func scheduleResync(after delay: TimeInterval) {
        scrollWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in await self?.resync() }
        }
        scrollWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func resync() async {
        guard isSpeaking, let scr = screen else { return }
        guard !isCapturing else { scheduleResync(after: 0.3); return }
        isCapturing = true
        defer { isCapturing = false }
        guard let lines = try? await capture.recognizeLines(on: scr), isSpeaking else { return }
        let fresh = Layout.blocks(from: lines)
        var updated = words
        if Layout.realign(&updated, from: currentIndex, to: fresh) {
            words = updated
            blocks = fresh
            captureTime = Date()
            if let r = words[currentIndex].rects.first,
               let b = Layout.blockIndex(containing: CGPoint(x: r.midX, y: r.midY), in: fresh) {
                blockIndex = b
            }
            highlightSuspended = false
        }
        render()
    }
}
