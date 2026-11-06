import Foundation
import os

/// A text-to-speech backend that reports which word it is currently speaking.
/// Word indices are relative to the `words` array passed to `speak`.
@MainActor
protocol SpeechEngine: AnyObject {
    var onWord: ((Int) -> Void)? { get set }
    var onFinish: (() -> Void)? { get set }
    var onError: ((Error) -> Void)? { get set }

    func speak(_ words: [String], speed: Double)
    /// Start generating audio for text that is likely to be spoken next (no-op for local engines).
    func prefetch(_ words: [String])
    func stop()
    func pause()
    func resume()
}

enum Log {
    private static let logger = Logger(subsystem: "com.ash.narrate", category: "perf")

    static func timing(_ what: String, since start: Date) {
        let ms = Int(Date().timeIntervalSince(start) * 1000)
        logger.notice("\(what, privacy: .public): \(ms)ms")
    }

    static func info(_ message: String) {
        logger.notice("\(message, privacy: .public)")
    }
}
