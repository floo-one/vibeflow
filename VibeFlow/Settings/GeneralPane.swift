import AppKit
import SwiftUI
import VibeFlowCore

/// The version and Check for Updates in the header, launch at login, how VibeFlow looks,
/// History and the update channel.
struct GeneralPane: View {
    @Environment(AppContainer.self) private var container

    var body: some View {
        @Bindable var prefs = container.preferences
        Form {
            VersionHeader()

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

/// "VibeFlow 1.4.0" with when it last looked for updates and Check for Updates. VibeFlow Dev
/// never updates itself (scripts/dev.sh replaces it), so it shows its version only.
private struct VersionHeader: View {
    @Environment(AppContainer.self) private var container

    var body: some View {
        #if DEBUG
        PaneHeader(.general, title: "VibeFlow Dev \(Updater.installedVersion)",
                   subtitle: "Built by scripts/dev.sh, never updates itself")
        #else
        PaneHeader(.general, title: "VibeFlow \(Updater.installedVersion)", subtitle: lastChecked) {
            Button("Check for Updates…") { container.updater?.checkForUpdates() }
        }
        #endif
    }

    #if !DEBUG
    private var lastChecked: String {
        let channel = Updater.isNightly ? "Nightly" : "Stable"
        guard let date = container.updater?.lastCheck else { return "\(channel) · not checked yet" }
        return "\(channel) · checked \(date.formatted(.relative(presentation: .named)))"
    }
    #endif
}

/// The installed version and how it updates (Updater). VibeFlow Dev only shows its version:
/// scripts/dev.sh replaces it, Sparkle never runs there.
private struct UpdateSettings: View {
    @Environment(AppContainer.self) private var container

    var body: some View {
        @Bindable var prefs = container.preferences
        Section {
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
}
