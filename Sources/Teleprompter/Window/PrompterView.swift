import AppKit

/// Intercepts trackpad scrolling before the scroll view consumes it, so the
/// engine can yield to manual input. Subclassing the scroll view (rather than
/// the text view) catches wheel events wherever they land inside the panel.
final class PrompterScrollView: NSScrollView {
    var onManualScroll: (() -> Void)?

    override func scrollWheel(with event: NSEvent) {
        onManualScroll?()
        super.scrollWheel(with: event)
    }

    /// Keep every mouse event at this level. The text view would otherwise
    /// swallow clicks, leaving no way to drag the panel by its middle — which is
    /// most of its surface.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        return bounds.contains(local) ? self : nil
    }

    /// Click anywhere and drag to move the window. `performDrag` runs AppKit's
    /// own drag loop, so this keeps snapping and multi-display behaviour without
    /// tracking mouse events by hand.
    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }
}

/// Non-interactive overlay: the reading line plus top/bottom fades.
/// Returns nil from hitTest so it never intercepts a scroll gesture.
private final class OverlayView: NSView {
    var readingLineFraction: CGFloat = 0.4 { didSet { needsDisplay = true } }
    var showsFades = true { didSet { needsDisplay = true } }
    var isLight = true { didSet { needsDisplay = true } }
    var showsBorder = true { didSet { needsDisplay = true } }
    var cornerRadius: CGFloat = 12

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let y = (bounds.height * readingLineFraction).rounded()

        // Off by default. The previous version darkened the top 22% and bottom
        // 33%, which split the panel into three visible bands instead of reading
        // as one continuous page. When enabled it is now a narrow, gentle edge
        // treatment that never encroaches on the text you are reading.
        if showsFades {
            let band = bounds.height * 0.10
            drawFade(from: 0, to: band, topDown: true)
            drawFade(from: bounds.height - band, to: bounds.height, topDown: false)
        }

        // The reading line: where the word you are currently saying sits.
        // Deliberately faint — it should register in peripheral vision only.
        NSColor.systemTeal.withAlphaComponent(0.28).setStroke()
        let line = NSBezierPath()
        line.lineWidth = 1
        line.move(to: NSPoint(x: 10, y: y + 0.5))
        line.line(to: NSPoint(x: bounds.width - 10, y: y + 0.5))
        line.stroke()

        if showsBorder { drawBorder() }

        NSColor.systemTeal.withAlphaComponent(0.55).setFill()
        for isLeft in [true, false] {
            let tri = NSBezierPath()
            let x: CGFloat = isLeft ? 4 : bounds.width - 4
            let dir: CGFloat = isLeft ? 1 : -1
            tri.move(to: NSPoint(x: x, y: y - 5))
            tri.line(to: NSPoint(x: x + 7 * dir, y: y))
            tri.line(to: NSPoint(x: x, y: y + 5))
            tri.close()
            tri.fill()
        }
    }

    /// Two concentric strokes, dark outside and light inside.
    ///
    /// A single-colour border disappears against a matching background, and with
    /// a transparent panel the background is whatever the video call happens to
    /// be showing. One of the two strokes always has contrast.
    private func drawBorder() {
        let outer = NSBezierPath(
            roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
            xRadius: cornerRadius, yRadius: cornerRadius
        )
        outer.lineWidth = 1
        NSColor.black.withAlphaComponent(0.45).setStroke()
        outer.stroke()

        let inner = NSBezierPath(
            roundedRect: bounds.insetBy(dx: 1.5, dy: 1.5),
            xRadius: max(0, cornerRadius - 1), yRadius: max(0, cornerRadius - 1)
        )
        inner.lineWidth = 1
        NSColor.white.withAlphaComponent(0.55).setStroke()
        inner.stroke()
    }

    private func drawFade(from y0: CGFloat, to y1: CGFloat, topDown: Bool) {
        guard y1 > y0 else { return }
        // Fade toward the panel's own background, not always toward black.
        let base: NSColor = isLight ? .white : .black
        let clear = base.withAlphaComponent(0.0)
        let solid = base.withAlphaComponent(0.35)
        let gradient = topDown
            ? NSGradient(starting: solid, ending: clear)
            : NSGradient(starting: clear, ending: solid)
        gradient?.draw(in: NSRect(x: 0, y: y0, width: bounds.width, height: y1 - y0),
                       angle: -90)
    }
}

/// The script surface: a TextKit 1 stack inside a scroll view, plus the mapping
/// between word indices and scroll offsets that the tracker needs.
///
/// TextKit 1 is chosen deliberately over TextKit 2 — `NSLayoutManager` gives a
/// direct, cheap word-index-to-rectangle query, which is called every frame.
final class PrompterView: NSView {

    /// The panel's only background.
    ///
    /// Both themes share this one layer. They previously took different paths —
    /// a blur for dark, a solid fill for light — and the two behaved differently
    /// in ways that read as unrelated bugs: the blur ignored the opacity setting
    /// so dark was never transparent, while light at 0% rendered fully
    /// transparent pixels and stopped receiving mouse events altogether.
    private let solidBackground = NSView()
    private let scrollView = PrompterScrollView()
    private let overlay = OverlayView()
    private let headerLabel = NSTextField(labelWithString: "")
    /// Live transcript, shown only when diagnostics are on. Being able to see
    /// what the recognizer actually heard turns "it didn't work" into a fact.
    private let debugLabel = NSTextField(labelWithString: "")

    private let textStorage = NSTextStorage()
    private let layoutManager = NSLayoutManager()
    private let textContainer = NSTextContainer()
    private let textView: NSTextView

    private(set) var script = ParsedScript.empty
    private(set) lazy var engine = ScrollEngine(scrollView: scrollView)

    /// Grab band around the panel edge for resizing. The window is borderless,
    /// so it has no system-drawn resize control and this stands in for one.
    private let resizeMargin: CGFloat = 10

    /// Lowest background alpha that still lets the window take mouse events.
    private static let minimumHitTestableOpacity: CGFloat = 0.03
    private struct Edges: OptionSet {
        let rawValue: Int
        static let left = Edges(rawValue: 1)
        static let right = Edges(rawValue: 2)
        static let top = Edges(rawValue: 4)
        static let bottom = Edges(rawValue: 8)
    }
    private var activeEdges: Edges = []
    private var initialFrame: NSRect = .zero
    private var initialMouse: NSPoint = .zero

    override var isFlipped: Bool { true }

    // MARK: - Move and resize

    private func edges(at point: NSPoint) -> Edges {
        var result: Edges = []
        if point.x <= resizeMargin { result.insert(.left) }
        if point.x >= bounds.width - resizeMargin { result.insert(.right) }
        // The view is flipped, so y == 0 is the panel's top edge.
        if point.y <= resizeMargin { result.insert(.top) }
        if point.y >= bounds.height - resizeMargin { result.insert(.bottom) }
        return result
    }

    /// Claim edge hits before the scroll view sees them, so the border band
    /// resizes while the interior still drags and scrolls.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard bounds.contains(local) else { return nil }
        return edges(at: local).isEmpty ? super.hitTest(point) : self
    }

    override func mouseDown(with event: NSEvent) {
        let local = convert(event.locationInWindow, from: nil)
        activeEdges = edges(at: local)
        if activeEdges.isEmpty {
            window?.performDrag(with: event)
        } else {
            initialFrame = window?.frame ?? .zero
            initialMouse = NSEvent.mouseLocation
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard !activeEdges.isEmpty, let window else { return }

        // Screen coordinates are bottom-up while this view is flipped, so the
        // top edge grows the height and the bottom edge also moves the origin.
        let current = NSEvent.mouseLocation
        let dx = current.x - initialMouse.x
        let dy = current.y - initialMouse.y

        var frame = initialFrame
        if activeEdges.contains(.left) { frame.origin.x += dx; frame.size.width -= dx }
        if activeEdges.contains(.right) { frame.size.width += dx }
        if activeEdges.contains(.top) { frame.size.height += dy }
        if activeEdges.contains(.bottom) { frame.origin.y += dy; frame.size.height -= dy }

        // Clamp without letting a dragged edge walk the opposite one off screen.
        let minSize = window.minSize
        if frame.size.width < minSize.width {
            if activeEdges.contains(.left) { frame.origin.x = NSMaxX(initialFrame) - minSize.width }
            frame.size.width = minSize.width
        }
        if frame.size.height < minSize.height {
            if activeEdges.contains(.bottom) { frame.origin.y = NSMaxY(initialFrame) - minSize.height }
            frame.size.height = minSize.height
        }

        window.setFrame(frame, display: true)
    }

    override func mouseUp(with event: NSEvent) {
        activeEdges = []
        if let frame = window?.frame { Settings.shared.savedFrame = frame }
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        let m = resizeMargin
        addCursorRect(NSRect(x: 0, y: 0, width: m, height: bounds.height),
                      cursor: .resizeLeftRight)
        addCursorRect(NSRect(x: bounds.width - m, y: 0, width: m, height: bounds.height),
                      cursor: .resizeLeftRight)
        addCursorRect(NSRect(x: 0, y: 0, width: bounds.width, height: m),
                      cursor: .resizeUpDown)
        addCursorRect(NSRect(x: 0, y: bounds.height - m, width: bounds.width, height: m),
                      cursor: .resizeUpDown)
    }

    // MARK: - Setup

    override init(frame frameRect: NSRect) {
        textStorage.addLayoutManager(layoutManager)
        layoutManager.addTextContainer(textContainer)
        textView = NSTextView(frame: .zero, textContainer: textContainer)
        super.init(frame: frameRect)
        build()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func build() {
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.masksToBounds = true

        solidBackground.wantsLayer = true
        addSubview(solidBackground)

        textContainer.widthTracksTextView = true
        textContainer.containerSize = NSSize(
            width: 0, height: CGFloat.greatestFiniteMagnitude
        )

        textView.isEditable = false
        textView.isSelectable = false
        textView.drawsBackground = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainerInset = NSSize(width: 22, height: 0)
        textView.minSize = .zero
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )

        scrollView.documentView = textView
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.verticalScrollElasticity = .allowed
        scrollView.horizontalScrollElasticity = .none
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.onManualScroll = { [weak self] in self?.engine.noteManualScroll() }
        addSubview(scrollView)

        addSubview(overlay)

        headerLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        headerLabel.lineBreakMode = .byTruncatingTail
        addSubview(headerLabel)

        debugLabel.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        debugLabel.lineBreakMode = .byTruncatingHead
        debugLabel.isHidden = true
        addSubview(debugLabel)

        applySettings()
        NotificationCenter.default.addObserver(
            self, selector: #selector(applySettings),
            name: Settings.didChange, object: nil
        )
        DistributedNotificationCenter.default.addObserver(
            self, selector: #selector(systemAppearanceChanged),
            name: Notification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil
        )
    }

    override func layout() {
        super.layout()
        solidBackground.frame = bounds
        overlay.frame = bounds
        headerLabel.frame = NSRect(x: 14, y: 6, width: bounds.width - 28, height: 14)

        let top: CGFloat = 24
        let bottom: CGFloat = debugLabel.isHidden ? 0 : 18
        debugLabel.frame = NSRect(
            x: 14, y: bounds.height - 15, width: bounds.width - 28, height: 13
        )
        scrollView.frame = NSRect(
            x: 0, y: top,
            width: bounds.width, height: max(0, bounds.height - top - bottom)
        )

        // Insets let the very first and very last word reach the reading line.
        let line = readingLineY
        scrollView.contentInsets = NSEdgeInsets(
            top: line, left: 0,
            bottom: max(0, scrollView.bounds.height - line), right: 0
        )
    }

    /// Latest reading from the background sampler, when automatic colour is on.
    /// Nil means no measurement is available and the system setting stands in.
    var sampledIsLight: Bool? {
        didSet { if oldValue != sampledIsLight { applySettings() } }
    }

    /// Whether to draw dark-on-light or light-on-dark.
    ///
    /// In `.auto` this reflects the measured luminance of whatever sits behind
    /// the panel, falling back to the system Light/Dark setting when Screen
    /// Recording permission has not been granted.
    private var isLightTheme: Bool {
        switch Settings.shared.themeMode {
        case .light: return true
        case .dark: return false
        case .auto:
            // A real measurement of what is behind the panel when we have one,
            // otherwise fall back to the system Light/Dark setting.
            if let sampledIsLight { return sampledIsLight }
            return NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) != .darkAqua
        }
    }

    var scriptTextColor: NSColor { isLightTheme ? .black : .white }

    /// Headings stay a shade of teal in both themes, darkened for light so it
    /// keeps enough contrast against a pale background.
    var headingTextColor: NSColor {
        isLightTheme
            ? NSColor(calibratedRed: 0.00, green: 0.36, blue: 0.42, alpha: 1)
            : .systemTeal
    }

    /// White behind black text, black behind white — only when enabled.
    var haloColor: NSColor? {
        guard Settings.shared.textHalo else { return nil }
        return (isLightTheme ? NSColor.white : .black).withAlphaComponent(0.9)
    }

    /// The notification arrives fractionally before `effectiveAppearance`
    /// actually flips, so re-read on the next runloop pass rather than now.
    @objc private func systemAppearanceChanged() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.applySettings()
        }
    }

    @objc private func applySettings() {
        let s = Settings.shared
        overlay.readingLineFraction = s.readingLineFraction
        overlay.showsFades = s.dimsDistantText
        overlay.isLight = isLightTheme
        overlay.showsBorder = s.showsBorder

        // Opacity applies to the background only, never to the whole view.
        // Fading the view dimmed the text along with it, which is why black text
        // looked washed out rather than black.
        alphaValue = 1.0

        // No lower clamp: 0 is a supported setting, giving a fully transparent
        // panel with the script floating directly on the call.
        // A window only receives mouse events where its content is not fully
        // transparent, so the fill needs a floor. At 3% it is imperceptible but
        // it keeps the panel scrollable and draggable at "0%" opacity.
        let opacity = max(Self.minimumHitTestableOpacity, s.backgroundOpacity)
        solidBackground.layer?.backgroundColor = (isLightTheme ? NSColor.white : .black)
            .withAlphaComponent(opacity).cgColor
        headerLabel.textColor = scriptTextColor.withAlphaComponent(0.55)
        debugLabel.textColor = isLightTheme
            ? NSColor(calibratedRed: 0.55, green: 0.30, blue: 0.0, alpha: 0.9)
            : NSColor.systemYellow.withAlphaComponent(0.75)

        // Beam-splitter rigs need the text flipped; the overlay is left alone.
        scrollView.layer?.setAffineTransform(
            s.mirrorHorizontally
                ? CGAffineTransform(scaleX: -1, y: 1)
                    .translatedBy(x: -scrollView.bounds.width, y: 0)
                : .identity
        )

        if !script.displayText.isEmpty {
            renderText(preservingPosition: true)
        }
        needsLayout = true
    }

    // MARK: - Script

    func load(_ newScript: ParsedScript, sourceName: String?) {
        script = newScript
        headerLabel.stringValue = sourceName ?? ""
        renderText(preservingPosition: false)
        engine.snap(to: -readingLineY)
    }

    private func renderText(preservingPosition: Bool) {
        let anchorWord = preservingPosition ? wordIndexAtReadingLine() : nil

        let attributed = ScriptRenderer.attributedString(
            for: script,
            fontSize: Settings.shared.fontSize,
            textColor: scriptTextColor,
            headingColor: headingTextColor,
            haloColor: haloColor
        )
        textStorage.setAttributedString(attributed)
        layoutManager.ensureLayout(for: textContainer)

        if let anchorWord, let y = documentY(forWord: anchorWord) {
            engine.snap(to: y - readingLineY)
        }
    }

    // MARK: - Geometry

    /// Reading-line offset in points from the top of the scrolling area.
    var readingLineY: CGFloat {
        scrollView.bounds.height * Settings.shared.readingLineFraction
    }

    /// Vertical center of a character range in document coordinates.
    func documentY(forCharacterRange range: NSRange) -> CGFloat? {
        guard range.length > 0, NSMaxRange(range) <= textStorage.length else { return nil }
        let glyphRange = layoutManager.glyphRange(
            forCharacterRange: range, actualCharacterRange: nil
        )
        var rect = layoutManager.boundingRect(
            forGlyphRange: glyphRange, in: textContainer
        )
        rect.origin.y += textView.textContainerOrigin.y
        return rect.midY
    }

    /// Vertical center of a word in document coordinates.
    func documentY(forWord index: Int) -> CGFloat? {
        guard index >= 0, index < script.words.count else { return nil }
        return documentY(forCharacterRange: script.words[index].range)
    }

    /// Scroll offset that places `index` exactly on the reading line.
    func scrollOffset(forWord index: Int) -> CGFloat? {
        documentY(forWord: index).map { $0 - readingLineY }
    }

    /// Average vertical distance one spoken word advances the page.
    ///
    /// Measured from the laid-out document rather than estimated from font
    /// metrics, so words-per-minute stays accurate across font sizes, panel
    /// widths, and scripts with different paragraph density.
    var pointsPerWord: CGFloat {
        guard !script.words.isEmpty,
              let document = scrollView.documentView,
              document.frame.height > 0
        else { return 0 }
        return document.frame.height / CGFloat(script.words.count)
    }

    /// Which word is currently sitting on the reading line. Used to re-anchor
    /// after you scroll by hand, so auto-scroll resumes from where you actually are.
    func wordIndexAtReadingLine() -> Int? {
        guard !script.words.isEmpty, textStorage.length > 0 else { return nil }

        let docY = scrollView.contentView.bounds.origin.y + readingLineY
        let point = NSPoint(x: 4, y: docY - textView.textContainerOrigin.y)
        let glyphIndex = layoutManager.glyphIndex(for: point, in: textContainer)
        let charIndex = layoutManager.characterIndexForGlyph(at: glyphIndex)
        return wordIndex(nearestCharacter: charIndex)
    }

    /// Last word starting at or before `charIndex`.
    private func wordIndex(nearestCharacter charIndex: Int) -> Int? {
        let words = script.words
        guard !words.isEmpty else { return nil }

        var low = 0
        var high = words.count - 1
        var best = 0
        while low <= high {
            let mid = (low + high) / 2
            if words[mid].range.location <= charIndex {
                best = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return best
    }

    // MARK: - Navigation

    func jump(toSection index: Int, animated: Bool = false) {
        guard index >= 0, index < script.sections.count else { return }
        let section = script.sections[index]
        headerLabel.stringValue = section.title

        // Measuring against a stale layout would land on the wrong line.
        layoutManager.ensureLayout(for: textContainer)

        // Land on the section's first spoken word, with its heading just above.
        //
        // This previously looked the *title's* character position up in the word
        // index — but that index holds body words only, because headings are
        // never read aloud and must not take part in speech alignment. The lookup
        // therefore returned the last word at or before the title, which is the
        // last body word of the PREVIOUS section. Choosing a section scrolled to
        // the end of the one before it.
        let documentTarget: CGFloat?
        if section.wordCount > 0 {
            documentTarget = documentY(forWord: section.firstWordIndex)
        } else {
            // A heading with nothing under it: aim at the heading itself.
            documentTarget = documentY(forCharacterRange: section.titleRange)
        }
        guard let y = documentTarget else { return }

        let offset = y - readingLineY
        engine.cancelManualOverride()
        if animated {
            engine.target = offset
        } else {
            engine.snap(to: offset)
            engine.target = offset
        }
    }

    func currentSectionIndex() -> Int? {
        wordIndexAtReadingLine().flatMap { script.section(containingWord: $0) }
    }

    func setHeader(_ text: String) {
        headerLabel.stringValue = text
    }

    func setDebugLine(_ text: String?) {
        let wasHidden = debugLabel.isHidden
        debugLabel.isHidden = (text == nil)
        debugLabel.stringValue = text ?? ""
        if wasHidden != debugLabel.isHidden { needsLayout = true }
    }
}
