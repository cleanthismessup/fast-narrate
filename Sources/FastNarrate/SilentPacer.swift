import Foundation

/// A silent "voice": moves the highlight at a steady reading pace with no audio.
/// Useful in class/libraries, and as a speed-reading pacer. Base pace is 250 wpm × speed.
@MainActor
final class SilentPacer: SpeechEngine {
    var onWord: ((Int) -> Void)?
    var onFinish: (() -> Void)?
    var onError: ((Error) -> Void)?

    nonisolated static let baseWPM = 250.0

    private var words: [String] = []
    private var index = 0
    private var speed = 1.0
    private var timer: Timer?
    private var paused = false

    func speak(_ words: [String], speed: Double) {
        stop()
        self.words = words
        self.speed = speed
        index = 0
        guard !words.isEmpty else { onFinish?(); return }
        onWord?(0)
        schedule()
    }

    func prefetch(_ words: [String]) {}

    func stop() {
        timer?.invalidate()
        timer = nil
        paused = false
        words = []
    }

    func pause() {
        paused = true
        timer?.invalidate()
        timer = nil
    }

    func resume() {
        guard paused else { return }
        paused = false
        schedule()
    }

    /// How long a word stays highlighted: longer words and punctuation get more time,
    /// the way a reader naturally lingers.
    nonisolated static func duration(of word: String, speed: Double) -> TimeInterval {
        let base = 60.0 / (baseWPM * max(speed, 0.3))
        var factor = 1.0
        let letters = word.filter(\.isLetter).count
        if letters > 6 { factor += Double(letters - 6) * 0.06 }
        if let last = word.last {
            if ".!?…".contains(last) { factor += 1.2 } else if ",;:)—–".contains(last) { factor += 0.5 }
        }
        return base * factor
    }

    private func schedule() {
        guard index < words.count else { return }
        let d = Self.duration(of: words[index], speed: speed)
        timer = Timer.scheduledTimer(withTimeInterval: d, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.advance() }
        }
    }

    private func advance() {
        index += 1
        if index >= words.count {
            let cb = onFinish
            stop()
            cb?()
            return
        }
        onWord?(index)
        schedule()
    }
}
