import AVFoundation
import NaturalLanguage

/// Text-to-speech with per-word progress callbacks (on the main queue).
final class Speaker: NSObject, AVSpeechSynthesizerDelegate {
    var onWord: ((Int) -> Void)?
    var onFinish: (() -> Void)?

    private let synth = AVSpeechSynthesizer()
    private var current: AVSpeechUtterance?
    private var ranges: [NSRange] = []

    override init() {
        super.init()
        synth.delegate = self
    }

    func speak(_ words: [String], speed: Double, voiceID: String?) {
        stop()
        var text = ""
        ranges = []
        for w in words {
            if !text.isEmpty { text += " " }
            let loc = (text as NSString).length
            text += w
            ranges.append(NSRange(location: loc, length: (w as NSString).length))
        }
        let u = AVSpeechUtterance(string: text)
        u.voice = Self.voice(for: text, preferredID: voiceID)
        u.rate = Self.rate(for: speed)
        current = u
        synth.speak(u)
    }

    func stop() {
        current = nil
        if synth.isSpeaking { synth.stopSpeaking(at: .immediate) }
    }

    func pause() { synth.pauseSpeaking(at: .word) }
    func resume() { synth.continueSpeaking() }

    // MARK: Delegate

    func speechSynthesizer(_ s: AVSpeechSynthesizer, willSpeakRangeOfSpeechString r: NSRange,
                           utterance: AVSpeechUtterance) {
        guard utterance === current else { return }
        let idx = ranges.lastIndex { $0.location <= r.location } ?? 0
        DispatchQueue.main.async { [weak self] in
            guard let self, utterance === self.current else { return }
            self.onWord?(idx)
        }
    }

    func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        DispatchQueue.main.async { [weak self] in
            guard let self, utterance === self.current else { return }
            self.current = nil
            self.onFinish?()
        }
    }

    // MARK: Voices

    /// AVSpeech rate is non-linear; this maps a "1.5×"-style multiplier to something that feels right.
    static func rate(for speed: Double) -> Float {
        let r = Double(AVSpeechUtteranceDefaultSpeechRate) + (speed - 1) * 0.16
        return Float(min(max(r, 0.35), 0.75))
    }

    /// The user's chosen voice, or the highest-quality voice for the text's detected language.
    static func voice(for text: String, preferredID: String?) -> AVSpeechSynthesisVoice? {
        if let id = preferredID, let v = AVSpeechSynthesisVoice(identifier: id) { return v }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        let fallback = String((Locale.preferredLanguages.first ?? "en").prefix(2))
        let lang = recognizer.dominantLanguage?.rawValue ?? fallback
        let region = Locale.current.region?.identifier ?? ""
        let candidates = AVSpeechSynthesisVoice.speechVoices().filter {
            $0.language.hasPrefix(lang) && !$0.voiceTraits.contains(.isNoveltyVoice)
        }
        let best = candidates.max { a, b in
            if a.quality != b.quality { return a.quality.rawValue < b.quality.rawValue }
            return !a.language.hasSuffix(region) && b.language.hasSuffix(region)
        }
        return best ?? AVSpeechSynthesisVoice(language: lang)
    }

    /// Voices worth offering in the menu: enhanced/premium ones first.
    static func menuVoices() -> [AVSpeechSynthesisVoice] {
        let all = AVSpeechSynthesisVoice.speechVoices().filter { !$0.voiceTraits.contains(.isNoveltyVoice) }
        let good = all.filter { $0.quality != .default }
        let pool = good.isEmpty
            ? all.filter { $0.language.hasPrefix(String((Locale.preferredLanguages.first ?? "en").prefix(2))) }
            : good
        return pool.sorted { ($0.language, $0.name) < ($1.language, $1.name) }
    }
}
