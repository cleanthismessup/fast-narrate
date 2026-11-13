import Foundation

/// Splits the word list into short caption groups (TikTok-style), breaking at sentence ends.
public enum CaptionChunks {
    private static let closers = CharacterSet(charactersIn: "\"')]}”’»")

    public static func chunks(for words: [String], maxWords: Int = 5) -> [Range<Int>] {
        var out: [Range<Int>] = []
        var start = 0
        for i in words.indices {
            let count = i - start + 1
            let w = words[i].trimmingCharacters(in: closers)
            let endsSentence = w.last.map { ".!?…;:".contains($0) } ?? false
            let endsComma = w.last == ","
            if count >= maxWords || endsSentence || (endsComma && count >= 3) {
                out.append(start..<(i + 1))
                start = i + 1
            }
        }
        if start < words.count { out.append(start..<words.count) }
        return out
    }

    public static func chunkIndex(containing i: Int, in chunks: [Range<Int>]) -> Int? {
        var lo = 0, hi = chunks.count - 1
        while lo <= hi {
            let mid = (lo + hi) / 2
            if chunks[mid].contains(i) { return mid }
            if i < chunks[mid].lowerBound { hi = mid - 1 } else { lo = mid + 1 }
        }
        return nil
    }
}
