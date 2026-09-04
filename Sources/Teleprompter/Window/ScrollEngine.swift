import AppKit
import QuartzCore

/// Drives the vertical scroll offset every frame.
///
/// Three behaviors share one loop:
///   * **seek**   — spring toward a target offset (speech alignment, Phase 2)
///   * **drift**  — constant points/sec (fallback when alignment is unsure)
///   * **manual** — the trackpad wins, always, for a few seconds after you touch it
///
/// Feature 4 depends on manual input never fighting the animation. Rather than
/// blending them, manual scroll hard-suspends the loop and the engine re-anchors
/// to wherever you left off.
final class ScrollEngine {

    enum Mode {
        case stopped
        /// Constant-rate scroll at `pointsPerSecond`.
        case drift
        /// Spring toward `target`, falling back to drift when target is nil.
        case seek
    }

    private weak var scrollView: NSScrollView?
    private var displayLink: CADisplayLink?
    private var lastTimestamp: CFTimeInterval = 0

    /// Spring state, in points and points/sec.
    private var velocity: CGFloat = 0

    /// Critically damped: no overshoot, which matters because overshooting a
    /// teleprompter means reading backwards.
    private let stiffness: CGFloat = 22.0

    var mode: Mode = .stopped
    var pointsPerSecond: CGFloat = 0

    /// Offset the spring is pulling toward. Nil means "no confident fix" and the
    /// engine degrades to drift.
    var target: CGFloat?

    /// While in the future, the loop yields entirely to the trackpad.
    private var manualOverrideUntil: CFTimeInterval = 0
    private let manualGrace: CFTimeInterval = 4.0

    var isManualOverrideActive: Bool {
        CACurrentMediaTime() < manualOverrideUntil
    }

    /// Called after manual scrolling settles, so the tracker can re-anchor its
    /// cursor to whatever is now under the reading line.
    var onManualScrollSettled: (() -> Void)?

    private var pendingSettle: DispatchWorkItem?

    init(scrollView: NSScrollView) {
        self.scrollView = scrollView
    }

    deinit { stop() }

    // MARK: - Loop

    func start(drivenBy view: NSView) {
        guard displayLink == nil else { return }
        let link = view.displayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
        lastTimestamp = 0
    }

    func stop() {
        displayLink?.invalidate()
        displayLink = nil
    }

    @objc private func tick(_ link: CADisplayLink) {
        let now = link.timestamp
        defer { lastTimestamp = now }
        guard lastTimestamp > 0 else { return }

        // Clamp dt so a stalled frame or a wake-from-sleep can't launch the
        // script off the end of the document.
        let dt = min(0.1, now - lastTimestamp)
        guard dt > 0, mode != .stopped, !isManualOverrideActive else {
            velocity = 0
            return
        }

        guard let scrollView, let documentView = scrollView.documentView else { return }
        var y = scrollView.contentView.bounds.origin.y

        switch mode {
        case .stopped:
            return

        case .drift:
            velocity = 0
            y += pointsPerSecond * CGFloat(dt)

        case .seek:
            if let target {
                let damping = 2 * sqrt(stiffness)
                let accel = -stiffness * (y - target) - damping * velocity
                velocity += accel * CGFloat(dt)
                y += velocity * CGFloat(dt)
            } else {
                velocity = 0
                y += pointsPerSecond * CGFloat(dt)
            }
        }

        let clamped = clamp(y, in: scrollView, documentView: documentView)
        if clamped != y { velocity = 0 }
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: clamped))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    private func clamp(
        _ y: CGFloat, in scrollView: NSScrollView, documentView: NSView
    ) -> CGFloat {
        let insets = scrollView.contentInsets
        let minY = -insets.top
        let maxY = max(
            minY,
            documentView.frame.height + insets.bottom - scrollView.contentView.bounds.height
        )
        return min(maxY, max(minY, y))
    }

    // MARK: - Manual input

    /// Called from the scroll view on every trackpad event.
    func noteManualScroll() {
        manualOverrideUntil = CACurrentMediaTime() + manualGrace
        velocity = 0

        // Re-anchor once the gesture and its momentum have actually stopped,
        // not on every event in the stream.
        pendingSettle?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.onManualScrollSettled?()
        }
        pendingSettle = work
        DispatchQueue.main.asyncAfter(deadline: .now() + manualGrace, execute: work)
    }

    /// Immediately hands control back to the engine, e.g. on a "resync" hotkey.
    func cancelManualOverride() {
        manualOverrideUntil = 0
        pendingSettle?.cancel()
        pendingSettle = nil
    }

    /// Jumps without animation, used for section jumps and initial layout.
    func snap(to y: CGFloat) {
        guard let scrollView, let documentView = scrollView.documentView else { return }
        velocity = 0
        let clamped = clamp(y, in: scrollView, documentView: documentView)
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: clamped))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }
}
