import AppKit
import os

let bundleID = "io.github.cleanthismessup.fastnarrate"
let appLog = Logger(subsystem: bundleID, category: "app")
let perfLog = Logger(subsystem: bundleID, category: "perf")

/// Plain-text trace in ~/Library/Application Support/FastNarrate/debug.log (kept small),
/// so problems can be diagnosed after the fact ("check feedback").
enum Trace {
    static let url: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FastNarrate", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("debug.log")
    }()
    private static let queue = DispatchQueue(label: "fastnarrate.trace")
    private static let df: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    static func log(_ s: String) {
        let line = "\(df.string(from: Date())) \(s)\n"
        appLog.notice("\(s, privacy: .public)")
        queue.async {
            if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
               (attrs[.size] as? Int ?? 0) > 2_000_000 {
                try? FileManager.default.removeItem(at: url)
            }
            if let h = try? FileHandle(forWritingTo: url) {
                h.seekToEndOfFile()
                h.write(line.data(using: .utf8)!)
                try? h.close()
            } else {
                try? line.data(using: .utf8)!.write(to: url)
            }
        }
    }
}

// MARK: - Settings

enum HighlightStyle: String, CaseIterable {
    case invert, marker, underline, outline, focus
    var title: String { self == .invert ? "Invert Colors" : rawValue.capitalized }
}

final class Settings {
    static let shared = Settings()
    private let d = UserDefaults.standard

    static let speeds: [Double] = [0.5, 0.75, 1, 1.25, 1.5, 1.75, 2, 2.5, 3]

    var speed: Double {
        get { let v = d.double(forKey: "speed"); return v > 0 ? v : 1.0 }
        set { d.set(min(3, max(0.5, newValue)), forKey: "speed") }
    }
    var style: HighlightStyle {
        get {
            // v2 made Invert the default; an older stored "marker" was just the old default.
            if !d.bool(forKey: "styleV2") { d.set(true, forKey: "styleV2"); d.removeObject(forKey: "style") }
            return HighlightStyle(rawValue: d.string(forKey: "style") ?? "") ?? .invert
        }
        set { d.set(true, forKey: "styleV2"); d.set(newValue.rawValue, forKey: "style") }
    }
    var showHighlight: Bool {
        get { d.object(forKey: "showHighlight") as? Bool ?? true }
        set { d.set(newValue, forKey: "showHighlight") }
    }
    var followMouse: Bool {
        get { d.bool(forKey: "followMouse") }
        set { d.set(newValue, forKey: "followMouse") }
    }
}

// MARK: - Screens and coordinates

/// Snapshot of a screen, safe to pass to background work.
struct ScreenInfo {
    let frame: CGRect
    let scale: CGFloat
    let displayID: CGDirectDisplayID

    init(_ s: NSScreen) {
        frame = s.frame
        scale = s.backingScaleFactor
        displayID = (s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }
}

enum Coords {
    /// Height of the primary (menu bar) screen. Accessibility uses a top-left origin on it.
    static var primaryHeight: CGFloat { NSScreen.screens.first?.frame.height ?? 0 }

    static func screen(containing p: CGPoint) -> NSScreen? {
        NSScreen.screens.first { $0.frame.contains(p) } ?? NSScreen.main
    }
}

// MARK: - Accessibility helpers

enum AX {
    static func setGlobalTimeout(_ seconds: Float) {
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), seconds)
    }

    static func element(atAX p: CGPoint) -> AXUIElement? {
        var el: AXUIElement?
        let err = AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(p.x), Float(p.y), &el)
        return err == .success ? el : nil
    }

    static func attr(_ el: AXUIElement, _ name: String) -> CFTypeRef? {
        var v: CFTypeRef?
        return AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success ? v : nil
    }

    static func param(_ el: AXUIElement, _ name: String, _ p: CFTypeRef) -> CFTypeRef? {
        var v: CFTypeRef?
        return AXUIElementCopyParameterizedAttributeValue(el, name as CFString, p, &v) == .success ? v : nil
    }

    static func paramNames(_ el: AXUIElement) -> [String] {
        var names: CFArray?
        guard AXUIElementCopyParameterizedAttributeNames(el, &names) == .success else { return [] }
        return names as? [String] ?? []
    }

    static func parent(_ el: AXUIElement) -> AXUIElement? {
        guard let v = attr(el, kAXParentAttribute), CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }

    static func pid(_ el: AXUIElement) -> pid_t {
        var p: pid_t = 0
        AXUIElementGetPid(el, &p)
        return p
    }

    /// Element frame in Accessibility coordinates.
    static func frame(_ el: AXUIElement) -> CGRect? {
        if let r = rect(attr(el, "AXFrame")) { return r }
        var p = CGPoint.zero, s = CGSize.zero
        guard let pv = attr(el, kAXPositionAttribute), let sv = attr(el, kAXSizeAttribute),
              CFGetTypeID(pv) == AXValueGetTypeID(), CFGetTypeID(sv) == AXValueGetTypeID(),
              AXValueGetValue(pv as! AXValue, .cgPoint, &p), AXValueGetValue(sv as! AXValue, .cgSize, &s) else { return nil }
        return CGRect(origin: p, size: s)
    }

    static func value(_ p: CGPoint) -> AXValue {
        var p = p
        return AXValueCreate(.cgPoint, &p)!
    }

    static func value(_ r: CGRect) -> AXValue {
        var r = r
        return AXValueCreate(.cgRect, &r)!
    }

    static func value(_ r: CFRange) -> AXValue {
        var r = r
        return AXValueCreate(.cfRange, &r)!
    }

    static func rect(_ v: CFTypeRef?) -> CGRect? {
        guard let v, CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var r = CGRect.zero
        return AXValueGetValue(v as! AXValue, .cgRect, &r) ? r : nil
    }

    static func range(_ v: CFTypeRef?) -> CFRange? {
        guard let v, CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var r = CFRange()
        return AXValueGetValue(v as! AXValue, .cfRange, &r) ? r : nil
    }

    /// Start / end marker of a text-marker range. Uses the HIServices C functions, which work
    /// even where the app (Chromium/Electron) doesn't answer AXStartTextMarkerForTextMarkerRange.
    static func rangeStart(_ r: CFTypeRef) -> CFTypeRef? {
        guard CFGetTypeID(r) == AXTextMarkerRangeGetTypeID() else { return nil }
        return AXTextMarkerRangeCopyStartMarker(r as! AXTextMarkerRange)
    }

    static func rangeEnd(_ r: CFTypeRef) -> CFTypeRef? {
        guard CFGetTypeID(r) == AXTextMarkerRangeGetTypeID() else { return nil }
        return AXTextMarkerRangeCopyEndMarker(r as! AXTextMarkerRange)
    }

    /// Accessibility rect (top-left origin) → Cocoa rect (bottom-left origin).
    static func cocoa(_ r: CGRect, primaryHeight h: CGFloat) -> CGRect? {
        guard r.width > 0, r.height > 0 else { return nil }
        return CGRect(x: r.minX, y: h - r.maxY, width: r.width, height: r.height)
    }
}

// MARK: - Permissions

/// Rules (from the first attempt): always preflight, ask the system at most once per launch,
/// never re-open our own dialogs, always leave a way out through the menu.
final class Permissions {
    static let shared = Permissions()
    private(set) var askedAX = false
    private(set) var askedSR = false

    var ax: Bool { AXIsProcessTrusted() }
    var sr: Bool { CGPreflightScreenCaptureAccess() }

    func requestAXOnce() {
        guard !ax, !askedAX else { return }
        askedAX = true
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    func requestSROnce() {
        guard !sr, !askedSR else { return }
        askedSR = true
        _ = CGRequestScreenCaptureAccess()
    }

    func openAXSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    func openSRSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
    }

    private func open(_ s: String) {
        if let u = URL(string: s) { NSWorkspace.shared.open(u) }
    }
}
