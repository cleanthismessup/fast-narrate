import AppKit

/// `Narrate --selftest`: renders sample text to an image and runs the real OCR + layout +
/// hit-test + scroll-realign pipeline on it, without needing Screen Recording permission.
enum SelfTest {
    static func run() -> Int32 {
        let size = CGSize(width: 1400, height: 760)
        let p1 = "Reading on screen takes time. Fast Narrate reads any text under your pointer aloud, highlighting each word as it is spoken, like subtitles that follow along."
        let p2 = "A second paragraph lives down here, separated by some space, so the layout analysis should treat it as its own block of text."
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.white.setFill()
            rect.fill()
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 30), .foregroundColor: NSColor.black]
            (p1 as NSString).draw(in: NSRect(x: 60, y: 420, width: 1280, height: 280), withAttributes: attrs)
            (p2 as NSString).draw(in: NSRect(x: 60, y: 360, width: 1280, height: 200), withAttributes: attrs)
            return true
        }
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            print("FAIL: could not render test image"); return 1
        }

        var failures = 0
        func check(_ ok: Bool, _ msg: String) {
            print(ok ? "  ok   \(msg)" : "  FAIL \(msg)")
            if !ok { failures += 1 }
        }

        let frame = CGRect(origin: .zero, size: size)
        let start = Date()
        let lines: [Line]
        do { lines = try OCR.lines(in: cg, mappedTo: frame) } catch {
            print("FAIL: OCR threw \(error)"); return 1
        }
        let blocks = Layout.blocks(from: lines)
        print(String(format: "OCR: %d lines, %d blocks in %.2fs", lines.count, blocks.count, Date().timeIntervalSince(start)))
        for (i, b) in blocks.enumerated() {
            print("  block \(i) \(b.rect.integral): \(b.words.map(\.text).joined(separator: " "))")
        }

        check(blocks.count == 2, "found 2 paragraphs")
        guard blocks.count == 2 else { return 1 }
        check(blocks[0].words.first?.text == "Reading", "first block starts with 'Reading'")
        check(blocks[1].words.first?.text == "A", "second block starts with 'A'")
        let widths = blocks[0].words.compactMap { $0.rects.first?.width }
        check(Set(widths.map { Int($0) }).count > 3, "words have distinct (per-word) boxes")

        // Hit test the centre of the word "pointer".
        if let wi = blocks[0].words.firstIndex(where: { $0.text.hasPrefix("pointer") }),
           let r = blocks[0].words[wi].rects.first {
            let hit = Layout.locate(CGPoint(x: r.midX, y: r.midY), in: blocks, tolerance: 2)
            check(hit?.block == 0 && hit?.word == wi, "pointer over 'pointer' hits that word")
        } else {
            check(false, "word 'pointer' recognised")
        }

        check(Layout.nextBlock(after: 0, in: blocks) == 1, "next paragraph after block 0 is block 1")

        // Simulate a 120pt scroll and re-anchor.
        let shifted = blocks.map { b in
            Block(lines: b.lines.map { l in
                Line(words: l.words.map { Word(text: $0.text, rects: $0.rects.map { $0.offsetBy(dx: 0, dy: 120) }) },
                     rect: l.rect.offsetBy(dx: 0, dy: 120))
            })
        }
        var words = blocks[0].words
        let idx = 5
        let before = words[idx + 2].rects.first!
        let ok = Layout.realign(&words, from: idx, to: shifted)
        let after = words[idx + 2].rects.first
        check(ok && after.map { abs($0.minY - before.minY - 120) < 1 } == true, "realign follows a scroll")

        let groups = SubtitleBar.groups(blocks[0].words.map(\.text))
        check(groups.allSatisfy { $0.count <= 6 }, "subtitle groups are ≤ 6 words (\(groups.count) groups)")

        print(failures == 0 ? "PASS" : "\(failures) failure(s)")
        return failures == 0 ? 0 : 1
    }
}
