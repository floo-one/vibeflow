import SwiftUI

/// The Settings panes in sidebar order. Title, symbol and colour live here so the menu can
/// use the same look for the same feature.
enum SettingsTab: Hashable, CaseIterable {
    case general, accounts, read, smartRead, dictation, clocks, meetings, keepAwake, pomodoro

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
        }
    }

    var tint: Color {
        switch self {
        case .general, .accounts: return .gray
        case .read: return FeatureColor.read
        case .smartRead: return FeatureColor.smartRead
        case .dictation: return FeatureColor.dictation
        case .clocks, .meetings, .keepAwake, .pomodoro: return FeatureColor.tools
        }
    }
}

/// One colour per feature: the voice features each have their own, the tools share one.
enum FeatureColor {
    static let read = Color(red: 0x00 / 255, green: 0x64 / 255, blue: 0xD2 / 255)
    static let smartRead = Color(red: 0x5B / 255, green: 0x4F / 255, blue: 0xE0 / 255)
    static let dictation = Color(red: 0xD9 / 255, green: 0x30 / 255, blue: 0x25 / 255)
    static let tools = Color(red: 0x0F / 255, green: 0x7B / 255, blue: 0x5F / 255)
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
                Section("Tools") {
                    row(.clocks)
                    row(.meetings)
                    row(.keepAwake)
                    row(.pomodoro)
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
        }
    }
}

/// The white symbol on a small coloured rounded square, as in System Settings.
struct SettingsIcon: View {
    let tab: SettingsTab

    var body: some View {
        Image(systemName: tab.symbol)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 20, height: 20)
            .background(tab.tint.gradient, in: .rect(cornerRadius: 5))
            .accessibilityHidden(true)
    }
}
