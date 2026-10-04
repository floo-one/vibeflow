import AppKit
import KeyboardShortcuts
import VibeFlowCore
import SwiftUI

enum SettingsTab: Hashable {
    case general, voices, smartRead, dictation, presets, keys
}

/// Settings window: General, Voices, Smart read, Dictation, Per-app presets, Keys.
struct SettingsView: View {
    @Environment(AppContainer.self) private var container

    var body: some View {
        @Bindable var container = container
        TabView(selection: $container.settingsTab) {
            GeneralTab()
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(SettingsTab.general)
            VoicesTab()
                .tabItem { Label("Voices", systemImage: "waveform") }
                .tag(SettingsTab.voices)
            SmartReadTab()
                .tabItem { Label("Smart read", systemImage: "sparkles") }
                .tag(SettingsTab.smartRead)
            DictationTab()
                .tabItem { Label("Dictation", systemImage: "mic") }
                .tag(SettingsTab.dictation)
            PresetsTab()
                .tabItem { Label("Per-app", systemImage: "app.badge") }
                .tag(SettingsTab.presets)
            KeysTab()
                .tabItem { Label("Keys", systemImage: "key") }
                .tag(SettingsTab.keys)
        }
        .frame(width: 640, height: 520)
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
            if container.secrets.read(.elevenLabs) == nil {
                MissingKeyCallout(service: "ElevenLabs", consequence: "Reads use the built-in Apple voice until a key is added.")
            }
            Section("Shortcuts") {
                KeyboardShortcuts.Recorder("Read selection", name: .read)
                KeyboardShortcuts.Recorder("Smart read selection", name: .smartRead)
                KeyboardShortcuts.Recorder("Read clipboard", name: .readClipboard)
                KeyboardShortcuts.Recorder("Smart read clipboard", name: .smartReadClipboard)
                KeyboardShortcuts.Recorder("Dictate", name: .record)
                Text("Press a read shortcut again to stop. Hold Dictate to talk and release to paste; tap it to dictate hands-free until the next press.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Long selections") {
                LabeledContent("Ask before reading more than") {
                    HStack {
                        TextField("", value: $prefs.sizeCap, format: .number)
                            .frame(width: 90)
                            .multilineTextAlignment(.trailing)
                        Text("characters")
                    }
                }
                Text("Nothing above \(SessionConfiguration.hardMax.formatted()) characters is ever sent; that is the model's limit.")
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

// MARK: - Voices (the global default preset)

private struct VoicesTab: View {
    @Environment(AppContainer.self) private var container

    var body: some View {
        @Bindable var store = container.presets
        Form {
            PresetEditor(preset: $store.defaultPreset, showSmartRead: false)
        }
        .formStyle(.grouped)
    }
}

// MARK: - Smart read

private struct SmartReadTab: View {
    @Environment(AppContainer.self) private var container

    var body: some View {
        @Bindable var prefs = container.preferences
        @Bindable var store = container.presets
        Form {
            Section("Model") {
                switch container.catalogs.modelsState {
                case .noKey:
                    MissingKeyCallout(service: "Anthropic", consequence: "Smart read is unavailable until a key is added.")
                case .loading:
                    ProgressView("Loading models").controlSize(.small)
                case .failed(let reason):
                    Label(reason, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                    Button("Retry") { container.catalogs.refreshModels() }
                case .limited(let reason):
                    Label(reason, systemImage: "info.circle")
                    TextField("Anthropic model id", text: $prefs.smartReadModel)
                case .loaded:
                    SearchablePicker(
                        title: "Model",
                        items: container.catalogs.models.map { ($0.id, $0.name, $0.id) },
                        selection: $prefs.smartReadModel
                    )
                    Text("Haiku answers fastest; Sonnet is more careful with long legal text.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Default behaviour") {
                Toggle("Smart read enabled", isOn: $store.defaultPreset.smartReadEnabled)
                Picker("Mode", selection: $store.defaultPreset.smartReadMode) {
                    Text("Explain simply: a quick overview, like for a 10-year-old").tag(SmartReadMode.brief)
                    Text("Cleanup: the full text, tidied for listening").tag(SmartReadMode.cleanup)
                }
                .pickerStyle(.radioGroup)
                InstructionsField(text: $store.defaultPreset.smartReadInstructions)
                Text("Per-app presets can turn smart read off for sensitive apps.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Dictation

private struct DictationTab: View {
    @Environment(AppContainer.self) private var container
    /// Loaded once when the tab appears, never in body (CoreAudio enumeration).
    @State private var inputs: [AudioInputDevice] = []

    private var hasGroqKey: Bool { container.secrets.read(.groq) != nil }

    var body: some View {
        @Bindable var prefs = container.preferences
        Form {
            if !hasGroqKey && (prefs.transcriber == .groq || (prefs.cleanupEnabled && prefs.cleanupProvider == .groq)) {
                MissingKeyCallout(
                    service: "Groq",
                    consequence: AppleTranscriber.isAvailable
                        ? "Dictation uses Apple's on-device recognizer and skips cleanup until a key is added."
                        : "Dictation needs a Groq key on this Mac."
                )
            }

            Section("Transcription") {
                Picker("Transcriber", selection: $prefs.transcriber) {
                    Text("Groq (Whisper, fast and accurate)").tag(TranscriberChoice.groq)
                    Text("Custom OpenAI-compatible endpoint").tag(TranscriberChoice.custom)
                    Text(AppleTranscriber.isAvailable ? "Apple on-device (never leaves this Mac)" : "Apple on-device (needs macOS 26)")
                        .tag(TranscriberChoice.apple)
                        .selectionDisabled(!AppleTranscriber.isAvailable)
                }
                .pickerStyle(.radioGroup)
                if prefs.transcriber == .custom {
                    TextField("Base URL", text: $prefs.customEndpoint, prompt: Text("http://localhost:8000/v1"))
                }
                if prefs.transcriber != .apple {
                    TextField("Model", text: $prefs.transcriptionModel, prompt: Text(OpenAITranscriber.defaultModel))
                    Text("Falls back to Apple on device when offline, rate limited or the service is down.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                LabeledContent("On-device model") {
                    HStack {
                        Text(container.onDeviceModel.summary)
                            .foregroundStyle(container.onDeviceModel.isReady ? .green : .secondary)
                        if case .failed = container.onDeviceModel.state {
                            Button("Retry") { container.onDeviceModel.retry() }
                        }
                    }
                }
            }

            Section("Cleanup") {
                Toggle("Fix punctuation, casing and misheard words", isOn: $prefs.cleanupEnabled)
                if prefs.cleanupEnabled {
                    Picker("Provider", selection: $prefs.cleanupProvider) {
                        Text("Groq").tag(CleanupProvider.groq)
                        Text("Anthropic (Claude Haiku)").tag(CleanupProvider.anthropic)
                    }
                    if prefs.cleanupProvider == .groq {
                        TextField("Model", text: $prefs.cleanupModel, prompt: Text(ChatCompletionsCleaner.defaultModel))
                    } else if container.secrets.read(.anthropic) == nil {
                        Label("No Anthropic key: dictations are pasted without cleanup.", systemImage: "key.slash")
                            .foregroundStyle(.orange).font(.callout)
                    }
                    Text("If cleanup takes longer than 1.5 s or fails, the raw transcript is pasted.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Vocabulary")
                    TextField("Names and terms, one per line or comma separated", text: $prefs.vocabulary, axis: .vertical)
                        .lineLimit(2...5)
                        .textFieldStyle(.roundedBorder)
                }
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
                Text("Automatic uses the built-in microphone while you listen on Bluetooth headphones, so they stay in high-quality mode, and the system input otherwise.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task { inputs = AudioDevices.inputs() }
    }
}

// MARK: - Per-app presets

private struct PresetsTab: View {
    @Environment(AppContainer.self) private var container
    @State private var selected: String?
    @State private var newBundleID = ""

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                List(selection: $selected) {
                    ForEach(container.presets.presets, id: \.bundleID) { preset in
                        Text(preset.bundleID ?? "")
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
                        Label("Add running app", systemImage: "plus")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    TextField("or bundle id", text: $newBundleID)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { add(bundleID: newBundleID); newBundleID = "" }
                    Button(role: .destructive) {
                        if let selected { container.presets.remove(bundleID: selected) }
                        selected = nil
                    } label: { Image(systemName: "minus") }
                    .disabled(selected == nil)
                }
                .padding(8)
            }
            .frame(minWidth: 200)

            Group {
                if let selected, let index = container.presets.presets.firstIndex(where: { $0.bundleID == selected }) {
                    Form {
                        PresetEditor(preset: binding(for: index), showSmartRead: true)
                    }
                    .formStyle(.grouped)
                } else {
                    ContentUnavailableView("No app selected", systemImage: "app.badge", description: Text("Add an app to give it its own voice, speed or privacy rule."))
                }
            }
            .frame(minWidth: 320)
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

    private func add(bundleID: String) {
        let id = bundleID.trimmingCharacters(in: .whitespaces)
        guard !id.isEmpty else { return }
        if !container.presets.presets.contains(where: { $0.bundleID == id }) {
            container.presets.upsert(container.presets.newPreset(bundleID: id))
        }
        selected = id
    }

    private func binding(for index: Int) -> Binding<AppPreset> {
        Binding(
            get: { container.presets.presets[index] },
            set: { container.presets.upsert($0) }
        )
    }
}

// MARK: - Shared preset editor

private struct PresetEditor: View {
    @Environment(AppContainer.self) private var container
    @Binding var preset: AppPreset
    let showSmartRead: Bool

    var body: some View {
        Section("Provider") {
            Picker("Provider", selection: $preset.provider) {
                Text("ElevenLabs").tag(ProviderKind.elevenLabs)
                Text("Apple (offline, never leaves this Mac)").tag(ProviderKind.apple)
            }
            .pickerStyle(.radioGroup)
        }

        if preset.provider == .elevenLabs {
            Section("ElevenLabs voice") {
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
                        selection: $preset.elevenLabsVoiceID
                    )
                case .limited(let reason):
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "info.circle").foregroundStyle(.blue)
                        VStack(alignment: .leading, spacing: 6) {
                            Text(reason).font(.callout)
                            HStack {
                                Link("Open ElevenLabs API keys", destination: URL(string: "https://elevenlabs.io/app/settings/api-keys")!)
                                Button("Check again") { container.catalogs.refreshVoices() }
                            }
                        }
                    }
                    .padding(10)
                    .background(.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                    SearchablePicker(
                        title: "Voice",
                        items: container.catalogs.voices.map { ($0.id, $0.name, $0.description) },
                        selection: $preset.elevenLabsVoiceID
                    )
                    TextField("Or paste a voice id from your ElevenLabs library", text: $preset.elevenLabsVoiceID)
                        .textFieldStyle(.roundedBorder)
                }
            }
        }

        Section("Speed and language") {
            SpeedSlider(speed: $preset.speed)
            TextField("Language override (BCP-47, e.g. de-DE), empty = detect", text: Binding(
                get: { preset.languageOverride ?? "" },
                set: { preset.languageOverride = $0.isEmpty ? nil : $0 }
            ))
        }

        AppleVoiceSection(map: $preset.appleVoiceByLanguage, voices: container.voices.voices(), systemLanguage: container.voices.systemLanguage)

        if showSmartRead {
            Section("Smart read") {
                Toggle("Smart read enabled for this app", isOn: $preset.smartReadEnabled)
                Picker("Mode", selection: $preset.smartReadMode) {
                    Text("Explain simply").tag(SmartReadMode.brief)
                    Text("Cleanup").tag(SmartReadMode.cleanup)
                }
                InstructionsField(text: $preset.smartReadInstructions)
            }
            Section("Dictation") {
                Toggle("Dictate on this Mac only", isOn: $preset.dictationLocalOnly)
                Text(AppleTranscriber.isAvailable
                     ? "Uses Apple's on-device recognizer and skips cloud cleanup when dictating into this app."
                     : "Needs macOS 26: dictation into this app fails instead of using the cloud.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Text("Choosing the Apple provider, turning smart read off and dictating on this Mac only keeps everything from this app on this Mac.")
                    .font(.caption).foregroundStyle(.secondary)
            }
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

// MARK: - Apple voice per language

/// Shows only the languages that matter: the system language, any language with a chosen
/// voice, plus a menu to add another. 49 pickers with 180 voices was too heavy to render.
private struct AppleVoiceSection: View {
    @Binding var map: [String: String]
    let voices: [AppleVoice]
    let systemLanguage: String

    private var byLanguage: [String: [AppleVoice]] { Dictionary(grouping: voices, by: \.language) }

    private var shownLanguages: [String] {
        var langs = Set(map.keys)
        langs.insert(systemLanguage)
        return langs.sorted { a, b in
            if a == systemLanguage { return true }
            if b == systemLanguage { return false }
            return a < b
        }
    }

    var body: some View {
        let grouped = byLanguage
        Section("Apple voice per language") {
            ForEach(shownLanguages, id: \.self) { language in
                Picker(languageName(language), selection: Binding(
                    get: { map[language] ?? "" },
                    set: { id in map[language] = id.isEmpty ? nil : id }
                )) {
                    Text("System default").tag("")
                    ForEach(grouped[language] ?? [], id: \.identifier) { voice in
                        Text(voice.name).tag(voice.identifier)
                    }
                }
            }
            Menu("Add a voice for another language") {
                ForEach(grouped.keys.sorted().filter { !shownLanguages.contains($0) }, id: \.self) { language in
                    Button(languageName(language)) {
                        if let first = grouped[language]?.first { map[language] = first.identifier }
                    }
                }
            }
            .fixedSize()
        }
    }

    private func languageName(_ code: String) -> String {
        let name = Locale.current.localizedString(forIdentifier: code) ?? code
        return "\(name) (\(code))"
    }
}

// MARK: - Per-app instructions

private struct InstructionsField: View {
    @Binding var text: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Extra instructions")
            TextField("e.g. Tell me what they want from me and by when", text: Binding(
                get: { text ?? "" },
                set: { text = $0.isEmpty ? nil : String($0.prefix(SmartReadPrompts.maxInstructionsLength)) }
            ), axis: .vertical)
            .lineLimit(2...4)
            .textFieldStyle(.roundedBorder)
            Text("Added to the smart read prompt for this app. Up to \(SmartReadPrompts.maxInstructionsLength) characters.")
                .font(.caption).foregroundStyle(.secondary)
        }
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
        LabeledContent("Current") {
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
        .frame(minHeight: 140, maxHeight: 220)
    }
}

// MARK: - Keys

private struct KeysTab: View {
    @Environment(AppContainer.self) private var container
    @State private var elevenLabs = ""
    @State private var anthropic = ""
    @State private var groq = ""
    @State private var customEndpoint = ""
    @State private var saved = false
    @State private var error: String?

    var body: some View {
        Form {
            Section("ElevenLabs") {
                SecureField("API key", text: $elevenLabs)
                keyStatus(stored: container.secrets.read(.elevenLabs) != nil, missing: "No key stored. Reads use the Apple voice until one is added.")
            }
            Section("Anthropic") {
                SecureField("API key", text: $anthropic)
                keyStatus(stored: container.secrets.read(.anthropic) != nil, missing: "No key stored. Smart read is unavailable until one is added.")
            }
            Section("Groq") {
                SecureField("API key", text: $groq)
                keyStatus(stored: container.secrets.read(.groq) != nil, missing: "No key stored. Dictation uses Apple's on-device recognizer until one is added.")
                Link("Create a Groq key", destination: URL(string: "https://console.groq.com/keys")!)
                    .font(.caption)
            }
            if container.preferences.transcriber == .custom {
                Section("Custom dictation endpoint (optional)") {
                    SecureField("API key", text: $customEndpoint)
                    Text("Leave empty for local servers that need no key.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section {
                HStack {
                    Button("Save") { save() }
                        .keyboardShortcut(.defaultAction)
                    if saved { Text("Saved. Takes effect on the next read or dictation.").foregroundStyle(.secondary) }
                    if let error { Text(error).foregroundStyle(.red) }
                }
                Text("Keys never leave your Keychain. A plain read sends the selected text to ElevenLabs; a smart read also sends it to Anthropic. Dictation sends your recording to Groq and the transcript to the cleanup provider.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            elevenLabs = container.secrets.read(.elevenLabs) ?? ""
            anthropic = container.secrets.read(.anthropic) ?? ""
            groq = container.secrets.read(.groq) ?? ""
            customEndpoint = container.secrets.read(.customEndpoint) ?? ""
        }
    }

    @ViewBuilder
    private func keyStatus(stored: Bool, missing: String) -> some View {
        if stored {
            Label("A key is stored in your Keychain.", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green).font(.callout)
        } else {
            Label(missing, systemImage: "key.slash")
                .foregroundStyle(.orange).font(.callout)
        }
    }

    private func save() {
        do {
            try container.secrets.write(elevenLabs, for: .elevenLabs)
            try container.secrets.write(anthropic, for: .anthropic)
            try container.secrets.write(groq, for: .groq)
            try container.secrets.write(customEndpoint, for: .customEndpoint)
            saved = true
            error = nil
            container.catalogs.refresh()
        } catch {
            self.error = "Could not save: \(error.localizedDescription)"
        }
    }
}
