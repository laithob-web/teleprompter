import AppKit

/// The teleprompter window.
///
/// Feature 1 lives on one line here: `sharingType = .none`. That flag excludes the
/// window from ScreenCaptureKit, which is the capture path Zoom, Teams, and
/// Chrome (Google Meet) all use on modern macOS. The window stays on your display
/// and vanishes from anything they capture.
final class PrompterPanel: NSPanel {

    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.nonactivatingPanel, .borderless, .resizable, .utilityWindow],
            backing: .buffered,
            defer: false
        )

        // ── Feature 1 ────────────────────────────────────────────────────────
        sharingType = .none

        // ── Never steal focus ────────────────────────────────────────────────
        // If this panel took key status, Zoom's mute hotkey would stop working
        // the moment you touched the script. .nonactivatingPanel plus these two
        // flags keep keyboard focus wherever it already was.
        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = true
        hidesOnDeactivate = false

        // ── Stay visible over the meeting ────────────────────────────────────
        // .fullScreenAuxiliary is what keeps it on screen when Zoom goes
        // fullscreen; .canJoinAllSpaces keeps it across Space switches.
        // .ignoresCycle and .stationary keep it out of Cmd-Tab and Mission Control.
        level = .floating
        collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .ignoresCycle,
            .stationary,
        ]

        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovableByWindowBackground = true
        isReleasedWhenClosed = false
        animationBehavior = .none
        minSize = NSSize(width: 320, height: 160)
    }

    // Borderless windows refuse key status by default; allow it only so the
    // settings fields and hotkey capture can work when explicitly summoned.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Click-through mode: the panel becomes inert to the pointer so you can
    /// click the meeting app behind it. Toggled back by a global hotkey, since
    /// in this state the panel itself cannot be clicked.
    var isClickThrough: Bool = false {
        didSet { ignoresMouseEvents = isClickThrough }
    }

    /// Raises the panel above fullscreen slideshows.
    ///
    /// Keynote, PowerPoint and Google Slides put their presentation window far
    /// above `.floating`, so while presenting the script is buried under your own
    /// slides — still hidden from the audience, just invisible to you as well.
    /// The shielding level is the one the system reserves for windows that must
    /// cover everything, which is exactly the requirement here.
    func setAlwaysOnTop(_ aggressive: Bool) {
        level = aggressive
            ? NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
            : .floating
        // Re-assert: changing level can drop a window out of the active Space.
        collectionBehavior = [
            .canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary,
        ]
    }
}
