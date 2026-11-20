import AppKit
import FastNarrateCore

/// One word being read. `rect` is in Cocoa screen coordinates.
struct ReadWord {
    var text: String
    var rect: CGRect?
    /// Source-specific handle used to re-query the live position (NSValue range or AX text-marker range).
    var handle: AnyObject?
    /// Which scroll "generation" `rect` belongs to (see ReaderController).
    var rectGen = 0
}

/// Supplies words to read, lazily.
protocol WordProvider: AnyObject {
    var sourceName: String { get }
    /// True when word positions can be re-queried live (Accessibility), so scrolling just works.
    var supportsLiveRects: Bool { get }
    var isExhausted: Bool { get }
    /// Called on a background queue.
    func fetchMore(max: Int) -> [ReadWord]
    /// May be called from any thread.
    func liveRect(for word: ReadWord) -> CGRect?
}

// MARK: - Native text (Notes, TextEdit, Pages, Mail, Xcode…)

/// Standard Accessibility text: AXValue + AXRangeForPosition + AXBoundsForRange.
final class NativeTextProvider: WordProvider {
    let sourceName = "Accessibility"
    let supportsLiveRects = true
    private let el: AXUIElement
    private let text: NSString
    private let primaryHeight: CGFloat
    private var cursor: Int
    private let end: Int
    private var produced = 0
    private let cap = 5000

    var isExhausted: Bool { cursor >= end || produced >= cap }

    private init(el: AXUIElement, text: NSString, start: Int, end: Int? = nil, primaryHeight: CGFloat) {
        self.el = el
        self.text = text
        self.cursor = start
        self.end = min(end ?? text.length, text.length)
        self.primaryHeight = primaryHeight
    }

    /// The selected text of a native text element.
    static func selection(in el: AXUIElement, primaryHeight: CGFloat) -> (NativeTextProvider, [ReadWord])? {
        guard AX.paramNames(el).contains(kAXBoundsForRangeParameterizedAttribute),
              let s = AX.attr(el, kAXValueAttribute) as? String, !s.isEmpty,
              let r = AX.range(AX.attr(el, kAXSelectedTextRangeAttribute)), r.length > 0 else { return nil }
        let p = NativeTextProvider(el: el, text: s as NSString, start: r.location, end: r.location + r.length, primaryHeight: primaryHeight)
        let first = p.fetchMore(max: 15)
        return first.isEmpty ? nil : (p, first)
    }

    /// Start of the paragraph (or else the sentence) containing `loc`, if it's on screen.
    private func sectionStart(containing loc: Int, visible: (CGRect) -> Bool) -> Int {
        let para = text.paragraphRange(for: NSRange(location: loc, length: 0))
        var sentence = para.location
        text.enumerateSubstrings(in: para, options: [.bySentences, .substringNotRequired]) { _, r, _, stop in
            if r.location <= loc { sentence = r.location } else { stop.pointee = true }
        }
        for c in [para.location, sentence] where c < loc {
            if let t = Tokenizer.tokens(in: text, from: c, limit: 1).first, let r = rect(for: t.range), visible(r) {
                return t.range.location
            }
        }
        return loc
    }

    static func make(from hit: AXUIElement, at axPoint: CGPoint, primaryHeight: CGFloat,
                     visible: @escaping (CGRect) -> Bool) -> (NativeTextProvider, [ReadWord])? {
        var el: AXUIElement? = hit
        for _ in 0..<4 {
            guard let cur = el else { break }
            let names = AX.paramNames(cur)
            if names.contains(kAXRangeForPositionParameterizedAttribute),
               names.contains(kAXBoundsForRangeParameterizedAttribute),
               let s = AX.attr(cur, kAXValueAttribute) as? String, !s.isEmpty,
               let r = AX.range(AX.param(cur, kAXRangeForPositionParameterizedAttribute, AX.value(axPoint))),
               r.location >= 0, r.location < (s as NSString).length {
                let ns = s as NSString
                let wordAt = Tokenizer.wordStart(in: ns, at: r.location)
                let probe = NativeTextProvider(el: cur, text: ns, start: wordAt, primaryHeight: primaryHeight)
                // Only accept if the word is really near the pointer (guards against odd elements).
                if let t = Tokenizer.tokens(in: ns, from: wordAt, limit: 1).first, let r0 = probe.rect(for: t.range) {
                    let pc = CGPoint(x: axPoint.x, y: primaryHeight - axPoint.y)
                    guard r0.insetBy(dx: -r0.height * 4, dy: -r0.height * 1.5).contains(pc) else { return nil }
                }
                // Read the whole section, not from the exact word.
                let start = probe.sectionStart(containing: wordAt, visible: visible)
                let p = NativeTextProvider(el: cur, text: ns, start: start, primaryHeight: primaryHeight)
                let first = p.fetchMore(max: 15)
                return first.isEmpty ? nil : (p, first)
            }
            el = AX.parent(cur)
        }
        return nil
    }

    func fetchMore(max: Int) -> [ReadWord] {
        guard !isExhausted else { return [] }
        let toks = Tokenizer.tokens(in: text, from: cursor, limit: min(max, cap - produced))
            .filter { $0.range.location < end }
        cursor = toks.count < max ? end : NSMaxRange(toks[toks.count - 1].range)
        produced += toks.count
        return toks.map { ReadWord(text: $0.text, rect: rect(for: $0.range), handle: NSValue(range: $0.range)) }
    }

    func liveRect(for word: ReadWord) -> CGRect? {
        guard let v = word.handle as? NSValue else { return nil }
        return rect(for: v.rangeValue)
    }

    private func rect(for r: NSRange) -> CGRect? {
        let v = AX.param(el, kAXBoundsForRangeParameterizedAttribute, AX.value(CFRange(location: r.location, length: r.length)))
        return AX.rect(v).flatMap { AX.cocoa($0, primaryHeight: primaryHeight) }
    }
}

// MARK: - Web content (Safari, Chrome, Electron)

/// WebKit/Chromium text markers: walk word by word from the pointer.
final class WebTextProvider: WordProvider {
    /// Logs every step (used by `--ax-probe`).
    static var verbose = false
    private static func v(_ s: @autoclosure () -> String) { if verbose { Trace.log("web: " + s()) } }

    let sourceName = "Accessibility (web)"
    let supportsLiveRects = true
    private let host: AXUIElement
    private var cursor: CFTypeRef
    private let primaryHeight: CGFloat
    private var produced = 0
    private var done = false
    private let cap: Int

    var isExhausted: Bool { done || produced >= cap }

    private init(host: AXUIElement, cursor: CFTypeRef, primaryHeight: CGFloat, maxWords: Int? = nil) {
        self.host = host
        self.cursor = cursor
        self.primaryHeight = primaryHeight
        self.cap = maxWords ?? 4000
    }

    /// The selected text in a web view: starts at the selection and reads `words` words.
    static func selection(from focused: AXUIElement, words: Int, primaryHeight: CGFloat) -> (WebTextProvider, [ReadWord])? {
        var el: AXUIElement? = focused
        for _ in 0..<14 {
            guard let cur = el else { break }
            if let r = AX.attr(cur, "AXSelectedTextMarkerRange"), let start = AX.rangeStart(r),
               let end = AX.rangeEnd(r), !CFEqual(start, end) {
                let p = WebTextProvider(host: cur, cursor: start, primaryHeight: primaryHeight, maxWords: max(1, words))
                let first = p.fetchMore(max: 15)
                v("selection: \(first.map(\.text))")
                return first.isEmpty ? nil : (p, first)
            }
            el = AX.parent(cur)
        }
        return nil
    }

    static func make(from hit: AXUIElement, at axPoint: CGPoint, primaryHeight: CGFloat,
                     visible: @escaping (CGRect) -> Bool) -> (WebTextProvider, [ReadWord])? {
        // The deepest element that speaks text markers, plus its ancestors up to the web area.
        var chain: [AXUIElement] = []
        var el: AXUIElement? = hit
        for _ in 0..<12 {
            guard let cur = el else { break }
            if AX.paramNames(cur).contains("AXTextMarkerForPosition") {
                chain.append(cur)
                if (AX.attr(cur, kAXRoleAttribute) as? String) == "AXWebArea" { break }
            }
            el = AX.parent(cur)
        }
        guard let host = chain.first else { v("no text-marker host"); return nil }
        guard let wordAt = startMarker(chain: chain, at: axPoint) else { v("no start marker"); return nil }
        let start = sectionStart(host: host, from: wordAt, primaryHeight: primaryHeight, visible: visible)
        let p = WebTextProvider(host: host, cursor: start, primaryHeight: primaryHeight)
        let first = p.fetchMore(max: 12)
        v("first words: \(first.map(\.text)) rects: \(first.prefix(3).map { $0.rect.map { "\($0.integral)" } ?? "nil" })")
        return first.isEmpty ? nil : (p, first)
    }

    /// Start of the paragraph (or else the sentence) around `m`, if it's on screen.
    private static func sectionStart(host: AXUIElement, from m: CFTypeRef, primaryHeight: CGFloat,
                                     visible: (CGRect) -> Bool) -> CFTypeRef {
        for name in ["AXParagraphTextMarkerRangeForTextMarker", "AXSentenceTextMarkerRangeForTextMarker"] {
            guard let r = AX.param(host, name, m), let s = AX.rangeStart(r), !CFEqual(s, m),
                  let e = AX.param(host, "AXNextWordEndTextMarkerForTextMarker", s),
                  let w = AX.param(host, "AXLeftWordTextMarkerRangeForTextMarker", e),
                  let b = AX.rect(AX.param(host, "AXBoundsForTextMarkerRange", w)).flatMap({ AX.cocoa($0, primaryHeight: primaryHeight) }),
                  plausible(b, chars: 20), visible(b) else { continue }
            v("section start via \(name)")
            return s
        }
        return m
    }

    /// Marker at the start of the word under the pointer. Safari answers AXTextMarkerForPosition;
    /// Chromium/Electron usually don't, so fall back to bounds and then to walking the element's words.
    private static func startMarker(chain: [AXUIElement], at pt: CGPoint) -> CFTypeRef? {
        let host = chain[0]
        func wordStart(_ m: CFTypeRef) -> CFTypeRef? {
            for name in ["AXLeftWordTextMarkerRangeForTextMarker", "AXRightWordTextMarkerRangeForTextMarker"] {
                if let wr = AX.param(host, name, m),
                   let b = AX.rect(AX.param(host, "AXBoundsForTextMarkerRange", wr)),
                   b.insetBy(dx: -3, dy: -3).contains(pt),
                   let s = AX.rangeStart(wr) { return s }
            }
            return nil
        }

        // 1. Position → marker (Safari / WebKit).
        for e in chain {
            if let m = AX.param(e, "AXTextMarkerForPosition", AX.value(pt)) {
                v("marker via position")
                return wordStart(m) ?? m
            }
        }
        // 2. A tiny rect at the pointer → marker.
        let tiny = CGRect(x: pt.x - 1, y: pt.y - 1, width: 2, height: 2)
        for e in chain {
            if let m = AX.param(e, "AXStartTextMarkerForBounds", AX.value(tiny)), let s = wordStart(m) {
                v("marker via bounds")
                return s
            }
        }
        // 3. Find the text leaf under the pointer and walk its words until one contains it.
        var leaf: AXUIElement?
        var base: AXUIElement? = host
        for _ in 0..<4 where leaf == nil {   // hit may be an empty group: retry from its ancestors
            guard let b = base else { break }
            leaf = textLeaf(at: pt, in: b, depth: 0)
            base = AX.parent(b)
        }
        guard let leaf else { v("no text leaf under pointer"); return nil }
        let leafLen = (AX.attr(leaf, kAXValueAttribute) as? String)?.count ?? 200
        guard let range = AX.param(host, "AXTextMarkerRangeForUIElement", leaf),
              var cur = AX.rangeStart(range) else {
            v("no element range")
            return nil
        }
        let elementEnd = AX.rangeEnd(range)
        var nearest: (d: CGFloat, m: CFTypeRef)?
        let deadline = CACurrentMediaTime() + 0.08 // never let a huge element stall the hotkey
        v("walk pt=\(Int(pt.x)),\(Int(pt.y)) leaf=\(leafLen) chars")
        for k in 0..<min(600, leafLen + 2) {
            if verbose, k < 12, let e = AX.param(host, "AXNextWordEndTextMarkerForTextMarker", cur),
               let w = AX.param(host, "AXLeftWordTextMarkerRangeForTextMarker", e) {
                v("  w\(k) “\(AX.param(host, "AXStringForTextMarkerRange", w) as? String ?? "nil")” \(AX.rect(AX.param(host, "AXBoundsForTextMarkerRange", w)).map { "\($0.integral)" } ?? "nil")")
            }
            if CACurrentMediaTime() > deadline { v("element walk timed out"); break }
            guard let end = AX.param(host, "AXNextWordEndTextMarkerForTextMarker", cur), !CFEqual(end, cur),
                  let wr = AX.param(host, "AXLeftWordTextMarkerRangeForTextMarker", end),
                  let ws = AX.rangeStart(wr) else { break }
            if let b = AX.rect(AX.param(host, "AXBoundsForTextMarkerRange", wr)), b.width > 0,
               plausible(b, chars: (AX.param(host, "AXStringForTextMarkerRange", wr) as? String)?.count ?? 1) {
                if b.insetBy(dx: -2, dy: -2).contains(pt) { v("marker via element walk"); return ws }
                // Closest word on the same line, so a pointer between words still works.
                if pt.y >= b.minY - 2, pt.y <= b.maxY + 2 {
                    let d = pt.x < b.minX ? b.minX - pt.x : pt.x - b.maxX
                    if nearest == nil || d < nearest!.d { nearest = (d, ws) }
                }
            }
            if let e = elementEnd, CFEqual(end, e) { break }
            cur = end
        }
        if let n = nearest, n.d < 40 { v("marker via nearest word (\(Int(n.d)) pt)"); return n.m }
        v("element walk found nothing")
        return nil
    }

    /// Chromium sometimes reports a whole block (or the page) as a "word's" bounds; that text is
    /// usually a hidden label or a duplicate of visible text, so it's skipped.
    private static func plausible(_ r: CGRect, chars: Int) -> Bool {
        r.height <= 64 && r.width <= max(80, CGFloat(chars) * 40)
    }

    /// Recent words, to drop text the page draws twice a few points apart (overlays, transitions).
    private var recent: [(text: String, rect: CGRect)] = []

    private func isEcho(_ s: String, _ r: CGRect) -> Bool {
        recent.contains { $0.text == s && abs($0.rect.minX - r.minX) <= 8 && abs($0.rect.minY - r.minY) <= 8 }
    }

    /// Deepest static-text element under the point (Chromium hit-tests to buttons/groups).
    private static func textLeaf(at pt: CGPoint, in el: AXUIElement, depth: Int) -> AXUIElement? {
        let role = AX.attr(el, kAXRoleAttribute) as? String
        if role == "AXStaticText" { return el }
        guard depth < 10, let kids = AX.attr(el, kAXChildrenAttribute) as? [AXUIElement] else { return nil }
        for k in kids.prefix(300) {
            guard let f = AX.frame(k), f.insetBy(dx: -2, dy: -2).contains(pt) else { continue }
            if let leaf = textLeaf(at: pt, in: k, depth: depth + 1) { return leaf }
        }
        return nil
    }

    func fetchMore(max: Int) -> [ReadWord] {
        var out: [ReadWord] = []
        var guardCount = 0
        while out.count < max, !isExhausted {
            guardCount += 1
            if guardCount > max * 8 { break }
            let end = AX.param(host, "AXNextWordEndTextMarkerForTextMarker", cursor)
            let same = end.map { CFEqual($0, cursor) } ?? false
            let wr = end.flatMap { AX.param(host, "AXLeftWordTextMarkerRangeForTextMarker", $0) }
            guard let end, !same, let wr else {
                Self.v("walk stopped: end=\(end != nil) same=\(same) range=\(wr != nil) after \(out.count) words")
                done = true
                break
            }
            cursor = end
            let raw = AX.param(host, "AXStringForTextMarkerRange", wr)
            let s = (raw as? String ?? "").replacingOccurrences(of: "\u{FFFC}", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if guardCount <= 3 { Self.v("word raw=\(raw.map { CFCopyDescription($0) as String? ?? "?" } ?? "nil")") }
            if s.isEmpty { continue }
            let hasWordChars = s.unicodeScalars.contains { CharacterSet.alphanumerics.contains($0) }
            if !hasWordChars {
                // Punctuation: attach to the previous word so timing pauses on it.
                if !out.isEmpty { out[out.count - 1].text += s }
                continue
            }
            // Skip text with no real on-screen box (hidden labels, collapsed sections, duplicates).
            guard let r = rect(wr), Self.plausible(r, chars: s.count) else { continue }
            if isEcho(s, r) { continue }
            recent.append((s, r))
            if recent.count > 80 { recent.removeFirst(recent.count - 80) }
            out.append(ReadWord(text: s, rect: r, handle: wr))
            produced += 1
        }
        return out
    }

    func liveRect(for word: ReadWord) -> CGRect? {
        guard let h = word.handle else { return nil }
        return rect(h)
    }

    private func rect(_ range: CFTypeRef) -> CGRect? {
        AX.rect(AX.param(host, "AXBoundsForTextMarkerRange", range)).flatMap { AX.cocoa($0, primaryHeight: primaryHeight) }
    }
}

// MARK: - OCR

final class OCRProvider: WordProvider {
    let sourceName = "OCR"
    let supportsLiveRects = false
    let isExhausted = true
    func fetchMore(max: Int) -> [ReadWord] { [] }
    func liveRect(for word: ReadWord) -> CGRect? { nil }
}

// MARK: - Locator

enum LocateOutcome {
    case found(WordProvider, [ReadWord])
    case needsAccessibility
    case needsScreenRecording
    case noText

    var summary: String {
        switch self {
        case .found(let p, let w):
            let first = w.prefix(4).map(\.text).joined(separator: " ")
            return "found via \(p.sourceName): \(w.count) words, first rect \(w.first?.rect.map { "\($0.integral)" } ?? "nil"), “\(first)…”"
        case .needsAccessibility: return "needs Accessibility"
        case .needsScreenRecording: return "needs Screen Recording"
        case .noText: return "no text"
        }
    }
}

final class TextLocator {
    private let queue = DispatchQueue(label: "fastnarrate.locate", qos: .userInteractive)
    private var enabledPIDs = Set<pid_t>() // only touched on `queue`

    /// `p` is in Cocoa screen coordinates. Completion runs on the main thread.
    func locate(at p: CGPoint, allowOCR: Bool, completion: @escaping (LocateOutcome) -> Void) {
        let h = Coords.primaryHeight
        let ax = Permissions.shared.ax
        let sr = Permissions.shared.sr
        let screen = Coords.screen(containing: p).map(ScreenInfo.init)
        let visible = Self.visibility()
        let finish: (LocateOutcome) -> Void = { o in DispatchQueue.main.async { completion(o) } }

        queue.async {
            if ax, let r = self.locateAX(p, primaryHeight: h, visible: visible) {
                finish(.found(r.0, r.1))
                return
            }
            guard sr else { finish(ax ? .needsScreenRecording : .needsAccessibility); return }
            guard allowOCR, let screen else { finish(.noText); return }
            Task {
                if let r = await OCRLocator.locate(at: p, screen: screen) { finish(.found(r.0, r.1)) }
                else { finish(.noText) }
            }
        }
    }

    /// Screen-visibility test usable off the main thread.
    private static func visibility() -> (CGRect) -> Bool {
        let frames = NSScreen.screens.map(\.frame)
        return { r in frames.contains { $0.insetBy(dx: 0, dy: 30).intersects(r) } }
    }

    /// Finds the user's selected text on screen so it can be highlighted where it is.
    /// `text` is the selection (from the Services menu). `p` is where the pointer is (Cocoa).
    func locateSelection(_ text: String, near p: CGPoint, completion: @escaping (LocateOutcome) -> Void) {
        let h = Coords.primaryHeight
        let ax = Permissions.shared.ax
        let sr = Permissions.shared.sr
        let screen = Coords.screen(containing: p).map(ScreenInfo.init)
        let finish: (LocateOutcome) -> Void = { o in DispatchQueue.main.async { completion(o) } }
        let ns = text as NSString
        let tokens = Tokenizer.tokens(in: ns, from: 0, limit: 20000).map(\.text)
        let wordCount = tokens.filter { $0.unicodeScalars.contains { CharacterSet.alphanumerics.contains($0) } }.count

        queue.async {
            if ax, let r = self.selectionAX(words: wordCount, primaryHeight: h) {
                finish(.found(r.0, r.1))
                return
            }
            guard sr else { finish(ax ? .needsScreenRecording : .needsAccessibility); return }
            guard let screen, !tokens.isEmpty else { finish(.noText); return }
            Task {
                let all = await OCRLocator.scanScreen(screen)
                let key = Array(tokens.prefix(6))
                if let k = Reanchor.find(remaining: key, in: all.map(\.text)) {
                    let slice = all[k..<min(all.count, k + max(1, tokens.count))]
                    Trace.log("selection via OCR at word \(k), \(slice.count) words")
                    finish(.found(OCRProvider(), slice.map { ReadWord(text: $0.text, rect: $0.rect) }))
                } else {
                    finish(.noText)
                }
            }
        }
    }

    private func selectionAX(words: Int, primaryHeight h: CGFloat) -> (WordProvider, [ReadWord])? {
        let sys = AXUIElementCreateSystemWide()
        var focused = AX.attr(sys, kAXFocusedUIElementAttribute).flatMap { CFGetTypeID($0) == AXUIElementGetTypeID() ? ($0 as! AXUIElement) : nil }
        if focused == nil, let app = NSWorkspace.shared.frontmostApplication {
            let a = AXUIElementCreateApplication(app.processIdentifier)
            focused = AX.attr(a, kAXFocusedUIElementAttribute).flatMap { CFGetTypeID($0) == AXUIElementGetTypeID() ? ($0 as! AXUIElement) : nil }
        }
        guard let el = focused else { Trace.log("selection: no focused element"); return nil }
        Trace.log("selection: focused \(AX.attr(el, kAXRoleAttribute) as? String ?? "?") in pid \(AX.pid(el))")
        if let r = NativeTextProvider.selection(in: el, primaryHeight: h) { return r }
        if let r = WebTextProvider.selection(from: el, words: words, primaryHeight: h) { return r }
        return nil
    }

    /// `--ax-probe`: run the Accessibility lookup at a Cocoa point with full tracing.
    func probe(_ p: CGPoint) {
        WebTextProvider.verbose = true
        let t = CACurrentMediaTime()
        let r = locateAX(p, primaryHeight: Coords.primaryHeight, visible: Self.visibility())
        if let (prov, _) = r { Trace.log("probe next: " + prov.fetchMore(max: 40).map { "\($0.text)@\(Int($0.rect?.minX ?? -1)),\(Int($0.rect?.minY ?? -1))" }.joined(separator: " ")) }
        Trace.log("probe \(Int(p.x)),\(Int(p.y)) → \(r.map { LocateOutcome.found($0.0, $0.1).summary } ?? "nil") in \(Int((CACurrentMediaTime() - t) * 1000)) ms")
    }

    private func locateAX(_ p: CGPoint, primaryHeight h: CGFloat, visible: @escaping (CGRect) -> Bool) -> (WordProvider, [ReadWord])? {
        let axp = CGPoint(x: p.x, y: h - p.y)
        guard let hit = AX.element(atAX: axp) else {
            Trace.log("AX: no element at \(Int(axp.x)),\(Int(axp.y))")
            return nil
        }
        let pid = AX.pid(hit)
        let role = AX.attr(hit, kAXRoleAttribute) as? String ?? "?"
        let app = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? "pid \(pid)"
        Trace.log("AX: hit \(role) in \(app); params: \(AX.paramNames(hit).joined(separator: ","))")
        if pid == getpid() { return nil }

        var newlyEnabled = false
        if !enabledPIDs.contains(pid) {
            enabledPIDs.insert(pid)
            // Chromium / Electron only build their web accessibility tree when asked.
            let app = AXUIElementCreateApplication(pid)
            newlyEnabled = AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue) == .success
        }

        if let r = NativeTextProvider.make(from: hit, at: axp, primaryHeight: h, visible: visible) { return r }
        if let r = WebTextProvider.make(from: hit, at: axp, primaryHeight: h, visible: visible) { return r }
        if newlyEnabled {
            usleep(200_000)
            if let hit2 = AX.element(atAX: axp), let r = WebTextProvider.make(from: hit2, at: axp, primaryHeight: h, visible: visible) { return r }
        }
        return nil
    }
}
