import AppKit
import ScreenCaptureKit
import Vision

enum CaptureError: LocalizedError {
    case noDisplay
    case permissionDenied

    var errorDescription: String? {
        switch self {
        case .noDisplay: return "Couldn't find the display under the pointer."
        case .permissionDenied:
            return "Narrate needs Screen Recording permission (System Settings ▸ Privacy & Security). Relaunch after allowing it."
        }
    }
}

/// Captures a display (excluding Narrate's own overlays) and runs on-device OCR on it.
final class TextCapture {
    func recognizeLines(on screen: NSScreen) async throws -> [Line] {
        let image = try await captureImage(of: screen)
        let frame = screen.frame
        return try await Task.detached(priority: .userInitiated) {
            try OCR.lines(in: image, mappedTo: frame)
        }.value
    }

    private func captureImage(of screen: NSScreen) async throws -> CGImage {
        guard let id = screen.displayID else { throw CaptureError.noDisplay }
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            throw CaptureError.permissionDenied
        }
        guard let display = content.displays.first(where: { $0.displayID == id }) else {
            throw CaptureError.noDisplay
        }
        let pid = ProcessInfo.processInfo.processIdentifier
        let mine = content.applications.filter { $0.processID == pid }
        let filter = SCContentFilter(display: display, excludingApplications: mine, exceptingWindows: [])
        let config = SCStreamConfiguration()
        let scale = screen.backingScaleFactor
        config.width = Int(CGFloat(display.width) * scale)
        config.height = Int(CGFloat(display.height) * scale)
        config.showsCursor = false
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }

    static func containing(_ p: CGPoint) -> NSScreen? {
        screens.first { NSMouseInRect(p, $0.frame, false) }
    }
}

enum OCR {
    /// Recognises text in `image` and returns lines whose word rects are mapped into `frame`
    /// (the screen's frame in global Cocoa coordinates). Vision's normalised coordinates are
    /// bottom-left origin, like Cocoa, so the mapping is a plain scale + offset.
    static func lines(in image: CGImage, mappedTo frame: CGRect) throws -> [Line] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])

        func toGlobal(_ b: CGRect) -> CGRect {
            CGRect(x: frame.minX + b.minX * frame.width,
                   y: frame.minY + b.minY * frame.height,
                   width: b.width * frame.width,
                   height: b.height * frame.height)
        }

        var out: [Line] = []
        for obs in request.results ?? [] {
            guard let cand = obs.topCandidates(1).first, cand.confidence > 0.3 else { continue }
            let s = cand.string
            let tokens = tokenRanges(in: s)
            guard !tokens.isEmpty else { continue }
            let lineBox = obs.boundingBox

            var boxes = tokens.map { r in (try? cand.boundingBox(for: r))?.boundingBox ?? .zero }
            // If Vision gave us whole-line boxes for every word, fall back to splitting the line
            // proportionally by character offset.
            let degenerate = tokens.count > 1 && boxes.allSatisfy { $0 == .zero || $0.width >= lineBox.width * 0.9 }
            if degenerate {
                let n = CGFloat(max(1, s.count))
                boxes = tokens.map { r in
                    let a = CGFloat(s.distance(from: s.startIndex, to: r.lowerBound)) / n
                    let b = CGFloat(s.distance(from: s.startIndex, to: r.upperBound)) / n
                    return CGRect(x: lineBox.minX + a * lineBox.width, y: lineBox.minY,
                                  width: (b - a) * lineBox.width, height: lineBox.height)
                }
            }
            let words = zip(tokens, boxes).map { r, b in
                Word(text: String(s[r]), rects: [toGlobal(b == .zero ? lineBox : b)])
            }
            out.append(Line(words: words, rect: toGlobal(lineBox)))
        }
        return out
    }

    /// Vision compiles its model for each image size the first time it sees it (~30s on first
    /// launch). Run a throwaway recognition at each display's pixel size so real reads are fast.
    static func warmUp(pixelSize: CGSize) {
        let w = Int(pixelSize.width), h = Int(pixelSize.height)
        guard w > 0, h > 0, let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                                space: CGColorSpaceCreateDeviceRGB(),
                                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        ("Warming up text recognition for Narrate." as NSString).draw(
            at: CGPoint(x: 80, y: h / 2),
            withAttributes: [.font: NSFont.systemFont(ofSize: 40), .foregroundColor: NSColor.black])
        NSGraphicsContext.restoreGraphicsState()
        guard let image = ctx.makeImage() else { return }
        _ = try? lines(in: image, mappedTo: CGRect(x: 0, y: 0, width: w, height: h))
    }

    /// Whitespace-separated tokens (punctuation kept, so speech still pauses at commas/periods).
    static func tokenRanges(in s: String) -> [Range<String.Index>] {
        var out: [Range<String.Index>] = []
        var start: String.Index?
        var i = s.startIndex
        while i < s.endIndex {
            if s[i].isWhitespace {
                if let st = start { out.append(st..<i); start = nil }
            } else if start == nil {
                start = i
            }
            i = s.index(after: i)
        }
        if let st = start { out.append(st..<s.endIndex) }
        return out
    }
}
