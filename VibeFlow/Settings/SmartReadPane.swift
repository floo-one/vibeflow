import SwiftUI
import VibeFlowCore

/// Briefs and follow-up answers: their own model and a speed separate from plain reads, since
/// a summary is listened to more slowly than a text you skim.
struct SmartReadPane: View {
    @Environment(AppContainer.self) private var container

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
                PromptsButton(initial: .brief)
            }
            Section {
                LabeledContent("Voice") {
                    Button("Same as Read") { container.settingsTab = .read }
                        .buttonStyle(.link)
                }
                SpeedSlider(speed: $prefs.smartReadSpeed)
            } header: {
                Text("Speaking")
            } footer: {
                Text("A brief is listened to more slowly than a text you skim, so it has its own speed.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
