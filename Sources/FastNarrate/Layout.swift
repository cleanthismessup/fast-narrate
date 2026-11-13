import CoreGraphics
import Foundation

/// A recognised word. `rects` are in global Cocoa screen coordinates (origin bottom-left of the
/// primary display). Usually one rect; two when a hyphenated word wraps across lines; empty when
/// the word is currently not visible (e.g. scrolled away).
struct Word {
    var text: String
    var rects: [CGRect]
}

struct Line {
    var words: [Word]
    var rect: CGRect
}

/// A paragraph-like group of lines, read top to bottom.
struct Block {
    var lines: [Line]
    var rect: CGRect
    var words: [Word]

    init(lines: [Line]) {
        self.lines = lines
        rect = lines.map(\.rect).reduce(CGRect.null) { $0.union($1) }
        var ws: [Word] = []
        for line in lines {
            for (j, w) in line.words.enumerated() {
                // Re-join words hyphenated across a line break: "under-" + "standing".
                if j == 0, let last = ws.last, last.text.count > 2, last.text.hasSuffix("-"),
                   let first = w.text.first, first.isLowercase {
                    ws[ws.count - 1] = Word(text: String(last.text.dropLast()) + w.text,
                                            rects: last.rects + w.rects)
                } else {
                    ws.append(w)
                }
            }
        }
        words = ws
    }

    var averageLineHeight: CGFloat {
        lines.isEmpty ? 0 : lines.map(\.rect.height).reduce(0, +) / CGFloat(lines.count)
    }
}

enum Layout {
    // MARK: Grouping

    /// Groups OCR lines into reading blocks (paragraphs / columns), sorted in reading order.
    static func blocks(from raw: [Line]) -> [Block] {
        let lines = mergeRows(raw).sorted { $0.rect.maxY > $1.rect.maxY } // top first
        var groups: [[Line]] = []
        for line in lines {
            var best: Int?
            var bestGap = CGFloat.infinity
            for (i, group) in groups.enumerated() {
                guard let last = group.last else { continue }
                let lh = max(line.rect.height, last.rect.height)
                let gap = last.rect.minY - line.rect.maxY
                guard gap > -lh * 0.5, gap < lh * 0.9 else { continue }
                let ratio = lh / max(1, min(line.rect.height, last.rect.height))
                guard ratio < 1.5 else { continue }
                let overlap = horizontalOverlap(line.rect, last.rect)
                let leftAligned = abs(line.rect.minX - last.rect.minX) < lh * 1.5
                guard overlap > 0,
                      leftAligned || overlap > min(line.rect.width, last.rect.width) * 0.5 else { continue }
                if gap < bestGap { best = i; bestGap = gap }
            }
            if let i = best { groups[i].append(line) } else { groups.append([line]) }
        }
        return groups.map(Block.init(lines:)).sorted {
            abs($0.rect.maxY - $1.rect.maxY) < 4 ? $0.rect.minX < $1.rect.minX : $0.rect.maxY > $1.rect.maxY
        }
    }

    /// Vision sometimes splits one visual line into several observations (e.g. at a bold span).
    /// Stitch pieces that sit on the same row and nearly touch.
    static func mergeRows(_ lines: [Line]) -> [Line] {
        var out: [Line] = []
        for line in lines.sorted(by: { $0.rect.minX < $1.rect.minX }) {
            let h = line.rect.height
            if let i = out.firstIndex(where: { other in
                let oh = other.rect.height
                let sameRow = abs(other.rect.midY - line.rect.midY) < min(h, oh) * 0.35
                let similar = max(h, oh) / max(1, min(h, oh)) < 1.4
                let gap = line.rect.minX - other.rect.maxX
                return sameRow && similar && gap > -h * 0.3 && gap < h * 1.2
            }) {
                out[i].words += line.words
                out[i].rect = out[i].rect.union(line.rect)
            } else {
                out.append(line)
            }
        }
        return out
    }

    // MARK: Hit testing

    /// Finds the block and word under (or nearest to) a point.
    static func locate(_ p: CGPoint, in blocks: [Block], tolerance: CGFloat) -> (block: Int, word: Int)? {
        var bestBlock: Int?
        var bestArea = CGFloat.infinity
        for (i, b) in blocks.enumerated() where b.rect.insetBy(dx: -tolerance, dy: -tolerance).contains(p) {
            let area = b.rect.width * b.rect.height
            if area < bestArea { bestArea = area; bestBlock = i }
        }
        guard let bi = bestBlock else { return nil }
        let words = blocks[bi].words
        guard !words.isEmpty else { return nil }

        if let wi = words.firstIndex(where: { $0.rects.contains { $0.insetBy(dx: -2, dy: -2).contains(p) } }) {
            return (bi, wi)
        }
        // Prefer words on the same row as the pointer, then anything nearest.
        func dist(_ w: Word) -> CGFloat { w.rects.map { distance(p, $0) }.min() ?? .infinity }
        let sameRow = words.indices.filter { i in words[i].rects.contains { p.y >= $0.minY - 2 && p.y <= $0.maxY + 2 } }
        let pool = sameRow.isEmpty ? Array(words.indices) : sameRow
        let wi = pool.min { dist(words[$0]) < dist(words[$1]) }!
        return (bi, wi)
    }

    /// The block directly below `i` in the same column, if it is close enough to be a continuation.
    static func nextBlock(after i: Int, in blocks: [Block]) -> Int? {
        guard blocks.indices.contains(i) else { return nil }
        let cur = blocks[i].rect
        let maxGap = max(60, blocks[i].averageLineHeight * 5)
        let candidates = blocks.indices.filter { j in
            guard j != i else { return false }
            let r = blocks[j].rect
            let gap = cur.minY - r.maxY
            return gap > -4 && gap < maxGap && horizontalOverlap(r, cur) > min(r.width, cur.width) * 0.3
        }
        return candidates.max { blocks[$0].rect.maxY < blocks[$1].rect.maxY }
    }

    static func blockIndex(containing p: CGPoint, in blocks: [Block]) -> Int? {
        blocks.firstIndex { $0.rect.insetBy(dx: -4, dy: -4).contains(p) }
    }

    // MARK: Re-anchoring after scroll

    /// After the page moved, find where the words still to be read now sit on screen and update
    /// their rects. Returns false if the current position could not be found.
    @discardableResult
    static func realign(_ words: inout [Word], from idx: Int, to blocks: [Block]) -> Bool {
        let fresh = blocks.flatMap(\.words)
        guard idx < words.count, !fresh.isEmpty else { return false }
        let normOld = words.map { normalize($0.text) }
        let normNew = fresh.map { normalize($0.text) }
        let patLen = min(4, words.count - idx)
        let pattern = Array(normOld[idx..<idx + patLen])
        let oldCenter = words[idx].rects.first.map { CGPoint(x: $0.midX, y: $0.midY) }

        var anchor: Int?
        var bestDist = CGFloat.infinity
        if normNew.count >= patLen {
            for k in 0...(normNew.count - patLen) where Array(normNew[k..<k + patLen]) == pattern {
                let d = oldCenter.flatMap { c in fresh[k].rects.first.map { abs($0.midY - c.y) } } ?? 0
                if d < bestDist { bestDist = d; anchor = k }
            }
        }
        guard var k = anchor else { return false }

        for i in 0..<idx { words[i].rects = [] }
        var i = idx
        while i < words.count {
            guard k < fresh.count else { words[i].rects = []; i += 1; continue }
            if normOld[i] == normNew[k] {
                words[i].rects = fresh[k].rects; i += 1; k += 1; continue
            }
            if let a = (1...3).first(where: { k + $0 < fresh.count && normNew[k + $0] == normOld[i] }) {
                k += a; continue
            }
            if let b = (1...3).first(where: { i + $0 < words.count && normOld[i + $0] == normNew[k] }) {
                for s in i..<i + b { words[s].rects = [] }
                i += b; continue
            }
            words[i].rects = []; i += 1; k += 1
        }
        return true
    }

    // MARK: Geometry helpers

    static func horizontalOverlap(_ a: CGRect, _ b: CGRect) -> CGFloat {
        min(a.maxX, b.maxX) - max(a.minX, b.minX)
    }

    static func distance(_ p: CGPoint, _ r: CGRect) -> CGFloat {
        let dx = max(r.minX - p.x, 0, p.x - r.maxX)
        let dy = max(r.minY - p.y, 0, p.y - r.maxY)
        return hypot(dx, dy)
    }

    static func normalize(_ s: String) -> String {
        String(s.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }
}
