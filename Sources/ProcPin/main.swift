import AppKit

// Menu-bar-only app (no Dock icon).
let app = NSApplication.shared
app.setActivationPolicy(.accessory)

// Top-level code runs on the main thread; assert that for the actor checker.
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
app.run()
