import AppKit

/// `FastNarrate --render-styles <dir>`: renders every highlight style over sample text into PNGs,
/// using the real OCR + layout + HighlightView, so visuals can be reviewed without screen access.
@MainActor
enum StyleRender {
    static func run(outDir: String) -> Int32 {
        let size = CGSize(width: 1100, height: 520)
        let p1 = "Reading on screen takes time. Fast Narrate reads any text under your pointer aloud, highlighting each word as it is spoken, like subtitles that follow along."
        let p2 = "A second paragraph lives down here, so the focus style can dim it while the first one is being read."
        let sample = NSImage(size: size, flipped: false) { rect in
            NSColor.white.setFill(); rect.fill()
            let a: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 24), .foregroundColor: NSColor.black]
            (p1 as NSString).draw(in: NSRect(x: 50, y: 300, width: 1000, height: 180), withAttributes: a)
            (p2 as NSString).draw(in: NSRect(x: 50, y: 110, width: 1000, height: 140), withAttributes: a)
            return true
        }
        guard let cg = sample.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let lines = try? OCR.lines(in: cg, mappedTo: CGRect(origin: .zero, size: size)) else { return 1 }
        let blocks = Layout.blocks(from: lines)
        guard let words = blocks.first?.words, words.count > 12 else { print("OCR failed"); return 1 }
        let current = 12

        try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
        let s = Settings.shared
        let saved = (s.highlightStyle, s.highlightColor, s.showParagraphOutline)
        defer { (s.highlightStyle, s.highlightColor, s.showParagraphOutline) = saved }
        for style in Settings.HighlightStyle.allCases {
            for color in [Settings.HighlightColor.yellow, .blue] {
                s.highlightStyle = style; s.highlightColor = color; s.showParagraphOutline = true
                let view = HighlightView(frame: CGRect(origin: .zero, size: size))
                view.apply(words: words, current: current, visible: true)
                let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
                let ctx = NSGraphicsContext(bitmapImageRep: rep)!.cgContext
                ctx.draw(cg, in: CGRect(origin: .zero, size: size))
                view.layer?.render(in: ctx)
                let url = URL(fileURLWithPath: outDir).appendingPathComponent("\(style.rawValue)-\(color.rawValue).png")
                try? rep.representation(using: .png, properties: [:])?.write(to: url)
                print(url.path)
            }
        }
        return 0
    }
}
