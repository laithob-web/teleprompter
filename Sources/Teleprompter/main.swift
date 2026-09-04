import AppKit

// .accessory keeps the app out of the Dock and the app switcher, matching
// LSUIElement in Info.plist. Set before the delegate so no Dock tile ever appears.
let application = NSApplication.shared
application.setActivationPolicy(.accessory)

// Top-level code is not main-actor isolated, but this is the main thread and the
// delegate is main-actor bound, so state the fact rather than hopping.
let delegate = MainActor.assumeIsolated { AppDelegate() }
application.delegate = delegate
application.run()
