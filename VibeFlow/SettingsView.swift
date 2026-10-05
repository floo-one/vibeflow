import AppKit
import KeyboardShortcuts
import VibeFlowCore
import SwiftUI

enum SettingsTab: Hashable {
    case general, reading, dictation, apps, keys
}

/// Settings window. Deliberately small: models, providers, fallbacks and limits are
/// opinionated constants; only what differs between people is a setting.
struct SettingsView: View {
    @Environment(AppContainer.self) private var container

    var body: some View {
        @Bindable var container = container
        TabView(selection: $container.settingsTab) {
            GeneralTab()
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(SettingsTab.general)
            ReadingTab()
                .tabItem { Label("Reading", systemImage: "waveform") }
                .tag(SettingsTab.reading)
            DictationTab()
                .tabItem { Label("Dictation", systemImage: "mic") }
                .tag(SettingsTab.dictation)
            AppsTab()
                .tabItem { Label("Apps", systemImage: "app.badge") }
                .tag(SettingsTab.apps)
            KeysTab()
                .tabItem { Label("Keys", systemImage: "key") }
                .tag(SettingsTab.keys)
        }
        .frame(width: 600, height: 480)
        .background(SettingsWindowConfigurator())
    }
}

// MARK: - Missing key callout

private struct MissingKeyCallout: View {
    @Environment(AppContainer.self) private var container
    let service: String
    let consequence: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "key.slash")
                .font(.title2)
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 4) {
                Text("No \(service) API key set").font(.headline)
                Text(consequence).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Add key") { container.settingsTab = .keys }
        }
        .padding(12)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - General

private struct GeneralTab: View {
    @Environment(AppContainer.self) private var container

    var body: some View {
        @Bindable var prefs = container.preferences
        Form {
            Section("Shortcuts") {
                KeyboardShortcuts.Recorder("Read selection", name: .read)
                KeyboardShortcuts.Recorder("Smart read selection", name: .smartRead)
                KeyboardShortcuts.Recorder("Read clipboard", name: .readClipboard)
                KeyboardShortcuts.Recorder("Smart read clipboard", name: .smartReadClipboard)
                KeyboardShortcuts.Recorder("Dictate", name: .record)
                Text("Press a read shortcut again to stop. Hold Dictate to talk and release to paste, or tap it to dictate hands-free until the next press.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Toggle("Launch at login", isOn: $prefs.launchAtLogin)
                    .onChange(of: prefs.launchAtLogin) { container.applyLaunchAtLogin() }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Reading (the global default preset)

private struct ReadingTab: View {
    @Environment(AppContainer.self) private var container

    var body: some View {
        @Bindable var store = container.presets
        Form {
            Section("Voice") {
                VoicePicker(voiceID: $store.defaultPreset.elevenLabsVoiceID)
                SpeedSlider(speed: $store.defaultPreset.speed)
                Text("Without a key or a connection, VibeFlow reads with the best Apple voice installed for the text's language.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Smart read") {
                if container.secrets.read(.anthropic) == nil {
                    MissingKeyCallout(service: "Anthropic", consequence: "Smart read is unavailable until a key is added.")
                }
                InstructionsField(text: $store.defaultPreset.smartReadInstructions)
                Text("Smart read gives a short, simple overview of the selection, as if for a 10-year-old.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Dictation

private struct DictationTab: View {
    @Environment(AppContainer.self) private var container
    /// Loaded when the tab appears, never in body (CoreAudio enumeration).
    @State private var inputs: [AudioInputDevice] = []

    var body: some View {
        @Bindable var prefs = container.preferences
        Form {
            if container.secrets.read(.groq) == nil {
                MissingKeyCallout(
                    service: "Groq",
                    consequence: AppleTranscriber.isAvailable
                        ? "Dictation uses Apple's on-device recognizer, without cleanup, until a key is added."
                        : "Dictation needs a Groq key on this Mac."
                )
            }

            Section("Vocabulary") {
                TextField("Names and terms, one per line or comma separated", text: $prefs.vocabulary, axis: .vertical)
                    .lineLimit(3...6)
                    .labelsHidden()
                Text("Groq Whisper transcribes, then cleanup fixes punctuation and misheard words and spells these terms as written.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Microphone") {
                Picker("Microphone", selection: Binding(
                    get: { prefs.microphoneUID ?? "" },
                    set: { prefs.microphoneUID = $0.isEmpty ? nil : $0 }
                )) {
                    Text("Automatic").tag("")
                    ForEach(inputs) { device in
                        Text(device.name).tag(device.uid)
                    }
                    if let chosen = prefs.microphoneUID, !inputs.contains(where: { $0.uid == chosen }) {
                        Text("Unplugged device (uses Automatic)").tag(chosen)
                    }
                }
                Text("Automatic uses the built-in microphone while you listen on Bluetooth headphones, so they keep their sound quality.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("Offline fallback") {
                    HStack {
                        Text(AppleTranscriber.isAvailable ? container.onDeviceModel.summary : "Needs macOS 26")
                            .foregroundStyle(container.onDeviceModel.isReady ? .green : .secondary)
                        if case .failed = container.onDeviceModel.state {
                            Button("Retry") { container.onDeviceModel.retry() }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .task { inputs = AudioDevices.inputs() }
    }
}

// MARK: - Apps

private struct AppsTab: View {
    @Environment(AppContainer.self) private var container
    @State private var selected: String?

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                List(selection: $selected) {
                    ForEach(container.presets.presets, id: \.bundleID) { preset in
                        HStack {
                            Text(appName(preset.bundleID ?? ""))
                            Spacer()
                            if preset.keepsOnThisMac {
                                Image(systemName: "lock.fill").foregroundStyle(.secondary).help("Kept on this Mac")
                            }
                        }
                        .tag(preset.bundleID ?? "")
                    }
                }
                Divider()
                HStack {
                    Menu {
                        ForEach(runningApps, id: \.bundleID) { app in
                            Button(app.name) { add(bundleID: app.bundleID) }
                        }
                    } label: {
                        Label("Add app", systemImage: "plus")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    Spacer()
                    Button(role: .destructive) {
                        if let selected { container.presets.remove(bundleID: selected) }
                        selected = nil
                    } label: { Image(systemName: "minus") }
                    .disabled(selected == nil)
                }
                .padding(8)
            }
            .frame(minWidth: 180)

            Group {
                if let selected, let index = container.presets.presets.firstIndex(where: { $0.bundleID == selected }) {
                    Form {
                        AppEditor(preset: binding(for: index))
                    }
                    .formStyle(.grouped)
                } else {
                    ContentUnavailableView("No app selected", systemImage: "app.badge", description: Text("Add an app to keep it on this Mac or give it its own voice, speed or smart read instructions."))
                }
            }
            .frame(minWidth: 340)
        }
    }

    private struct RunningApp { let name: String; let bundleID: String }

    private var runningApps: [RunningApp] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app in
                guard let id = app.bundleIdentifier, let name = app.localizedName else { return nil }
                return RunningApp(name: name, bundleID: id)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func appName(_ bundleID: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return bundleID }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }

    private func add(bundleID: String) {
        if !container.presets.presets.contains(where: { $0.bundleID == bundleID }) {
            container.presets.upsert(container.presets.newPreset(bundleID: bundleID))
        }
        selected = bundleID
    }

    private func binding(for index: Int) -> Binding<AppPreset> {
        Binding(
            get: { container.presets.presets[index] },
            set: { container.presets.upsert($0) }
        )
    }
}

private struct AppEditor: View {
    @Binding var preset: AppPreset

    var body: some View {
        Section {
            Toggle("Keep this app on this Mac", isOn: $preset.keepsOnThisMac)
            Text(preset.keepsOnThisMac
                 ? "Reads use the Apple voice, smart read is off and dictation stays on device. Nothing from this app leaves the Mac."
                 : AppleTranscriber.isAvailable
                    ? "Turn on for confidential apps: Apple voice, no smart read, on-device dictation."
                    : "Turn on for confidential apps: Apple voice and no smart read. Dictation into this app then fails, since on-device dictation needs macOS 26.")
                .font(.caption).foregroundStyle(.secondary)
        }
        Section("Voice") {
            if !preset.keepsOnThisMac {
                VoicePicker(voiceID: $preset.elevenLabsVoiceID)
            }
            SpeedSlider(speed: $preset.speed)
        }
        if !preset.keepsOnThisMac {
            Section("Smart read") {
                InstructionsField(text: $preset.smartReadInstructions)
            }
        }
    }
}

// MARK: - ElevenLabs voice

private struct VoicePicker: View {
    @Environment(AppContainer.self) private var container
    @Binding var voiceID: String

    var body: some View {
        switch container.catalogs.voicesState {
        case .noKey:
            MissingKeyCallout(service: "ElevenLabs", consequence: "Reads use the Apple voice until a key is added.")
        case .loading:
            ProgressView("Loading voices").controlSize(.small)
        case .failed(let reason):
            Label(reason, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            Button("Retry") { container.catalogs.refreshVoices() }
        case .loaded:
            SearchablePicker(
                title: "Voice",
                items: container.catalogs.voices.map { ($0.id, $0.name, $0.description) },
                selection: $voiceID
            )
        case .limited(let reason):
            Label(reason, systemImage: "info.circle").font(.callout)
            SearchablePicker(
                title: "Voice",
                items: container.catalogs.voices.map { ($0.id, $0.name, $0.description) },
                selection: $voiceID
            )
            TextField("Or paste a voice id from your ElevenLabs library", text: $voiceID)
                .textFieldStyle(.roundedBorder)
        }
    }
}

// MARK: - Speed slider

/// Drags update local state only; the preset (and its persistence and every observer) is
/// written once, when the drag ends.
private struct SpeedSlider: View {
    @Binding var speed: Double
    @State private var draft: Double?

    var body: some View {
        LabeledContent("Speed") {
            HStack {
                Slider(value: Binding(get: { draft ?? speed }, set: { draft = $0 }), in: 0.7...2.0, step: 0.05) { editing in
                    if !editing, let value = draft {
                        speed = value
                        draft = nil
                    }
                }
                Text((draft ?? speed).formatted(.number.precision(.fractionLength(2))))
                    .monospacedDigit()
                    .frame(width: 40)
            }
        }
    }
}

// MARK: - Smart read instructions

private struct InstructionsField: View {
    @Binding var text: String?

    var body: some View {
        TextField("Extra instructions, e.g. Tell me what they want from me and by when", text: Binding(
            get: { text ?? "" },
            set: { text = $0.isEmpty ? nil : String($0.prefix(SmartReadPrompts.maxInstructionsLength)) }
        ), axis: .vertical)
        .lineLimit(2...4)
        .textFieldStyle(.roundedBorder)
    }
}

// MARK: - Searchable picker

/// A filter field over a list of (id, name, detail). The current selection is shown even
/// when it is not in the list (e.g. a voice removed from the account).
private struct SearchablePicker: View {
    let title: String
    let items: [(id: String, name: String, detail: String)]
    @Binding var selection: String
    @State private var query = ""

    private var filtered: [(id: String, name: String, detail: String)] {
        guard !query.isEmpty else { return items }
        return items.filter { $0.name.localizedCaseInsensitiveContains(query) || $0.detail.localizedCaseInsensitiveContains(query) || $0.id.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        LabeledContent(title) {
            Text(items.first { $0.id == selection }?.name ?? selection)
                .fontWeight(.medium)
        }
        TextField("Search \(title.lowercased())s", text: $query)
            .textFieldStyle(.roundedBorder)
        List(filtered, id: \.id, selection: $selection) { item in
            HStack {
                Text(item.name)
                if !item.detail.isEmpty {
                    Text(item.detail).foregroundStyle(.secondary).font(.caption)
                }
                Spacer()
                if item.id == selection { Image(systemName: "checkmark") }
            }
            .contentShape(Rectangle())
            .onTapGesture { selection = item.id }
        }
        .frame(minHeight: 120, maxHeight: 180)
    }
}

// MARK: - Keys

private struct KeysTab: View {
    @Environment(AppContainer.self) private var container
    @State private var elevenLabs = ""
    @State private var anthropic = ""
    @State private var groq = ""
    @State private var saved = false
    @State private var error: String?

    var body: some View {
        Form {
            keySection("ElevenLabs", purpose: "Natural voice for reading", text: $elevenLabs, key: .elevenLabs)
            keySection("Anthropic", purpose: "Smart read", text: $anthropic, key: .anthropic)
            keySection("Groq", purpose: "Dictation", text: $groq, key: .groq)
            Section {
                HStack {
                    Button("Save") { save() }
                        .keyboardShortcut(.defaultAction)
                    if saved { Text("Saved.").foregroundStyle(.secondary) }
                    if let error { Text(error).foregroundStyle(.red) }
                }
                Text("Keys stay in your Keychain. Reading sends the text to ElevenLabs, smart read to Anthropic, and dictation sends your recording to Groq.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            elevenLabs = container.secrets.read(.elevenLabs) ?? ""
            anthropic = container.secrets.read(.anthropic) ?? ""
            groq = container.secrets.read(.groq) ?? ""
        }
    }

    private func keySection(_ service: String, purpose: String, text: Binding<String>, key: SecretKey) -> some View {
        Section {
            SecureField("API key", text: text)
            if container.secrets.read(key) != nil {
                Label("Stored in your Keychain", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green).font(.callout)
            } else {
                Label("No key", systemImage: "key.slash")
                    .foregroundStyle(.orange).font(.callout)
            }
        } header: {
            Text("\(service) · \(purpose)")
        }
    }

    private func save() {
        do {
            try container.secrets.write(elevenLabs, for: .elevenLabs)
            try container.secrets.write(anthropic, for: .anthropic)
            try container.secrets.write(groq, for: .groq)
            saved = true
            error = nil
            container.catalogs.refresh()
        } catch {
            self.error = "Could not save: \(error.localizedDescription)"
        }
    }
}
