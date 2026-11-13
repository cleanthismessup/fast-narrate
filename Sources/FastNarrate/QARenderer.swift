import AppKit
import FastNarrateCore

/// `FastNarrate --render-qa <dir>`: offline visual check without any permissions.
/// Draws a synthetic two-column page, runs the real OCR + layout pipeline on it, then renders
/// every highlight style on top and saves PNGs.
enum QARenderer {
    static let size = CGSize(width: 1440, height: 900)
    static let scale: CGFloat = 2

    static func run(outDir: String) -> Bool {
        let dir = URL(fileURLWithPath: outDir, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        guard let page = makePage() else { print("could not draw page"); return false }
        save(page, dir.appendingPathComponent("page.png"))

        var t = CACurrentMediaTime()
        let lines = OCREngine.recognizeSync(page, frame: CGRect(origin: .zero, size: size), keepTopEdge: true, keepBottomEdge: true)
        print(String(format: "OCR (first run, includes model compile): %.0f ms, %d lines", (CACurrentMediaTime() - t) * 1000, lines.count))
        t = CACurrentMediaTime()
        _ = OCREngine.recognizeSync(page, frame: CGRect(origin: .zero, size: size), keepTopEdge: true, keepBottomEdge: true)
        print(String(format: "OCR (warm): %.0f ms", (CACurrentMediaTime() - t) * 1000))

        let words = Layout.readingWords(lines)
        print("Reading order (\(words.count) words):")
        print("  " + words.map(\.text).joined(separator: " "))

        guard let start = words.firstIndex(where: { $0.text.hasPrefix("Highlighting") }) else {
            print("FAIL: anchor word not found"); return false
        }
        let pointer = CGPoint(x: words[start].rect.midX, y: words[start].rect.midY)
        let hit = Layout.hitTest(pointer, words: words)
        print("Hit test at anchor → index \(hit.map(String.init) ?? "nil") (expected \(start))")

        // Word boxes debug image.
        if let boxes = compose(page: page, draw: { ctx in
            ctx.setLineWidth(1)
            for (i, w) in words.enumerated() {
                ctx.setStrokeColor(i == start ? CGColor(red: 1, green: 0, blue: 0, alpha: 1) : CGColor(red: 0, green: 0.4, blue: 1, alpha: 0.8))
                ctx.stroke(w.rect)
            }
        }) { save(boxes, dir.appendingPathComponent("ocr-boxes.png")) }

        // Each style, a few words into the paragraph.
        let current = min(start + 4, words.count - 1)
        let rects: [CGRect?] = words.map { $0.rect }
        let line = Layout.lineRect(rects: rects, index: current)
        for style in HighlightStyle.allCases {
            let hl = HighlightRenderer()
            hl.root.frame = CGRect(origin: .zero, size: size)
            hl.update(box: (line ?? words[current].rect).insetBy(dx: 0, dy: -3), line: line, style: style, animated: false)
            if let img = compose(page: page, draw: { ctx in
                hl.root.render(in: ctx)
            }) {
                save(img, dir.appendingPathComponent("overlay-\(style.rawValue).png"))
            }
        }
        print("Wrote PNGs to \(dir.path)")
        return hit == start
    }

    // MARK: Drawing

    private static func makePage() -> CGImage? {
        guard let ctx = bitmap() else { return nil }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(origin: .zero, size: size))
        let gc = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = gc

        let title: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 34, weight: .bold), .foregroundColor: NSColor.black]
        let para = NSMutableParagraphStyle()
        para.lineSpacing = 5
        para.paragraphSpacing = 16
        let body: [NSAttributedString.Key: Any] = [.font: NSFont(name: "Georgia", size: 18) ?? NSFont.systemFont(ofSize: 18),
                                                   .foregroundColor: NSColor(white: 0.1, alpha: 1), .paragraphStyle: para]
        NSAttributedString(string: "Reading Faster With Your Eyes and Ears", attributes: title)
            .draw(at: CGPoint(x: 80, y: 800))

        let left = """
        Most people read silently at a steady pace, but attention drifts when a page is dense. A moving marker gives the eye a place to land and keeps the rhythm going.

        Highlighting each word as it is reached turns a wall of text into a guided path. Readers with dyslexia or tired eyes often find long articles much easier this way.
        """
        let right = """
        Captions repeat the current phrase in large type near the bottom of the screen, so the words can be followed from a distance or on a busy display.

        Silent mode keeps everything visual. It works in a quiet classroom, a library, or anywhere sound is not welcome, and the speed can be raised as confidence grows.
        """
        NSAttributedString(string: left, attributes: body)
            .draw(with: CGRect(x: 80, y: 120, width: 600, height: 640), options: [.usesLineFragmentOrigin])
        NSAttributedString(string: right, attributes: body)
            .draw(with: CGRect(x: 760, y: 120, width: 600, height: 640), options: [.usesLineFragmentOrigin])
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage()
    }

    private static func bitmap() -> CGContext? {
        let ctx = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale),
                            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        ctx?.scaleBy(x: scale, y: scale)
        return ctx
    }

    private static func compose(page: CGImage, draw: (CGContext) -> Void) -> CGImage? {
        guard let ctx = bitmap() else { return nil }
        ctx.draw(page, in: CGRect(origin: .zero, size: size))
        draw(ctx)
        return ctx.makeImage()
    }

    private static func save(_ img: CGImage, _ url: URL) {
        try? NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])?.write(to: url)
    }
}
