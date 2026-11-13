import Foundation

/// A word and where it sits in the source string. Ranges are UTF-16 offsets,
/// the same units NSString and the Accessibility API use.
public struct Token: Equatable {
    public let text: String
    public let range: NSRange
    public init(text: String, range: NSRange) {
        self.text = text
        self.range = range
    }
}

public enum Tokenizer {
    private static let space = CharacterSet.whitespacesAndNewlines
    private static let wordy = CharacterSet.alphanumerics

    @inline(__always)
    static func isSpace(_ c: unichar) -> Bool {
        guard let u = UnicodeScalar(c) else { return false }
        return space.contains(u)
    }

    /// Splits on whitespace, keeping punctuation attached to its word.
    /// Tokens with no letters or digits (bullets, dashes) are skipped.
    public static func tokens(in s: NSString, from start: Int = 0, limit: Int = .max) -> [Token] {
        var out: [Token] = []
        let n = s.length
        var i = max(0, min(start, n))
        while i < n && out.count < limit {
            while i < n && isSpace(s.character(at: i)) { i += 1 }
            if i >= n { break }
            let b = i
            while i < n && !isSpace(s.character(at: i)) { i += 1 }
            let r = NSRange(location: b, length: i - b)
            let text = s.substring(with: r)
            if text.unicodeScalars.contains(where: { wordy.contains($0) }) {
                out.append(Token(text: text, range: r))
            }
        }
        return out
    }

    /// Start of the word containing `index` (or of the next word if `index` is on whitespace).
    public static func wordStart(in s: NSString, at index: Int) -> Int {
        let n = s.length
        var i = max(0, min(index, n))
        if i < n && isSpace(s.character(at: i)) {
            while i < n && isSpace(s.character(at: i)) { i += 1 }
            return i
        }
        while i > 0 && !isSpace(s.character(at: i - 1)) { i -= 1 }
        return i
    }
}
