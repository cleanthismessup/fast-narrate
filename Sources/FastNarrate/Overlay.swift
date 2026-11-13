import AppKit
import FastNarrateCore

/// Inverts whatever is on screen behind it (window-server backdrop, like vibrancy uses).
enum InvertLayer {
    static func make() -> CALayer? {
        guard let cls = NSClassFromString("CABackdropLayer") as? CALayer.Type,
              let fcls = NSClassFromString("CAFilter") as? NSObject.Type else { return nil }
        let sel = NSSelectorFromString("filterWithType:")
        guard fcls.responds(to: sel), let f = fcls.perform(sel, with: "colorInvert")?.takeUnretainedValue() else { return nil }
        let l = cls.init()
        l.setValue(true, forKey: "windowServerAware")
        l.filters = [f]
        return l
    }
}

/// One highlight box: an optional invert backdrop plus a styled frame layer.
private final class BoxLayer: CALayer {
    let invert = InvertLayer.make()
    let deco = CALayer()

    override init() {
        super.init()
        if let invert { addSublayer(invert) }
        addSublayer(deco)
        masksToBounds = true
        actions = HighlightRenderer.noActions
        invert?.actions = HighlightRenderer.noActions
        deco.actions = HighlightRenderer.noActions
    }
    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { fatalError() }

    func apply(style: HighlightStyle) {
        let inv = style == .invert && invert != nil
        invert?.isHidden = !inv
        deco.borderWidth = 0
        deco.cornerRadius = 0
        switch style {
        case .invert:
            cornerRadius = 5
            backgroundColor = inv ? nil : HighlightRenderer.markerColor   // fallback if invert unavailable
            deco.backgroundColor = nil
        case .marker:
            cornerRadius = 5
            backgroundColor = HighlightRenderer.markerColor
            deco.backgroundColor = nil
        case .underline:
            cornerRadius = 0
            backgroundColor = nil
            deco.backgroundColor = HighlightRenderer.accentColor
            deco.cornerRadius = 1.75
        case .outline:
            cornerRadius = 6
            backgroundColor = nil
            deco.backgroundColor = nil
            deco.borderWidth = 2.5
            deco.borderColor = HighlightRenderer.accentColor
            deco.cornerRadius = 6
        case .focus:
            cornerRadius = 5
            backgroundColor = NSColor(calibratedRed: 1.0, green: 0.84, blue: 0.0, alpha: 0.22).cgColor
            deco.backgroundColor = nil
        }
    }

    func layout(style: HighlightStyle) {
        invert?.frame = bounds
        deco.frame = style == .underline
            ? CGRect(x: 0, y: 0, width: bounds.width, height: 3.5)
            : bounds
    }
}

/// Draws the reading highlight with Core Animation layers. Shared by the live overlay and the QA renderer.
///
/// The box keeps one size per line and glides continuously (spring-smoothed, stepped every
/// display frame); the reader moves its target smoothly at reading pace. On a new line it
/// cross-fades instead of sweeping back across the text.
final class HighlightRenderer {
    let root = CALayer()
    private let dim = CAShapeLayer()
    private let mark = BoxLayer()
    private let ghost = BoxLayer()       // old position fading out on a line change
    private(set) var hasShown = false

    private var box = SmoothRect(.zero, smoothTime: 0.14)
    private var hole = SmoothRect(.zero, smoothTime: 0.2)
    private var style: HighlightStyle = .invert
    private var styled = false

    static let markerColor = NSColor(calibratedRed: 1.0, green: 0.84, blue: 0.0, alpha: 0.42).cgColor
    static let accentColor = NSColor(calibratedRed: 1.0, green: 0.55, blue: 0.0, alpha: 1.0).cgColor
    static let noActions: [String: CAAction] = [
        "position": NSNull(), "bounds": NSNull(), "frame": NSNull(), "path": NSNull(),
        "hidden": NSNull(), "backgroundColor": NSNull(), "borderWidth": NSNull(),
        "borderColor": NSNull(), "cornerRadius": NSNull(), "opacity": NSNull(), "sublayers": NSNull(),
    ]

    init() {
        dim.fillRule = .evenOdd
        dim.fillColor = NSColor.black.withAlphaComponent(0.5).cgColor
        dim.actions = Self.noActions
        root.actions = Self.noActions
        dim.isHidden = true
        mark.isHidden = true
        ghost.isHidden = true
        root.addSublayer(dim)
        root.addSublayer(ghost)
        root.addSublayer(mark)
    }

    /// `box` / `line` are in the root layer's coordinates (y up). Sets where the highlight is
    /// heading; `step(_:)` moves it each frame. `animated: false` jumps straight there.
    func update(box b: CGRect, line: CGRect?, style st: HighlightStyle, animated: Bool) {
        if st != style || !styled { style = st; styled = true; mark.apply(style: st); ghost.apply(style: st) }
        let holeTarget = line ?? b
        if !animated || !hasShown || mark.isHidden {
            box.snap(to: b)
            hole.snap(to: holeTarget)
            hasShown = true
            render()
        } else if abs(b.midY - box.target.midY) > max(b.height, box.target.height) * 0.6 {
            crossFade(to: b)
            hole.target = holeTarget
            render()
        } else {
            box.target = b
            hole.target = holeTarget
        }
    }

    /// Advances the glide by `dt` seconds. Cheap when nothing is moving.
    func step(_ dt: Double) {
        guard hasShown else { return }
        let a = box.step(dt)
        let c = style == .focus ? hole.step(dt) : false
        if a || c { render() }
    }

    func clear() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        mark.isHidden = true
        ghost.isHidden = true
        dim.isHidden = true
        CATransaction.commit()
        hasShown = false
    }

    private func crossFade(to b: CGRect) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        ghost.frame = mark.frame
        ghost.layout(style: style)
        ghost.isHidden = false
        CATransaction.commit()
        fade(ghost, from: 1, to: 0, duration: 0.22)
        fade(mark, from: 0, to: 1, duration: 0.18)
        box.snap(to: b)
    }

    private func fade(_ l: CALayer, from: Float, to: Float, duration: Double) {
        let a = CABasicAnimation(keyPath: "opacity")
        a.fromValue = from
        a.toValue = to
        a.duration = duration
        a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        l.opacity = to
        l.add(a, forKey: "fade")
    }

    private func render() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let b = box.value
        mark.isHidden = false
        dim.isHidden = style != .focus
        mark.frame = style == .underline
            ? CGRect(x: b.minX, y: b.minY - 3, width: b.width, height: 3.5)
            : b
        mark.layout(style: style)
        if style == .focus {
            let h = hole.value.insetBy(dx: -12, dy: -7)
            let path = CGMutablePath()
            path.addRect(root.bounds)
            let r = min(8, h.width / 2, h.height / 2)
            path.addRoundedRect(in: h, cornerWidth: r, cornerHeight: r)
            dim.frame = root.bounds
            dim.path = path
        }
        CATransaction.commit()
    }
}

/// Transparent, click-through panel covering one screen.
final class OverlayWindow: NSPanel {
    let renderer = HighlightRenderer()

    init(screen: NSScreen) {
        super.init(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        setFrame(screen.frame, display: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        sharingType = .none          // never appears in our own OCR captures
        isReleasedWhenClosed = false
        hidesOnDeactivate = false

        let v = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        v.layer = renderer.root
        v.wantsLayer = true
        renderer.root.frame = v.bounds
        contentView = v
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class OverlayManager {
    private var windows: [OverlayWindow] = []

    init() {
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in self?.rebuild() }
    }

    func rebuild() {
        windows.forEach { $0.orderOut(nil) }
        windows = NSScreen.screens.map { OverlayWindow(screen: $0) }
    }

    /// `box` / `line` in Cocoa global coordinates.
    func show(box: CGRect, line: CGRect?, style: HighlightStyle, animated: Bool) {
        if windows.isEmpty { rebuild() }
        let c = CGPoint(x: box.midX, y: box.midY)
        for w in windows {
            if w.frame.contains(c) {
                let o = w.frame.origin
                w.renderer.update(box: box.offsetBy(dx: -o.x, dy: -o.y),
                                  line: line?.offsetBy(dx: -o.x, dy: -o.y),
                                  style: style, animated: animated && w.isVisible)
                if !w.isVisible { w.orderFrontRegardless() }
            } else if w.isVisible {
                w.renderer.clear()
                w.orderOut(nil)
            }
        }
    }

    /// Call every display frame.
    func step(_ dt: Double) {
        for w in windows where w.isVisible { w.renderer.step(dt) }
    }

    func hide() {
        for w in windows where w.isVisible {
            w.renderer.clear()
            w.orderOut(nil)
        }
    }

    /// Lets the overlay show up in a screenshot (feedback reports only).
    func setCapturable(_ on: Bool) {
        windows.forEach { $0.sharingType = on ? .readOnly : .none }
    }
}
