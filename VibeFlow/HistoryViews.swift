import AppKit
import SwiftUI
import VibeFlowCore

// MARK: - Window

/// The History window. Like Settings it is brought to the front explicitly, since VibeFlow
/// has no Dock icon and macOS never activates it on its own.
@MainActor
enum HistoryWindow {
    static let id = "history"

    static func present(_ openWindow: OpenWindowAction, container: AppContainer, select entry: HistoryEntry.ID? = nil) {
        if let entry { container.historySelection = entry }
        NSApp.activate()
        openWindow(id: id)
        DispatchQueue.main.async {
            guard let window = NSApp.windows.first(where: { $0.identifier?.rawValue.contains(id) == true }) else { return }
            window.collectionBehavior.insert([.moveToActiveSpace, .fullScreenAuxiliary])
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
        }
    }
}

// MARK: - Formatting

enum HistoryFormat {
    /// One line for the menu: "Q: Which option…" or the start of the text read.
    static func menuTitle(_ entry: HistoryEntry) -> String {
        let line = entry.kind == .question ? "Q: \(entry.question ?? "")" : entry.text
        return shorten(line, to: 60)
    }

    static func shorten(_ text: String, to length: Int) -> String {
        let flat = text.split(whereSeparator: \.isNewline).joined(separator: " ")
        return flat.count > length ? String(flat.prefix(length - 1)) + "…" : flat
    }

    static func kindLabel(_ entry: HistoryEntry) -> String {
        switch entry.kind {
        case .question: return "Question"
        case .read: return entry.smart ? "Smart read" : "Read"
        }
    }
}

// MARK: - History view

struct HistoryView: View {
    @Environment(AppContainer.self) private var container

    var body: some View {
        @Bindable var container = container
        let entries = container.history.entries
        NavigationSplitView {
            List(selection: $container.historySelection) {
                ForEach(entries) { entry in
                    HistoryRow(entry: entry, source: container.appName(for: entry.sourceBundleID))
                        .tag(entry.id)
                        .contextMenu {
                            Button("Delete") { delete(entry) }
                        }
                }
            }
            .overlay {
                if entries.isEmpty {
                    ContentUnavailableView("No History Yet", systemImage: "clock.arrow.circlepath",
                                           description: Text("Texts you read aloud and questions you ask show up here."))
                }
            }
            .onDeleteCommand {
                if let id = container.historySelection, let entry = entries.first(where: { $0.id == id }) { delete(entry) }
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 260)
        } detail: {
            if let id = container.historySelection, let entry = entries.first(where: { $0.id == id }) {
                HistoryDetail(entry: entry, source: container.appName(for: entry.sourceBundleID)) { delete(entry) }
            } else {
                Text("Select an entry").foregroundStyle(.secondary)
            }
        }
        .frame(minWidth: 560, minHeight: 360)
    }

    private func delete(_ entry: HistoryEntry) {
        if container.historySelection == entry.id { container.historySelection = nil }
        container.history.delete(entry.id)
    }
}

private struct HistoryRow: View {
    let entry: HistoryEntry
    let source: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(HistoryFormat.shorten(entry.kind == .question ? entry.question ?? "" : entry.text, to: 80))
                .lineLimit(2)
            HStack(spacing: 4) {
                Image(systemName: entry.kind == .question ? "questionmark.bubble" : (entry.smart ? "sparkles" : "speaker.wave.2"))
                Text("\(HistoryFormat.kindLabel(entry)) · \(source) · \(entry.date.formatted(.relative(presentation: .named)))")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

private struct HistoryDetail: View {
    @Environment(AppContainer.self) private var container
    let entry: HistoryEntry
    let source: String
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("\(HistoryFormat.kindLabel(entry)) from \(source), \(entry.date.formatted(date: .abbreviated, time: .shortened))")
                .font(.caption)
                .foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if entry.kind == .question {
                        Labeled("Question", entry.question ?? "")
                        Labeled("Answer", entry.text)
                        if let excerpt = entry.documentExcerpt, !excerpt.isEmpty {
                            Labeled("About", excerpt + (excerpt.count >= HistoryEntry.excerptLength ? "…" : ""))
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Text(entry.text).textSelection(.enabled)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Button(entry.kind == .question ? "Read Answer Aloud" : "Read Aloud", systemImage: "speaker.wave.2") {
                    container.readAgain(entry)
                }
                Button(entry.kind == .question ? "Copy Answer" : "Copy", systemImage: "doc.on.doc") {
                    container.copy(entry.text)
                }
                Spacer()
                Button("Delete", systemImage: "trash", role: .destructive, action: onDelete)
            }
        }
        .padding()
    }
}

private struct Labeled: View {
    let title: String
    let text: String
    init(_ title: String, _ text: String) {
        self.title = title
        self.text = text
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.headline)
            Text(text).textSelection(.enabled)
        }
    }
}

// MARK: - Settings > General

struct HistorySettings: View {
    @Environment(AppContainer.self) private var container
    @State private var confirmClear = false

    var body: some View {
        @Bindable var prefs = container.preferences
        Section {
            Picker("Keep history", selection: $prefs.historyRetention) {
                ForEach(HistoryRetention.choices, id: \.self) { Text($0.title).tag($0) }
            }
            .onChange(of: prefs.historyRetention) { _, retention in container.history.retention = retention }
            LabeledContent("\(container.history.entries.count) entries, stored on this Mac only") {
                Button("Clear History…", role: .destructive) { confirmClear = true }
                    .disabled(container.history.entries.isEmpty)
            }
        } header: {
            Text("History")
        }
        .confirmationDialog("Clear all history?", isPresented: $confirmClear) {
            Button("Clear History", role: .destructive) {
                container.historySelection = nil
                container.history.clear()
            }
        } message: {
            Text("Every saved read and answer is deleted from this Mac. This cannot be undone.")
        }
    }
}
