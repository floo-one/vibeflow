import SwiftUI
import VibeFlowCore

/// The API keys, each with what it unlocks. Google sign-in lives in Meetings.
struct AccountsPane: View {
    @Environment(AppContainer.self) private var container
    @State private var elevenLabs = ""
    @State private var anthropic = ""
    @State private var groq = ""
    @State private var saved = false
    @State private var error: String?

    var body: some View {
        Form {
            Section("API keys") {
                keyField("ElevenLabs", hint: "Natural voices for Read and Smart read", text: $elevenLabs, key: .elevenLabs)
                keyField("Anthropic", hint: "Smart read and follow-up questions", text: $anthropic, key: .anthropic)
                keyField("Groq", hint: "Whisper transcription and cleanup", text: $groq, key: .groq)
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

    private func keyField(_ service: String, hint: String, text: Binding<String>, key: SecretKey) -> some View {
        LabeledContent {
            HStack {
                SecureField(service, text: text, prompt: Text("API key"))
                    .labelsHidden()
                Image(systemName: container.secrets.read(key) != nil ? "checkmark.circle.fill" : "circle.dashed")
                    .foregroundStyle(container.secrets.read(key) != nil ? .green : .secondary)
            }
        } label: {
            Text(service)
            Text(hint)
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
