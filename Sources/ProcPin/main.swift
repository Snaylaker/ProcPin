import AppKit

// Activation policy (Dock icon vs menu-bar-only) is set by AppDelegate from
// the user's preference. Default to .regular so the Dock icon shows.
let app = NSApplication.shared
app.setActivationPolicy(UserDefaults.standard.object(forKey: "ProcPin.showDock") as? Bool == false ? .accessory : .regular)

// Top-level code runs on the main thread; assert that for the actor checker.
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
app.run()
