import AppKit
import SwiftUI
import VibeFlowCore

/// Launch at login, how VibeFlow looks and sounds, History and updates.
struct GeneralPane: View {
    @Environment(AppContainer.self) private var container

    var body: some View {
        @Bindable var prefs = container.preferences
        Form {
            Section {
                Toggle("Launch at login", isOn: $prefs.launchAtLogin)
                    .onChange(of: prefs.launchAtLogin) { container.applyLaunchAtLogin() }
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
            #if DEBUG
            Text("VibeFlow Dev does not update itself; scripts/dev.sh builds a new one.")
                .foregroundStyle(.secondary)
            #else
            Toggle("Update to the newest main", isOn: $prefs.updateToNewestMain)
                .onChange(of: prefs.updateToNewestMain) { container.updater?.channelChanged() }
            LabeledContent {
                Button("Check for Updates…") { container.updater?.checkForUpdates() }
            } label: {
                Text(lastChecked)
            }
            if Updater.isNightly {
                // Off first, or the release would update straight back to this nightly.
                LabeledContent("Something broke?") {
                    Button("Go Back to the Release…") {
                        prefs.updateToNewestMain = false
                        NSWorkspace.shared.open(Updater.releaseDMG)
                    }
                }
            }
            #endif
        } header: {
            Text("Updates")
        } footer: {
            #if !DEBUG
            Group {
                if Updater.isNightly {
                    Text("Go Back to the Release turns this off and downloads the release; drag it to Applications to replace this build. Turning this off alone keeps this build until a release is newer.")
                } else if prefs.updateToNewestMain {
                    Text("Installs a build of every new main that passed CI.")
                } else {
                    Text("Installs new releases. Checks every 6 hours and installs while you are away from the Mac.")
                }
            }
            .foregroundStyle(.secondary)
            #endif
        }
    }

    #if !DEBUG
    private var lastChecked: String {
        guard let date = container.updater?.lastCheck else { return "Not checked yet" }
        return "Last checked \(date.formatted(.relative(presentation: .named)))"
    }
    #endif
}
