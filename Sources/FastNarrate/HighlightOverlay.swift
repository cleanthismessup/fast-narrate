import AppKit
import QuartzCore

/// Transparent, click-through window over the whole screen that draws the reading highlight.
@MainActor
final class HighlightOverlay {
    private var panel: NSPanel?
    private let view = HighlightView(frame: .zero)

    func show(on screen: NSScreen) {
        let p = panel ?? makePanel()
        panel = p
        if p.frame != screen.frame {
            p.setFrame(screen.frame, display: false)
            view.reset()
        }
        view.screenOrigin = screen.frame.origin
        p.orderFrontRegardless()
    }

    func update(words: [Word], current: Int, visible: Bool) {
        view.apply(words: words, current: current, visible: visible)
    }

    /// Lets a feedback snapshot include the overlay.
    func setCapturable(_ on: Bool) { panel?.sharingType = on ? .readOnly : .none }

    func hide() {
        view.reset()
        panel?.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.ignoresMouseEvents = true
        p.level = .screenSaver
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        p.sharingType = .none // keep our own drawing out of screen captures (except feedback snapshots)
        p.isReleasedWhenClosed = false
        p.hidesOnDeactivate = false
        p.contentView = view
        return p
    }
}

final class HighlightView: NSView {
    var screenOrigin = CGPoint.zero

    /// Focus style: dims the screen outside the paragraph, and the paragraph outside the line.
    private let dimScreen = CAShapeLayer()
    private let dimBlock = CAShapeLayer()
    private let blockLayer = CAShapeLayer()
    private var currentLayers: [CALayer] = []
    private var trailLayers: [CALayer] = []
    private var hadHighlight = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        for dim in [dimScreen, dimBlock] {
            dim.fillRule = .evenOdd
            layer?.addSublayer(dim)
        }
        dimScreen.fillColor = NSColor.black.withAlphaComponent(0.55).cgColor
        dimBlock.fillColor = NSColor.black.withAlphaComponent(0.28).cgColor
        blockLayer.lineWidth = 2
        layer?.addSublayer(blockLayer)
        for _ in 0..<2 { trailLayers.append(makeLayer()) }
        for _ in 0..<2 { currentLayers.append(makeLayer()) }
    }

    required init?(coder: NSCoder) { fatalError() }

    private func makeLayer() -> CALayer {
        let l = CALayer()
        l.cornerRadius = 5
        l.opacity = 0
        layer?.addSublayer(l)
        return l
    }

    private func local(_ r: CGRect) -> CGRect { r.offsetBy(dx: -screenOrigin.x, dy: -screenOrigin.y) }

    func reset() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        (currentLayers + trailLayers).forEach { $0.opacity = 0 }
        blockLayer.path = nil
        dimScreen.path = nil
        dimBlock.path = nil
        CATransaction.commit()
        hadHighlight = false
    }

    /// Paints `l` as the word highlight in the chosen style.
    private func style(_ l: CALayer, word r: CGRect, style: Settings.HighlightStyle, color: NSColor, strength: Float) {
        let box = local(r).insetBy(dx: -3, dy: -2)
        switch style {
        case .marker, .focus:
            l.frame = box
            l.backgroundColor = color.withAlphaComponent(style == .focus ? 0.35 : 0.45).cgColor
            l.borderWidth = 0
            l.cornerRadius = 5
        case .underline:
            let h = max(3, r.height * 0.12)
            l.frame = CGRect(x: box.minX + 2, y: box.minY - h * 0.6, width: box.width - 4, height: h)
            l.backgroundColor = color.cgColor
            l.borderWidth = 0
            l.cornerRadius = h / 2
        case .outline:
            l.frame = box
            l.backgroundColor = color.withAlphaComponent(0.08).cgColor
            l.borderColor = color.cgColor
            l.borderWidth = 2.5
            l.cornerRadius = 6
        }
        l.opacity = strength
    }

    func apply(words: [Word], current: Int, visible: Bool) {
        guard visible, words.indices.contains(current) else { reset(); return }
        let settings = Settings.shared
        let style = settings.highlightStyle
        let color = settings.highlightColor.color

        CATransaction.begin()
        // Slide smoothly between words, but jump (no fly-in from 0,0) on the first frame.
        CATransaction.setDisableActions(!hadHighlight)
        CATransaction.setAnimationDuration(0.06)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .linear))

        let rects = words[current].rects
        let visibleRects = words.flatMap(\.rects)
        let block = visibleRects.isEmpty ? nil
            : local(visibleRects.reduce(CGRect.null) { $0.union($1) }).insetBy(dx: -8, dy: -6)

        // Paragraph outline
        if let block, settings.showParagraphOutline, style != .focus {
            blockLayer.path = CGPath(roundedRect: block, cornerWidth: 10, cornerHeight: 10, transform: nil)
            blockLayer.strokeColor = color.withAlphaComponent(0.6).cgColor
            blockLayer.fillColor = color.withAlphaComponent(0.04).cgColor
        } else {
            blockLayer.path = nil
        }

        // Focus: dim outside the paragraph, then dim the paragraph outside the current line.
        if style == .focus, let block, let r = rects.first {
            let lineRects = visibleRects.filter { abs($0.midY - r.midY) < r.height * 0.5 }
            let line = local(lineRects.reduce(r) { $0.union($1) }).insetBy(dx: -10, dy: -1.5)
            let screen = CGPath(rect: bounds, transform: nil)
            let p1 = CGMutablePath()
            p1.addPath(screen)
            p1.addRoundedRect(in: block, cornerWidth: 10, cornerHeight: 10)
            dimScreen.path = p1
            let p2 = CGMutablePath()
            p2.addRoundedRect(in: block, cornerWidth: 10, cornerHeight: 10)
            p2.addRoundedRect(in: line, cornerWidth: 6, cornerHeight: 6)
            dimBlock.path = p2
        } else {
            dimScreen.path = nil
            dimBlock.path = nil
        }

        for (i, l) in currentLayers.enumerated() {
            if i < rects.count {
                self.style(l, word: rects[i], style: style, color: color, strength: 1)
            } else {
                l.opacity = 0
            }
        }
        for (i, l) in trailLayers.enumerated() {
            let wi = current - 1 - i
            if wi >= 0, let r = words[wi].rects.last, style != .focus {
                self.style(l, word: r, style: style, color: color, strength: i == 0 ? 0.4 : 0.2)
            } else {
                l.opacity = 0
            }
        }
        CATransaction.commit()
        hadHighlight = !rects.isEmpty
    }
}
