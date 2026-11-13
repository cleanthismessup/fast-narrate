import Foundation

/// After the page scrolls (OCR path), finds where the remaining words are in a fresh scan.
public enum Reanchor {
    static func norm(_ s: String) -> String {
        String(s.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }

    /// Index in `candidates` where the first words of `remaining` appear, matching up to
    /// `window` words (falls back to shorter matches, down to 2).
    public static func find(remaining: [String], in candidates: [String], window: Int = 4) -> Int? {
        let r = remaining.prefix(window).map(norm)
        guard !r.isEmpty else { return nil }
        let c = candidates.map(norm)
        let minK = min(2, r.count)
        for k in stride(from: min(window, r.count), through: minK, by: -1) {
            guard c.count >= k else { continue }
            let target = Array(r[0..<k])
            for i in 0...(c.count - k) where Array(c[i..<(i + k)]) == target {
                return i
            }
        }
        return nil
    }
}
