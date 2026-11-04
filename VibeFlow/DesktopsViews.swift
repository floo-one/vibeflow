import AppKit
import KeyboardShortcuts
import SwiftUI
import VibeFlowCore

// Desktop Roles views (docs/designs/desktop-roles.md): the role tag in the menu bar, the
// Desktops menu (the panel tile's chevron and the role tag), and Settings > Desktops.

/// The menu bar item's label: the focused desktop's role as a colored tag.
struct RoleTagLabel: View {
    @Environment(AppContainer.self) private var container

    var body: some View {
        if let role = container.desktops.currentRole {
            Image(nsImage: RoleTag.image(name: role.name, colorHex: role.colorHex))
        }
    }
}

/// The Desktops menu: behind the panel tile's chevron and on the role tag. Every action closes
/// the panel first, since a walk switches desktops and Settings takes the front.
struct DesktopsMenuItems: View {
    @Environment(AppContainer.self) private var container

    var body: some View {
        let desktops = container.desktops
        if desktops.isPaused {
            Text("Paused: the installed VibeFlow handles desktops")
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
    /// Roles whose app group is folded away; all start open.
    @State private var collapsed: Set<UUID> = []

    /// Colors offered to new roles, in order.
    private static let palette = BackgroundPicker.colors

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
                    set: { container.preferences.desktopRoleTag = $0 }
                )) {
                    Text("Show the role in the menu bar")
                    Text("The same tag shows on every screen; the wallpaper names each screen's own role.")
                }
            } footer: {
                Text("Each role lives on one desktop, numbered like Mission Control across your screens. Setting up opens only what is missing, tints the desktop with the role's color and name, and puts every screen back where it was.")
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
        .onAppear { profiles = ChromeProfiles.list() }
    }

    private var subtitle: String {
        let desktops = container.desktops
        if desktops.isPaused { return "Paused while the installed VibeFlow runs" }
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

    /// One card per role: what the desktop is (name, color, number), then a group with what opens
    /// on it, then Set Up and Remove.
    @ViewBuilder
    private func roleSection(_ index: Int) -> some View {
        let role = roles[index]
        let desktops = container.desktops
        Section {
            TextField("Name", text: Binding(
                get: { role.name },
                set: { name in update { $0[index].name = name } }
            ))
            BackgroundPicker(
                role: role,
                choose: { background in update { $0[index].background = background } },
                recolor: { hex in update { $0[index].colorHex = hex } })
            Picker("Desktop", selection: Binding(
                get: { role.desktopNumber },
                set: { number in update { $0[index].desktopNumber = number } }
            )) {
                ForEach(([role.desktopNumber] + freeDesktops).sorted(), id: \.self) { Text("Desktop \($0)").tag($0) }
            }
            DisclosureGroup(isExpanded: Binding(
                get: { !collapsed.contains(role.id) },
                set: { open in if open { collapsed.remove(role.id) } else { collapsed.insert(role.id) } }
            )) {
                if role.items.isEmpty {
                    Text("Nothing yet: add the apps and Chrome windows this desktop should have.")
                        .foregroundStyle(.secondary)
                }
                ForEach(Array(role.items.enumerated()), id: \.offset) { itemIndex, item in
                    itemRow(item, role: index, item: itemIndex)
                }
                Menu("Add App or Chrome Window") {
                    Button("App…") { chooseApp(for: index) }
                    if !profiles.isEmpty {
                        Section("Chrome window") {
                            ForEach(profiles, id: \.directory) { profile in
                                Button(profile.name) {
                                    update { $0[index].items.append(.chrome(profileDirectory: profile.directory, profileName: profile.name, urls: [])) }
                                }
                            }
                        }
                    }
                }
                .fixedSize()
            } label: {
                LabeledContent("Opens on this desktop") {
                    Text(role.items.isEmpty ? "None" : "\(role.items.count) item\(role.items.count == 1 ? "" : "s")")
                }
            }
            HStack {
                Button("Set Up \(role.name)") { desktops.setUp([role]) }
                    .disabled(desktops.isWalking || desktops.isPaused || role.items.isEmpty)
                Spacer()
                Button("Remove Role", role: .destructive) { update { $0.remove(at: index) } }
            }
        } header: {
            HStack(spacing: 6) {
                Image(nsImage: RoleTag.image(name: role.name, colorHex: role.colorHex))
                Text("Desktop \(role.desktopNumber)")
            }
        }
    }

    @ViewBuilder
    private func itemRow(_ item: RoleItem, role: Int, item index: Int) -> some View {
        switch item {
        case .app(let bundleID):
            LabeledContent {
                removeButton(role: role, item: index)
            } label: {
                Label { Text(container.appName(for: bundleID)) } icon: { AppIcon(bundleID: bundleID) }
            }
        case .chrome(let directory, let name, let urls):
            LabeledContent {
                HStack {
                    TextField("Pages (optional)", text: Binding(
                        get: { urls.joined(separator: " ") },
                        set: { text in
                            let pages = text.split(whereSeparator: \.isWhitespace).map(String.init)
                            update { $0[role].items[index] = .chrome(profileDirectory: directory, profileName: name, urls: pages) }
                        }
                    ))
                    .labelsHidden()
                    removeButton(role: role, item: index)
                }
            } label: {
                Label { Text("Chrome · \(name)") } icon: { AppIcon(bundleID: RoleItem.chromeBundleID) }
            }
        }
    }

    private func removeButton(role: Int, item: Int) -> some View {
        Button {
            update { $0[role].items.remove(at: item) }
        } label: {
            Image(systemName: "minus.circle")
        }
        .buttonStyle(.borderless)
        .help("Remove")
    }

    private func chooseApp(for role: Int) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        let ids = panel.urls.compactMap { Bundle(url: $0)?.bundleIdentifier }
        update { roles in
            for id in ids where !roles[role].items.contains(.app(bundleID: id)) {
                roles[role].items.append(.app(bundleID: id))
            }
        }
    }
}

/// The role's look: a row of backgrounds (the colorable styles in the role color, then a picture),
/// and a row of colors that recolors the styles, the tag and the panel badge.
struct BackgroundPicker: View {
    let role: DesktopRole
    let choose: (RoleBackground) -> Void
    let recolor: (String) -> Void

    /// The palette new roles take colors from, plus a few more.
    static let colors = ["#2F7D4F", "#2563EB", "#7C3AED", "#D97706", "#DB2777", "#0891B2", "#DC2626", "#475569"]
    private static let thumb = NSSize(width: 64, height: 40)

    var body: some View {
        LabeledContent("Background") {
            HStack(spacing: 8) {
                ForEach(BackgroundStyle.allCases, id: \.self) { style in
                    swatch(.colored(style), title: style.title)
                }
                if let path = role.background.imagePath {
                    swatch(.image(path: path), title: URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent)
                }
                Button { choosePicture() } label: {
                    Image(systemName: "photo.badge.plus")
                        .frame(width: Self.thumb.width, height: Self.thumb.height)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .help("Choose a picture…")
            }
        }
        LabeledContent {
            HStack(spacing: 6) {
                ForEach(Self.colors, id: \.self) { hex in
                    Button { recolor(hex) } label: {
                        Circle()
                            .fill(Color(nsColor: NSColor(hex: hex)))
                            .frame(width: 18, height: 18)
                            .overlay { if hex == role.colorHex.uppercased() { selectionRing(Circle()) } }
                    }
                    .buttonStyle(.plain)
                    .help(hex)
                }
                ColorPicker("Other color", selection: Binding(
                    get: { Color(nsColor: NSColor(hex: role.colorHex)) },
                    set: { recolor(NSColor($0).hexString) }
                ), supportsOpacity: false)
                .labelsHidden()
            }
        } label: {
            Text("Color")
            Text(role.background.imagePath == nil ? "Colors the background, the tag and the panel" : "Colors the tag and the panel")
        }
    }

    private func swatch(_ background: RoleBackground, title: String) -> some View {
        let selected = background == role.background
        return Button { choose(background) } label: {
            Image(nsImage: RoleWallpaper.thumbnail(background, colorHex: role.colorHex, size: Self.thumb))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay { if selected { selectionRing(RoundedRectangle(cornerRadius: 6)) } }
        }
        .buttonStyle(.plain)
        .help(title)
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? .isSelected : [])
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

/// An app's own icon at list size, looked up from its bundle id.
struct AppIcon: View {
    let bundleID: String

    var body: some View {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable()
                .frame(width: 18, height: 18)
        } else {
            Image(systemName: "app.dashed")
        }
    }
}
