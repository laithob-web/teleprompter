import Foundation

/// Loads a script file and reloads it when it changes on disk, so you can keep
/// the script open in an editor and see edits appear in the panel live.
final class ScriptDocument {

    /// Where the current script came from, so Reload knows whether to re-read a
    /// file or re-fetch from Google.
    enum Source {
        case none
        case file(URL)
        case googleDoc(id: String, title: String)
    }

    private(set) var source: Source = .none
    private(set) var script = ParsedScript.empty

    var onChange: ((ParsedScript, String) -> Void)?
    /// Surfaces async load failures, since Google fetches can fail long after
    /// the menu command returns.
    var onError: ((String) -> Void)?

    private var watcher: DispatchSourceFileSystemObject?
    private var watchedDescriptor: CInt = -1

    var url: URL? {
        if case .file(let url) = source { return url }
        return nil
    }

    var displayName: String {
        switch source {
        case .none: return "No script loaded"
        case .file(let url): return url.lastPathComponent
        case .googleDoc(_, let title): return title
        }
    }

    // MARK: - Loading

    @discardableResult
    func load(from url: URL) -> Bool {
        // A .gdoc is not a document — it is a JSON stub pointing at one in the
        // cloud, so opening it has to turn into a fetch.
        if url.pathExtension.lowercased() == "gdoc" {
            guard let id = GoogleDocsLoader.documentID(fromGDocFileAt: url) else {
                return false
            }
            let title = url.deletingPathExtension().lastPathComponent
            loadGoogleDoc(id: id, title: title)
            return true
        }

        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            return false
        }
        source = .file(url)
        script = ScriptParser.parse(text)
        Settings.shared.lastScriptPath = url.path
        Settings.shared.lastGoogleDocID = nil
        startWatching(url)
        onChange?(script, url.lastPathComponent)
        return true
    }

    /// Loads from a pasted Google Docs link, a bare document id, or a .gdoc stub.
    func loadGoogleDoc(id: String, title: String = "Google Doc") {
        stopWatching()
        onChange?(script, "Loading \(title)…")

        Task { @MainActor in
            do {
                let markdown = try await GoogleDocsLoader.fetchMarkdown(documentID: id)
                self.source = .googleDoc(id: id, title: title)
                self.script = ScriptParser.parse(markdown)
                Settings.shared.lastGoogleDocID = id
                Settings.shared.lastGoogleDocTitle = title
                Settings.shared.lastScriptPath = nil
                self.onChange?(self.script, title)
            } catch {
                self.onError?(error.localizedDescription)
            }
        }
    }

    /// Re-reads a local file, or re-fetches a Google Doc so edits made in the
    /// browser show up without reopening the link.
    func reload() {
        switch source {
        case .none:
            break
        case .file(let url):
            load(from: url)
        case .googleDoc(let id, let title):
            loadGoogleDoc(id: id, title: title)
        }
    }

    func loadPlaceholder() {
        script = ScriptParser.parse(Self.placeholder)
        onChange?(script, "Sample script")
    }

    // MARK: - File watching

    private func startWatching(_ url: URL) {
        stopWatching()

        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { return }
        watchedDescriptor = fd

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .delete, .extend],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let events = source.data
            // Editors that save by replacing the file break the descriptor, so
            // re-open by path rather than trusting the old handle.
            if events.contains(.rename) || events.contains(.delete) {
                self.stopWatching()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    self.reload()
                }
            } else {
                self.reload()
            }
        }
        source.setCancelHandler { [weak self] in
            if let fd = self?.watchedDescriptor, fd >= 0 { close(fd) }
            self?.watchedDescriptor = -1
        }
        source.resume()
        watcher = source
    }

    private func stopWatching() {
        watcher?.cancel()
        watcher = nil
    }

    deinit { stopWatching() }

    // MARK: -

    private static let placeholder = """
    ## Welcome — this is your teleprompter
    <!-- triggers: how does this work, what is this -->

    This panel is invisible to screen sharing. Open Zoom, Teams, or Google Meet, \
    share your entire screen, and this text will not appear in what anyone else sees.

    Two-finger scroll anywhere on this panel to move through the script by hand. \
    Auto-scroll pauses while you do, then picks up from wherever you stopped.

    ## Loading your own script

    Choose "Open Script…" from the menu bar icon. Scripts are markdown files where \
    each `##` heading is a question and the text underneath is your answer.

    Keep the file open in your editor while you work — the panel reloads \
    automatically every time you save.

    ## Keyboard shortcuts

    Option-Command-T shows and hides this panel. Option-Command-P starts and stops \
    auto-scroll. Option-Command-C makes the panel click-through, so the pointer \
    passes straight to the meeting window behind it.

    Use Option-Command-bracket to move between sections, and Option-Command-R to \
    resync after scrolling by hand.
    """
}
