import Foundation

final class Settings {
    static let shared = Settings()
    private let d = UserDefaults.standard

    private init() {
        d.register(defaults: [
            "speed": 1.0,
            "followMouse": false,
            "continueReading": true,
            "showSubtitles": true,
            "showHighlight": true,
        ])
    }

    var speed: Double {
        get { d.double(forKey: "speed") }
        set { d.set(newValue, forKey: "speed") }
    }

    /// nil = pick the best voice for the detected language automatically.
    var voiceID: String? {
        get { d.string(forKey: "voiceID") }
        set { d.set(newValue, forKey: "voiceID") }
    }

    enum Engine: String { case apple, natural }

    var engine: Engine {
        get { Engine(rawValue: d.string(forKey: "engine") ?? "") ?? .apple }
        set { d.set(newValue.rawValue, forKey: "engine") }
    }

    var elevenVoiceID: String? {
        get { d.string(forKey: "elevenVoiceID") }
        set { d.set(newValue, forKey: "elevenVoiceID") }
    }

    var elevenModel: String {
        get { d.string(forKey: "elevenModel") ?? "eleven_flash_v2_5" }
        set { d.set(newValue, forKey: "elevenModel") }
    }

    var elevenVoices: [ElevenLabsVoice] {
        get {
            guard let data = d.data(forKey: "elevenVoices"),
                  let v = try? JSONDecoder().decode([ElevenLabsVoice].self, from: data) else { return [] }
            return v
        }
        set { d.set(try? JSONEncoder().encode(newValue), forKey: "elevenVoices") }
    }

    var followMouse: Bool {
        get { d.bool(forKey: "followMouse") }
        set { d.set(newValue, forKey: "followMouse") }
    }

    var continueReading: Bool {
        get { d.bool(forKey: "continueReading") }
        set { d.set(newValue, forKey: "continueReading") }
    }

    var showSubtitles: Bool {
        get { d.bool(forKey: "showSubtitles") }
        set { d.set(newValue, forKey: "showSubtitles") }
    }

    var showHighlight: Bool {
        get { d.bool(forKey: "showHighlight") }
        set { d.set(newValue, forKey: "showHighlight") }
    }
}
