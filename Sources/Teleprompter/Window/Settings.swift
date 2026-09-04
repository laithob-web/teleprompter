import AppKit

/// User-tunable display and behavior settings, persisted to UserDefaults.
final class Settings {
    static let shared = Settings()

    static let didChange = Notification.Name("TeleprompterSettingsDidChange")

    private let defaults = UserDefaults.standard

    private func value<T>(_ key: String, _ fallback: T) -> T {
        defaults.object(forKey: key) as? T ?? fallback
    }

    private func set<T>(_ key: String, _ newValue: T) {
        defaults.set(newValue, forKey: key)
        NotificationCenter.default.post(name: Settings.didChange, object: nil)
    }

    var fontSize: CGFloat {
        get { value("fontSize", 30.0) }
        set { set("fontSize", min(96, max(12, newValue))) }
    }

    /// Background opacity. Fully transparent is legible over a bright meeting
    /// window only if you also raise contrast, so the default keeps a scrim.
    var backgroundOpacity: CGFloat {
        get { value("backgroundOpacity", 0.0) }
        set { set("backgroundOpacity", min(1.0, max(0.0, newValue))) }
    }

    /// Where the "now reading" line sits, as a fraction of panel height.
    /// Slightly above center reads more naturally than dead center.
    var readingLineFraction: CGFloat {
        get { value("readingLineFraction", 0.40) }
        set { set("readingLineFraction", min(0.9, max(0.1, newValue))) }
    }

    /// Fallback scroll speed used when speech alignment has no confident fix.
    var fallbackWPM: Double {
        get { value("fallbackWPM", 140.0) }
        set { set("fallbackWPM", min(400, max(40, newValue))) }
    }

    /// Soften the very top and bottom edges. Off by default: the script should
    /// read as one continuous page.
    var dimsDistantText: Bool {
        get { value("dimsDistantText", false) }
        set { set("dimsDistantText", newValue) }
    }

    enum ThemeMode: String {
        /// Follow the system Light/Dark setting.
        case auto
        /// Force black text.
        case light
        /// Force white text.
        case dark
    }

    /// How the script's text colour is chosen.
    var themeMode: ThemeMode {
        get { ThemeMode(rawValue: value("themeMode", "auto")) ?? .auto }
        set { set("themeMode", newValue.rawValue) }
    }

    /// Soft halo behind the glyphs, in the opposite colour to the text.
    ///
    /// With a transparent background the script sits directly on the video call,
    /// so black text lands on whatever happens to be behind it — including dark
    /// clothing and dark UI. The halo keeps it readable without adding a panel.
    var textHalo: Bool {
        get { value("textHalo", false) }
        set { set("textHalo", newValue) }
    }

    /// Outline around the panel. With a transparent background and no halo,
    /// this is the only thing showing where the prompter actually is — including
    /// where to put the pointer to scroll it.
    var showsBorder: Bool {
        get { value("showsBorder", true) }
        set { set("showsBorder", newValue) }
    }

    var mirrorHorizontally: Bool {
        get { value("mirrorHorizontally", false) }
        set { set("mirrorHorizontally", newValue) }
    }

    /// The menu-bar icon is drawn by the system, not by this app, so it cannot
    /// be cloaked — it shows up in a full-screen share like any other menu-bar
    /// item. Hiding it leaves hotkeys as the only control surface.
    var hidesMenuBarIcon: Bool {
        get { value("hidesMenuBarIcon", false) }
        set { set("hidesMenuBarIcon", newValue) }
    }

    /// 0 = only jump on near-certain matches, 1 = jump readily.
    /// Maps onto the matcher's accept threshold.
    var matchSensitivity: Double {
        get { value("matchSensitivity", 0.5) }
        set { set("matchSensitivity", min(1.0, max(0.0, newValue))) }
    }

    /// Threshold derived from `matchSensitivity`; 0.5 gives the measured 0.65.
    /// Scripts differ in vocabulary, so this is exposed rather than fixed.
    var matchThreshold: Double {
        0.78 - matchSensitivity * 0.26
    }

    /// Shows the live transcript and match scores in the panel.
    var showsDiagnostics: Bool {
        get { value("showsDiagnostics", false) }
        set { set("showsDiagnostics", newValue) }
    }

    var lastScriptPath: String? {
        get { defaults.string(forKey: "lastScriptPath") }
        set { defaults.set(newValue, forKey: "lastScriptPath") }
    }

    var lastGoogleDocID: String? {
        get { defaults.string(forKey: "lastGoogleDocID") }
        set { defaults.set(newValue, forKey: "lastGoogleDocID") }
    }

    var lastGoogleDocTitle: String? {
        get { defaults.string(forKey: "lastGoogleDocTitle") }
        set { defaults.set(newValue, forKey: "lastGoogleDocTitle") }
    }

    /// Saved panel frame, so the prompter reopens where you left it.
    var savedFrame: NSRect? {
        get {
            guard let s = defaults.string(forKey: "panelFrame") else { return nil }
            let r = NSRectFromString(s)
            return r.width > 0 && r.height > 0 ? r : nil
        }
        set {
            guard let newValue else { return }
            defaults.set(NSStringFromRect(newValue), forKey: "panelFrame")
        }
    }
}
