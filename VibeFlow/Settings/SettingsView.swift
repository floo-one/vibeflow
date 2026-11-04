import SwiftUI

/// The Settings panes in sidebar order. Title, symbol and colour live here so the menu can
/// use the same look for the same feature.
enum SettingsTab: Hashable, CaseIterable {
    case general, accounts, read, smartRead, dictation, clocks, meetings, pomodoro, keepAwake, desktops

    var title: String {
        switch self {
        case .general: return "General"
        case .accounts: return "Accounts"
        case .read: return "Read"
        case .smartRead: return "Smart Read"
        case .dictation: return "Dictation"
        case .clocks: return "Clocks"
        case .meetings: return "Meetings"
        case .keepAwake: return "Keep Awake"
        case .pomodoro: return "Pomodoro"
        case .desktops: return "Desktops"
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .accounts: return "key.fill"
        case .read: return "waveform"
        case .smartRead: return "sparkles"
        case .dictation: return "mic.fill"
        case .clocks: return "clock"
        case .meetings: return "calendar"
        case .keepAwake: return "cup.and.saucer.fill"
        case .pomodoro: return "timer"
        case .desktops: return "rectangle.3.group"
        }
    }

    var tint: Color {
        switch self {
        case .general, .accounts: return .gray
        case .read: return FeatureColor.read
        case .smartRead: return FeatureColor.smartRead
        case .dictation: return FeatureColor.dictation
        case .clocks, .meetings, .pomodoro: return FeatureColor.tools
        case .keepAwake, .desktops: return FeatureColor.utilities
        }
    }
}

/// One colour per feature: the voice features each have their own, Focus & Time share one,
/// Utilities another.
enum FeatureColor {
    static let read = Color(red: 0x00 / 255, green: 0x64 / 255, blue: 0xD2 / 255)
    static let smartRead = Color(red: 0x5B / 255, green: 0x4F / 255, blue: 0xE0 / 255)
    static let dictation = Color(red: 0xD9 / 255, green: 0x30 / 255, blue: 0x25 / 255)
    static let tools = Color(red: 0x0F / 255, green: 0x7B / 255, blue: 0x5F / 255)
    static let utilities = Color(red: 0x5A / 255, green: 0x64 / 255, blue: 0x78 / 255)
}

/// Settings: a sidebar of panes, each a dropdown per voice, model and device plus the
/// shortcuts of that feature. Nothing else.
struct SettingsView: View {
    @Environment(AppContainer.self) private var container
    /// Always .all: the sidebar is the only way to the other panes (SettingsWindow pins it too).
    @State private var columns = NavigationSplitViewVisibility.all

    var body: some View {
        @Bindable var container = container
        NavigationSplitView(columnVisibility: $columns) {
            List(selection: $container.settingsTab) {
                row(.general)
                row(.accounts)
                Section("Voice") {
                    row(.read)
                    row(.smartRead)
                    row(.dictation)
                }
                Section("Focus & Time") {
                    row(.clocks)
                    row(.meetings)
                    row(.pomodoro)
                }
                Section("Utilities") {
                    row(.keepAwake)
                    row(.desktops)
                }
            }
            .navigationSplitViewColumnWidth(SettingsWindow.sidebarWidth)
            .toolbar(removing: .sidebarToggle)
        } detail: {
            pane(container.settingsTab)
                .navigationTitle(container.settingsTab.title)
        }
        .onChange(of: columns) { _, newValue in
            if newValue != .all { columns = .all }
        }
        .frame(width: 720, height: 540)
        .background(SettingsWindowConfigurator())
    }

    private func row(_ tab: SettingsTab) -> some View {
        Label {
            Text(tab.title)
        } icon: {
            SettingsIcon(tab: tab)
        }
        .tag(tab)
    }

    @ViewBuilder
    private func pane(_ tab: SettingsTab) -> some View {
        switch tab {
        case .general: GeneralPane()
        case .accounts: AccountsPane()
        case .read: ReadPane()
        case .smartRead: SmartReadPane()
        case .dictation: DictationPane()
        case .clocks: ClocksTab()
        case .meetings: MeetingsTab()
        case .keepAwake: KeepAwakePane()
        case .pomodoro: PomodoroPane()
        case .desktops: DesktopsPane()
        }
    }
}

/// The white symbol on a small coloured rounded square, as in System Settings. 20 points in
/// the sidebar, 40 in a pane's header.
struct SettingsIcon: View {
    let tab: SettingsTab
    var size: CGFloat = 20

    var body: some View {
        Image(systemName: tab.symbol)
            .font(.system(size: size * 0.55, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(tab.tint.gradient, in: .rect(cornerRadius: size / 4))
            .accessibilityHidden(true)
    }
}

/// The card at the top of every pane: the feature's icon, a title, one line on what it does
/// or its state, and its one main action (Start Focus, Check for Updates…) on the right.
struct PaneHeader<Trailing: View>: View {
    let tab: SettingsTab
    var title: String?
    let subtitle: String
    @ViewBuilder var trailing: Trailing

    init(_ tab: SettingsTab, title: String? = nil, subtitle: String, @ViewBuilder trailing: () -> Trailing = { EmptyView() }) {
        self.tab = tab
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing()
    }

    var body: some View {
        Section {
            HStack(spacing: 12) {
                SettingsIcon(tab: tab, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title ?? tab.title).font(.headline)
                    Text(subtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                trailing
            }
            .padding(.vertical, 4)
        }
    }
}
