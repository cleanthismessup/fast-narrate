import AppKit
import CoreText
import FastNarrateCore
import ScreenCaptureKit
import Vision

enum CaptureError: Error { case noPermission, noDisplay }

enum ScreenCapture {
    /// Captures `rect` (Cocoa global coordinates) from `screen` at native resolution.
    /// Callers must have checked `CGPreflightScreenCaptureAccess()` first.
    static func image(of rect: CGRect, screen: ScreenInfo, excludeSelf: Bool) async throws -> CGImage {
        guard CGPreflightScreenCaptureAccess() else { throw CaptureError.noPermission }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == screen.displayID }) else {
            throw CaptureError.noDisplay
        }
        let me = excludeSelf ? content.applications.filter { $0.processID == getpid() } : []
        let filter = SCContentFilter(display: display, excludingApplications: me, exceptingWindows: [])
        let cfg = SCStreamConfiguration()
        let f = screen.frame
        cfg.sourceRect = CGRect(x: rect.minX - f.minX, y: f.maxY - rect.maxY, width: rect.width, height: rect.height)
        cfg.width = Int((rect.width * screen.scale).rounded())
        cfg.height = Int((rect.height * screen.scale).rounded())
        cfg.showsCursor = false
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)
    }
}

enum OCREngine {
    static let queue = DispatchQueue(label: "fastnarrate.ocr", qos: .userInitiated)
    private static var warmSizes = Set<String>()
    private static let lock = NSLock()

    static var isWarm: Bool {
        lock.lock(); defer { lock.unlock() }
        return !warmSizes.isEmpty
    }

    /// Recognises text. `frame` is where the image sits on screen (Cocoa points).
    /// Lines touching a cut edge of the image are dropped (they'd be half-read).
    static func recognizeSync(_ img: CGImage, frame: CGRect, keepTopEdge: Bool, keepBottomEdge: Bool) -> [OCRLine] {
        let req = VNRecognizeTextRequest()
        req.recognitionLevel = .accurate
        req.usesLanguageCorrection = true
        req.automaticallyDetectsLanguage = true
        let handler = VNImageRequestHandler(cgImage: img, options: [:])
        do { try handler.perform([req]) } catch {
            appLog.error("OCR failed: \(error.localizedDescription, privacy: .public)")
            return []
        }
        lock.lock(); warmSizes.insert("\(img.width)x\(img.height)"); lock.unlock()

        var lines: [OCRLine] = []
        for obs in req.results ?? [] {
            guard let cand = obs.topCandidates(1).first else { continue }
            let bb = obs.boundingBox
            if !keepBottomEdge && bb.minY < 0.004 { continue }
            if !keepTopEdge && bb.maxY > 0.996 { continue }
            let s = cand.string
            var words: [OCRWord] = []
            for t in Tokenizer.tokens(in: s as NSString) {
                guard let r = Range(t.range, in: s),
                      let box = (try? cand.boundingBox(for: r))??.boundingBox else { continue }
                words.append(OCRWord(text: t.text, rect: map(box, into: frame)))
            }
            if !words.isEmpty { lines.append(OCRLine(words: words)) }
        }
        return lines
    }

    static func recognize(_ img: CGImage, frame: CGRect, keepTopEdge: Bool, keepBottomEdge: Bool) async -> [OCRLine] {
        await withCheckedContinuation { c in
            queue.async {
                c.resume(returning: recognizeSync(img, frame: frame, keepTopEdge: keepTopEdge, keepBottomEdge: keepBottomEdge))
            }
        }
    }

    static func map(_ n: CGRect, into f: CGRect) -> CGRect {
        CGRect(x: f.minX + n.minX * f.width, y: f.minY + n.minY * f.height,
               width: n.width * f.width, height: n.height * f.height)
    }

    /// The first OCR per image size compiles Vision's model (~30s on a fresh binary).
    /// Do it in the background at launch for the sizes we actually use.
    static func warmUp(screens: [ScreenInfo]) {
        var sizes: [CGSize] = []
        for s in screens {
            let tile = OCRLocator.tileRect(around: CGPoint(x: s.frame.midX, y: s.frame.midY), in: s.frame)
            sizes.append(CGSize(width: (tile.width * s.scale).rounded(), height: (tile.height * s.scale).rounded()))
            sizes.append(CGSize(width: (s.frame.width * s.scale).rounded(), height: (s.frame.height * s.scale).rounded()))
        }
        var seen = Set<String>()
        sizes = sizes.filter { seen.insert("\($0.width)x\($0.height)").inserted }
        DispatchQueue.global(qos: .utility).async {
            for size in sizes {
                guard let img = sampleImage(size) else { continue }
                let t = CACurrentMediaTime()
                queue.sync { _ = recognizeSync(img, frame: CGRect(origin: .zero, size: size), keepTopEdge: true, keepBottomEdge: true) }
                perfLog.info("OCR warm-up \(Int(size.width))x\(Int(size.height)) took \(Int((CACurrentMediaTime() - t) * 1000)) ms")
            }
        }
    }

    private static func sampleImage(_ size: CGSize) -> CGImage? {
        let w = Int(size.width), h = Int(size.height)
        guard w > 0, h > 0, let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                                space: CGColorSpaceCreateDeviceRGB(),
                                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        let font = CTFontCreateWithName("Helvetica" as CFString, 36, nil)
        let str = NSAttributedString(string: "Fast Narrate warms up text recognition.",
                                     attributes: [.font: font, .foregroundColor: CGColor(gray: 0, alpha: 1)])
        let line = CTLineCreateWithAttributedString(str)
        ctx.textPosition = CGPoint(x: 40, y: CGFloat(h) / 2)
        CTLineDraw(line, ctx)
        return ctx.makeImage()
    }
}

enum OCRLocator {
    /// Fixed-size band around the pointer: full screen width, up to 900pt tall,
    /// starting a little above the pointer (reading goes down).
    static func tileRect(around p: CGPoint, in f: CGRect) -> CGRect {
        let h = min(900, f.height)
        var top = min(f.maxY, p.y + 150)
        var bottom = top - h
        if bottom < f.minY { bottom = f.minY; top = bottom + h }
        return CGRect(x: f.minX, y: bottom, width: f.width, height: h)
    }

    static func locate(at p: CGPoint, screen: ScreenInfo) async -> (WordProvider, [ReadWord])? {
        let tile = tileRect(around: p, in: screen.frame)
        let t0 = CACurrentMediaTime()
        guard let img = try? await ScreenCapture.image(of: tile, screen: screen, excludeSelf: true) else { return nil }
        let t1 = CACurrentMediaTime()
        let lines = await OCREngine.recognize(img, frame: tile,
                                              keepTopEdge: tile.maxY >= screen.frame.maxY - 1,
                                              keepBottomEdge: tile.minY <= screen.frame.minY + 1)
        let t2 = CACurrentMediaTime()
        perfLog.info("OCR capture \(Int((t1 - t0) * 1000)) ms, recognise \(Int((t2 - t1) * 1000)) ms, lines \(lines.count)")
        let words = Layout.readingWords(lines)
        guard let i = Layout.hitTest(p, words: words) else { return nil }
        return (OCRProvider(), words[i...].map { ReadWord(text: $0.text, rect: $0.rect) })
    }

    /// Full-screen scan used to re-anchor after scrolling.
    static func scanScreen(_ screen: ScreenInfo) async -> [OCRWord] {
        guard let img = try? await ScreenCapture.image(of: screen.frame, screen: screen, excludeSelf: true) else { return [] }
        let lines = await OCREngine.recognize(img, frame: screen.frame, keepTopEdge: true, keepBottomEdge: true)
        return Layout.readingWords(lines)
    }
}
