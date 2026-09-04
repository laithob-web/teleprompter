import AppKit

/// Keeps *every* window this app owns out of screen captures — not just the
/// prompter panel.
///
/// `sharingType` is a per-window property, so setting it on the panel alone
/// leaves the rest of the app exposed. Measured defaults on macOS 26, all of
/// which are capturable:
///
///     NSAlert.window        sharingType = .readOnly
///     NSOpenPanel           sharingType = .readOnly
///     status-item NSMenu    sharingType = .readOnly
///
/// The file picker is the dangerous one: opening a script mid-call while sharing
/// your screen would put your filenames on everyone's display.
///
/// Menus are handled at `menuWillOpen`, which fires while the menu window still
/// sits at window layer 0 — created but not yet promoted to the menu layer and
/// drawn. Cloaking there lands before the first visible frame.
enum WindowCloak {

    /// Marks a single window non-shareable. Safe to call repeatedly.
    static func cloak(_ window: NSWindow?) {
        guard let window, window.sharingType != .none else { return }
        window.sharingType = .none
    }

    /// Sweeps every window currently owned by the app.
    @discardableResult
    static func cloakAll() -> Int {
        var count = 0
        for window in NSApp.windows where window.sharingType != .none {
            window.sharingType = .none
            count += 1
        }
        return count
    }

    /// Backstop for any window created by AppKit that we do not construct
    /// ourselves. Explicit cloaking at each creation site is the primary defense;
    /// this only catches what slips through.
    static func installGlobalGuard() {
        let center = NotificationCenter.default
        for name: Notification.Name in [
            NSWindow.didBecomeKeyNotification,
            NSWindow.didUpdateNotification,
            NSWindow.didExposeNotification,
        ] {
            center.addObserver(
                forName: name, object: nil, queue: .main
            ) { note in
                cloak(note.object as? NSWindow)
            }
        }

        center.addObserver(
            forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main
        ) { _ in
            cloakAll()
        }
    }

    /// Asks for a line of text in a dialog that cannot be captured.
    static func promptForText(
        title: String, message: String, placeholder: String
    ) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Load")
        alert.addButton(withTitle: "Cancel")

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
        field.placeholderString = placeholder
        alert.accessoryView = field

        cloak(alert.window)
        alert.window.initialFirstResponder = field

        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    /// Runs a modal alert that cannot be captured.
    @discardableResult
    static func runAlert(_ title: String, _ body: String) -> NSApplication.ModalResponse {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = body
        alert.alertStyle = .informational
        cloak(alert.window)
        return alert.runModal()
    }
}
