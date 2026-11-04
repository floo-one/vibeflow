import SwiftUI
import VibeFlowCore

/// Briefs and follow-up answers: their own model and a speed separate from plain reads, since
/// a summary is listened to more slowly than a text you skim.
struct SmartReadPane: View {
    @Environment(AppContainer.self) private var container
    /// Loaded when the pane appears, never in body (CoreAudio enumeration).
    @State private var speakers: [AudioDevice] = []

    var body: some View {
        @Bindable var prefs = container.preferences
        Form {
            PaneHeader(.smartRead, subtitle: "Tap for a spoken brief of the selection. Hold to ask a follow-up.")
            Section("Shortcuts") {
                ShortcutRecorder("Smart read selection", hint: "Tap for a brief of the selected text", name: .smartRead)
                HeldShortcutRow(title: "Ask a follow-up", hint: "Hold the same key, speak, let go to hear the answer", name: .smartRead)
                ShortcutRecorder("Smart read clipboard", name: .smartReadClipboard)
                ShortcutRecorder("Paste last smart read", name: .pasteLastAnswer)
            }
            Section("Thinking") {
                ModelPicker(title: "Model", options: ModelOptions.smartRead, selection: $prefs.smartReadModel)
                PromptsLink()
            }
            Section {
                InheritingVoicePicker(voiceID: $prefs.smartReadVoiceID, readVoiceID: container.presets.defaultPreset.elevenLabsVoiceID)
                InheritingModelPicker(title: "Voice model", options: ModelOptions.voice, selection: $prefs.smartReadVoiceModel, readModel: prefs.voiceModel)
                SpeedSlider(speed: $prefs.smartReadSpeed)
                InheritingDevicePicker(devices: speakers, selection: $prefs.smartReadSpeaker)
            } header: {
                Text("Speaking")
            } footer: {
                Text("Briefs and follow-up answers. A brief is listened to more slowly than a text you skim, so it has its own speed.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task { speakers = AudioDevices.outputs() }
    }
}
