import AppKit

/// Commands the menu and the hotkeys both drive. Main-actor isolated: every
/// one of these touches AppKit.
@MainActor
protocol PrompterCommands: AnyObject {
    func openScript()
    func reloadScript()
    func openGoogleDoc()
    func togglePanelVisibility()
    func toggleClickThrough()
    func toggleAutoScroll()
    func nextSection()
    func previousSection()
    func resync()
    func adjustFontSize(by delta: CGFloat)
    func adjustSpeed(by delta: Double)
    func toggleMirror()
    func toggleDimming()
    func setThemeMode(_ raw: String)
    func toggleTextHalo()
    func toggleBorder()
    func toggleReadingLine()
    func adjustBackgroundOpacity(by delta: CGFloat)
    func jump(toSection index: Int)
    func runInvisibilitySelfTest()
    func toggleMenuBarIcon()
    func toggleFollowMode()
    func toggleAnswerMode()
    func undoJump()
    func toggleDiagnostics()
    func adjustMatchSensitivity(by delta: Double)

    var isPanelVisible: Bool { get }
    var isClickThrough: Bool { get }
    var isAutoScrolling: Bool { get }
    var isMirrored: Bool { get }
    var isMenuBarIconHidden: Bool { get }
    var isFollowing: Bool { get }
    var isAnswering: Bool { get }
    var showsDiagnostics: Bool { get }
    var scriptName: String { get }
    var sectionTitles: [String] { get }
}

/// The menu-bar icon and its menu. This is the app's only persistent UI chrome —
/// there is no Dock icon (LSUIElement), which also keeps the app out of the
/// app switcher and Mission Control.
@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {

    private let statusItem: NSStatusItem
    private weak var commands: PrompterCommands?

    init(commands: PrompterCommands) {
        self.commands = commands
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        if let button = statusItem.button {
            button.image = NSImage(
                systemSymbolName: "text.alignleft",
                accessibilityDescription: "Teleprompter"
            )
            button.image?.isTemplate = true
        }

        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    func setIconVisible(_ visible: Bool) {
        statusItem.isVisible = visible
    }

    /// Fires while the menu's window still sits at layer 0 — created but not yet
    /// drawn — so this lands before any capturable frame exists.
    func menuWillOpen(_ menu: NSMenu) {
        WindowCloak.cloakAll()
    }

    // Rebuild on open so checkmarks and the section list always reflect reality.
    func menuNeedsUpdate(_ menu: NSMenu) {
        WindowCloak.cloakAll()
        guard let c = commands else { return }
        menu.removeAllItems()

        let header = NSMenuItem(title: c.scriptName, action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        add(to: menu, "Open Script…", #selector(openScript), key: "o")
        add(to: menu, "Open from Google Docs…", #selector(openGoogleDoc), key: "g")
        add(to: menu, "Reload Script", #selector(reloadScript), key: "r")
        menu.addItem(.separator())

        add(to: menu, c.isPanelVisible ? "Hide Prompter" : "Show Prompter",
            #selector(togglePanel), hint: "⌥⌘T")
        add(to: menu, "Auto-Scroll", #selector(toggleAutoScroll),
            hint: "⌥⌘P", checked: c.isAutoScrolling)
        add(to: menu, "Follow My Voice", #selector(toggleFollow),
            hint: "⌥⌘F", checked: c.isFollowing)
        add(to: menu, "Answer Questions Automatically", #selector(toggleAnswer),
            hint: "⌥⌘A", checked: c.isAnswering)
        add(to: menu, "Undo Last Jump", #selector(undoJump), hint: "⌥⌘Z")
        add(to: menu, "Click-Through", #selector(toggleClickThrough),
            hint: "⌥⌘C", checked: c.isClickThrough)
        menu.addItem(.separator())

        let sections = c.sectionTitles
        if !sections.isEmpty {
            let item = NSMenuItem(title: "Jump to Section", action: nil, keyEquivalent: "")
            let submenu = NSMenu()
            for (i, title) in sections.enumerated() {
                let entry = NSMenuItem(
                    title: title.isEmpty ? "(untitled)" : title,
                    action: #selector(jumpToSection(_:)),
                    keyEquivalent: ""
                )
                entry.target = self
                entry.tag = i
                submenu.addItem(entry)
            }
            item.submenu = submenu
            menu.addItem(item)
        }

        add(to: menu, "Next Section", #selector(nextSection), hint: "⌥⌘]")
        add(to: menu, "Previous Section", #selector(previousSection), hint: "⌥⌘[")
        add(to: menu, "Resync", #selector(resync), hint: "⌥⌘R")
        menu.addItem(.separator())

        add(to: menu, "Larger Text", #selector(larger), hint: "⌥⌘=")
        add(to: menu, "Smaller Text", #selector(smaller), hint: "⌥⌘-")
        add(to: menu, "Faster", #selector(faster))
        add(to: menu, "Slower", #selector(slower))
        let themeItem = NSMenuItem(title: "Text Colour", action: nil, keyEquivalent: "")
        let themeMenu = NSMenu()
        for (label, mode) in [("Automatic (follows Light/Dark mode)", "auto"),
                              ("Always Black", "light"),
                              ("Always White", "dark")] {
            let entry = NSMenuItem(title: label, action: #selector(pickTheme(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = mode
            entry.state = Settings.shared.themeMode.rawValue == mode ? .on : .off
            themeMenu.addItem(entry)
        }
        themeItem.submenu = themeMenu
        menu.addItem(themeItem)
        add(to: menu, "Show Border", #selector(toggleBorder),
            checked: Settings.shared.showsBorder)
        add(to: menu, "Show Reading Line", #selector(toggleReadingLine),
            checked: Settings.shared.showsReadingLine)
        add(to: menu, "Text Halo (for busy backgrounds)", #selector(toggleHalo),
            checked: Settings.shared.textHalo)
        add(to: menu, "More Opaque Background", #selector(moreOpaque))
        add(to: menu, "More Transparent Background", #selector(moreTransparent))
        add(to: menu, "Fade Edges", #selector(toggleDimming),
            checked: Settings.shared.dimsDistantText)
        add(to: menu, "Mirror (beam splitter)", #selector(toggleMirror),
            checked: c.isMirrored)
        menu.addItem(.separator())

        let speed = NSMenuItem(
            title: String(format: "Speed: %.0f wpm · Text: %.0fpt · Match: %.2f · BG: %.0f%%",
                          Settings.shared.fallbackWPM, Settings.shared.fontSize,
                          Settings.shared.matchThreshold,
                          Settings.shared.backgroundOpacity * 100),
            action: nil, keyEquivalent: ""
        )
        speed.isEnabled = false
        menu.addItem(speed)
        menu.addItem(.separator())

        add(to: menu, "Hide Menu Bar Icon", #selector(toggleIcon), hint: "⌥⌘M")
        add(to: menu, "Jump More Readily", #selector(moreSensitive))
        add(to: menu, "Jump Less Readily", #selector(lessSensitive))
        add(to: menu, "Show Diagnostics", #selector(toggleDiag), checked: c.showsDiagnostics)
        add(to: menu, "Verify Invisibility…", #selector(selfTest))
        menu.addItem(.separator())
        add(to: menu, "Quit Teleprompter", #selector(quit), key: "q")
    }

    private func add(
        to menu: NSMenu,
        _ title: String,
        _ action: Selector,
        key: String = "",
        hint: String? = nil,
        checked: Bool = false
    ) {
        let item = NSMenuItem(
            title: hint.map { "\(title)  (\($0))" } ?? title,
            action: action,
            keyEquivalent: key
        )
        item.target = self
        item.state = checked ? .on : .off
        menu.addItem(item)
    }

    // MARK: - Forwarding

    @objc private func openScript() { commands?.openScript() }
    @objc private func reloadScript() { commands?.reloadScript() }
    @objc private func openGoogleDoc() { commands?.openGoogleDoc() }
    @objc private func togglePanel() { commands?.togglePanelVisibility() }
    @objc private func toggleAutoScroll() { commands?.toggleAutoScroll() }
    @objc private func toggleClickThrough() { commands?.toggleClickThrough() }
    @objc private func nextSection() { commands?.nextSection() }
    @objc private func previousSection() { commands?.previousSection() }
    @objc private func resync() { commands?.resync() }
    @objc private func larger() { commands?.adjustFontSize(by: 2) }
    @objc private func smaller() { commands?.adjustFontSize(by: -2) }
    @objc private func faster() { commands?.adjustSpeed(by: 10) }
    @objc private func slower() { commands?.adjustSpeed(by: -10) }
    @objc private func toggleMirror() { commands?.toggleMirror() }
    @objc private func toggleDimming() { commands?.toggleDimming() }
    @objc private func pickTheme(_ sender: NSMenuItem) {
        commands?.setThemeMode(sender.representedObject as? String ?? "auto")
    }
    @objc private func toggleHalo() { commands?.toggleTextHalo() }
    @objc private func toggleBorder() { commands?.toggleBorder() }
    @objc private func toggleReadingLine() { commands?.toggleReadingLine() }
    @objc private func moreOpaque() { commands?.adjustBackgroundOpacity(by: 0.15) }
    @objc private func moreTransparent() { commands?.adjustBackgroundOpacity(by: -0.15) }
    @objc private func selfTest() { commands?.runInvisibilitySelfTest() }
    @objc private func toggleIcon() { commands?.toggleMenuBarIcon() }
    @objc private func toggleFollow() { commands?.toggleFollowMode() }
    @objc private func toggleAnswer() { commands?.toggleAnswerMode() }
    @objc private func undoJump() { commands?.undoJump() }
    @objc private func toggleDiag() { commands?.toggleDiagnostics() }
    @objc private func moreSensitive() { commands?.adjustMatchSensitivity(by: 0.1) }
    @objc private func lessSensitive() { commands?.adjustMatchSensitivity(by: -0.1) }
    @objc private func quit() { NSApp.terminate(nil) }

    @objc private func jumpToSection(_ sender: NSMenuItem) {
        commands?.jump(toSection: sender.tag)
    }
}
