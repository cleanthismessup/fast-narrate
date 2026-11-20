import CoreGraphics
import Foundation
import XCTest
@testable import FastNarrateCore

final class TokenizerTests: XCTestCase {
    func testSplitsOnWhitespaceKeepsPunctuationSkipsBullets() {
        let s = "Hello,  world.\n• Next — line" as NSString
        let t = Tokenizer.tokens(in: s)
        XCTAssertEqual(t.map(\.text), ["Hello,", "world.", "Next", "line"])
        XCTAssertEqual(s.substring(with: t[1].range), "world.")
    }

    func testFromOffsetAndLimit() {
        let s = "one two three four" as NSString
        let t = Tokenizer.tokens(in: s, from: 4, limit: 2)
        XCTAssertEqual(t.map(\.text), ["two", "three"])
    }

    func testWordStart() {
        let s = "alpha beta gamma" as NSString
        XCTAssertEqual(Tokenizer.wordStart(in: s, at: 8), 6)   // inside "beta"
        XCTAssertEqual(Tokenizer.wordStart(in: s, at: 5), 6)   // on the space
        XCTAssertEqual(Tokenizer.wordStart(in: s, at: 0), 0)
    }

    func testUTF16RangesWithEmoji() {
        let s = "hi 👋 there" as NSString
        let t = Tokenizer.tokens(in: s)
        XCTAssertEqual(t.map(\.text), ["hi", "there"])
        XCTAssertEqual(s.substring(with: t[1].range), "there")
    }
}

final class TimingTests: XCTestCase {
    func testPunctuationAndLengthAndSpeed() {
        let plain = SilentTiming.duration(of: "word", speed: 1)
        XCTAssertGreaterThan(SilentTiming.duration(of: "word.", speed: 1), plain)
        XCTAssertGreaterThan(SilentTiming.duration(of: "word,", speed: 1), plain)
        XCTAssertGreaterThan(SilentTiming.duration(of: "extraordinarily", speed: 1), plain)
        XCTAssertEqual(SilentTiming.duration(of: "word", speed: 2), plain / 2, accuracy: 1e-9)
        XCTAssertGreaterThan(SilentTiming.duration(of: "end.\"", speed: 1), plain)
    }

    func testAveragePaceIsNear250WPM() {
        let words = "The quick brown fox jumps over the lazy dog and keeps running far away".split(separator: " ").map(String.init)
        let avg = words.map { SilentTiming.duration(of: $0, speed: 1) }.reduce(0, +) / Double(words.count)
        XCTAssertEqual(avg, 60.0 / 250.0, accuracy: 0.06)
    }
}

final class CaptionChunkTests: XCTestCase {
    func testBreaksAtSentenceAndMax() {
        let w = "This is short. Then a much longer sentence goes on here".split(separator: " ").map(String.init)
        let c = CaptionChunks.chunks(for: w, maxWords: 5)
        XCTAssertEqual(c.first, 0..<3)
        XCTAssertEqual(c[1], 3..<8)
        XCTAssertEqual(c.last?.upperBound, w.count)
        XCTAssertEqual(CaptionChunks.chunkIndex(containing: 4, in: c), 1)
        XCTAssertNil(CaptionChunks.chunkIndex(containing: 99, in: c))
    }
}

final class ReanchorTests: XCTestCase {
    func testFindsSequenceIgnoringCaseAndPunctuation() {
        let fresh = ["Intro", "text", "the", "Quick", "brown,", "fox", "jumps"]
        XCTAssertEqual(Reanchor.find(remaining: ["quick", "brown", "fox", "jumps", "over"], in: fresh), 3)
    }

    func testFallsBackToShorterMatch() {
        let fresh = ["a", "quick", "brown", "cat"]
        XCTAssertEqual(Reanchor.find(remaining: ["quick", "brown", "fox", "jumps"], in: fresh), 1)
        XCTAssertNil(Reanchor.find(remaining: ["nothing", "here"], in: fresh))
    }
}

final class LayoutTests: XCTestCase {
    /// Builds a line of words starting at (x, y) with a fixed line height.
    func line(_ text: String, x: CGFloat, y: CGFloat, h: CGFloat = 20) -> OCRLine {
        var cx = x
        let words = text.split(separator: " ").map { w -> OCRWord in
            let width = CGFloat(w.count) * 10
            defer { cx += width + 8 }
            return OCRWord(text: String(w), rect: CGRect(x: cx, y: y, width: width, height: h))
        }
        return OCRLine(words: words)
    }

    func testTwoColumnsReadLeftColumnFirst() {
        let lines = [
            line("Big Title Here", x: 100, y: 900, h: 40),
            line("left one", x: 100, y: 820), line("left two", x: 100, y: 795), line("left three", x: 100, y: 770),
            line("right one", x: 700, y: 820), line("right two", x: 700, y: 795),
        ]
        let words = Layout.readingWords(lines).map(\.text)
        XCTAssertEqual(words, ["Big", "Title", "Here", "left", "one", "left", "two", "left", "three",
                               "right", "one", "right", "two"])
    }

    func testMergesSplitRowFragments() {
        let a = line("first half", x: 100, y: 500)
        let b = line("second half", x: 198 + 20, y: 500)   // "first half" ends at x=198
        let merged = Layout.mergeRows([b, a])
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].words.map(\.text), ["first", "half", "second", "half"])
    }

    func testHyphenJoinAcrossLines() {
        let lines = [line("an extra-", x: 100, y: 500), line("ordinary day", x: 100, y: 475)]
        XCTAssertEqual(Layout.readingWords(lines).map(\.text), ["an", "extraordinary", "day"])
    }

    func testKeepsRealHyphenBeforeCapital() {
        let lines = [line("New-", x: 100, y: 500), line("York city", x: 100, y: 475)]
        XCTAssertEqual(Layout.readingWords(lines).map(\.text), ["New-", "York", "city"])
    }

    func testHitTest() {
        let words = Layout.readingWords([line("alpha beta gamma", x: 100, y: 500)])
        // "beta" spans x 158...198
        XCTAssertEqual(Layout.hitTest(CGPoint(x: 170, y: 510), words: words), 1)
        // Slightly right of the line end: nearest on the row.
        XCTAssertEqual(Layout.hitTest(CGPoint(x: 300, y: 510), words: words), 2)
        // Far away: nothing.
        XCTAssertNil(Layout.hitTest(CGPoint(x: 170, y: 300), words: words))
    }

    func testLineRect() {
        let rects: [CGRect?] = [
            CGRect(x: 0, y: 100, width: 30, height: 20), CGRect(x: 40, y: 100, width: 30, height: 20),
            CGRect(x: 0, y: 70, width: 30, height: 20), nil,
        ]
        XCTAssertEqual(Layout.lineRect(rects: rects, index: 1), CGRect(x: 0, y: 100, width: 70, height: 20))
        XCTAssertEqual(Layout.lineRect(rects: rects, index: 2), CGRect(x: 0, y: 70, width: 30, height: 20))
        XCTAssertNil(Layout.lineRect(rects: rects, index: 3))
    }

    func testSmoothRectGlidesWithoutOvershoot() {
        var r = SmoothRect(CGRect(x: 0, y: 0, width: 40, height: 18), smoothTime: 0.075)
        r.target = CGRect(x: 100, y: 0, width: 60, height: 18)
        var xs: [CGFloat] = []
        for _ in 0..<60 { r.step(1.0 / 120); xs.append(r.value.minX) }
        XCTAssertEqual(zip(xs, xs.dropFirst()).filter { $0 > $1 }.count, 0, "moves forward only")
        XCTAssertLessThanOrEqual(xs.max()!, 100.0001, "no overshoot")
        XCTAssertGreaterThan(xs[17], 80, "most of the way within ~150 ms")
        for _ in 0..<120 { r.step(1.0 / 120) }
        XCTAssertTrue(r.isSettled)
    }

    func testBlockStartFindsParagraphStart() {
        XCTAssertEqual(Layout.blockStart(of: 7, blockStarts: [0, 5, 12]), 5)
        XCTAssertEqual(Layout.blockStart(of: 12, blockStarts: [0, 5, 12]), 12)
        XCTAssertEqual(Layout.blockStart(of: 3, blockStarts: [0, 5, 12]), 0)
    }
}
