import KeyboardShortcuts
import SwiftUI
import MaagicalCore

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

/// Opens the Context window, where every prompt and what Maagical knows about you are edited.
struct PromptsLink: View {
    @Environment(AppContainer.self) private var container
    @Environment(\.openWindow) private var openWindow
    let page: ContextPage

    var body: some View {
        LabeledContent("Prompts and context") {
            Button("Open Context…") { ContextWindow.present(openWindow, container: container, page: page) }
                .buttonStyle(.link)
        }
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

/// A voice that can follow Read's: nil = the Read voice.
struct InheritingVoicePicker: View {
    @Environment(AppContainer.self) private var container
    @Binding var voiceID: String?
    let readVoiceID: String

    var body: some View {
        let voices = container.catalogs.voices
        let readName = voices.first { $0.id == readVoiceID }?.name
        Picker("Voice", selection: Binding(get: { voiceID ?? "" }, set: { voiceID = $0.isEmpty ? nil : $0 })) {
            Text(readName.map { "Same as Read (\($0))" } ?? "Same as Read").tag("")
            Divider()
            ForEach(voices) { voice in
                Text(voice.name).tag(voice.id)
            }
            if let chosen = voiceID, !voices.contains(where: { $0.id == chosen }) {
                Text("Custom voice").tag(chosen)
            }
        }
    }
}

/// A model that can follow Read's: nil = the Read model.
struct InheritingModelPicker: View {
    let title: String
    let options: [ModelOption]
    @Binding var selection: String?
    let readModel: String

    var body: some View {
        let readName = options.first { $0.id == readModel }?.name
        Picker(title, selection: Binding(get: { selection ?? "" }, set: { selection = $0.isEmpty ? nil : $0 })) {
            Text(readName.map { "Same as Read (\($0))" } ?? "Same as Read").tag("")
            Divider()
            ForEach(options) { option in
                Text(option.name).tag(option.id)
            }
            if let chosen = selection, !options.contains(where: { $0.id == chosen }) {
                Text(chosen).tag(chosen)
            }
        }
    }
}

/// A speaker that can follow Read's: nil = the Read speaker, "" = system output, else a device.
struct InheritingDevicePicker: View {
    let devices: [AudioDevice]
    @Binding var selection: String?

    private static let sameAsRead = "same-as-read"

    var body: some View {
        Picker("Speaker", selection: Binding(
            get: { selection ?? Self.sameAsRead },
            set: { selection = $0 == Self.sameAsRead ? nil : $0 }
        )) {
            Text("Same as Read").tag(Self.sameAsRead)
            Divider()
            Text("System output").tag("")
            ForEach(devices) { device in
                Text(device.name).tag(device.uid)
            }
            if let chosen = selection, !chosen.isEmpty, !devices.contains(where: { $0.uid == chosen }) {
                Text("Unplugged device").tag(chosen)
            }
        }
    }
}
