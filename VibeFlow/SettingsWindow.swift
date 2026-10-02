import AppKit
import SwiftUI

/// VibeFlow is an agent app (no Dock icon), so macOS never brings its windows forward by
/// itself. The Settings window is either in front or closed: opening it activates the app,
/// and the window floats above other apps' windows while it is open.
@MainActor
enum SettingsWindow {
    /// Opens Settings (optionally on a tab) and brings it to the front.
    static func present(_ openSettings: OpenSettingsAction, container: AppContainer, tab: SettingsTab? = nil) {
        if let tab { container.settingsTab = tab }
        NSApp.activate()
        openSettings()
        // The window may not exist until the next runloop pass on first open.
        DispatchQueue.main.async { bringToFront() }
    }

    static func bringToFront() {
        guard let window = NSApp.windows.first(where: isSettingsWindow) else { return }
        configure(window)
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    static func configure(_ window: NSWindow) {
        window.level = .floating
        // Follow the user to the current Space and over full-screen apps instead of
        // switching Spaces to wherever the window was last.
        window.collectionBehavior.insert([.moveToActiveSpace, .fullScreenAuxiliary])
        window.hidesOnDeactivate = false
    }

    private static func isSettingsWindow(_ window: NSWindow) -> Bool {
        window.identifier?.rawValue.contains("Settings") == true
    }
}

/// Placed in the Settings view so the window is configured the moment it exists, even when
/// opened by Cmd-, from the app's own menu.
struct SettingsWindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            if let window = view.window { SettingsWindow.configure(window) }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
