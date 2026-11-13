import AppKit

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
            "showParagraphOutline": true,
            "highlightStyle": HighlightStyle.marker.rawValue,
            "highlightColor": HighlightColor.yellow.rawValue,
            "subtitleSize": SubtitleSize.medium.rawValue,
            "subtitlePosition": SubtitlePosition.bottom.rawValue,
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

    enum Engine: String { case apple, natural, silent }

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

    // MARK: Appearance

    enum HighlightStyle: String, CaseIterable {
        case marker, underline, outline, focus
        var label: String {
            switch self {
            case .marker: return "Marker"
            case .underline: return "Underline"
            case .outline: return "Outline"
            case .focus: return "Focus (dim the rest)"
            }
        }
    }

    enum HighlightColor: String, CaseIterable {
        case yellow, green, pink, blue
        var label: String { rawValue.capitalized }
        var color: NSColor {
            switch self {
            case .yellow: return NSColor(calibratedRed: 1.0, green: 0.84, blue: 0.04, alpha: 1)
            case .green: return NSColor(calibratedRed: 0.20, green: 0.85, blue: 0.45, alpha: 1)
            case .pink: return NSColor(calibratedRed: 1.0, green: 0.36, blue: 0.62, alpha: 1)
            case .blue: return NSColor(calibratedRed: 0.25, green: 0.62, blue: 1.0, alpha: 1)
            }
        }
    }

    enum SubtitleSize: String, CaseIterable {
        case small, medium, large
        var label: String { rawValue.capitalized }
        var points: CGFloat { self == .small ? 22 : self == .medium ? 30 : 42 }
    }

    enum SubtitlePosition: String, CaseIterable {
        case bottom, top
        var label: String { rawValue.capitalized }
    }

    var highlightStyle: HighlightStyle {
        get { HighlightStyle(rawValue: d.string(forKey: "highlightStyle") ?? "") ?? .marker }
        set { d.set(newValue.rawValue, forKey: "highlightStyle") }
    }

    var highlightColor: HighlightColor {
        get { HighlightColor(rawValue: d.string(forKey: "highlightColor") ?? "") ?? .yellow }
        set { d.set(newValue.rawValue, forKey: "highlightColor") }
    }

    var showParagraphOutline: Bool {
        get { d.bool(forKey: "showParagraphOutline") }
        set { d.set(newValue, forKey: "showParagraphOutline") }
    }

    var subtitleSize: SubtitleSize {
        get { SubtitleSize(rawValue: d.string(forKey: "subtitleSize") ?? "") ?? .medium }
        set { d.set(newValue.rawValue, forKey: "subtitleSize") }
    }

    var subtitlePosition: SubtitlePosition {
        get { SubtitlePosition(rawValue: d.string(forKey: "subtitlePosition") ?? "") ?? .bottom }
        set { d.set(newValue.rawValue, forKey: "subtitlePosition") }
    }

    /// Where "Send UI Feedback" saves snapshots.
    var feedbackFolder: URL {
        if let p = d.string(forKey: "feedbackFolder"), !p.isEmpty {
            return URL(fileURLWithPath: (p as NSString).expandingTildeInPath, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/Fast Narrate Feedback", isDirectory: true)
    }
}
