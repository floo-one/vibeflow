import AppKit
import SwiftUI

/// Maagical is an agent app (no Dock icon), so macOS never brings its windows forward by
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
        pinSidebar(in: window.contentView)
        repinOnLayout()
    }

    /// Width of the Settings sidebar. The divider does not move and the sidebar cannot be
    /// dragged or toggled away: without it there is no way to reach the other panes.
    static let sidebarWidth: CGFloat = 190

    /// NavigationSplitView lets the sidebar collapse when its divider is dragged to the edge,
    /// whatever its column width says. Its AppKit split view item can say no.
    private static func pinSidebar(in view: NSView?) {
        guard let view else { return }
        if let splitView = view as? NSSplitView,
           let controller = splitView.delegate as? NSSplitViewController,
           let sidebar = controller.splitViewItems.first {
            // Assign only on change: each assignment lays the split view out again.
            if sidebar.canCollapse { sidebar.canCollapse = false }
            if sidebar.canCollapseFromWindowResize { sidebar.canCollapseFromWindowResize = false }
            if sidebar.minimumThickness != sidebarWidth { sidebar.minimumThickness = sidebarWidth }
            if sidebar.maximumThickness != sidebarWidth { sidebar.maximumThickness = sidebarWidth }
            if sidebar.isCollapsed { sidebar.isCollapsed = false }
            hideDividerCursor(of: splitView)
            return
        }
        for subview in view.subviews { pinSidebar(in: subview) }
    }

    /// A pinned divider still shows the left-right resize cursor on hover, which promises a
    /// drag that does nothing. NSSplitView adds that cursor in resetCursorRects, and SwiftUI
    /// owns the split view, so give this one instance a subclass whose resetCursorRects adds
    /// nothing (the way KVO subclasses an object). Other split views keep their cursor.
    private static func hideDividerCursor(of splitView: NSSplitView) {
        guard let base = object_getClass(splitView) else { return }
        let baseName = NSStringFromClass(base)
        guard !baseName.hasPrefix(pinnedPrefix) else { return }
        // A KVO-observed object already runs on a runtime subclass; leave it alone.
        guard base == splitView.classForCoder else { return }
        let name = pinnedPrefix + baseName
        let pinned: AnyClass
        if let existing = NSClassFromString(name) {
            pinned = existing
        } else {
            guard let made = objc_allocateClassPair(base, name, 0) else { return }
            let noCursorRects: @convention(block) (NSView) -> Void = { _ in }
            class_addMethod(made, #selector(NSView.resetCursorRects),
                            imp_implementationWithBlock(noCursorRects), "v@:")
            objc_registerClassPair(made)
            pinned = made
        }
        object_setClass(splitView, pinned)
        splitView.window?.invalidateCursorRects(for: splitView)
    }

    private static let pinnedPrefix = "VFPinnedSidebar_"

    private static var layoutObserver: NSObjectProtocol?

    /// SwiftUI often adds the split view items only after configure has run, so a one-time pin
    /// finds nothing and the sidebar stays collapsible (and comes back collapsed, as saved).
    /// The split view lays out once its items exist and again on every divider drag: pin then.
    private static func repinOnLayout() {
        guard layoutObserver == nil else { return }
        layoutObserver = NotificationCenter.default.addObserver(
            forName: NSSplitView.didResizeSubviewsNotification, object: nil, queue: .main
        ) { note in
            let splitView = note.object as? NSSplitView
            MainActor.assumeIsolated {
                guard let splitView, let window = splitView.window, isSettingsWindow(window) else { return }
                pinSidebar(in: splitView)
            }
        }
    }

    /// Closes the Settings window if it is open.
    static func close() {
        NSApp.windows.first { isSettingsWindow($0) && $0.isVisible }?.performClose(nil)
    }

    /// True while the Settings window is on screen (feedback reports name its pane).
    static var isVisible: Bool { NSApp.windows.contains { isSettingsWindow($0) && $0.isVisible } }

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
