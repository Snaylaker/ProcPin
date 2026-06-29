import AppKit

// Menu-bar-only by default (no Dock icon). The user can opt into a Dock icon
// via Settings, which sets ProcPin.showDock = true.
let app = NSApplication.shared
let showDock = UserDefaults.standard.bool(forKey: "ProcPin.showDock") // default false
app.setActivationPolicy(showDock ? .regular : .accessory)

// Top-level code runs on the main thread; assert that for the actor checker.
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
app.run()
