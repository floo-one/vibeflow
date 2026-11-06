import AppKit
import OSLog
import SwiftUI
import UniformTypeIdentifiers
import MaagicalCore

private let log = Logger(subsystem: "one.floo.vibeflow", category: "menu-bar-panel")

/// The Maagical menu bar icon and its panel (docs/designs/menu-bar-popover.md, eng review R1).
///
/// An own NSStatusItem instead of SwiftUI's MenuBarExtra, because the panel must close from
/// code (D13) and the icon must accept dropped files (D15), and MenuBarExtra offers neither.
/// The panel is a non-activating NSPanel like NotchIndicator, so the app you work in stays
/// frontmost while it is open: a read captures its selection and a dictation pastes into it.
///
/// Left click toggles the panel, right-click or Control-click toggles Settings (R3), a file
/// dragged onto the icon opens the panel with its drop zone, and a file dropped on the icon
/// starts a transcription. The panel closes on Escape, a click anywhere else, a Space change,
/// any Maagical shortcut, and whenever it hands you on to a window (D13). Its SwiftUI view
/// exists only while it is open (R5), so nothing renders while it is hidden.
@MainActor
final class StatusItemController: NSObject {
    static private(set) var shared: StatusItemController?

    private let container: AppContainer
    private let statusItem: NSStatusItem
    private let panel = KeyPanel()
    private let flyout = KeyPanel()
    private var hosting: NSHostingView<AnyView>?
    private var flyoutHosting: NSHostingView<AnyView>?
    private var monitors: [Any] = []
    private var flyoutHide: Task<Void, Never>?
    private var spaceObserver: NSObjectProtocol?

    /// The panel's live state, read by the SwiftUI views.
    let model = PanelModel()

    var isOpen: Bool { panel.isVisible }
    /// The status item's window, which StatusItemRightClick must leave alone.
    var statusWindow: NSWindow? { statusItem.button?.window }

    static func install(container: AppContainer) {
        guard shared == nil else { return }
        shared = StatusItemController(container: container)
    }

    private init(container: AppContainer) {
        self.container = container
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        // An own name, so it never inherits the remembered "hidden" state of a MenuBarExtra
        // slot (those hide themselves while inactive), and always shown, like the old icon.
        statusItem.autosaveName = "vibeflow-icon"
        statusItem.isVisible = true
        if let button = statusItem.button {
            button.imagePosition = .imageLeading
            let target = IconTargetView(frame: button.bounds)
            target.autoresizingMask = [.width, .height]
            target.controller = self
            button.addSubview(target)
        }
        configure(panel)
        configure(flyout)
        flyout.level = .init(panel.level.rawValue + 1)
        container.closePanel = { [weak self] in self?.close() }
        watchIcon()
        log.notice("Menu bar icon installed, visible=\(self.statusItem.isVisible, privacy: .public)")
    }

    private func configure(_ panel: KeyPanel) {
        panel.styleMask = [.borderless, .nonactivatingPanel, .fullSizeContentView]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.onCancel = { [weak self] in self?.close() }
    }

    // MARK: Icon

    /// The waveform (or mic, ellipsis, error) symbol, with DEV in the Debug build; follows
    /// AppContainer.iconSymbol like the old MenuBarExtra label.
    private func watchIcon() {
        let symbol = withObservationTracking { container.iconSymbol } onChange: { [weak self] in
            Task { @MainActor in self?.watchIcon() }
        }
        guard let button = statusItem.button else { return }
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Maagical")
        image?.isTemplate = true
        button.image = image
        #if DEBUG
        button.title = " DEV"
        button.font = .systemFont(ofSize: 10, weight: .semibold)
        #endif
        button.setAccessibilityLabel("Maagical")
    }

    // MARK: Clicks

    fileprivate func iconClicked(right: Bool) {
        log.notice("Icon clicked, right=\(right, privacy: .public), open=\(self.isOpen, privacy: .public)")
        if right {
            close()
            container.toggleSettings(tab: nil)
        } else {
            toggle()
        }
    }

    func toggle() { isOpen ? close() : open() }

    func open() {
        guard !isOpen else { return }
        log.notice("Panel opens")
        container.refreshPermissions()
        model.dropMessage = nil
        let view = PopoverView(controller: self).environment(container)
        let hosting = NSHostingView(rootView: AnyView(view))
        hosting.sizingOptions = [.intrinsicContentSize]
        panel.contentView = hosting
        self.hosting = hosting
        position()
        panel.orderFrontRegardless()
        panel.makeKey()
        statusItem.button?.highlight(true)
        installMonitors()
        // The first layout pass settles the height; place it again once it has.
        DispatchQueue.main.async { [weak self] in self?.position() }
    }

    func close() {
        guard isOpen else { return }
        log.notice("Panel closes")
        hideFlyout(now: true)
        panel.orderOut(nil)
        panel.contentView = nil
        hosting = nil
        model.isDragging = false
        statusItem.button?.highlight(false)
        removeMonitors()
    }

    /// Under the icon, right-aligned to it, kept inside the screen.
    func position() {
        guard let hosting, let buttonWindow = statusItem.button?.window else { return }
        let size = hosting.fittingSize
        let icon = buttonWindow.frame
        let screen = buttonWindow.screen ?? NSScreen.main
        let visible = screen?.visibleFrame ?? icon
        var x = icon.maxX - size.width + 10
        x = min(max(x, visible.minX + 8), visible.maxX - size.width - 8)
        let y = icon.minY - 6 - size.height
        panel.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
    }

    // MARK: Closing on outside clicks and Space changes (D13)

    private func installMonitors() {
        removeMonitors()
        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown],
                                                         handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }) {
            monitors.append(global)
        }
        // Clicks in Maagical's own other windows (Settings, History) close it too.
        if let local = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] event in
            guard let self else { return event }
            let inside = [self.panel, self.flyout, self.statusItem.button?.window].contains { $0 != nil && $0 === event.window }
            if !inside { self.close() }
            return event
        }) {
            monitors.append(local)
        }
        spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }
    }

    private func removeMonitors() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors = []
        if let spaceObserver { NSWorkspace.shared.notificationCenter.removeObserver(spaceObserver) }
        spaceObserver = nil
    }

    // MARK: History flyout (D14)

    /// Shows the flyout to the left of the History row. `rowFrame` is in the panel's SwiftUI
    /// global space (top-left origin).
    func showFlyout(rowFrame: CGRect) {
        flyoutHide?.cancel()
        guard isOpen, let hosting else { return }
        if flyoutHosting == nil {
            let view = HistoryFlyoutView(controller: self).environment(container)
            let flyoutHosting = NSHostingView(rootView: AnyView(view))
            flyoutHosting.sizingOptions = [.intrinsicContentSize]
            flyout.contentView = flyoutHosting
            self.flyoutHosting = flyoutHosting
        }
        guard let flyoutHosting else { return }
        let size = flyoutHosting.fittingSize
        // SwiftUI's global space in an NSHostingView starts at its top-left corner.
        let rowInWindow = NSRect(x: rowFrame.minX, y: hosting.bounds.height - rowFrame.maxY,
                                 width: rowFrame.width, height: rowFrame.height)
        let rowOnScreen = panel.convertToScreen(hosting.convert(rowInWindow, to: nil))
        var frame = NSRect(x: panel.frame.minX - size.width - 6, y: rowOnScreen.maxY + 8 - size.height,
                           width: size.width, height: size.height)
        if let visible = panel.screen?.visibleFrame {
            frame.origin.y = min(max(frame.minY, visible.minY + 8), visible.maxY - size.height - 8)
            if frame.minX < visible.minX + 8 { frame.origin.x = panel.frame.maxX + 6 }
        }
        flyout.setFrame(frame, display: true)
        if !flyout.isVisible {
            panel.addChildWindow(flyout, ordered: .above)
            flyout.orderFrontRegardless()
        }
        model.flyoutOpen = true
    }

    /// Hover intent: leaving the row or the flyout waits a moment, so the pointer can travel
    /// from one to the other.
    func scheduleFlyoutHide() {
        flyoutHide?.cancel()
        flyoutHide = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(320))
            guard !Task.isCancelled else { return }
            self?.hideFlyout(now: true)
        }
    }

    func keepFlyout() { flyoutHide?.cancel() }

    func hideFlyout(now: Bool) {
        flyoutHide?.cancel()
        guard flyout.isVisible || flyoutHosting != nil else { return }
        panel.removeChildWindow(flyout)
        flyout.orderOut(nil)
        flyout.contentView = nil
        flyoutHosting = nil
        model.flyoutOpen = false
    }

    // MARK: Files (D15)

    fileprivate func dragEnteredIcon() {
        open()
        model.isDragging = true
    }

    fileprivate func dragExitedIcon() {
        // The pointer may be on its way to the drop zone; the zone keeps its own highlight.
        model.isDragging = false
    }

    /// A file dropped on the icon or the drop zone. Only audio and video, and only while no
    /// other file is being transcribed (one job at a time, R4 item 6).
    @discardableResult
    func handleDrop(_ urls: [URL]) -> Bool {
        model.isDragging = false
        guard let url = urls.first else { return false }
        if container.files.job.isRunning {
            open()
            model.dropMessage = "A file is already transcribing"
            log.notice("Drop refused: a file is already transcribing")
            return false
        }
        let type = UTType(filenameExtension: url.pathExtension)
        guard let type, type.conforms(to: .audio) || type.conforms(to: .movie) || type.conforms(to: .audiovisualContent) else {
            open()
            model.dropMessage = "Only audio or video files"
            log.notice("Drop refused: not audio or video")
            return false
        }
        close()
        container.files.use(url) { [container] in
            guard let openWindow = container.openWindow else { return }
            TranscribeFileWindow.present(openWindow)
        }
        return true
    }
}

/// Live panel state that is not app state: the drop zone's highlight and message, whether the
/// History flyout is open.
@MainActor
@Observable
final class PanelModel {
    var isDragging = false
    var dropMessage: String?
    var flyoutOpen = false
}

/// A borderless panel that can take keyboard focus (Escape, Tab) without activating Maagical.
final class KeyPanel: NSPanel {
    var onCancel: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { onCancel?() }
}

/// Covers the status button: turns clicks into open/close or Settings, and takes file drags
/// (NSStatusBarButton cannot be subclassed into a dragging destination).
private final class IconTargetView: NSView {
    weak var controller: StatusItemController?

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func mouseDown(with event: NSEvent) {
        let control = event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.control)
        MainActor.assumeIsolated { controller?.iconClicked(right: control) }
    }

    override func rightMouseDown(with event: NSEvent) {
        MainActor.assumeIsolated { controller?.iconClicked(right: true) }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        MainActor.assumeIsolated { controller?.dragEnteredIcon() }
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        MainActor.assumeIsolated { controller?.dragExitedIcon() }
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                         options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return MainActor.assumeIsolated { controller?.handleDrop(urls) ?? false }
    }
}

extension IconState {
    var symbolName: String {
        switch self {
        case .idle: return "waveform"
        case .speaking: return "waveform.circle.fill"
        case .transforming: return "sparkles"
        case .awaitingConfirm: return "exclamationmark.circle"
        case .warning: return "exclamationmark.triangle"
        case .error: return "xmark.circle"
        }
    }
}
