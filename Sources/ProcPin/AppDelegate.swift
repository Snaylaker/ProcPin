import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {

    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private let state = AppState()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Status bar item shows the app's colorful icon (not a template glyph).
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = Self.menuBarIcon()
            button.action = #selector(togglePopover(_:))
            button.target = self
        }

        // Popover hosting the SwiftUI UI.
        popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        popover.contentViewController = NSHostingController(rootView: RootView(state: state))
    }

    /// The colorful app icon, sized for the menu bar. Falls back to a symbol
    /// when run outside the .app bundle (e.g. `swift run`).
    private static func menuBarIcon() -> NSImage {
        if let path = Bundle.main.path(forResource: "AppIcon", ofType: "icns"),
           let img = NSImage(contentsOfFile: path) {
            let menuIcon = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
                img.draw(in: rect)
                return true
            }
            menuIcon.isTemplate = false   // keep full color
            return menuIcon
        }
        let fallback = NSImage(systemSymbolName: "checklist", accessibilityDescription: "ProcPin")
            ?? NSImage(systemSymbolName: "list.bullet", accessibilityDescription: "ProcPin")
            ?? NSImage()
        fallback.isTemplate = true
        return fallback
    }

    @objc private func togglePopover(_ sender: Any?) {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            state.startAutoRefresh()
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    func popoverDidClose(_ notification: Notification) {
        state.stopAutoRefresh()
    }

    /// Clicking the Dock icon opens the panel from the menu bar item.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !popover.isShown { togglePopover(nil) }
        return true
    }

    /// Switches between showing a Dock icon and menu-bar-only.
    static func setDockVisible(_ visible: Bool) {
        NSApp.setActivationPolicy(visible ? .regular : .accessory)
        if visible { NSApp.activate(ignoringOtherApps: true) }
    }
}
