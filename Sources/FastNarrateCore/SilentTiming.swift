import Foundation

/// How long each word stays highlighted in silent mode.
public enum SilentTiming {
    public static let baseWPM = 250.0
    private static let closers = CharacterSet(charactersIn: "\"')]}”’»")

    public static func duration(of word: String, speed: Double, wpm: Double = baseWPM) -> Double {
        let base = 60.0 / (wpm * max(0.1, speed))
        let letters = word.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.count
        // Short words a bit faster, long words a bit slower (average stays near `base`).
        var factor = 0.75 + 0.05 * Double(min(letters, 14))
        let trimmed = word.trimmingCharacters(in: closers)
        if let last = trimmed.last {
            if ".!?…".contains(last) {
                factor += 1.2
            } else if ",;:—–".contains(last) {
                factor += 0.6
            }
        }
        return base * factor
    }
}
