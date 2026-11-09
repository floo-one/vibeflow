import AppKit
import KeyboardShortcuts
import SwiftUI
import MaagicalCore

// Desktop Roles views (docs/designs/desktop-roles.md): the Desktops menu behind the panel tile's
// chevron, and Settings > Desktops. The menu bar tag is AppKit (RoleTagItem).

/// The Desktops menu behind the panel tile's chevron (the role tag builds the same in AppKit). Every action closes
/// the panel first, since a walk switches desktops and Settings takes the front.
struct DesktopsMenuItems: View {
    @Environment(AppContainer.self) private var container

    var body: some View {
        let desktops = container.desktops
        if desktops.isPaused {
            Text("Paused: the installed Maagical handles desktops")
        }
        Button(desktops.isWalking ? "Stop Setting Up" : "Set Up All") {
            container.closePanel?()
            desktops.setUpOrStop()
        }
            .globalKeyboardShortcut(.setUpDesktops)
            .disabled(desktops.roles.isEmpty || desktops.isPaused)
        ForEach(desktops.roles) { role in
            Button("Set Up \(role.name) · Desktop \(role.desktopNumber)") {
                container.closePanel?()
                desktops.setUp([role])
            }
                .disabled(desktops.isWalking || desktops.isPaused)
        }
        if let report = desktops.setup.lastReport {
            Divider()
            Text(DesktopReportFormat.summary(report))
            ForEach(Array(report.unresolved.enumerated()), id: \.offset) { _, entry in
                Text(DesktopReportFormat.line(entry, appName: container.appName(for:)))
            }
        }
        Divider()
        Button("Desktops Settings…") {
            container.closePanel?()
            container.presentSettings(tab: .desktops)
        }
    }
}

enum DesktopReportFormat {
    /// "Opened 3 · 7 already there · 1 to check", or why the walk did not start.
    static func summary(_ report: SetupReport) -> String {
        switch report.refusal {
        case .busy: return "Not started: a read or dictation was running"
        case .alreadyRunning: return "Already setting up"
        case .unknownDesktops: return "Not started: the desktops could not be read"
        case nil: break
        }
        var parts = ["Opened \(report.opened)", "\(report.alreadyThere) already there"]
        if !report.unresolved.isEmpty { parts.append("\(report.unresolved.count) to check") }
        return parts.joined(separator: " · ")
    }

    /// "Comms · Slack: open on desktop 1".
    static func line(_ entry: SetupReport.Entry, appName: (String?) -> String) -> String {
        let reason: String
        if case .unresolved(let why) = entry.outcome { reason = text(why) } else { reason = "" }
        return "\(entry.role) · \(itemName(entry.item, appName: appName)): \(reason)"
    }

    static func itemName(_ item: RoleItem, appName: (String?) -> String) -> String {
        switch item {
        case .app(let bundleID): return appName(bundleID)
        case .chrome(_, let profile, _): return "Chrome (\(profile))"
        }
    }

    static func text(_ reason: UnresolvedReason) -> String {
        switch reason {
        case .openOnAnotherDesktop(let desktops):
            return "open on desktop \(desktops.map(String.init).joined(separator: ", "))"
        case .notResponding: return "not responding"
        case .couldNotCheck: return "could not check"
        case .checkProfile: return "a Chrome window here shows no profile"
        case .didNotAppear: return "no window appeared"
        case .landedElsewhere: return "opened on another desktop"
        case .missingDesktop: return "desktop missing, add it in Mission Control"
        case .switchFailed: return "could not switch to its desktop"
        case .stoppedBecauseYouSwitched: return "stopped, you switched desktops"
        case .cancelled: return "stopped"
        case .launchFailed(let message): return message
        }
    }
}

// MARK: - Settings > Desktops

/// Roles (name, color, desktop, what opens there), the macOS settings they need, and the shortcut.
struct DesktopsPane: View {
    @Environment(AppContainer.self) private var container
    @State private var profiles: [(directory: String, name: String)] = []
    /// The role waiting for "Remove" to be confirmed.
    @State private var removing: DesktopRole?

    /// Colors offered to new roles, in order.
    private static let palette = RoleColorRow.colors

    var body: some View {
        let desktops = container.desktops
        Form {
            PaneHeader(.desktops, subtitle: subtitle) {
                Button(desktops.isWalking ? "Stop" : "Set Up Desktops") { desktops.setUpOrStop() }
                    .buttonStyle(.borderedProminent)
                    .disabled(desktops.roles.isEmpty || desktops.isPaused)
            }

            ForEach(roles.indices, id: \.self) { index in
                roleSection(index)
            }

            Section {
                Button("Add Role") { addRole() }
                    .disabled(freeDesktops.isEmpty)
                ShortcutRecorder("Set up all desktops", hint: "Press again while it runs to stop", name: .setUpDesktops)
                Toggle(isOn: Binding(
                    get: { container.preferences.desktopRoleTag },
                    set: {
                        container.preferences.desktopRoleTag = $0
                        container.desktops.rolesChanged()
                    }
                )) {
                    Text("Show the role in the menu bar")
                    Text("The same tag shows on every screen; the wallpaper names each screen's own role.")
                }
            } footer: {
                Text("Each role sticks to its desktop: drag desktops around in Mission Control and the role moves with it. Setting up opens only what is missing, sets the role's wallpaper, and puts every screen back where it was.")
                    .foregroundStyle(.secondary)
            }

            Section("macOS settings") {
                ForEach(DesktopsCheck.rows(roles: roles, layout: desktops.layout, accessibilityTrusted: container.session.accessibilityTrusted)) { row in
                    LabeledContent {
                        if let fix = row.fix {
                            Button("Open Settings") { NSWorkspace.shared.open(fix) }
                        } else {
                            Image(systemName: row.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                .foregroundStyle(row.ok ? .green : .orange)
                        }
                    } label: {
                        Text(row.title)
                        Text(row.detail)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog(
            "Remove \(removing?.name ?? "this role")?",
            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
            presenting: removing
        ) { role in
            Button("Remove", role: .destructive) { update { $0.removeAll { $0.id == role.id } } }
        } message: { role in
            Text("Its apps and look on Desktop \(role.desktopNumber) are forgotten. The desktop and its windows stay as they are.")
        }
        .onAppear { profiles = ChromeProfiles.list() }
        // Back from System Settings with a wallpaper downloaded: the desktops pick it up.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            container.desktops.rolesChanged()
        }
    }

    private var subtitle: String {
        let desktops = container.desktops
        if desktops.isPaused { return "Paused while the installed Maagical runs" }
        if roles.isEmpty { return "Give each desktop a job: what opens there and its color" }
        if let report = desktops.setup.lastReport { return "Last run: " + DesktopReportFormat.summary(report) }
        return "\(roles.count) role\(roles.count == 1 ? "" : "s")"
    }

    // MARK: Roles

    private var roles: [DesktopRole] { container.preferences.desktopRoles }

    private func update(_ change: (inout [DesktopRole]) -> Void) {
        var roles = container.preferences.desktopRoles
        change(&roles)
        container.preferences.desktopRoles = roles.sorted { $0.desktopNumber < $1.desktopNumber }
        container.desktops.rolesChanged()
    }

    private var freeDesktops: [Int] {
        let used = Set(roles.map(\.desktopNumber))
        return DesktopRole.desktopNumbers.filter { !used.contains($0) }
    }

    private func addRole() {
        guard let number = freeDesktops.first else { return }
        let color = Self.palette[roles.count % Self.palette.count]
        update { $0.append(DesktopRole(name: "Desktop \(number)", colorHex: color, desktopNumber: number)) }
    }

    /// One card per role: what the desktop is (name, desktop, color, background), then what opens
    /// on it, then Set Up and Remove.
    @ViewBuilder
    private func roleSection(_ index: Int) -> some View {
        let role = roles[index]
        let desktops = container.desktops
        Section {
            LabeledContent("Name") {
                HStack(spacing: 8) {
                    TextField("Name", text: Binding(
                        get: { role.name },
                        set: { name in update { $0[index].name = name } }
                    ))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    Picker("Desktop", selection: Binding(
                        get: { role.desktopNumber },
                        set: { number in
                            let id = container.desktops.desktopID(at: number)
                            update {
                                $0[index].desktopNumber = number
                                $0[index].desktopID = id
                            }
                        }
                    )) {
                        ForEach(([role.desktopNumber] + freeDesktops).sorted(), id: \.self) { Text("Desktop \($0)").tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            }
            RoleColorRow(colorHex: role.colorHex) { hex in update { $0[index].colorHex = hex } }
            BackgroundPicker(role: role) { background in update { $0[index].background = background } }
            RoleAppsGrid(
                items: role.items,
                profiles: profiles,
                appName: container.appName(for:),
                change: { items in update { $0[index].items = items } })
            HStack {
                Button("Set Up \(role.name)") { desktops.setUp([role]) }
                    .disabled(desktops.isWalking || desktops.isPaused || role.items.isEmpty)
                Spacer()
                Button("Remove Role…", role: .destructive) { removing = role }
            }
        } header: {
            HStack(spacing: 6) {
                Image(nsImage: RoleTag.image(name: role.name, colorHex: role.colorHex))
                Text("Desktop \(role.desktopNumber)")
            }
        }
    }
}

/// The role color: six dots and a well for any other. It colors the background, the menu bar tag
/// and the panel badge.
struct RoleColorRow: View {
    let colorHex: String
    let recolor: (String) -> Void

    /// Also the order new roles take colors in.
    static let colors = ["#2F7D4F", "#2563EB", "#7C3AED", "#D97706", "#DB2777", "#0891B2"]

    var body: some View {
        LabeledContent("Color") {
            HStack(spacing: 8) {
                ForEach(Self.colors, id: \.self) { hex in
                    Button { recolor(hex) } label: {
                        Circle()
                            .fill(Color(nsColor: NSColor(hex: hex)))
                            .frame(width: 16, height: 16)
                            .overlay {
                                if hex == colorHex.uppercased() {
                                    Circle().inset(by: -3).strokeBorder(Color.accentColor, lineWidth: 2)
                                }
                            }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(hex)
                }
                ColorPicker("Other color", selection: Binding(
                    get: { Color(nsColor: NSColor(hex: colorHex)) },
                    set: { recolor(NSColor($0).hexString) }
                ), supportsOpacity: false)
                .labelsHidden()
                .help("Any other color")
            }
        }
    }
}

/// The role's background: Apple wallpapers in the role color, then a picture of your own, in one
/// row that fills the card.
struct BackgroundPicker: View {
    let role: DesktopRole
    let choose: (RoleBackground) -> Void
    /// Rendered size; the tiles stretch to share the row, so it is drawn a little large.
    nonisolated static let thumbnailSize = NSSize(width: 128, height: 80)
    /// The Apple wallpapers offered, in one row with Picture…. Solid is no longer offered (every
    /// one of these shows the role color), but roles set to it keep it.
    nonisolated static let offered: [MaagicalCore.BackgroundStyle] = [.radial, .motion, .imac, .hello, .chroma]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Background")
            HStack(alignment: .top, spacing: 8) {
                ForEach(Self.offered, id: \.self) { style in
                    swatch(.colored(style), title: style.title)
                }
                pictureTile
            }
            if let style = role.background.style, !AppleWallpaper.isOnThisMac(style) {
                HStack {
                    Text("\(style.title) is not on this Mac yet, so the desktop shows Radial. Click \(AppleWallpaper.appleName(style) ?? style.title) once in System Settings > Wallpaper to download it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Open Wallpaper Settings") { NSWorkspace.shared.open(AppleWallpaper.settingsURL) }
                }
            }
        }
    }

    private func swatch(_ background: RoleBackground, title: String) -> some View {
        let selected = background == role.background
        let pending = background.style.map { !AppleWallpaper.isOnThisMac($0) } ?? false
        return Button { choose(background) } label: {
            VStack(spacing: 3) {
                Image(nsImage: RoleWallpaper.thumbnail(background, colorHex: role.colorHex, size: Self.thumbnailSize))
                    .resizable()
                    .aspectRatio(Self.thumbnailSize.width / Self.thumbnailSize.height, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(alignment: .topTrailing) {
                        if pending {
                            Image(systemName: "arrow.down.circle.fill")
                                .font(.system(size: 12))
                                .foregroundStyle(.white, .black.opacity(0.5))
                                .padding(3)
                        }
                    }
                    .overlay { if selected { selectionRing(RoundedRectangle(cornerRadius: 6)) } }
                Text(title).font(.caption2).foregroundStyle(selected ? .primary : .secondary).lineLimit(1)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .help(pending ? "\(title): download it once in System Settings > Wallpaper" : title)
        .accessibilityLabel(pending ? "\(title), not downloaded" : title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// The last tile: the chosen picture (selected), or an empty tile to add one. Either way a
    /// click opens the file chooser.
    private var pictureTile: some View {
        let path = role.background.imagePath
        return Button { choosePicture() } label: {
            VStack(spacing: 3) {
                Group {
                    if let path {
                        Image(nsImage: RoleWallpaper.thumbnail(.image(path: path), colorHex: role.colorHex, size: Self.thumbnailSize))
                            .resizable()
                    } else {
                        RoundedRectangle(cornerRadius: 6).fill(.quaternary)
                            .overlay { Image(systemName: "photo.badge.plus").font(.title3).foregroundStyle(.secondary) }
                    }
                }
                .aspectRatio(Self.thumbnailSize.width / Self.thumbnailSize.height, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay { if path != nil { selectionRing(RoundedRectangle(cornerRadius: 6)) } }
                Text(path.map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent } ?? "Picture…")
                    .font(.caption2).foregroundStyle(path != nil ? .primary : .secondary).lineLimit(1)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .help(path == nil ? "Choose any picture" : "Choose another picture")
    }

    private func selectionRing(_ shape: some InsettableShape) -> some View {
        shape.inset(by: -2.5).strokeBorder(Color.accentColor, lineWidth: 2)
    }

    /// Opens on the macOS wallpapers; any picture works.
    private func choosePicture() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.directoryURL = role.background.imagePath.map { URL(fileURLWithPath: $0).deletingLastPathComponent() }
            ?? URL(fileURLWithPath: "/System/Library/Desktop Pictures")
        panel.message = "Choose a picture for \(role.name). Its name goes on top."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        choose(.image(path: url.path))
    }
}

/// What opens on the desktop, as a grid of app tiles: the app's icon and name, a ✕ on hover to
/// take it out, and for a Chrome window its profile and a popover for the pages it opens. The
/// last tile adds: a running app in one click, a Chrome profile, or any app from Applications.
struct RoleAppsGrid: View {
    let items: [RoleItem]
    let profiles: [(directory: String, name: String)]
    let appName: (String?) -> String
    let change: ([RoleItem]) -> Void

    private let columns = [GridItem(.adaptive(minimum: 76, maximum: 96), spacing: 8)]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Opens here")
                Spacer()
                Text(items.isEmpty ? "Only what is missing opens" : "\(items.count) item\(items.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    RoleItemTile(
                        item: item,
                        appName: appName,
                        remove: { change(items.enumerated().filter { $0.offset != index }.map(\.element)) },
                        setPages: { pages in
                            guard case .chrome(let directory, let name, _) = item else { return }
                            var next = items
                            next[index] = .chrome(profileDirectory: directory, profileName: name, urls: pages)
                            change(next)
                        })
                }
                addTile
            }
        }
    }

    private var addTile: some View {
        Menu {
            let running = Self.runningApps(excluding: Set(items.compactMap { if case .app(let id) = $0 { id } else { nil } }))
            if !running.isEmpty {
                Section("Open now") {
                    ForEach(running, id: \.bundleID) { app in
                        Button { add(.app(bundleID: app.bundleID)) } label: {
                            Label { Text(app.name) } icon: { Image(nsImage: app.icon) }
                        }
                    }
                }
            }
            if !profiles.isEmpty {
                Section("Chrome window") {
                    ForEach(profiles, id: \.directory) { profile in
                        Button { add(.chrome(profileDirectory: profile.directory, profileName: profile.name, urls: [])) } label: {
                            Label { Text(profile.name) } icon: { Image(nsImage: Self.icon(RoleItem.chromeBundleID)) }
                        }
                    }
                }
            }
            Divider()
            Button("Choose App…") { chooseApps() }
        } label: {
            VStack(spacing: 6) {
                Image(systemName: "plus")
                    .font(.system(size: 16, weight: .medium))
                    .frame(width: 36, height: 36)
                Text("Add").font(.caption)
            }
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 76)
            .background {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(.secondary.opacity(0.4), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            }
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .help("Add an app or a Chrome window")
    }

    private func add(_ item: RoleItem) {
        guard !items.contains(item) else { return }
        change(items + [item])
    }

    private func chooseApps() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        let added = panel.urls.compactMap { Bundle(url: $0)?.bundleIdentifier }
            .map { RoleItem.app(bundleID: $0) }
            .filter { !items.contains($0) }
        if !added.isEmpty { change(items + added) }
    }

    /// Apps with a Dock icon that run now, by name, without Maagical and what the role has.
    private static func runningApps(excluding taken: Set<String>) -> [(bundleID: String, name: String, icon: NSImage)] {
        var seen = taken
        seen.insert(Bundle.main.bundleIdentifier ?? "")
        return NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app in
                guard let id = app.bundleIdentifier, seen.insert(id).inserted else { return nil }
                return (id, app.localizedName ?? id, menuIcon(app.icon ?? icon(id)))
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func icon(_ bundleID: String) -> NSImage {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return NSImage(systemSymbolName: "app.dashed", accessibilityDescription: nil) ?? NSImage()
        }
        return menuIcon(NSWorkspace.shared.icon(forFile: url.path))
    }

    /// Menus show an image at its own size: 16 pt.
    private static func menuIcon(_ image: NSImage) -> NSImage {
        let copy = image.copy() as? NSImage ?? image
        copy.size = NSSize(width: 16, height: 16)
        return copy
    }
}

/// One thing on the desktop: icon, name, and a ✕ while the pointer is over it. A Chrome tile
/// carries its profile name and opens a popover for the pages to open.
private struct RoleItemTile: View {
    let item: RoleItem
    let appName: (String?) -> String
    let remove: () -> Void
    let setPages: ([String]) -> Void

    @State private var hovering = false
    @State private var editingPages = false
    @State private var pagesText = ""

    var body: some View {
        VStack(spacing: 4) {
            AppIcon(bundleID: item.bundleID, size: 36)
            Text(title)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.tail)
            if let subtitle {
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, minHeight: 76)
        .background(.quaternary.opacity(hovering ? 0.9 : 0.5), in: RoundedRectangle(cornerRadius: 10))
        .overlay(alignment: .topTrailing) {
            if hovering {
                Button(action: remove) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(.white, .secondary)
                }
                .buttonStyle(.plain)
                .padding(4)
                .help("Take off this desktop")
                .accessibilityLabel("Remove \(title)")
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .onHover { hovering = $0 }
        .onTapGesture {
            guard case .chrome(_, _, let urls) = item else { return }
            pagesText = urls.joined(separator: "\n")
            editingPages = true
        }
        .popover(isPresented: $editingPages, arrowEdge: .bottom) { pagesEditor }
        .help(helpText)
        .accessibilityElement(children: .combine)
        .accessibilityAction(named: "Remove", remove)
    }

    private var title: String {
        switch item {
        case .app(let bundleID): return appName(bundleID)
        case .chrome(_, let profile, _): return profile
        }
    }

    private var subtitle: String? {
        guard case .chrome(_, _, let urls) = item else { return nil }
        return urls.isEmpty ? "Chrome" : "Chrome · \(urls.count) page\(urls.count == 1 ? "" : "s")"
    }

    private var helpText: String {
        guard case .chrome = item else { return title }
        return "Click to set the pages this Chrome window opens"
    }

    private var pagesEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Pages for \(title)").font(.headline)
            TextField("https://…", text: $pagesText, axis: .vertical)
                .lineLimit(4...8)
                .textFieldStyle(.roundedBorder)
                .frame(width: 320)
            Text("One per line. Empty opens the profile's usual start page.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Done") {
                    setPages(pagesText.split(whereSeparator: \.isWhitespace).map(String.init))
                    editingPages = false
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
    }
}

/// An app's own icon, looked up from its bundle id.
struct AppIcon: View {
    let bundleID: String
    var size: CGFloat = 18

    var body: some View {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable()
                .frame(width: size, height: size)
        } else {
            Image(systemName: "app.dashed")
                .font(.system(size: size * 0.7))
                .frame(width: size, height: size)
        }
    }
}
