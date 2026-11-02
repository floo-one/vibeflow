import AppKit
import SwiftUI
import VibeFlowCore

/// Launch at login, the focus timer, how VibeFlow looks and sounds, History and updates.
struct GeneralPane: View {
    @Environment(AppContainer.self) private var container

    var body: some View {
        @Bindable var prefs = container.preferences
        Form {
            Section {
                Toggle("Launch at login", isOn: $prefs.launchAtLogin)
                    .onChange(of: prefs.launchAtLogin) { container.applyLaunchAtLogin() }
            }
            Section {
                Toggle("Focus timer in menu bar", isOn: $prefs.focusEnabled)
                    .onChange(of: prefs.focusEnabled) { if !prefs.focusEnabled { container.focus.switchedOff() } }
            } header: {
                Text("Focus")
            } footer: {
                Text("A Pomodoro timer: focus, break, and a long break after a few blocks. Pick the preset in its menu.")
                    .foregroundStyle(.secondary)
            }
            Section("Look & Feel") {
                Picker("Appearance", selection: $prefs.colorMode) {
                    ForEach(ColorMode.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .onChange(of: prefs.colorMode) { container.applyColorMode() }
                Toggle("Sound when dictation starts and stops", isOn: $prefs.dictationSounds)
                Toggle("Show activity around the notch", isOn: $prefs.notchIndicator)
                Picker("While listening", selection: $prefs.listeningStyle) {
                    ForEach(ListeningStyle.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .disabled(!prefs.notchIndicator)
            }
            HistorySettings()
            UpdateSettings()
        }
        .formStyle(.grouped)
    }
}

/// The installed version and how it updates (Updater). VibeFlow Dev only shows its version:
/// scripts/dev.sh replaces it, Sparkle never runs there.
private struct UpdateSettings: View {
    @Environment(AppContainer.self) private var container

    var body: some View {
        @Bindable var prefs = container.preferences
        Section {
            LabeledContent("Version", value: Updater.installedVersion)
            Picker("Channel", selection: $prefs.updateToNewestMain) {
                Text("Stable").tag(false)
                Text("Nightly").tag(true)
            }
            .pickerStyle(.segmented)
            #if DEBUG
            .disabled(true)
            #else
            .onChange(of: prefs.updateToNewestMain) { container.updater?.channelChanged() }
            #endif
            #if !DEBUG
            LabeledContent {
                Button("Check for Updates…") { container.updater?.checkForUpdates() }
            } label: {
                Text(lastChecked)
            }
            if Updater.isNightly {
                LabeledContent("Something broke?") {
                    if let step = StableInstaller.shared.step {
                        HStack {
                            ProgressView().controlSize(.small)
                            Text(step)
                        }
                    } else {
                        Button("Back to Stable") { StableInstaller.shared.install(preferences: prefs) }
                    }
                }
            }
            #endif
        } header: {
            Text("Updates")
        } footer: {
            Group {
                #if DEBUG
                Text("VibeFlow Dev does not update itself; scripts/dev.sh builds a new one. The installed VibeFlow uses this choice.")
                #else
                if Updater.isNightly {
                    Text("Back to Stable installs the newest release in place of this nightly and reopens VibeFlow. Choose Nightly again once main is fixed. Stable alone keeps this build until a release is newer.")
                } else if prefs.updateToNewestMain {
                    Text("Nightly installs a build of every new main that passed CI, between releases.")
                } else {
                    Text("Stable installs releases only. Checks every 6 hours and installs while you are away from the Mac.")
                }
                #endif
            }
            .foregroundStyle(.secondary)
        }
    }

    #if !DEBUG
    private var lastChecked: String {
        guard let date = container.updater?.lastCheck else { return "Not checked yet" }
        return "Last checked \(date.formatted(.relative(presentation: .named)))"
    }
    #endif
}
