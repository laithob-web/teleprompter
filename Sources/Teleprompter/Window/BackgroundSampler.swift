import AppKit
import CoreGraphics
import ScreenCaptureKit

/// Measures how light or dark the screen is *underneath* the panel, so the
/// script's text colour can follow it.
///
/// Captures through ScreenCaptureKit — `CGWindowListCreateImage` was obsoleted
/// in macOS 15, not merely deprecated, and no longer links.
///
/// The prompter panel is `sharingType = .none`, and ScreenCaptureKit honours
/// that flag; it is the same mechanism that hides the panel from Zoom. So the
/// capture excludes the panel automatically and it can never sample its own text
/// and mistake it for the background.
///
/// This needs Screen Recording permission. That is a real cost for an app whose
/// purpose is hiding from screen capture, so it is requested only when automatic
/// colour is actually switched on, and refusing it degrades to following the
/// system Light/Dark setting rather than breaking.
@MainActor
final class BackgroundSampler {

    /// Relative luminance, 0 (black) to 1 (white).
    var onLuminance: ((Double) -> Void)?

    private var timer: Timer?
    private var frameProvider: (() -> NSRect)?
    /// Capture is async; skip a tick rather than queue overlapping requests.
    private var isSampling = false

    /// Once per second: fast enough to follow a slide change, slow enough that
    /// the capture cost stays invisible.
    private let interval: TimeInterval = 1.0

    static var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    /// Triggers the system prompt the first time; afterwards the user must grant
    /// it in System Settings, so a false result is not necessarily permanent.
    @discardableResult
    static func requestPermission() -> Bool { CGRequestScreenCaptureAccess() }

    var isRunning: Bool { timer != nil }

    func start(frame: @escaping () -> NSRect) {
        stop()
        self.frameProvider = frame

        sample()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sample() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    deinit { timer?.invalidate() }

    // MARK: - Sampling

    private func sample() {
        guard !isSampling, let frameProvider else { return }
        let frame = frameProvider()
        guard frame.width > 4, frame.height > 4 else { return }

        // Inset past the border so the border's own pixels do not skew the read.
        guard let captureRect = screenRect(for: frame.insetBy(dx: 6, dy: 6)) else { return }

        isSampling = true
        Task { @MainActor in
            defer { self.isSampling = false }
            guard let image = try? await SCScreenshotManager.captureImage(in: captureRect),
                  let luminance = self.averageLuminance(of: image)
            else { return }
            self.onLuminance?(luminance)
        }
    }

    /// AppKit frames are bottom-left origin; CoreGraphics capture wants
    /// top-left origin measured from the primary display.
    private func screenRect(for frame: NSRect) -> CGRect? {
        guard let primary = NSScreen.screens.first else { return nil }
        return CGRect(
            x: frame.origin.x,
            y: primary.frame.height - frame.origin.y - frame.height,
            width: frame.width,
            height: frame.height
        )
    }

    /// Averages by drawing the capture into a tiny bitmap and reading it back —
    /// the downscale does the averaging, so cost is independent of panel size.
    private func averageLuminance(of image: CGImage) -> Double? {
        let side = 8
        var pixels = [UInt8](repeating: 0, count: side * side * 4)

        guard let context = CGContext(
            data: &pixels,
            width: side, height: side,
            bitsPerComponent: 8, bytesPerRow: side * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))

        var total = 0.0
        var counted = 0.0
        for index in stride(from: 0, to: pixels.count, by: 4) {
            let alpha = Double(pixels[index + 3]) / 255.0
            // Skip transparent pixels: with nothing behind the panel the capture
            // is empty, and counting those as black would force white text.
            guard alpha > 0.1 else { continue }
            let r = Double(pixels[index]) / 255.0
            let g = Double(pixels[index + 1]) / 255.0
            let b = Double(pixels[index + 2]) / 255.0
            total += 0.2126 * r + 0.7152 * g + 0.0722 * b
            counted += 1
        }
        guard counted > 0 else { return nil }
        return total / counted
    }
}
