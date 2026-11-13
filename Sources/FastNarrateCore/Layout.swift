import CoreGraphics
import Foundation

/// A recognised word with its box in screen points (Cocoa coordinates, y grows upward).
public struct OCRWord: Equatable {
    public var text: String
    public var rect: CGRect
    public init(text: String, rect: CGRect) {
        self.text = text
        self.rect = rect
    }
}

public struct OCRLine: Equatable {
    public var words: [OCRWord]
    public init(words: [OCRWord]) { self.words = words }
    public var rect: CGRect {
        words.dropFirst().reduce(words.first?.rect ?? .zero) { $0.union($1.rect) }
    }
}

/// Turns OCR lines into words in reading order.
public enum Layout {

    // MARK: Rows

    /// Joins line fragments that sit on the same row and are close together
    /// (Vision sometimes splits one line in two). Columns stay apart.
    public static func mergeRows(_ lines: [OCRLine]) -> [OCRLine] {
        let sorted = lines.filter { !$0.words.isEmpty }.sorted {
            let a = $0.rect, b = $1.rect
            if abs(a.midY - b.midY) > min(a.height, b.height) * 0.5 { return a.midY > b.midY }
            return a.minX < b.minX
        }
        var out: [OCRLine] = []
        for line in sorted {
            let r = line.rect
            if let j = out.lastIndex(where: { canMerge($0.rect, r) }) {
                out[j].words += line.words
            } else {
                out.append(line)
            }
        }
        return out
    }

    static func canMerge(_ a: CGRect, _ b: CGRect) -> Bool {
        let h = min(a.height, b.height)
        guard h > 0 else { return false }
        let ratio = max(a.height, b.height) / h
        let vOverlap = min(a.maxY, b.maxY) - max(a.minY, b.minY)
        let gap = b.minX - a.maxX
        return ratio < 1.5 && vOverlap > h * 0.6 && gap > -h * 0.3 && gap < h * 1.5
    }

    // MARK: Blocks (paragraphs / column runs)

    /// Groups lines into blocks: consecutive lines of similar height that are stacked
    /// closely and overlap horizontally. Lines inside a block are top to bottom.
    public static func blocks(_ lines: [OCRLine]) -> [[OCRLine]] {
        let sorted = lines.sorted { $0.rect.maxY > $1.rect.maxY }
        var blocks: [[OCRLine]] = []
        for line in sorted {
            let r = line.rect
            var best: (index: Int, gap: CGFloat)?
            for (i, block) in blocks.enumerated() {
                let last = block[block.count - 1].rect
                let h = (last.height + r.height) / 2
                let gap = last.minY - r.maxY
                let ratio = max(last.height, r.height) / max(1, min(last.height, r.height))
                let overlap = min(last.maxX, r.maxX) - max(last.minX, r.minX)
                let aligned = overlap > min(last.width, r.width) * 0.3 || abs(last.minX - r.minX) < h * 2
                if gap >= -h * 0.5 && gap <= h * 1.6 && ratio < 1.5 && aligned {
                    if best == nil || gap < best!.gap { best = (i, gap) }
                }
            }
            if let b = best { blocks[b.index].append(line) } else { blocks.append([line]) }
        }
        return blocks
    }

    static func bounds(_ block: [OCRLine]) -> CGRect {
        block.dropFirst().reduce(block[0].rect) { $0.union($1.rect) }
    }

    /// Orders blocks so each column is read top to bottom before moving on:
    /// start at the top-most (left-most on ties) block, follow blocks below it that
    /// overlap horizontally, then jump to the next top-most remaining block.
    public static func orderedBlocks(_ blocks: [[OCRLine]]) -> [[OCRLine]] {
        var remaining = blocks.map { (lines: $0, rect: bounds($0)) }
        var out: [[OCRLine]] = []

        func topMost(_ items: [(lines: [OCRLine], rect: CGRect)]) -> Int? {
            guard let maxY = items.map(\.rect.maxY).max() else { return nil }
            let tol = (items.map { $0.lines[0].rect.height }.min() ?? 10) * 0.5
            return items.indices
                .filter { items[$0].rect.maxY >= maxY - tol }
                .min { items[$0].rect.minX < items[$1].rect.minX }
        }

        while let start = topMost(remaining) {
            var current = remaining.remove(at: start)
            out.append(current.lines)
            while true {
                let cur = current.rect
                let below = remaining.indices.filter { i in
                    let r = remaining[i].rect
                    let overlap = min(cur.maxX, r.maxX) - max(cur.minX, r.minX)
                    return r.maxY <= cur.minY + cur.height * 0.05 + 2
                        && overlap > min(cur.width, r.width) * 0.3
                }
                guard let next = topMost(below.map { remaining[$0] }).map({ below[$0] }) else { break }
                current = remaining.remove(at: next)
                out.append(current.lines)
            }
        }
        return out
    }

    // MARK: Words

    /// Full pipeline: rows → blocks → reading order → flat word list,
    /// re-joining words hyphenated across a line break.
    public static func readingWords(_ lines: [OCRLine]) -> [OCRWord] {
        var out: [OCRWord] = []
        for block in orderedBlocks(blocks(mergeRows(lines))) {
            var pendingHyphen = false
            for line in block {
                let words = line.words.sorted { $0.rect.minX < $1.rect.minX }
                for (k, w) in words.enumerated() {
                    if k == 0, pendingHyphen, let first = w.text.unicodeScalars.first,
                       CharacterSet.lowercaseLetters.contains(first), !out.isEmpty {
                        out[out.count - 1].text = String(out[out.count - 1].text.dropLast()) + w.text
                        continue
                    }
                    out.append(w)
                }
                if let last = words.last?.text, last.count > 2, last.hasSuffix("-"),
                   let prev = last.dropLast().unicodeScalars.last, CharacterSet.letters.contains(prev) {
                    pendingHyphen = true
                } else {
                    pendingHyphen = false
                }
            }
        }
        return out
    }

    /// Index of the word under (or nearest to) the pointer.
    public static func hitTest(_ p: CGPoint, words: [OCRWord]) -> Int? {
        if let i = words.firstIndex(where: { $0.rect.insetBy(dx: -2, dy: -2).contains(p) }) { return i }
        // Same row: nearest word horizontally.
        let row = words.indices.filter { p.y >= words[$0].rect.minY - 2 && p.y <= words[$0].rect.maxY + 2 }
        if let i = row.min(by: { hDist(p, words[$0].rect) < hDist(p, words[$1].rect) }),
           hDist(p, words[i].rect) < words[i].rect.height * 3 {
            return i
        }
        // Otherwise the nearest word within about one line.
        guard let i = words.indices.min(by: { dist(p, words[$0].rect) < dist(p, words[$1].rect) }) else { return nil }
        return dist(p, words[i].rect) < words[i].rect.height * 1.0 ? i : nil
    }

    static func hDist(_ p: CGPoint, _ r: CGRect) -> CGFloat {
        p.x < r.minX ? r.minX - p.x : (p.x > r.maxX ? p.x - r.maxX : 0)
    }

    static func dist(_ p: CGPoint, _ r: CGRect) -> CGFloat {
        let dx = hDist(p, r)
        let dy = p.y < r.minY ? r.minY - p.y : (p.y > r.maxY ? p.y - r.maxY : 0)
        return (dx * dx + dy * dy).squareRoot()
    }

    /// The current line's box: union of neighbouring word boxes on the same row.
    /// `rects[i] == nil` means unknown (stops the scan).
    public static func lineRect(rects: [CGRect?], index: Int, reach: Int = 40) -> CGRect? {
        guard rects.indices.contains(index), let r = rects[index] else { return nil }
        var u = r
        func sameLine(_ j: Int) -> CGRect? {
            guard let q = rects[j], abs(q.midY - r.midY) < r.height * 0.5 else { return nil }
            return q
        }
        var j = index - 1
        while j >= max(0, index - reach), let q = sameLine(j) { u = u.union(q); j -= 1 }
        j = index + 1
        while j < min(rects.count, index + reach), let q = sameLine(j) { u = u.union(q); j += 1 }
        return u
    }
}
