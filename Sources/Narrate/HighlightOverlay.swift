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
        p.sharingType = .none // keep our own drawing out of screen captures
        p.isReleasedWhenClosed = false
        p.hidesOnDeactivate = false
        p.contentView = view
        return p
    }
}

final class HighlightView: NSView {
    var screenOrigin = CGPoint.zero

    private let blockLayer = CAShapeLayer()
    private var currentLayers: [CALayer] = []
    private var trailLayers: [CALayer] = []
    private var hadHighlight = false

    private let wordColor = NSColor.systemYellow.withAlphaComponent(0.45).cgColor
    private let trailColor = NSColor.systemYellow.withAlphaComponent(0.18).cgColor

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        blockLayer.fillColor = NSColor.controlAccentColor.withAlphaComponent(0.05).cgColor
        blockLayer.strokeColor = NSColor.controlAccentColor.withAlphaComponent(0.55).cgColor
        blockLayer.lineWidth = 2
        layer?.addSublayer(blockLayer)
        for _ in 0..<2 { trailLayers.append(makeLayer(trailColor)) }
        for _ in 0..<2 { currentLayers.append(makeLayer(wordColor)) }
    }

    required init?(coder: NSCoder) { fatalError() }

    private func makeLayer(_ color: CGColor) -> CALayer {
        let l = CALayer()
        l.backgroundColor = color
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
        CATransaction.commit()
        hadHighlight = false
    }

    func apply(words: [Word], current: Int, visible: Bool) {
        guard visible, words.indices.contains(current) else { reset(); return }

        CATransaction.begin()
        // Slide smoothly between words, but jump (no fly-in from 0,0) on the first frame.
        CATransaction.setDisableActions(!hadHighlight)
        CATransaction.setAnimationDuration(0.06)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .linear))

        let visibleRects = words.flatMap(\.rects)
        if visibleRects.isEmpty {
            blockLayer.path = nil
        } else {
            let block = local(visibleRects.reduce(CGRect.null) { $0.union($1) }).insetBy(dx: -8, dy: -6)
            blockLayer.path = CGPath(roundedRect: block, cornerWidth: 10, cornerHeight: 10, transform: nil)
        }

        let rects = words[current].rects
        for (i, l) in currentLayers.enumerated() {
            if i < rects.count {
                l.frame = local(rects[i]).insetBy(dx: -3, dy: -2)
                l.opacity = 1
            } else {
                l.opacity = 0
            }
        }
        for (i, l) in trailLayers.enumerated() {
            let wi = current - 1 - i
            if wi >= 0, let r = words[wi].rects.last {
                l.frame = local(r).insetBy(dx: -3, dy: -2)
                l.opacity = i == 0 ? 1 : 0.6
            } else {
                l.opacity = 0
            }
        }
        CATransaction.commit()
        hadHighlight = !rects.isEmpty
    }
}
