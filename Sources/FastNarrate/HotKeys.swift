import Carbon.HIToolbox
import Foundation

/// Global hotkeys via Carbon's RegisterEventHotKey (needs no Accessibility permission).
final class HotKeys {
    static let shared = HotKeys()

    private var handlers: [UInt32: () -> Void] = [:]
    private var refs: [UInt32: EventHotKeyRef] = [:]

    private init() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hk = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
            HotKeys.shared.fire(hk.id)
            return noErr
        }, 1, &spec, nil, nil)
    }

    func register(_ id: UInt32, keyCode: Int, modifiers: Int, _ handler: @escaping () -> Void) {
        unregister(id)
        var ref: EventHotKeyRef?
        let hkID = EventHotKeyID(signature: OSType(0x4E41_5252), id: id) // 'NARR'
        let status = RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), hkID,
                                         GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else { return }
        refs[id] = ref
        handlers[id] = handler
    }

    func unregister(_ id: UInt32) {
        if let r = refs[id] { UnregisterEventHotKey(r) }
        refs[id] = nil
        handlers[id] = nil
    }

    private func fire(_ id: UInt32) {
        DispatchQueue.main.async { self.handlers[id]?() }
    }
}

enum HotKeyID: UInt32 {
    case read = 1, pause, follow, escape, feedback
}

let ctrlOpt = controlKey | optionKey
