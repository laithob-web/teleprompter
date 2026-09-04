import AppKit

/// Restores ⌘X / ⌘C / ⌘V / ⌘A / ⌘Z inside this app's text fields.
///
/// Standard editing shortcuts are not built into AppKit's text views — they are
/// key equivalents on the Edit menu, and `NSApplication` matches them against
/// `mainMenu`. A menu-bar-only app (`LSUIElement`, `.accessory`) has no
/// application menu bar at all, so nothing ever matches and ⌘V silently does
/// nothing in every text field the app puts on screen.
///
/// Rather than construct a hidden main menu, this routes the key equivalents
/// straight to the first responder. `sendAction(to: nil)` walks the responder
/// chain, so it resolves to whichever text field is focused and returns false
/// when none is — which lets the event through untouched.
enum EditingShortcuts {

    private static var monitor: Any?

    static func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Command only: leave ⌥⌘ combinations to the global hotkeys.
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard modifiers == .command,
                  let key = event.charactersIgnoringModifiers?.lowercased()
            else { return event }

            let action: Selector
            switch key {
            case "v": action = #selector(NSText.paste(_:))
            case "c": action = #selector(NSText.copy(_:))
            case "x": action = #selector(NSText.cut(_:))
            case "a": action = #selector(NSText.selectAll(_:))
            case "z": action = Selector(("undo:"))
            default: return event
            }

            // Swallow the event only if something actually handled it.
            return NSApp.sendAction(action, to: nil, from: nil) ? nil : event
        }
    }
}
