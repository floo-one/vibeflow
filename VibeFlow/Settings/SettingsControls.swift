import KeyboardShortcuts
import SwiftUI
import VibeFlowCore

// MARK: - Shortcuts

/// A shortcut recorder with an optional caption under its title saying how the key behaves.
struct ShortcutRecorder: View {
    let title: String
    var hint: String?
    let name: KeyboardShortcuts.Name

    init(_ title: String, hint: String? = nil, name: KeyboardShortcuts.Name) {
        self.title = title
        self.hint = hint
        self.name = name
    }

    var body: some View {
        KeyboardShortcuts.Recorder(for: name) {
            Text(title)
            if let hint { Text(hint) }
        }
    }
}

/// A gesture that has no shortcut of its own because it holds another one (hold the smart
/// read key to ask). Shows that key, kept current when it is re-recorded.
struct HeldShortcutRow: View {
    let title: String
    let hint: String
    let name: KeyboardShortcuts.Name
    @State private var keys = ""

    /// KeyboardShortcuts posts this after every recorder change; its own name is internal.
    private static let didChange = Notification.Name("KeyboardShortcuts_shortcutByNameDidChange")

    var body: some View {
        LabeledContent {
            Text(keys.isEmpty ? "Not set" : "Hold \(keys)")
                .monospacedDigit()
                .foregroundStyle(.secondary)
        } label: {
            Text(title)
            Text(hint)
        }
        .onAppear(perform: refresh)
        .onReceive(NotificationCenter.default.publisher(for: Self.didChange)) { _ in refresh() }
    }

    private func refresh() {
        keys = KeyboardShortcuts.getShortcut(for: name)?.description ?? ""
    }
}

// MARK: - Prompts

/// The prompts VibeFlow sends to the models, read-only for now.
enum PromptKind: String, CaseIterable, Identifiable {
    case brief = "Smart read: brief"
    case cleanup = "Smart read: cleanup"
    case dictation = "Dictation cleanup"
    var id: Self { self }
}

struct PromptsButton: View {
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
struct PromptsSheet: View {
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
                        section("Added before your preferences in ChatGPT, Codex, Claude and Gemini", SmartReadPrompts.aiReplyRule)
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
struct VoicePicker: View {
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

struct ModelPicker: View {
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
struct DevicePicker: View {
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
struct SpeedSlider: View {
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
