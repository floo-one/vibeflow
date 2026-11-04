import AppKit
import SwiftUI

/// Right-click (or Control-click) on a VibeFlow menu bar item opens Settings instead of its
/// menu: the VibeFlow icon on the last tab used, the clock, meeting, Pomodoro and Keep Awake
/// items on their own tab. While Settings is open, the same click on any of them closes it.
/// Left-click still opens the menu.
///
/// MenuBarExtra hands out no NSStatusItem, but its status items live in our own windows, so
/// a local event monitor sees the click first and can swallow it. SwiftUI gives those windows
/// no identifier; it creates one per MenuBarExtra at launch, in scene order (items that are
/// not inserted yet get theirs too, parked off screen), so the position among the app's
/// status bar windows says which item was clicked.
@MainActor
enum StatusItemRightClick {
    /// Settings tab per MenuBarExtra, in the order VibeFlowApp declares them; nil keeps the
    /// tab Settings was last on.
    private static let tabs: [SettingsTab?] = [nil, .clocks, .meetings, .pomodoro, .keepAwake]

    private static var monitor: Any?

    static func install(openSettings: OpenSettingsAction, container: AppContainer) {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown, .leftMouseDown]) { event in
            let isRightClick = event.type == .rightMouseDown
                || event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .control
            guard isRightClick, let window = event.window,
                  let index = statusWindows().firstIndex(of: window) else { return event }
            if SettingsWindow.isVisible {
                SettingsWindow.close()
            } else {
                SettingsWindow.present(openSettings, container: container,
                                       tab: index < tabs.count ? tabs[index] : nil)
            }
            return nil
        }
    }

    private static func statusWindows() -> [NSWindow] {
        NSApp.windows.filter { NSStringFromClass(type(of: $0)) == "NSStatusBarWindow" }
    }
}
