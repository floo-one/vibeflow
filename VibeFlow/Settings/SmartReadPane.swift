import SwiftUI
import VibeFlowCore

/// Briefs and follow-up answers: their own model and a speed separate from plain reads, since
/// a summary is listened to more slowly than a text you skim.
struct SmartReadPane: View {
    @Environment(AppContainer.self) private var container

    var body: some View {
        @Bindable var prefs = container.preferences
        Form {
            Section("Shortcuts") {
                ShortcutRecorder("Smart read selection", hint: "Tap for a brief of the selected text", name: .smartRead)
                HeldShortcutRow(title: "Ask a follow-up", hint: "Hold the same key, speak, let go to hear the answer", name: .smartRead)
                ShortcutRecorder("Smart read clipboard", name: .smartReadClipboard)
                ShortcutRecorder("Paste last smart read", name: .pasteLastAnswer)
            }
            Section {
                ModelPicker(title: "Model", options: ModelOptions.smartRead, selection: $prefs.smartReadModel)
                SpeedSlider(speed: $prefs.smartReadSpeed)
                PromptsButton(initial: .brief)
            } footer: {
                Text("Speaks with the voice set in Read. The menu can copy the last answer.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
