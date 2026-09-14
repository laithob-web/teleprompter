import AppKit

/// One row in the section list.
struct SidebarEntry {
    let sectionIndex: Int
    let title: String
    /// A heading with nothing under it — a group label such as "3A · Results".
    let isGroup: Bool
}

/// The clickable section list docked on the left edge of the prompter.
///
/// It lives inside the prompter's own window rather than in a second one, so it
/// inherits everything the panel already does: excluded from screen capture,
/// raised above fullscreen slides, moved and resized with the panel. A separate
/// window would need each of those applied again and kept in sync by hand.
final class SectionSidebarView: NSView {

    var onSelect: ((Int) -> Void)?

    var entries: [SidebarEntry] = [] {
        didSet { rows.entries = entries }
    }

    /// Section under the reading line, highlighted and kept in view.
    var currentSection: Int? {
        didSet {
            guard oldValue != currentSection else { return }
            rows.currentSection = currentSection
            revealCurrent()
        }
    }

    var textColor: NSColor = .black {
        didSet { rows.textColor = textColor }
    }

    var accentColor: NSColor = .systemTeal {
        didSet { rows.accentColor = accentColor }
    }

    private let scrollView = NSScrollView()
    private let rows = SectionRowsView()

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.verticalScrollElasticity = .allowed
        scrollView.horizontalScrollElasticity = .none
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.documentView = rows
        addSubview(scrollView)
        rows.onSelect = { [weak self] index in self?.onSelect?(index) }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func layout() {
        super.layout()
        // Leave room on the right for the divider.
        scrollView.frame = NSRect(x: 0, y: 0, width: max(0, bounds.width - 3), height: bounds.height)
        rows.relayout(width: scrollView.contentSize.width)
        revealCurrent()
    }

    /// Two strokes, dark and light, for the same reason as the panel border: over
    /// a transparent panel the backdrop is whatever the call shows, and one of the
    /// two always has contrast.
    override func draw(_ dirtyRect: NSRect) {
        let x = bounds.maxX - 1.5
        let dark = NSBezierPath()
        dark.move(to: NSPoint(x: x, y: 6))
        dark.line(to: NSPoint(x: x, y: bounds.height - 6))
        dark.lineWidth = 1
        NSColor.black.withAlphaComponent(0.28).setStroke()
        dark.stroke()

        let light = NSBezierPath()
        light.move(to: NSPoint(x: x + 1, y: 6))
        light.line(to: NSPoint(x: x + 1, y: bounds.height - 6))
        light.lineWidth = 1
        NSColor.white.withAlphaComponent(0.4).setStroke()
        light.stroke()
    }

    private func revealCurrent() {
        guard let rect = rows.rect(forSection: currentSection) else { return }
        rows.scrollToVisible(rect.insetBy(dx: 0, dy: -28))
    }
}

/// Draws the rows and handles clicks. Custom-drawn rather than a table view: a
/// table accepts first responder, and a click would move keyboard focus into the
/// panel — breaking the meeting app's mute shortcut until you clicked back.
private final class SectionRowsView: NSView {

    var entries: [SidebarEntry] = [] {
        didSet { relayout(width: bounds.width) }
    }
    var currentSection: Int? { didSet { needsDisplay = true } }
    var textColor: NSColor = .black { didSet { needsDisplay = true } }
    var accentColor: NSColor = .systemTeal { didSet { needsDisplay = true } }
    var onSelect: ((Int) -> Void)?

    private var frames: [NSRect] = []
    private var hovered: Int? {
        didSet { if oldValue != hovered { needsDisplay = true } }
    }
    private var trackingArea: NSTrackingArea?

    private let horizontalPadding: CGFloat = 10
    private let verticalPadding: CGFloat = 5
    private let maximumLines = 2

    override var isFlipped: Bool { true }

    // A click must land on the first try, and must not take keyboard focus away
    // from the meeting app.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var acceptsFirstResponder: Bool { false }
    override var needsPanelToBecomeKey: Bool { false }

    // MARK: Layout

    func relayout(width: CGFloat) {
        guard width > 0 else { return }
        var y: CGFloat = 4
        frames = entries.map { entry in
            let height = rowHeight(for: entry, width: width)
            defer { y += height }
            return NSRect(x: 0, y: y, width: width, height: height)
        }
        setFrameSize(NSSize(width: width, height: y + 4))
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
    }

    private func font(for entry: SidebarEntry, isCurrent: Bool) -> NSFont {
        entry.isGroup
            ? .systemFont(ofSize: 10.5, weight: .semibold)
            : .systemFont(ofSize: 12.5, weight: isCurrent ? .semibold : .regular)
    }

    private func paragraphStyle() -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byWordWrapping
        style.lineHeightMultiple = 1.05
        return style
    }

    private func rowHeight(for entry: SidebarEntry, width: CGFloat) -> CGFloat {
        let font = font(for: entry, isCurrent: false)
        let textWidth = max(10, width - horizontalPadding * 2)
        let measured = (entry.title as NSString).boundingRect(
            with: NSSize(width: textWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin],
            attributes: [.font: font, .paragraphStyle: paragraphStyle()]
        ).height
        // Long titles are capped at two lines and truncated, so one wordy
        // question cannot push the rest of the list off the panel.
        let lineHeight = ceil(font.ascender - font.descender + font.leading) * 1.05
        let capped = min(ceil(measured), lineHeight * CGFloat(maximumLines))
        let groupGap: CGFloat = entry.isGroup ? 6 : 0
        return capped + verticalPadding * 2 + groupGap
    }

    func rect(forSection section: Int?) -> NSRect? {
        guard let section,
              let row = entries.firstIndex(where: { $0.sectionIndex == section }),
              row < frames.count
        else { return nil }
        return frames[row]
    }

    private func row(at point: NSPoint) -> Int? {
        frames.firstIndex { $0.contains(point) }
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        for (row, frame) in frames.enumerated() where frame.intersects(dirtyRect) {
            let entry = entries[row]
            let isCurrent = entry.sectionIndex == currentSection

            let pill = NSBezierPath(
                roundedRect: frame.insetBy(dx: 4, dy: 1), xRadius: 6, yRadius: 6
            )
            if isCurrent {
                accentColor.withAlphaComponent(0.20).setFill()
                pill.fill()
                accentColor.setFill()
                NSBezierPath(
                    roundedRect: NSRect(x: 4, y: frame.minY + 4, width: 3, height: frame.height - 8),
                    xRadius: 1.5, yRadius: 1.5
                ).fill()
            } else if row == hovered {
                textColor.withAlphaComponent(0.08).setFill()
                pill.fill()
            }

            let color: NSColor
            if isCurrent {
                color = accentColor
            } else if entry.isGroup {
                color = textColor.withAlphaComponent(0.5)
            } else {
                color = textColor.withAlphaComponent(0.88)
            }

            var textRect = frame.insetBy(dx: horizontalPadding, dy: verticalPadding)
            if entry.isGroup { textRect.origin.y += 6; textRect.size.height -= 6 }
            (entry.title as NSString).draw(
                with: textRect,
                options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                attributes: [
                    .font: font(for: entry, isCurrent: isCurrent),
                    .foregroundColor: color,
                    .paragraphStyle: paragraphStyle(),
                ]
            )
        }
    }

    // MARK: Interaction

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let row = row(at: point) {
            onSelect?(entries[row].sectionIndex)
        } else {
            // Empty space below the list still drags the panel, like everywhere else.
            window?.performDrag(with: event)
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        // .activeAlways: the app is never frontmost during a call, and hover
        // feedback should still work.
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        hovered = row(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        hovered = nil
    }

    override func resetCursorRects() {
        for frame in frames { addCursorRect(frame, cursor: .pointingHand) }
    }
}
