import AppKit

/// TikTok-style caption bar: shows a few words at a time with the spoken word lit up.
@MainActor
final class SubtitleBar {
    private var panel: NSPanel?
    private let label = NSTextField(labelWithString: "")
    private var hideWork: DispatchWorkItem?

    private var highlight: NSColor { Settings.shared.highlightColor.color }
    private var captionFont: NSFont { Self.rounded(size: Settings.shared.subtitleSize.points, weight: .heavy) }
    private var statusFont: NSFont { Self.rounded(size: 20, weight: .semibold) }

    /// Lets a feedback snapshot include the caption bar.
    func setCapturable(_ on: Bool) { panel?.sharingType = on ? .readOnly : .none }

    /// Words per caption, broken early at punctuation, so the eye takes in a short chunk at a time.
    nonisolated static func groups(_ words: [String], maxWords: Int = 6) -> [Range<Int>] {
        var out: [Range<Int>] = []
        var start = 0
        for (i, w) in words.enumerated() {
            let n = i - start + 1
            let last = w.last.map(String.init) ?? ""
            let hardStop = ".!?;:…".contains(last)
            let softStop = ",)—–".contains(last) && n >= 3
            if n >= maxWords || hardStop || softStop {
                out.append(start..<i + 1)
                start = i + 1
            }
        }
        if start < words.count { out.append(start..<words.count) }
        return out
    }

    func update(words: [String], current: Int, on screen: NSScreen?) {
        guard words.indices.contains(current) else { return }
        let group = Self.groups(words).first { $0.contains(current) } ?? current..<current + 1

        let para = NSMutableParagraphStyle()
        para.alignment = .center
        para.lineBreakMode = .byWordWrapping
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.6)
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        shadow.shadowBlurRadius = 3

        let text = NSMutableAttributedString()
        for i in group {
            let color: NSColor = i == current ? highlight
                : i < current ? .white : NSColor.white.withAlphaComponent(0.55)
            if i > group.lowerBound { text.append(NSAttributedString(string: " ")) }
            text.append(NSAttributedString(string: words[i], attributes: [
                .font: captionFont, .foregroundColor: color, .paragraphStyle: para, .shadow: shadow,
            ]))
        }
        present(text, on: screen)
    }

    func showStatus(_ message: String, on screen: NSScreen?, autoHide: TimeInterval? = nil) {
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        present(NSAttributedString(string: message, attributes: [
            .font: statusFont, .foregroundColor: NSColor.white.withAlphaComponent(0.85), .paragraphStyle: para,
        ]), on: screen)
        if let t = autoHide { hide(after: t) }
    }

    func hide(after delay: TimeInterval = 0) {
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.panel?.orderOut(nil) }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func present(_ text: NSAttributedString, on screen: NSScreen?) {
        hideWork?.cancel()
        let p = panel ?? makePanel()
        panel = p
        label.attributedStringValue = text
        if let s = screen ?? NSScreen.main {
            let vf = s.visibleFrame
            let size = Settings.shared.subtitleSize.points
            let w = min(size * 30, vf.width - 80)
            let h = size * 2.6 + 34
            let y = Settings.shared.subtitlePosition == .bottom ? vf.minY + 36 : vf.maxY - h - 24
            let frame = NSRect(x: vf.midX - w / 2, y: y, width: w, height: h)
            if p.frame != frame { p.setFrame(frame, display: true) }
        }
        p.orderFrontRegardless()
    }

    private func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.ignoresMouseEvents = true
        p.level = .statusBar
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        p.sharingType = .none
        p.isReleasedWhenClosed = false
        p.hidesOnDeactivate = false

        let bg = NSVisualEffectView()
        bg.material = .hudWindow
        bg.state = .active
        bg.blendingMode = .behindWindow
        bg.appearance = NSAppearance(named: .vibrantDark)
        bg.wantsLayer = true
        bg.layer?.cornerRadius = 20
        bg.layer?.masksToBounds = true

        label.maximumNumberOfLines = 2
        label.lineBreakMode = .byWordWrapping
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        bg.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: bg.leadingAnchor, constant: 28),
            label.trailingAnchor.constraint(equalTo: bg.trailingAnchor, constant: -28),
            label.centerYAnchor.constraint(equalTo: bg.centerYAnchor),
        ])
        p.contentView = bg
        return p
    }

    private static func rounded(size: CGFloat, weight: NSFont.Weight) -> NSFont {
        let base = NSFont.systemFont(ofSize: size, weight: weight)
        guard let d = base.fontDescriptor.withDesign(.rounded) else { return base }
        return NSFont(descriptor: d, size: size) ?? base
    }
}
