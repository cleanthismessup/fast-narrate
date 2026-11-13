import AppKit

/// Follow-mouse mode: rest the pointer on text for a moment and reading starts there.
/// Polls the pointer position (no permission needed, ~free).
final class FollowMouse {
    weak var reader: ReaderController?
    private var timer: Timer?
    private var lastPos = CGPoint.zero
    private var stillSince = CACurrentMediaTime()
    private var armed = false
    private var lastTrigger: CGPoint?

    static let restDelay = 0.6
    static let minMove: CGFloat = 40

    var isRunning: Bool { timer != nil }

    func start() {
        guard timer == nil else { return }
        lastPos = NSEvent.mouseLocation
        stillSince = CACurrentMediaTime()
        armed = true
        lastTrigger = nil
        let t = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in self?.poll() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func poll() {
        let p = NSEvent.mouseLocation
        let now = CACurrentMediaTime()
        if hypot(p.x - lastPos.x, p.y - lastPos.y) > 2 {
            lastPos = p
            stillSince = now
            armed = true
            return
        }
        guard armed, now - stillSince >= Self.restDelay, NSEvent.pressedMouseButtons == 0 else { return }
        armed = false
        if let t = lastTrigger, hypot(p.x - t.x, p.y - t.y) < Self.minMove { return }
        lastTrigger = p
        reader?.readAtPointer(follow: true)
    }
}
