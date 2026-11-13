import Carbon
import Foundation

/// Global hotkeys via Carbon RegisterEventHotKey (no Accessibility permission needed).
final class HotKeys {
    static let shared = HotKeys()

    enum ID: UInt32 {
        case read = 1, pause, stop, feedback, follow
        case escape = 20, faster, slower
    }

    static let ctrlOpt = UInt32(controlKey | optionKey)

    private var refs: [UInt32: EventHotKeyRef] = [:]
    fileprivate var handlers: [UInt32: () -> Void] = [:]
    private var installed = false

    func register(_ id: ID, keyCode: Int, mods: UInt32, _ handler: @escaping () -> Void) {
        install()
        unregister(id)
        var ref: EventHotKeyRef?
        let hk = EventHotKeyID(signature: OSType(0x464E_5254), id: id.rawValue) // "FNRT"
        let status = RegisterEventHotKey(UInt32(keyCode), mods, hk, GetApplicationEventTarget(), 0, &ref)
        if status == noErr, let ref {
            refs[id.rawValue] = ref
            handlers[id.rawValue] = handler
        } else {
            Trace.log("hotkey \(id) FAILED to register: OSStatus \(status)")
        }
    }

    func unregister(_ id: ID) {
        if let r = refs.removeValue(forKey: id.rawValue) { UnregisterEventHotKey(r) }
        handlers[id.rawValue] = nil
    }

    func isRegistered(_ id: ID) -> Bool { refs[id.rawValue] != nil }

    private func install() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hk = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
            let id = hk.id
            DispatchQueue.main.async {
                Trace.log("hotkey pressed id=\(id) handler=\(HotKeys.shared.handlers[id] != nil)")
                HotKeys.shared.handlers[id]?()
            }
            return noErr
        }, 1, &spec, nil, nil)
    }
}
