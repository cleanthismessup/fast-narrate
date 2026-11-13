import AppKit

/// Small transient message bubble (status, hints, errors).
final class HUD {
    private let panel: NSPanel
    private let label: NSTextField
    private var hideWork: DispatchWorkItem?

    init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 50),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.sharingType = .none
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false

        let box = NSView()
        box.wantsLayer = true
        box.layer?.backgroundColor = NSColor(white: 0.07, alpha: 0.9).cgColor
        box.layer?.cornerRadius = 12
        label = NSTextField(wrappingLabelWithString: "")
        label.font = .systemFont(ofSize: 15, weight: .medium)
        label.textColor = .white
        label.alignment = .center
        label.maximumNumberOfLines = 4
        label.preferredMaxLayoutWidth = 460
        box.addSubview(label)
        panel.contentView = box
    }

    func show(_ text: String, seconds: Double = 2.8) {
        label.stringValue = text
        let s = label.fittingSize
        let size = CGSize(width: ceil(s.width) + 36, height: ceil(s.height) + 22)
        label.frame = NSRect(x: 18, y: 11, width: ceil(s.width), height: ceil(s.height))
        let vf = (Coords.screen(containing: NSEvent.mouseLocation) ?? NSScreen.main)?.visibleFrame ?? .zero
        panel.setFrame(NSRect(x: vf.midX - size.width / 2, y: vf.maxY - size.height - 24,
                              width: size.width, height: size.height), display: true)
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        hideWork?.cancel()
        let w = DispatchWorkItem { [weak self] in
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.25
                self?.panel.animator().alphaValue = 0
            }, completionHandler: { self?.panel.orderOut(nil) })
        }
        hideWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: w)
    }
}
