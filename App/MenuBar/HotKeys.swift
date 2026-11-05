import Foundation
import Carbon.HIToolbox

/// Globala kortkommandon via Carbons `RegisterEventHotKey` — fungerar utan någon behörighet
/// och utan beroenden.
@MainActor
final class HotKeys {
    static let shared = HotKeys()
    private var handlers: [UInt32: () -> Void] = [:]
    private var refs: [EventHotKeyRef] = []
    private var installed = false

    /// ⌃⌥⌘ + tangent.
    func register(_ keyCode: Int, id: UInt32, _ handler: @escaping () -> Void) {
        installIfNeeded()
        handlers[id] = handler
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x4253_5245), id: id) // "BSRE"
        let mods = UInt32(cmdKey | optionKey | controlKey)
        if RegisterEventHotKey(UInt32(keyCode), mods, hotKeyID, GetApplicationEventTarget(), 0, &ref) == noErr,
           let ref {
            refs.append(ref)
        }
    }

    fileprivate func fire(_ id: UInt32) { handlers[id]?() }

    private func installIfNeeded() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            let id = hotKeyID.id
            DispatchQueue.main.async { MainActor.assumeIsolated { HotKeys.shared.fire(id) } }
            return noErr
        }, 1, &spec, nil, nil)
    }
}

enum HotKeyID {
    static let toggleRecording: UInt32 = 1
    static let pause: UInt32 = 2
    static let area: UInt32 = 3
    static let flashback: UInt32 = 4
}
