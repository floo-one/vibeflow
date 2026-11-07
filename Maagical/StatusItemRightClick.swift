import AppKit
import SwiftUI

/// Right-click (or Control-click) on the clock, meeting, Pomodoro or Keep Awake item opens
/// Settings on its own tab instead of its menu; while Settings is open, the same click closes
/// it. Left-click still opens the menu. The Maagical icon handles its own right-click
/// (StatusItemController, menu bar popover eng review R3).
///
/// MenuBarExtra hands out no NSStatusItem, but its status items live in our own windows, so
/// a local event monitor sees the click first and can swallow it. SwiftUI gives those windows
/// no identifier; it creates one per MenuBarExtra at launch, in scene order (items that are
/// not inserted yet get theirs too, parked off screen), so the position among the app's
/// status bar windows says which item was clicked. The Maagical icon's own window is left out.
@MainActor
enum StatusItemRightClick {
    /// Settings tab per MenuBarExtra, in the order MaagicalApp declares them.
    private static let tabs: [SettingsTab] = [.clocks, .meetings, .pomodoro, .keepAwake]

    private static var monitor: Any?

    static func install(container: AppContainer) {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown, .leftMouseDown]) { event in
            let isRightClick = event.type == .rightMouseDown
                || event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .control
            guard isRightClick, let window = event.window,
                  let index = statusWindows().firstIndex(of: window) else { return event }
            container.toggleSettings(tab: index < tabs.count ? tabs[index] : nil)
            return nil
        }
    }

    private static func statusWindows() -> [NSWindow] {
        let own = StatusItemController.shared?.statusWindow
        return NSApp.windows.filter { NSStringFromClass(type(of: $0)) == "NSStatusBarWindow" && $0 !== own }
    }
}
