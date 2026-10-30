import SwiftUI
import VibeFlowCore

/// Plain reads: their shortcuts, the ElevenLabs voice, model, speed and speaker.
struct ReadPane: View {
    @Environment(AppContainer.self) private var container
    /// Loaded when the pane appears, never in body (CoreAudio enumeration).
    @State private var speakers: [AudioDevice] = []

    var body: some View {
        @Bindable var prefs = container.preferences
        @Bindable var store = container.presets
        Form {
            Section("Shortcuts") {
                ShortcutRecorder("Read selection", name: .read)
                ShortcutRecorder("Read clipboard", name: .readClipboard)
            }
            Section {
                VoicePicker(voiceID: $store.defaultPreset.elevenLabsVoiceID)
                ModelPicker(title: "Voice model", options: ModelOptions.voice, selection: $prefs.voiceModel)
                SpeedSlider(speed: $store.defaultPreset.speed)
            }
            Section {
                DevicePicker(title: "Speaker", automaticLabel: "System output", devices: speakers, selection: $prefs.speakerUID)
            }
        }
        .formStyle(.grouped)
        .task { speakers = AudioDevices.outputs() }
    }
}
