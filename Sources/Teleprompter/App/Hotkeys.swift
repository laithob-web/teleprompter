import AppKit
import Carbon.HIToolbox

/// Global hotkeys via Carbon's `RegisterEventHotKey`.
///
/// This is deliberately not `NSEvent.addGlobalMonitorForEvents`, which would
/// require Accessibility permission. Carbon hotkeys need no TCC grant at all,
/// which keeps the whole of Phase 1 permission-free.
final class HotkeyManager {

    static let shared = HotkeyManager()

    struct Binding {
        let keyCode: UInt32
        let modifiers: UInt32
        let action: () -> Void
    }

    private var actions: [UInt32: () -> Void] = [:]
    private var refs: [EventHotKeyRef?] = []
    private var handler: EventHandlerRef?
    private var nextID: UInt32 = 1

    private init() {}

    func installIfNeeded() {
        guard handler == nil else { return }
        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, _ -> OSStatus in
                guard let event else { return OSStatus(eventNotHandledErr) }
                var hotKeyID = EventHotKeyID()
                let status = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                guard status == noErr else { return status }
                DispatchQueue.main.async {
                    HotkeyManager.shared.fire(hotKeyID.id)
                }
                return noErr
            },
            1, &spec, nil, &handler
        )
    }

    @discardableResult
    func register(
        keyCode: Int, modifiers: UInt32, action: @escaping () -> Void
    ) -> Bool {
        installIfNeeded()

        let id = nextID
        nextID += 1

        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x54_50_52_4D), id: id) // 'TPRM'
        let status = RegisterEventHotKey(
            UInt32(keyCode), modifiers, hotKeyID,
            GetApplicationEventTarget(), 0, &ref
        )
        guard status == noErr else { return false }

        actions[id] = action
        refs.append(ref)
        return true
    }

    func unregisterAll() {
        for ref in refs where ref != nil {
            UnregisterEventHotKey(ref!)
        }
        refs.removeAll()
        actions.removeAll()
    }

    private func fire(_ id: UInt32) {
        actions[id]?()
    }
}

/// Modifier masks and key codes, named so the binding table below reads clearly.
enum Key {
    static let cmdOpt = UInt32(cmdKey | optionKey)

    static let t = kVK_ANSI_T
    static let c = kVK_ANSI_C
    static let p = kVK_ANSI_P
    static let r = kVK_ANSI_R
    static let m = kVK_ANSI_M
    static let f = kVK_ANSI_F
    static let a = kVK_ANSI_A
    static let s = kVK_ANSI_S
    static let z = kVK_ANSI_Z
    static let leftBracket = kVK_ANSI_LeftBracket
    static let rightBracket = kVK_ANSI_RightBracket
    static let minus = kVK_ANSI_Minus
    static let equal = kVK_ANSI_Equal
}
