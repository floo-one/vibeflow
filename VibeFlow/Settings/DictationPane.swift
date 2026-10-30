import SwiftUI
import VibeFlowCore

/// Dictation: its shortcuts, the transcription and cleanup models and the microphone.
struct DictationPane: View {
    @Environment(AppContainer.self) private var container
    @State private var microphones: [AudioDevice] = []

    var body: some View {
        @Bindable var prefs = container.preferences
        Form {
            Section("Shortcuts") {
                ShortcutRecorder("Dictate", hint: "Hold to talk, release to paste", name: .record)
                ShortcutRecorder("Hands-free", hint: "Press to start, press again to stop", name: .recordToggle)
                ShortcutRecorder("Paste last dictation", name: .pasteLastDictation)
            }
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
