import AppKit
import SwiftUI
import VibeFlowCore

/// Every prompt VibeFlow sends, as a tree by feature: shared parts, each feature's own parts,
/// per-app instructions, and the full prompt each feature sends. Untouched parts follow the
/// built-in defaults; the safety rules around them stay fixed.
struct PromptsPane: View {
    @Environment(AppContainer.self) private var container
    @State private var path: [PromptRoute] = []
    /// Loaded when the pane appears, never in body (system enumeration).
    @State private var runningApps: [RunningApp] = []

    var body: some View {
        NavigationStack(path: $path) {
            Form {
                PaneHeader(.prompts, subtitle: "What VibeFlow tells the models, by feature. Edit a part to fine-tune it; parts you never touch follow the built-in defaults.")
                ForEach(PromptLibrary.Group.allCases) { group in
                    Section(group.title) {
                        ForEach(group.parts) { part in
                            NavigationLink(value: PromptRoute.part(part)) { PromptPartRow(part: part) }
                        }
                    }
                }
                perAppSection
                Section {
                    ForEach(PromptLibrary.Feature.allCases) { feature in
                        NavigationLink(feature.title, value: PromptRoute.feature(feature))
                    }
                } header: {
                    Text("Full prompts")
                } footer: {
                    Text("Each feature's prompt as sent, with the fixed safety rules, your edits and the per-app instructions.")
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .navigationDestination(for: PromptRoute.self) { route in
                switch route {
                case .part(let part): PromptPartView(part: part)
                case .feature(let feature): FullPromptView(feature: feature)
                case .app(let bundleID): AppInstructionsView(bundleID: bundleID)
                }
            }
        }
        .task { runningApps = RunningApp.current() }
    }

    private var perAppSection: some View {
        let apps = container.presets.presets.filter { $0.smartReadInstructions != nil }
        return Section {
            ForEach(apps, id: \.bundleID) { preset in
                if let bundleID = preset.bundleID {
                    NavigationLink(value: PromptRoute.app(bundleID)) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(container.appName(for: bundleID))
                            Text(preset.smartReadInstructions.flatMap { $0.isEmpty ? nil : $0 } ?? "No instructions yet")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
            }
            Menu("Add App") {
                ForEach(runningApps.filter { app in !apps.contains { $0.bundleID == app.bundleID } }) { app in
                    Button(app.name) { add(app.bundleID) }
                }
                Divider()
                Button("Choose Application…", action: chooseApp)
            }
            .fixedSize()
        } header: {
            Text("Per app")
        } footer: {
            Text("Added to the brief, cleanup and follow-up answers for text selected in that app. Clipboard reads use none.")
                .foregroundStyle(.secondary)
        }
    }

    private func add(_ bundleID: String) {
        var preset = container.presets.preset(for: bundleID)
        if preset.bundleID == nil { preset = container.presets.newPreset(bundleID: bundleID) }
        if preset.smartReadInstructions == nil { preset.smartReadInstructions = "" }
        container.presets.upsert(preset)
        path.append(.app(bundleID))
    }

    private func chooseApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(filePath: "/Applications")
        guard panel.runModal() == .OK, let url = panel.url, let bundleID = Bundle(url: url)?.bundleIdentifier else { return }
        add(bundleID)
    }
}

enum PromptRoute: Hashable {
    case part(PromptLibrary.Part)
    case feature(PromptLibrary.Feature)
    case app(String)
}

/// An app that is open now, offered in "Add App".
struct RunningApp: Identifiable {
    let bundleID: String
    let name: String
    var id: String { bundleID }

    static func current() -> [RunningApp] {
        let own = Bundle.main.bundleIdentifier
        let apps = NSWorkspace.shared.runningApplications.compactMap { app -> RunningApp? in
            guard app.activationPolicy == .regular, let id = app.bundleIdentifier, id != own else { return nil }
            return RunningApp(bundleID: id, name: app.localizedName ?? id)
        }
        return apps.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

/// A part in the tree: its title, which features use it, and whether it is edited.
private struct PromptPartRow: View {
    @Environment(AppContainer.self) private var container
    let part: PromptLibrary.Part

    var body: some View {
        let prompts = container.preferences.prompts
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(part.title)
                Text(usedByText(prompts.usedBy(part)))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if prompts[part] != nil || (part == .customRules && prompts.customRulesFeatures != PromptLibrary.defaultCustomRulesFeatures) {
                EditedBadge()
            }
        }
    }
}

func usedByText(_ features: [PromptLibrary.Feature]) -> String {
    features.isEmpty ? "Not used" : "Used by " + features.map(\.title).formatted(.list(type: .and))
}

private struct EditedBadge: View {
    var body: some View {
        Text("Edited")
            .font(.caption)
            .foregroundStyle(FeatureColor.smartRead)
    }
}

/// One editable part: what it does, where it goes, the text, and the way back to the default.
struct PromptPartView: View {
    @Environment(AppContainer.self) private var container
    let part: PromptLibrary.Part

    var body: some View {
        @Bindable var prefs = container.preferences
        let edited = prefs.prompts[part] != nil
        Form {
            Section {
                Text(part.hint).foregroundStyle(.secondary)
                if part == .customRules {
                    ForEach(PromptLibrary.Feature.allCases) { feature in
                        Toggle(feature.title, isOn: Binding(
                            get: { prefs.prompts.customRulesFeatures.contains(feature) },
                            set: { on in
                                if on { prefs.prompts.customRulesFeatures.insert(feature) } else { prefs.prompts.customRulesFeatures.remove(feature) }
                            }
                        ))
                    }
                } else {
                    LabeledContent("Used by", value: prefs.prompts.usedBy(part).map(\.title).formatted(.list(type: .and)))
                }
            }
            Section {
                TextEditor(text: Binding(
                    get: { prefs.prompts.editableText(part) },
                    set: { prefs.prompts[part] = $0 }
                ))
                .font(.callout.monospaced())
                .frame(minHeight: 220)
                .scrollContentBackground(.hidden)
            } header: {
                HStack {
                    Text("Text")
                    if edited { EditedBadge() }
                }
            } footer: {
                HStack {
                    Text(part == .customRules ? "Changes apply from the next use." : "Changes apply from the next use. Clearing the text brings the default back.")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Reset to Default") { prefs.prompts[part] = nil }
                        .disabled(!edited)
                }
            }
            Section("See it in context") {
                ForEach(prefs.prompts.usedBy(part)) { feature in
                    NavigationLink("Full \(feature.title) prompt", value: PromptRoute.feature(feature))
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(part.title)
    }
}

/// A feature's whole prompt as it is sent now, read-only.
struct FullPromptView: View {
    @Environment(AppContainer.self) private var container
    let feature: PromptLibrary.Feature
    @State private var asAIReply = false

    var body: some View {
        Form {
            if feature == .brief {
                Picker("Text from", selection: $asAIReply) {
                    Text("Any app").tag(false)
                    Text("An AI app, e.g. Claude").tag(true)
                }
            }
            Section("System prompt") { promptText(system) }
            Section("User message") { promptText(user) }
        }
        .formStyle(.grouped)
        .navigationTitle(feature.title)
    }

    private func promptText(_ text: String) -> some View {
        Text(text)
            .font(.callout.monospaced())
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Built with the default preset, so per-app instructions show only on app prompts.
    private var system: String {
        let preset = container.presets.defaultPreset
        let prompts = container.preferences.prompts
        switch feature {
        case .brief:
            return SmartReadPrompts.system(mode: .brief, language: preset.languageOverride, instructions: preset.smartReadInstructions,
                                           assistant: asAIReply ? "Claude" : nil, prompts: prompts)
        case .cleanup:
            return SmartReadPrompts.system(mode: .cleanup, language: preset.languageOverride, instructions: preset.smartReadInstructions, prompts: prompts)
        case .followUp:
            return SmartReadPrompts.askSystem(language: preset.languageOverride, instructions: preset.smartReadInstructions, prompts: prompts)
        case .dictation:
            return SmartReadPrompts.dictationCleanupSystem(vocabulary: container.preferences.vocabularyTerms, prompts: prompts)
        case .callSummary:
            return SmartReadPrompts.callSummarySystem(prompts: prompts)
        }
    }

    private var user: String {
        switch feature {
        case .brief, .cleanup: SmartReadPrompts.user(text: "…selected text…")
        case .followUp: SmartReadPrompts.user(text: "…selected text…") + "\n\n…your question…"
        case .dictation: SmartReadPrompts.dictationUser("…transcript…")
        case .callSummary: "Speakers:\n{S1} = …\n\n\(SmartReadPrompts.openDelimiter)\n#1 {S1} [00:00]: …\n\(SmartReadPrompts.closeDelimiter)"
        }
    }
}

/// Instructions for text from one app, added to its brief, cleanup and follow-up answers.
struct AppInstructionsView: View {
    @Environment(AppContainer.self) private var container
    @Environment(\.dismiss) private var dismiss
    let bundleID: String

    var body: some View {
        let preset = container.presets.preset(for: bundleID)
        let text = preset.smartReadInstructions ?? ""
        Form {
            Section {
                TextEditor(text: Binding(
                    get: { text },
                    set: { newValue in
                        var updated = container.presets.preset(for: bundleID)
                        guard updated.bundleID == bundleID else { return }
                        updated.smartReadInstructions = String(newValue.prefix(SmartReadPrompts.maxInstructionsLength))
                        container.presets.upsert(updated)
                    }
                ))
                .font(.callout.monospaced())
                .frame(minHeight: 160)
                .scrollContentBackground(.hidden)
            } header: {
                Text("Instructions")
            } footer: {
                HStack {
                    Text("For example \"Focus on deadlines and amounts.\" \(text.count) of \(SmartReadPrompts.maxInstructionsLength) characters.")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Remove", role: .destructive) {
                        var updated = container.presets.preset(for: bundleID)
                        updated.smartReadInstructions = nil
                        container.presets.upsert(updated)
                        dismiss()
                    }
                }
            }
            Section {
                LabeledContent("Used by", value: usedByText([.brief, .cleanup, .followUp]).replacingOccurrences(of: "Used by ", with: ""))
            }
        }
        .formStyle(.grouped)
        .navigationTitle(container.appName(for: bundleID))
    }
}
