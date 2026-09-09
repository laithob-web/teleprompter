import AppKit
import CoreGraphics
import CoreImage
import UniformTypeIdentifiers

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, PrompterCommands {

    private var panel: PrompterPanel!
    private var prompter: PrompterView!
    private var menuBar: MenuBarController!
    private let document = ScriptDocument()

    private var autoScrolling = false
    private let flow = FlowController()
    /// Follow mode adds speech tracking on top of auto-scroll. Off means the
    /// script drifts at a fixed rate and the microphone is never touched.
    private var followMode = false
    private let listener = MeetingListener()
    private var answerMode = false
    /// Sections visited by automatic jumps, so a wrong jump is one keypress
    /// away from being undone.
    private var jumpHistory: [Int] = []
    private let sampler = BackgroundSampler()
    private let server = PrompterServer()

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Installed first: every window created from here on is born non-shareable.
        WindowCloak.installGlobalGuard()
        // Without this, ⌘V does nothing in any text field — see EditingShortcuts.
        EditingShortcuts.install()

        buildPanel()
        menuBar = MenuBarController(commands: self)
        menuBar.setIconVisible(!Settings.shared.hidesMenuBarIcon)
        registerHotkeys()

        document.onChange = { [weak self] script, name in
            guard let self else { return }
            self.prompter.load(script, sourceName: name)
            self.flow.setScript(script)
            self.listener.setScript(script)
            self.updateSpeed()
            // Tell any connected phone to refetch rather than show a stale script.
            self.server.broadcastScriptChanged()
        }

        server.scriptProvider = { [weak self] in self?.document.script ?? .empty }

        document.onError = { [weak self] message in
            self?.presentAlert("Could not load that script", message)
        }

        if let id = Settings.shared.lastGoogleDocID {
            document.loadGoogleDoc(
                id: id, title: Settings.shared.lastGoogleDocTitle ?? "Google Doc"
            )
        } else if let path = Settings.shared.lastScriptPath,
                  FileManager.default.fileExists(atPath: path),
                  document.load(from: URL(fileURLWithPath: path)) {
            // Restored the last local script.
        } else {
            document.loadPlaceholder()
        }

        prompter.engine.start(drivenBy: prompter)
        prompter.engine.onManualScrollSettled = { [weak self] in
            self?.reanchorAfterManualScroll()
        }
        wireFlow()
        wireListener()

        showPanel()
        updateSampler()

        // Restore the phone link so a device that had the page open reconnects
        // on its own after a restart, instead of failing silently.
        if Settings.shared.phoneLinkEnabled { try? server.start() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        flow.stop()
        listener.stop()
        sampler.stop()
        server.stop()
        Settings.shared.savedFrame = panel.frame
        HotkeyManager.shared.unregisterAll()
        prompter.engine.stop()
    }

    private func buildPanel() {
        let frame = Settings.shared.savedFrame ?? defaultFrame()
        panel = PrompterPanel(contentRect: frame)
        prompter = PrompterView(frame: NSRect(origin: .zero, size: frame.size))
        prompter.autoresizingMask = [.width, .height]
        panel.contentView = prompter
    }

    private func defaultFrame() -> NSRect {
        let visible = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let width = min(560, visible.width * 0.4)
        let height = min(420, visible.height * 0.5)
        // Top-right by default: out of the way of a centered video grid, and
        // close to the camera on most laptops so your eyeline stays natural.
        return NSRect(
            x: visible.maxX - width - 32,
            y: visible.maxY - height - 32,
            width: width,
            height: height
        )
    }

    // MARK: - Hotkeys

    private func registerHotkeys() {
        let m = HotkeyManager.shared
        m.register(keyCode: Key.t, modifiers: Key.cmdOpt) { [weak self] in
            self?.togglePanelVisibility()
        }
        m.register(keyCode: Key.c, modifiers: Key.cmdOpt) { [weak self] in
            self?.toggleClickThrough()
        }
        m.register(keyCode: Key.p, modifiers: Key.cmdOpt) { [weak self] in
            self?.toggleAutoScroll()
        }
        m.register(keyCode: Key.r, modifiers: Key.cmdOpt) { [weak self] in
            self?.resync()
        }
        m.register(keyCode: Key.rightBracket, modifiers: Key.cmdOpt) { [weak self] in
            self?.nextSection()
        }
        m.register(keyCode: Key.leftBracket, modifiers: Key.cmdOpt) { [weak self] in
            self?.previousSection()
        }
        m.register(keyCode: Key.equal, modifiers: Key.cmdOpt) { [weak self] in
            self?.adjustFontSize(by: 2)
        }
        m.register(keyCode: Key.minus, modifiers: Key.cmdOpt) { [weak self] in
            self?.adjustFontSize(by: -2)
        }
        m.register(keyCode: Key.f, modifiers: Key.cmdOpt) { [weak self] in
            self?.toggleFollowMode()
        }
        m.register(keyCode: Key.a, modifiers: Key.cmdOpt) { [weak self] in
            self?.toggleAnswerMode()
        }
        m.register(keyCode: Key.z, modifiers: Key.cmdOpt) { [weak self] in
            self?.undoJump()
        }
        // Only route back in when the icon is hidden.
        m.register(keyCode: Key.m, modifiers: Key.cmdOpt) { [weak self] in
            guard let self, Settings.shared.hidesMenuBarIcon else { return }
            Settings.shared.hidesMenuBarIcon = false
            self.menuBar.setIconVisible(true)
        }
    }

    // MARK: - Speech-driven scrolling

    private func wireFlow() {
        flow.onCursor = { [weak self] cursor, isConfident in
            guard let self, self.autoScrolling else { return }

            if isConfident, let offset = self.prompter.scrollOffset(forWord: cursor) {
                self.prompter.engine.target = offset
            } else {
                // Lost the place: drop the spring target so the engine falls back
                // to drifting at the last measured pace rather than guessing.
                self.prompter.engine.target = nil
            }
            self.updateSpeed()
            self.server.broadcast(
                word: cursor,
                section: self.document.script.section(containingWord: cursor),
                isConfident: isConfident
            )
        }

        flow.onTranscript = { [weak self] text in
            guard let self, Settings.shared.showsDiagnostics else { return }
            let lock = self.flow.tracker.isConfident ? "lock" : "drift"
            let wpm = self.flow.measuredWPM.map { String(format: "%.0fwpm", $0) } ?? "--"
            self.prompter.setDebugLine(
                "you[\(lock) w\(self.flow.tracker.cursor) \(wpm)]: \(text.suffix(60))"
            )
        }

        flow.onStatus = { [weak self] message in
            guard let self else { return }
            if let message {
                self.prompter.setHeader(message)
            } else if let index = self.prompter.currentSectionIndex(),
                      index < self.document.script.sections.count {
                self.prompter.setHeader(self.document.script.sections[index].title)
            }
        }
    }

    private func wireListener() {
        // Veto while you are speaking: if you answered less than 2.5s ago you are
        // almost certainly still mid-answer, and the "question" is backchannel.
        listener.shouldAcceptJump = { [weak self] in
            guard let self else { return false }
            return self.flow.secondsSinceUserSpoke > 2.5
        }

        listener.onQuestion = { [weak self] match in
            guard let self, self.answerMode else { return }
            if let current = self.prompter.currentSectionIndex() {
                self.jumpHistory.append(current)
            }
            self.prompter.jump(toSection: match.sectionIndex)
            if let word = self.prompter.wordIndexAtReadingLine() {
                self.flow.reanchor(to: word)
            }
            self.prompter.setHeader("→ \(match.title)   (⌥⌘Z to undo)")
        }

        listener.onTranscript = { [weak self] text in
            guard let self, Settings.shared.showsDiagnostics else { return }
            self.prompter.setDebugLine("them: \(text.suffix(70))")
        }

        listener.onStatus = { [weak self] message in
            guard let self, let message else { return }
            self.prompter.setHeader(message)
        }
    }

    /// Undoes the last automatic jump. The matcher is deliberately strict, but
    /// when it is wrong it is wrong at the worst possible moment, so getting back
    /// must be instant and must not require finding the menu.
    func undoJump() {
        guard let previous = jumpHistory.popLast() else { return }
        prompter.jump(toSection: previous)
        if let word = prompter.wordIndexAtReadingLine() {
            flow.reanchor(to: word)
        }
    }

    /// Listens to the meeting audio and jumps to the matching answer.
    func toggleAnswerMode() {
        if answerMode {
            answerMode = false
            listener.stop()
            return
        }

        answerMode = true
        Task { @MainActor in
            if let error = await self.listener.start(script: self.document.script) {
                self.answerMode = false
                self.presentAlert("Could not listen to meeting audio", error)
            } else if !self.listener.semanticTierReady {
                self.prompter.setHeader("Listening (keyword matching only)")
            } else {
                self.prompter.setHeader("Listening for questions")
            }
        }
    }

    var isAnswering: Bool { answerMode }

    /// Turns speech following on or off. Auto-scroll is switched on with it,
    /// since following without scrolling does nothing visible.
    func toggleFollowMode() {
        if followMode {
            followMode = false
            flow.stop()
            prompter.engine.target = nil
            updateSpeed()
            return
        }

        followMode = true
        if !autoScrolling { toggleAutoScroll() }
        prompter.engine.mode = .seek

        // Seed the tracker at whatever is under the reading line so the first
        // match has a sensible search window instead of starting from word zero.
        if let word = prompter.wordIndexAtReadingLine() {
            flow.reanchor(to: word)
        }

        Task { @MainActor in
            if let error = await flow.start() {
                self.followMode = false
                self.prompter.engine.mode = self.autoScrolling ? .drift : .stopped
                self.presentAlert("Could not start speech following", error
                    + "\n\nAuto-scroll will keep running at a constant speed.")
            }
        }
    }

    var isFollowing: Bool { followMode }

    // MARK: - PrompterCommands

    var isPanelVisible: Bool { panel?.isVisible ?? false }
    var isClickThrough: Bool { panel?.isClickThrough ?? false }
    var isAutoScrolling: Bool { autoScrolling }
    var isMirrored: Bool { Settings.shared.mirrorHorizontally }
    var scriptName: String { document.displayName }
    var sectionTitles: [String] { document.script.sections.map(\.title) }

    func openScript() {
        let openPanel = NSOpenPanel()
        openPanel.allowedContentTypes = [
            .plainText, .text, .rtf,
            UTType("net.daringfireball.markdown") ?? .plainText,
            // Google Drive for Desktop stubs, resolved to a fetch on open.
            UTType(filenameExtension: "gdoc") ?? .plainText,
        ]
        openPanel.allowsOtherFileTypes = true
        openPanel.canChooseDirectories = false
        openPanel.allowsMultipleSelection = false
        openPanel.message = "Choose a script: markdown, plain text, or a .gdoc from your Google Drive folder."

        // Without this the file browser — and your filenames — appear in a
        // screen share. NSOpenPanel defaults to .readOnly, i.e. capturable.
        WindowCloak.cloak(openPanel)

        NSApp.activate(ignoringOtherApps: true)
        guard openPanel.runModal() == .OK, let url = openPanel.url else { return }

        if !document.load(from: url) {
            presentAlert(
                "Could not read that file",
                "The script must be UTF-8 text. Try re-saving it as plain text or markdown."
            )
        }
        showPanel()
    }

    func reloadScript() { document.reload() }

    /// Loads a script straight from a Google Docs link.
    ///
    /// Exports the document as HTML rather than plain text so real Google Docs
    /// headings survive as script sections. A document with no heading styles at
    /// all still works — short prompt lines are inferred as sections.
    func openGoogleDoc() {
        NSApp.activate(ignoringOtherApps: true)

        // If the clipboard already holds a usable link, skip the dialog entirely.
        if let pasted = NSPasteboard.general.string(forType: .string),
           let id = GoogleDocsLoader.documentID(from: pasted) {
            document.loadGoogleDoc(id: id)
            showPanel()
            return
        }

        let input = WindowCloak.promptForText(
            title: "Open a Google Doc",
            message: """
                Paste a Google Docs link. The document must be shared as \
                "Anyone with the link" — Share › General access › Anyone with the link.

                Reload (⌘R in the menu) re-fetches it, so edits you make in the \
                browser show up here without pasting the link again.
                """,
            placeholder: "https://docs.google.com/document/d/…"
        )
        guard let input else { return }

        guard let id = GoogleDocsLoader.documentID(from: input) else {
            presentAlert(
                "That is not a Google Docs link",
                GoogleDocsLoader.LoadError.notADocsURL.localizedDescription
            )
            return
        }
        document.loadGoogleDoc(id: id)
        showPanel()
    }

    func togglePanelVisibility() {
        if panel.isVisible {
            Settings.shared.savedFrame = panel.frame
            panel.orderOut(nil)
        } else {
            showPanel()
        }
    }

    private func showPanel() {
        // orderFrontRegardless, not makeKeyAndOrderFront: the panel must appear
        // without taking focus away from the meeting app.
        panel.orderFrontRegardless()
    }

    func toggleClickThrough() {
        panel.isClickThrough.toggle()
        // In click-through mode the panel cannot be clicked at all, so fade it
        // slightly as the only available visual confirmation of the state.
        panel.alphaValue = panel.isClickThrough ? 0.85 : 1.0
    }

    func toggleAutoScroll() {
        autoScrolling.toggle()
        prompter.engine.cancelManualOverride()
        prompter.engine.mode = autoScrolling ? .drift : .stopped
        updateSpeed()
    }

    func nextSection() { step(by: 1) }
    func previousSection() { step(by: -1) }

    private func step(by delta: Int) {
        let sections = document.script.sections
        guard !sections.isEmpty else { return }
        let current = prompter.currentSectionIndex() ?? 0
        let next = min(sections.count - 1, max(0, current + delta))
        prompter.jump(toSection: next)
        if let word = prompter.wordIndexAtReadingLine() {
            flow.reanchor(to: word)
        }
    }

    func resync() {
        prompter.engine.cancelManualOverride()
        reanchorAfterManualScroll()
    }

    /// After you scroll by hand, the tracker's cursor is stale — everything you
    /// said before the scroll describes a different part of the script. Re-seed
    /// it from the reading line rather than letting it fight you back.
    private func reanchorAfterManualScroll() {
        if let word = prompter.wordIndexAtReadingLine() {
            flow.reanchor(to: word)
            prompter.engine.target = prompter.scrollOffset(forWord: word)
        }
        if let index = prompter.currentSectionIndex(),
           index < document.script.sections.count {
            prompter.setHeader(document.script.sections[index].title)
        }
        broadcastCurrentPosition()
    }

    func adjustFontSize(by delta: CGFloat) {
        Settings.shared.fontSize += delta
    }

    func adjustSpeed(by delta: Double) {
        Settings.shared.fallbackWPM += delta
        updateSpeed()
    }

    func toggleMirror() {
        Settings.shared.mirrorHorizontally.toggle()
    }

    func toggleDimming() {
        Settings.shared.dimsDistantText.toggle()
    }

    func setThemeMode(_ raw: String) {
        let mode = Settings.ThemeMode(rawValue: raw) ?? .auto
        Settings.shared.themeMode = mode

        if mode == .auto, !BackgroundSampler.hasPermission {
            BackgroundSampler.requestPermission()
            presentAlert(
                "Automatic text colour needs Screen Recording",
                """
                To pick black or white from what is actually behind the panel, \
                Teleprompter has to read those pixels — which macOS gates behind \
                Screen Recording permission.

                Approve the prompt, or enable Teleprompter under System Settings › \
                Privacy & Security › Screen Recording, then quit and reopen the app.

                This does not make the prompter visible to anyone: the panel stays \
                excluded from capture, and it is excluded from its own sampling too.

                Until then, Automatic follows your Mac's Light/Dark setting, and \
                Always Black / Always White still work.
                """
            )
        }
        updateSampler()
    }

    /// Runs the sampler only in automatic mode, and only with permission.
    private func updateSampler() {
        guard Settings.shared.themeMode == .auto, BackgroundSampler.hasPermission else {
            sampler.stop()
            prompter.sampledIsLight = nil
            return
        }
        guard !sampler.isRunning else { return }

        sampler.onLuminance = { [weak self] luminance in
            self?.applyMeasuredLuminance(luminance)
        }
        sampler.start(frame: { [weak self] in self?.panel.frame ?? .zero })
    }

    /// Converts luminance into a colour choice, with hysteresis.
    ///
    /// A single threshold makes the text flicker whenever the background sits
    /// near mid-grey — which is exactly where a video call spends much of its
    /// time. Requiring a decisive move before switching costs nothing and stops
    /// the script strobing between black and white mid-sentence.
    private func applyMeasuredLuminance(_ luminance: Double) {
        let next: Bool
        switch prompter.sampledIsLight {
        case .some(true): next = luminance > 0.42   // stay light until clearly dark
        case .some(false): next = luminance > 0.60  // stay dark until clearly light
        case nil: next = luminance > 0.50
        }
        prompter.sampledIsLight = next

        if Settings.shared.showsDiagnostics {
            prompter.setDebugLine(
                String(format: "bg luminance %.2f -> %@ text",
                       luminance, next ? "black" : "white")
            )
        }
    }

    func toggleTextHalo() {
        Settings.shared.textHalo.toggle()
    }

    func toggleBorder() {
        Settings.shared.showsBorder.toggle()
    }

    func toggleReadingLine() {
        Settings.shared.showsReadingLine.toggle()
    }

    func adjustBackgroundOpacity(by delta: CGFloat) {
        Settings.shared.backgroundOpacity += delta
    }

    func toggleDiagnostics() {
        Settings.shared.showsDiagnostics.toggle()
        prompter.setDebugLine(
            Settings.shared.showsDiagnostics ? "diagnostics on — waiting for audio…" : nil
        )
    }

    var showsDiagnostics: Bool { Settings.shared.showsDiagnostics }

    /// Match strictness is script-dependent — vocabulary and section count both
    /// shift the scores — so it is a dial rather than a constant.
    func adjustMatchSensitivity(by delta: Double) {
        Settings.shared.matchSensitivity += delta
        listener.setScript(document.script)
        prompter.setHeader(
            String(format: "Match threshold: %.2f", Settings.shared.matchThreshold)
        )
    }

    func jump(toSection index: Int) {
        prompter.jump(toSection: index)
        broadcastCurrentPosition()
    }

    /// Mirrors wherever the Mac has moved to onto any connected phone.
    private func broadcastCurrentPosition() {
        guard server.isRunning, let word = prompter.wordIndexAtReadingLine() else { return }
        server.broadcast(
            word: word,
            section: document.script.section(containingWord: word),
            isConfident: true
        )
    }

    var isMenuBarIconHidden: Bool { Settings.shared.hidesMenuBarIcon }

    /// The menu-bar icon is the one part of this app that cannot be cloaked —
    /// the system draws it, so it appears in a full-screen share like any other
    /// menu-bar item. Hiding it leaves hotkeys as the only way in, so warn once.
    func toggleMenuBarIcon() {
        let nowHidden = !Settings.shared.hidesMenuBarIcon
        if nowHidden {
            let response = WindowCloak.runAlert(
                "Hide the menu bar icon?",
                """
                The icon is drawn by macOS, not by this app, so it is the one \
                thing here that a screen share can see.

                With it hidden, hotkeys are your only control:

                    ⌥⌘M   bring the icon back
                    ⌥⌘T   show or hide the prompter
                    ⌥⌘P   start or stop auto-scroll
                    ⌥⌘C   click-through on or off
                    ⌥⌘R   resync after scrolling by hand
                    ⌥⌘[ ]  previous / next section
                """
            )
            guard response == .alertFirstButtonReturn else { return }
        }
        Settings.shared.hidesMenuBarIcon = nowHidden
        menuBar.setIconVisible(!nowHidden)
    }

    /// Converts words-per-minute into points-per-second using the actual laid-out
    /// document, so the speed stays honest across font sizes and panel widths.
    private func updateSpeed() {
        // Once speech tracking has measured your real pace, drift at that rate
        // instead of the configured default — so losing the alignment lock keeps
        // the script moving at roughly the speed you were already speaking.
        let wpm = flow.measuredWPM ?? Settings.shared.fallbackWPM
        let pointsPerWord = prompter.pointsPerWord
        prompter.engine.pointsPerSecond = pointsPerWord * CGFloat(wpm / 60.0)
    }

    // MARK: - Invisibility self-test

    /// Confirms with the window server that the panel is flagged non-shareable.
    ///
    /// This reads `kCGWindowSharingState`, which is the exact property capture
    /// APIs consult, and needs no Screen Recording permission. It proves the flag
    /// is set; it cannot prove a given app honors it, so the alert still asks for
    /// one real capture check.
    /// Starts the local server if needed and shows a QR code to point a phone at.
    ///
    /// A phone is the strongest answer to screen-share invisibility available:
    /// it is a different device, so it cannot appear in a capture at all.
    func showOnPhone() {
        if !server.isRunning {
            do {
                try server.start()
                Settings.shared.phoneLinkEnabled = true
            } catch {
                presentAlert(
                    "Could not start the phone link",
                    "No local port was available. \(error.localizedDescription)"
                )
                return
            }
        }

        guard let url = server.url else {
            presentAlert(
                "Not connected to a network",
                """
                The Mac needs to be on wifi for a phone to reach it. Join a \
                network and try again.
                """
            )
            return
        }

        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Open this on your phone"
        let others = server.candidateURLs
            .filter { $0.url != url }
            .map { "\($0.interface):  \($0.url.absoluteString)" }
            .joined(separator: "\n")

        alert.informativeText = """
            Scan with your phone's camera, on the same wifi as this Mac.

            \(url.absoluteString)
            \(others.isEmpty ? "" : "\nOther addresses on this Mac:\n\(others)\n")
            If the page will not open, the wifi is probably blocking device-to-device \
            traffic. Turn on your phone's hotspot, join this Mac to it, and open this \
            menu again for a new address.

            The script follows along as you speak and jumps with the answer \
            matcher, exactly as it does here. Scroll by touch any time — it \
            resumes following a few seconds later.

            The link carries a private key, so nobody else on the network can \
            read your script. It survives restarts — rotate it from the menu to \
            revoke links you have already shared.
            """
        alert.addButton(withTitle: "Copy Link")
        alert.addButton(withTitle: "Done")
        if let qr = Self.qrImage(for: url.absoluteString) {
            // NSImageView(image:) comes back with a zero frame, and NSAlert sizes
            // its accessory view from that frame — so the code was present but
            // laid out at zero size and never appeared.
            let view = NSImageView(frame: NSRect(origin: .zero, size: qr.size))
            view.image = qr
            view.imageScaling = .scaleNone
            alert.accessoryView = view
        }
        WindowCloak.cloak(alert.window)

        if alert.runModal() == .alertFirstButtonReturn {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(url.absoluteString, forType: .string)
        }
    }

    var isServingToPhone: Bool { server.isRunning }

    func stopPhoneLink() {
        server.stop()
        Settings.shared.phoneLinkEnabled = false
    }

    /// Rotates the access key, invalidating every link already handed out.
    func regeneratePhoneKey() {
        Settings.shared.phoneLinkToken = Settings.makeToken()
        presentAlert(
            "Phone key rotated",
            "Existing links no longer work. Open \"Show on Phone…\" to scan the new code."
        )
    }

    private static func qrImage(for string: String) -> NSImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(string.utf8), forKey: "inputMessage")
        // High correction: the code still scans on a dim laptop screen.
        filter.setValue("H", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { return nil }

        // Nearest-neighbour at a whole-number scale. The generator emits roughly
        // 43x43; smoothing it up to display size softens the module edges, which
        // is the one thing a scanner needs to be crisp.
        let scale = max(1, (220 / output.extent.width).rounded(.down))
        let scaled = output
            .samplingNearest()
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))

        let context = CIContext()
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else {
            return nil
        }
        return NSImage(cgImage: cgImage, size: scaled.extent.size)
    }

    func runInvisibilitySelfTest() {
        let ours = panel.windowNumber
        let info = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]]

        let entry = info?.first { ($0[kCGWindowNumber as String] as? Int) == ours }
        let sharingState = entry?[kCGWindowSharingState as String] as? Int

        let body: String
        if entry == nil {
            body = """
            The panel is not currently listed by the window server. \
            Make sure the prompter is visible (⌥⌘T), then run this check again.
            """
        } else if sharingState == 0 {
            body = """
            Confirmed: the window server reports this panel as non-shareable \
            (sharing state 0). Screen capture APIs will skip it.

            One real check is still worth doing, because it tests the meeting app \
            rather than the flag:

            1. Open QuickTime Player → File → New Screen Recording
            2. Record your whole screen for a few seconds, then play it back
            3. The panel should be absent from the recording but visible to you

            Repeat after any Zoom or Chrome update.
            """
        } else {
            body = """
            Warning: sharing state is \(sharingState.map(String.init) ?? "unknown"), \
            not 0. The panel may be visible in screen shares. Do not rely on it \
            until this reads 0.
            """
        }

        presentAlert("Invisibility check", body)
    }

    private func presentAlert(_ title: String, _ body: String) {
        NSApp.activate(ignoringOtherApps: true)
        WindowCloak.runAlert(title, body)
    }
}
