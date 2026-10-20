import AppKit
import KeyboardShortcuts
import VibeFlowCore
import SwiftUI

enum SettingsTab: Hashable {
    case general, reading, dictation, clocks, lookAndFeel, keys
}

/// Settings: a dropdown per voice, model and device, the keys and the shortcuts. Nothing else.
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
            ClocksTab()
                .tabItem { Label("Clocks", systemImage: "clock") }
                .tag(SettingsTab.clocks)
            LookAndFeelTab()
                .tabItem { Label("Look & Feel", systemImage: "sparkles") }
                .tag(SettingsTab.lookAndFeel)
            KeysTab()
                .tabItem { Label("Keys", systemImage: "key") }
                .tag(SettingsTab.keys)
        }
        .frame(width: 520, height: 400)
        .background(SettingsWindowConfigurator())
    }
}

// MARK: - General

private struct GeneralTab: View {
    @Environment(AppContainer.self) private var container

    var body: some View {
        @Bindable var prefs = container.preferences
        Form {
            Section {
                KeyboardShortcuts.Recorder("Read selection", name: .read)
                KeyboardShortcuts.Recorder("Smart read selection", name: .smartRead)
                KeyboardShortcuts.Recorder("Read clipboard", name: .readClipboard)
                KeyboardShortcuts.Recorder("Smart read clipboard", name: .smartReadClipboard)
                KeyboardShortcuts.Recorder("Dictate (hold to talk)", name: .record)
                KeyboardShortcuts.Recorder("Dictate (toggle)", name: .recordToggle)
            }
            Section {
                Toggle("Launch at login", isOn: $prefs.launchAtLogin)
                    .onChange(of: prefs.launchAtLogin) { container.applyLaunchAtLogin() }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Reading

private struct ReadingTab: View {
    @Environment(AppContainer.self) private var container
    /// Loaded when the tab appears, never in body (CoreAudio enumeration).
    @State private var speakers: [AudioDevice] = []

    var body: some View {
        @Bindable var prefs = container.preferences
        @Bindable var store = container.presets
        Form {
            Section {
                VoicePicker(voiceID: $store.defaultPreset.elevenLabsVoiceID)
                ModelPicker(title: "Voice model", options: ModelOptions.voice, selection: $prefs.voiceModel)
                SpeedSlider(speed: $store.defaultPreset.speed)
                ModelPicker(title: "Smart read model", options: ModelOptions.smartRead, selection: $prefs.smartReadModel)
                PromptsButton(initial: .brief)
            }
            Section {
                DevicePicker(title: "Speaker", automaticLabel: "System output", devices: speakers, selection: $prefs.speakerUID)
            }
        }
        .formStyle(.grouped)
        .task { speakers = AudioDevices.outputs() }
    }
}

// MARK: - Dictation

private struct DictationTab: View {
    @Environment(AppContainer.self) private var container
    @State private var microphones: [AudioDevice] = []

    var body: some View {
        @Bindable var prefs = container.preferences
        Form {
            Section {
                ModelPicker(title: "Transcription model", options: ModelOptions.transcription, selection: $prefs.transcriptionModel)
                ModelPicker(title: "Cleanup model", options: ModelOptions.cleanup, selection: $prefs.cleanupModel)
                PromptsButton(initial: .dictation)
            }
            Section {
                DevicePicker(title: "Microphone", automaticLabel: "Automatic", devices: microphones, selection: $prefs.microphoneUID)
            }
        }
        .formStyle(.grouped)
        .task { microphones = AudioDevices.inputs() }
    }
}

// MARK: - Look & Feel

private struct LookAndFeelTab: View {
    @Environment(AppContainer.self) private var container

    var body: some View {
        @Bindable var prefs = container.preferences
        Form {
            Section {
                Toggle("Sound when dictation starts and stops", isOn: $prefs.dictationSounds)
                Toggle("Show activity around the notch", isOn: $prefs.notchIndicator)
                Picker("While listening", selection: $prefs.listeningStyle) {
                    ForEach(ListeningStyle.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .disabled(!prefs.notchIndicator)
            }
        }
        .formStyle(.grouped)
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
            Section {
                keyField("ElevenLabs", text: $elevenLabs, key: .elevenLabs)
                keyField("Anthropic", text: $anthropic, key: .anthropic)
                keyField("Groq", text: $groq, key: .groq)
            }
            Section {
                HStack {
                    Button("Save") { save() }
                        .keyboardShortcut(.defaultAction)
                    if saved { Text("Saved").foregroundStyle(.secondary) }
                    if let error { Text(error).foregroundStyle(.red) }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            elevenLabs = container.secrets.read(.elevenLabs) ?? ""
            anthropic = container.secrets.read(.anthropic) ?? ""
            groq = container.secrets.read(.groq) ?? ""
        }
    }

    private func keyField(_ service: String, text: Binding<String>, key: SecretKey) -> some View {
        LabeledContent(service) {
            HStack {
                SecureField(service, text: text, prompt: Text("API key"))
                    .labelsHidden()
                Image(systemName: container.secrets.read(key) != nil ? "checkmark.circle.fill" : "circle.dashed")
                    .foregroundStyle(container.secrets.read(key) != nil ? .green : .secondary)
            }
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

// MARK: - Prompts

/// The prompts VibeFlow sends to the models, read-only for now.
private enum PromptKind: String, CaseIterable, Identifiable {
    case brief = "Smart read: brief"
    case cleanup = "Smart read: cleanup"
    case dictation = "Dictation cleanup"
    var id: Self { self }
}

private struct PromptsButton: View {
    let initial: PromptKind
    @State private var showing = false

    var body: some View {
        LabeledContent("Prompts") {
            Button("Show Prompts…") { showing = true }
        }
        .sheet(isPresented: $showing) { PromptsSheet(kind: initial) }
    }
}

/// Built with the current vocabulary and default preset, so it shows what is actually sent.
private struct PromptsSheet: View {
    @Environment(AppContainer.self) private var container
    @Environment(\.dismiss) private var dismiss
    @State var kind: PromptKind

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Prompt", selection: $kind) {
                ForEach(PromptKind.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    section("System", system)
                    if kind == .brief {
                        Text("The word limit follows the selection: 40 words under 600 characters, 80 under 4,000, 140 above.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    section("User message", user)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
            }
            .background(.background.secondary, in: .rect(cornerRadius: 6))
            HStack {
                Text("Read-only. Editing comes later.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(width: 500, height: 380)
    }

    private func section(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text(text)
                .font(.callout.monospaced())
                .textSelection(.enabled)
        }
    }

    private var system: String {
        let preset = container.presets.defaultPreset
        switch kind {
        case .brief, .cleanup:
            return SmartReadPrompts.system(mode: kind == .brief ? .brief : .cleanup,
                                           language: preset.languageOverride,
                                           instructions: preset.smartReadInstructions)
        case .dictation:
            return SmartReadPrompts.dictationCleanupSystem(vocabulary: container.preferences.vocabularyTerms)
        }
    }

    private var user: String {
        kind == .dictation ? SmartReadPrompts.dictationUser("…transcript…") : SmartReadPrompts.user(text: "…selected text…")
    }
}

// MARK: - Pickers

/// The ElevenLabs voices of the account, or the premade ones when the key cannot list them.
private struct VoicePicker: View {
    @Environment(AppContainer.self) private var container
    @Binding var voiceID: String

    var body: some View {
        let voices = container.catalogs.voices
        Picker("Voice", selection: $voiceID) {
            ForEach(voices) { voice in
                Text(voice.name).tag(voice.id)
            }
            if !voices.contains(where: { $0.id == voiceID }) {
                Text(placeholder).tag(voiceID)
            }
        }
        .disabled(voices.isEmpty)
    }

    private var placeholder: String {
        switch container.catalogs.voicesState {
        case .noKey: return "Add an ElevenLabs key"
        case .loading: return "Loading voices…"
        case .failed: return "Voices unavailable"
        case .loaded, .limited: return "Custom voice"
        }
    }
}

private struct ModelPicker: View {
    let title: String
    let options: [ModelOption]
    @Binding var selection: String

    var body: some View {
        Picker(title, selection: $selection) {
            ForEach(options) { option in
                Text(option.name).tag(option.id)
            }
            if !options.contains(where: { $0.id == selection }) {
                Text(selection).tag(selection)
            }
        }
    }
}

/// nil = the automatic choice. A saved device that is unplugged stays visible.
private struct DevicePicker: View {
    let title: String
    let automaticLabel: String
    let devices: [AudioDevice]
    @Binding var selection: String?

    var body: some View {
        Picker(title, selection: Binding(
            get: { selection ?? "" },
            set: { selection = $0.isEmpty ? nil : $0 }
        )) {
            Text(automaticLabel).tag("")
            ForEach(devices) { device in
                Text(device.name).tag(device.uid)
            }
            if let chosen = selection, !devices.contains(where: { $0.uid == chosen }) {
                Text("Unplugged device").tag(chosen)
            }
        }
    }
}

/// Drags update local state only; the preset is written once, when the drag ends.
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
