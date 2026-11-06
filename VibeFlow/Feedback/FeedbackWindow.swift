import AppKit
import SwiftUI
import VibeFlowCore

/// Send Feedback (docs/designs/feedback.md): its own window, because the menu bar entry has
/// no window to hang a sheet on. Opened from the Settings sidebar and the menu.
enum FeedbackWindow {
    static let id = "feedback"

    static func present(_ openWindow: OpenWindowAction) {
        NSApp.activate()
        openWindow(id: id)
        DispatchQueue.main.async {
            guard let window = NSApp.windows.first(where: { $0.identifier?.rawValue.contains(id) == true }) else { return }
            // Settings floats, so the form must too or it opens behind it.
            window.level = .floating
            window.collectionBehavior.insert([.moveToActiveSpace, .fullScreenAuxiliary])
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
        }
    }
}

/// Kind, note, the exact report under "What gets sent", Copy report and Send. Facts and logs
/// are captured once when the form opens, so dictating the note does not become the last
/// action (D8).
struct FeedbackView: View {
    @Environment(AppContainer.self) private var container
    @Environment(\.dismiss) private var dismiss

    @State private var kind: FeedbackReport.Kind = .bug
    @State private var note = ""
    @State private var facts: FeedbackReport.Facts?
    @State private var logs: FeedbackReport.Logs?
    @State private var sent = false
    @State private var copied = false
    @State private var showsReport = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Kind", selection: $kind) {
                ForEach(FeedbackReport.Kind.allCases, id: \.self) { kind in
                    Text(kind.title).tag(kind)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            TextField(placeholder, text: $note, axis: .vertical)
                .lineLimit(6...12)
                .textFieldStyle(.roundedBorder)

            // Built only while open: scrubbing up to 200 KB of log on every keystroke would lag.
            DisclosureGroup("What gets sent", isExpanded: $showsReport) {
                ScrollView {
                    Text(report?.render() ?? "Collecting logs…")
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 180)
            }

            Text("Maagical also sends crash reports, without your text.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Button(copied ? "Copied" : "Copy report", action: copy)
                    .disabled(!ready)
                Spacer()
                if sent {
                    Text("Thanks. It sends now, or as soon as you are online.")
                        .foregroundStyle(.secondary)
                } else {
                    Button("Send", action: send)
                        .keyboardShortcut(.defaultAction)
                        .disabled(!ready || note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .padding(16)
        .frame(width: 480)
        .task {
            facts = FeedbackSender.facts(container: container)
            logs = await FeedbackSender.readLogs()
        }
    }

    private var placeholder: String {
        switch kind {
        case .bug: return "What happened, and what did you expect?"
        case .idea: return "What should Maagical do?"
        case .loveIt: return "What do you like?"
        }
    }

    private var ready: Bool { facts != nil && logs != nil }

    private var report: FeedbackReport? {
        guard let facts, let logs else { return nil }
        return FeedbackReport(kind: kind, note: note, facts: facts, logs: logs)
    }

    private func copy() {
        guard let report else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(report.render(), forType: .string)
        copied = true
    }

    private func send() {
        guard let report else { return }
        FeedbackSender.send(report)
        sent = true
        Task {
            try? await Task.sleep(for: .seconds(2))
            dismiss()
        }
    }
}
