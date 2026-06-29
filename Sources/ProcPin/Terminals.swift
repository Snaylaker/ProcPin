import Foundation

/// Known macOS terminal emulators, used by the Settings picker and by Focus
/// when raising the window that hosts a tmux pane.
struct TerminalApp: Identifiable, Equatable {
    let id: String          // stable key stored in settings
    let name: String        // display name
    let bundleID: String?   // nil == auto-detect
}

enum Terminals {
    static let all: [TerminalApp] = [
        TerminalApp(id: "auto",      name: "Auto-detect",  bundleID: nil),
        TerminalApp(id: "ghostty",   name: "Ghostty",      bundleID: "com.mitchellh.ghostty"),
        TerminalApp(id: "iterm2",    name: "iTerm2",       bundleID: "com.googlecode.iterm2"),
        TerminalApp(id: "terminal",  name: "Terminal",     bundleID: "com.apple.Terminal"),
        TerminalApp(id: "wezterm",   name: "WezTerm",      bundleID: "com.github.wez.wezterm"),
        TerminalApp(id: "kitty",     name: "kitty",        bundleID: "net.kovidgoyal.kitty"),
        TerminalApp(id: "alacritty", name: "Alacritty",    bundleID: "org.alacritty"),
        TerminalApp(id: "warp",      name: "Warp",         bundleID: "dev.warp.Warp-Stable"),
        TerminalApp(id: "hyper",     name: "Hyper",        bundleID: "co.zeit.hyper"),
        TerminalApp(id: "tabby",     name: "Tabby",        bundleID: "org.tabby"),
        TerminalApp(id: "rio",       name: "Rio",          bundleID: "com.raphaelamorim.rio"),
    ]

    static let settingsKey = "ProcPin.terminal"

    /// The currently selected terminal id (defaults to auto-detect).
    static var selectedID: String {
        UserDefaults.standard.string(forKey: settingsKey) ?? "auto"
    }

    static var selected: TerminalApp {
        all.first { $0.id == selectedID } ?? all[0]
    }

    static func bundleID(forID id: String) -> String? {
        all.first { $0.id == id }?.bundleID
    }
}
