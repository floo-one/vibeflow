import AppKit
import SwiftUI
import MaagicalCore

/// Context and prompts in their own window: what Maagical knows about you, and every prompt it
/// sends, shown per feature as the blocks it is made of. Opened from the menu and Settings.
enum ContextWindow {
    static let id = "context"

    @MainActor static func present(_ openWindow: OpenWindowAction, container: AppContainer, page: ContextPage? = nil) {
        if let page { container.contextPage = page }
        NSApp.activate()
        openWindow(id: id)
        DispatchQueue.main.async {
            guard let window = NSApp.windows.first(where: { $0.identifier?.rawValue.contains(id) == true }) else { return }
            // Settings floats, so this window must too or it opens behind it.
            window.level = .floating
            window.collectionBehavior.insert([.moveToActiveSpace, .fullScreenAuxiliary])
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
        }
    }
}

enum ContextPage: Hashable {
    case aboutYou
    case terms
    case feature(PromptLibrary.Feature)
    case app(String)
}

struct ContextView: View {
    @Environment(AppContainer.self) private var container
    /// Loaded when the window appears, never in body (system enumeration).
    @State private var runningApps: [RunningApp] = []

    var body: some View {
        @Bindable var container = container
        NavigationSplitView {
            List(selection: Binding(get: { container.contextPage }, set: { if let page = $0 { container.contextPage = page } })) {
                Section("Context") {
                    Label("About you", systemImage: "person").tag(ContextPage.aboutYou)
                    Label("Terms and people", systemImage: "character.book.closed").tag(ContextPage.terms)
                }
                Section("Features") {
                    ForEach(PromptLibrary.Feature.allCases) { feature in
                        Label(feature.title, systemImage: feature.symbol).tag(ContextPage.feature(feature))
                    }
                }
                Section("Apps") {
                    ForEach(appsWithInstructions, id: \.self) { bundleID in
                        Label(container.appName(for: bundleID), systemImage: "app").tag(ContextPage.app(bundleID))
                    }
                    Menu {
                        ForEach(runningApps.filter { !appsWithInstructions.contains($0.bundleID) }) { app in
                            Button(app.name) { add(app.bundleID) }
                        }
                        Divider()
                        Button("Choose Application…", action: chooseApp)
                    } label: {
                        Label("Add app", systemImage: "plus")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .foregroundStyle(.secondary)
                }
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 260)
        } detail: {
            switch container.contextPage {
            case .aboutYou: AboutYouPage()
            case .terms: TermsPage()
            case .feature(let feature): FeaturePromptPage(feature: feature, apps: appsWithInstructions)
            case .app(let bundleID): AppRulesPage(bundleID: bundleID)
            }
        }
        .frame(minWidth: 760, minHeight: 520)
        .task { runningApps = RunningApp.current() }
    }

    private var appsWithInstructions: [String] {
        container.presets.presets.filter { $0.smartReadInstructions != nil }.compactMap(\.bundleID)
    }

    private func add(_ bundleID: String) {
        var preset = container.presets.preset(for: bundleID)
        if preset.bundleID == nil { preset = container.presets.newPreset(bundleID: bundleID) }
        if preset.smartReadInstructions == nil { preset.smartReadInstructions = "" }
        container.presets.upsert(preset)
        container.contextPage = .app(bundleID)
    }

    private func chooseApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(filePath: "/Applications")
        guard panel.runModal() == .OK, let url = panel.url, let bundleID = Bundle(url: url)?.bundleIdentifier else { return }
        add(bundleID)
    }
}

extension PromptLibrary.Feature {
    var symbol: String {
        switch self {
        case .brief: "sparkles"
        case .cleanup: "text.alignleft"
        case .followUp: "questionmark.bubble"
        case .dictation: "mic"
        case .callSummary: "doc.text"
        }
    }
}

/// An app that is open now, offered in "Add app".
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

// MARK: - Pages

/// Title, explanation and which features a page feeds.
private struct PageHeader: View {
    let title: String
    let subtitle: String
    var usedBy: [PromptLibrary.Feature] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.title2.weight(.semibold))
            Text(subtitle).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if !usedBy.isEmpty {
                Text("Sent with " + usedBy.map(\.title).formatted(.list(type: .and)))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A plain text box that saves as you type.
private struct ContextEditor: View {
    @Binding var text: String
    var minHeight: CGFloat = 160

    var body: some View {
        TextEditor(text: $text)
            .font(.body.monospaced())
            .scrollContentBackground(.hidden)
            .padding(6)
            .frame(minHeight: minHeight)
            .background(.background, in: .rect(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
    }
}

private struct AboutYouPage: View {
    @Environment(AppContainer.self) private var container

    var body: some View {
        @Bindable var prefs = container.preferences
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                PageHeader(title: "About you",
                           subtitle: "A few lines about you, so a brief can say \"your email to Charlotte\" and answers fit your work. For example: \"I'm Florian, I run Global Law Experts, a lawyer network. I write in German and English.\"",
                           usedBy: PromptLibrary.Part.aboutYou.defaultUsedBy)
                ContextEditor(text: Binding(get: { prefs.prompts.editableText(.aboutYou) }, set: { prefs.prompts[.aboutYou] = $0 }))
                Text("Sent to Claude with every brief and follow-up answer. Leave it empty to send nothing.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(20)
        }
    }
}

private struct TermsPage: View {
    @Environment(AppContainer.self) private var container

    var body: some View {
        @Bindable var prefs = container.preferences
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                PageHeader(title: "Terms and people",
                           subtitle: "Names, companies, products and terms, one per line or comma separated. Dictation spells them like this, and briefs and answers use the same spelling.",
                           usedBy: SmartReadPrompts.termsFeatures)
                ContextEditor(text: $prefs.vocabulary, minHeight: 220)
                Text("\(prefs.vocabularyTerms.count) terms. The same list as Dictation's vocabulary; the first 100 are sent.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(20)
        }
    }
}

/// Instructions for text selected in one app.
private struct AppRulesPage: View {
    @Environment(AppContainer.self) private var container
    let bundleID: String

    var body: some View {
        let text = container.presets.preset(for: bundleID).smartReadInstructions ?? ""
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                PageHeader(title: container.appName(for: bundleID),
                           subtitle: "How to treat text you select in this app, for example \"Focus on deadlines and amounts.\" Clipboard reads use none.",
                           usedBy: [.brief, .cleanup, .followUp])
                ContextEditor(text: Binding(get: { text }, set: { update($0) }))
                HStack {
                    Text("\(text.count) of \(SmartReadPrompts.maxInstructionsLength) characters")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("See the brief for this app") { container.contextPage = .feature(.brief) }
                    Button("Remove app", role: .destructive) {
                        update(nil)
                        container.contextPage = .feature(.brief)
                    }
                }
            }
            .padding(20)
        }
    }

    private func update(_ instructions: String?) {
        var preset = container.presets.preset(for: bundleID)
        guard preset.bundleID == bundleID else { return }
        preset.smartReadInstructions = instructions.map { String($0.prefix(SmartReadPrompts.maxInstructionsLength)) }
        container.presets.upsert(preset)
    }
}

// MARK: - Feature prompt as blocks

/// Which text a feature's prompt is shown for.
enum PromptPreview: Hashable {
    case anyApp
    case aiApp
    case app(String)
}

/// A feature's prompt in the order it is sent, one block per source, each editable in place.
private struct FeaturePromptPage: View {
    @Environment(AppContainer.self) private var container
    let feature: PromptLibrary.Feature
    let apps: [String]
    @State private var preview = PromptPreview.anyApp
    @State private var expanded: Set<Int> = []

    var body: some View {
        let blocks = self.blocks
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top) {
                    PageHeader(title: feature.title, subtitle: subtitle)
                    if hasPreviewChoice {
                        Picker("Preview for", selection: $preview) {
                            Text("Any app").tag(PromptPreview.anyApp)
                            if feature == .brief { Text("An AI app (Claude)").tag(PromptPreview.aiApp) }
                            ForEach(apps, id: \.self) { Text(container.appName(for: $0)).tag(PromptPreview.app($0)) }
                        }
                        .fixedSize()
                    }
                }
                .padding(.bottom, 6)
                ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                    card(block, index: index, placeholder: false)
                }
                let unsent = unsentBlocks(blocks)
                if !unsent.isEmpty {
                    Text("Not sent yet").font(.caption).foregroundStyle(.secondary).padding(.top, 8)
                    ForEach(Array(unsent.enumerated()), id: \.offset) { index, block in
                        card(block, index: 1_000 + index, placeholder: true)
                    }
                }
                Legend().padding(.top, 6)
            }
            .padding(20)
        }
        .onChange(of: feature) { expanded = []; preview = .anyApp }
        .onChange(of: preview) { expanded = [] }
    }

    private var subtitle: String {
        switch feature {
        case .brief: "Tap Smart Read: a short spoken brief of the selection."
        case .cleanup: "Smart Read in cleanup mode: the text rewritten to read well aloud."
        case .followUp: "Hold Smart Read and ask: the spoken answer."
        case .dictation: "Tidies what you dictated before it is pasted."
        case .callSummary: "Summary and action items for a transcribed call."
        }
    }

    private var hasPreviewChoice: Bool {
        switch feature {
        case .brief: true
        case .cleanup, .followUp: !apps.isEmpty
        case .dictation, .callSummary: false
        }
    }

    private var blocks: [PromptBlock] {
        let prefs = container.preferences
        let preset: AppPreset = if case .app(let id) = preview { container.presets.preset(for: id) } else { container.presets.defaultPreset }
        let instructions = preset.smartReadInstructions
        switch feature {
        case .brief:
            return SmartReadPrompts.systemBlocks(mode: .brief, language: preset.languageOverride, instructions: instructions,
                                                 assistant: preview == .aiApp ? "Claude" : nil, prompts: prefs.prompts, terms: prefs.vocabularyTerms)
        case .cleanup:
            return SmartReadPrompts.systemBlocks(mode: .cleanup, language: preset.languageOverride, instructions: instructions,
                                                 prompts: prefs.prompts, terms: prefs.vocabularyTerms)
        case .followUp:
            return SmartReadPrompts.askBlocks(language: preset.languageOverride, instructions: instructions, prompts: prefs.prompts, terms: prefs.vocabularyTerms)
        case .dictation:
            return SmartReadPrompts.dictationBlocks(vocabulary: prefs.vocabularyTerms, prompts: prefs.prompts)
        case .callSummary:
            return SmartReadPrompts.callSummaryBlocks(prompts: prefs.prompts)
        }
    }

    private func card(_ block: PromptBlock, index: Int, placeholder: Bool) -> some View {
        PromptBlockCard(block: block, feature: feature, preview: preview, isPlaceholder: placeholder, isExpanded: Binding(
            get: { expanded.contains(index) },
            set: { if $0 { expanded.insert(index) } else { expanded.remove(index) } }
        ))
    }

    /// Context and rules this feature could use but does not send now, so they can be found and filled.
    private func unsentBlocks(_ blocks: [PromptBlock]) -> [PromptBlock] {
        let sources = Set(blocks.map(\.source))
        var unsent: [PromptBlock] = []
        if PromptLibrary.Part.aboutYou.defaultUsedBy.contains(feature), !sources.contains(.part(.aboutYou)) {
            unsent.append(PromptBlock(.part(.aboutYou), ""))
        }
        if SmartReadPrompts.termsFeatures.contains(feature), !sources.contains(.terms) {
            unsent.append(PromptBlock(.terms, ""))
        }
        if !sources.contains(.part(.customRules)) {
            unsent.append(PromptBlock(.part(.customRules), ""))
        }
        return unsent
    }
}

/// One block: where it comes from, who else uses it, and its text, editable when it is yours.
private struct PromptBlockCard: View {
    @Environment(AppContainer.self) private var container
    let block: PromptBlock
    let feature: PromptLibrary.Feature
    let preview: PromptPreview
    var isPlaceholder = false
    @Binding var isExpanded: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.easeOut(duration: 0.15)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: icon).frame(width: 16).foregroundStyle(kind.tint)
                    Text(title).fontWeight(.medium)
                    Text(kind.label(otherFeatures)).font(.caption).foregroundStyle(kind.tint)
                    if isEdited { Text("Edited").font(.caption).foregroundStyle(.orange) }
                    Spacer()
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down").font(.caption).foregroundStyle(.secondary)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            if isExpanded {
                editor
            } else if isPlaceholder {
                Text(placeholderText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text(block.text)
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(10)
        .opacity(isPlaceholder && !isExpanded ? 0.7 : 1)
        .background(kind.tint.opacity(kind == .fixed || isPlaceholder ? 0.04 : 0.08), in: .rect(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(kind.tint.opacity(kind == .feature ? 0.5 : 0.25)))
    }

    @ViewBuilder
    private var editor: some View {
        @Bindable var prefs = container.preferences
        switch block.source {
        case .fixed:
            Text(block.text)
                .font(.callout.monospaced())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("Fixed: keeps your text from being read as instructions, and the reply in the right language and format.")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .part(let part):
            if part == .customRules {
                HStack {
                    Text("Add to:").font(.caption).foregroundStyle(.secondary)
                    ForEach(PromptLibrary.Feature.allCases) { f in
                        Toggle(f.title, isOn: Binding(
                            get: { prefs.prompts.customRulesFeatures.contains(f) },
                            set: { if $0 { prefs.prompts.customRulesFeatures.insert(f) } else { prefs.prompts.customRulesFeatures.remove(f) } }
                        ))
                        .toggleStyle(.checkbox)
                        .font(.caption)
                    }
                }
            }
            ContextEditor(text: Binding(get: { prefs.prompts.editableText(part) }, set: { prefs.prompts[part] = $0 }))
            HStack {
                Text(part.hint).font(.caption).foregroundStyle(.secondary)
                Spacer()
                if part.defaultText.isEmpty == false {
                    Button("Reset to Default") { prefs.prompts[part] = nil }.disabled(prefs.prompts[part] == nil)
                }
            }
        case .terms:
            if !block.text.isEmpty {
                Text(block.text).font(.callout.monospaced()).frame(maxWidth: .infinity, alignment: .leading)
            }
            Button("Edit terms and people") { container.contextPage = .terms }
        case .app:
            Text(block.text).font(.callout.monospaced()).frame(maxWidth: .infinity, alignment: .leading)
            if case .app(let id) = preview {
                Button("Edit \(container.appName(for: id)) rules") { container.contextPage = .app(id) }
            }
        }
    }

    private enum Kind: Equatable {
        case fixed, shared, context, feature, app

        var tint: Color {
            switch self {
            case .fixed: .secondary
            case .shared, .context: FeatureColor.smartRead
            case .feature: .primary
            case .app: FeatureColor.tools
            }
        }

        func label(_ others: [PromptLibrary.Feature]) -> String {
            switch self {
            case .fixed: "Fixed"
            case .shared: others.isEmpty ? "Shared" : "Shared · also " + others.map(\.title).formatted(.list(type: .and))
            case .context: others.isEmpty ? "Context" : "Context · also " + others.map(\.title).formatted(.list(type: .and))
            case .feature: "This feature only"
            case .app: "This app only"
            }
        }
    }

    private var kind: Kind {
        switch block.source {
        case .fixed: .fixed
        case .terms: .context
        case .app: .app
        case .part(let part):
            switch part.group {
            case .context: .context
            case .shared: .shared
            default: part.defaultUsedBy.count > 1 ? .shared : .feature
            }
        }
    }

    private var otherFeatures: [PromptLibrary.Feature] {
        let users: [PromptLibrary.Feature] = switch block.source {
        case .part(let part): container.preferences.prompts.usedBy(part)
        case .terms: SmartReadPrompts.termsFeatures
        default: []
        }
        return users.filter { $0 != feature }
    }

    private var title: String {
        switch block.source {
        case .fixed(let name): name
        case .part(let part): part.title
        case .terms: "Terms and people"
        case .app: if case .app(let id) = preview { "\(container.appName(for: id)) rules" } else { "App rules" }
        }
    }

    private var icon: String {
        switch block.source {
        case .fixed: "lock"
        case .part(.aboutYou): "person"
        case .part(.customRules): "list.bullet"
        case .part: kind == .shared ? "square.on.square" : "pencil"
        case .terms: "character.book.closed"
        case .app: "app"
        }
    }

    private var placeholderText: String {
        switch block.source {
        case .part(.customRules):
            container.preferences.prompts.text(.customRules).isEmpty
                ? "Empty. Open to write rules for this and other features."
                : "Written, but not ticked for \(feature.title). Open to add it."
        case .part(.aboutYou): "Empty. Open to say who you are."
        case .terms: "No terms yet."
        default: ""
        }
    }

    private var isEdited: Bool {
        guard case .part(let part) = block.source, !part.defaultText.isEmpty else { return false }
        return container.preferences.prompts[part] != nil
    }
}

private struct Legend: View {
    var body: some View {
        HStack(spacing: 14) {
            item("lock", "Fixed", .secondary)
            item("square.on.square", "Shared or context: edit once, used by several", FeatureColor.smartRead)
            item("pencil", "This feature only", .primary)
            item("app", "This app only", FeatureColor.tools)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private func item(_ symbol: String, _ text: String, _ tint: Color) -> some View {
        Label { Text(text) } icon: { Image(systemName: symbol).foregroundStyle(tint) }
    }
}
