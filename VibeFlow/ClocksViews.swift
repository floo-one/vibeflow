import SwiftUI
import VibeFlowCore

/// The clocks item's menu: one line per clock, then a way into the Clocks tab.
struct ClocksMenuView: View {
    @Environment(AppContainer.self) private var container
    @Environment(\.openSettings) private var openSettings
    let now: Date

    var body: some View {
        ForEach(container.preferences.worldClocks) { clock in
            Text(ClockFormat.detail(for: clock, at: now))
        }
        Divider()
        Button("Edit Clocks…") { SettingsWindow.present(openSettings, container: container, tab: .clocks) }
    }
}

/// Settings > Clocks: the clocks in the menu bar (reorder, remove) and a search over every
/// time zone by city, country, abbreviation or IANA name.
struct ClocksTab: View {
    @Environment(AppContainer.self) private var container
    @State private var query = ""
    @State private var results: [WorldClock] = []
    private let catalog = TimeZoneCatalog.bundled

    var body: some View {
        @Bindable var prefs = container.preferences
        TimelineView(.everyMinute) { context in
            Form {
                Section {
                    if prefs.worldClocks.isEmpty {
                        Text("No clocks in the menu bar.").foregroundStyle(.secondary)
                    }
                    ForEach(prefs.worldClocks) { clock in
                        row(clock, at: context.date) {
                            Button("Remove", systemImage: "minus.circle.fill") { remove(clock) }
                                .labelStyle(.iconOnly)
                                .buttonStyle(.borderless)
                                .foregroundStyle(.secondary)
                        }
                        .contextMenu {
                            Button("Move Up") { move(clock, by: -1) }
                                .disabled(clock == prefs.worldClocks.first)
                            Button("Move Down") { move(clock, by: 1) }
                                .disabled(clock == prefs.worldClocks.last)
                            Button("Remove") { remove(clock) }
                        }
                    }
                    .onMove { prefs.worldClocks.move(fromOffsets: $0, toOffset: $1) }
                } header: {
                    Text("Menu bar")
                } footer: {
                    if prefs.worldClocks.count > 1 {
                        Text("Drag to reorder, or right-click a clock.").foregroundStyle(.secondary)
                    }
                }

                Section("Add a clock") {
                    TextField("Search", text: $query, prompt: Text("City, country or time zone"))
                        .labelsHidden()
                    ForEach(results) { clock in
                        row(clock, at: context.date) {
                            Button("Add") { add(clock) }
                        }
                    }
                    if !query.trimmingCharacters(in: .whitespaces).isEmpty && results.isEmpty {
                        Text("No matching time zone.").foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)
        }
        .onChange(of: query) { search() }
    }

    private func row(_ clock: WorldClock, at date: Date, @ViewBuilder trailing: () -> some View) -> some View {
        let zone = clock.timeZone
        let place = [catalog.zone(for: clock)?.country, catalog.zone(for: clock)?.name]
            .compactMap { $0 }.filter { !$0.isEmpty }
        return HStack {
            Text(clock.flag).font(.title2)
            VStack(alignment: .leading) {
                Text(clock.city)
                Text((place + [ClockFormat.offset(date, in: zone)]).joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(ClockFormat.time(date, in: zone)).monospacedDigit()
            trailing()
        }
    }

    private func search() {
        let added = Set(container.preferences.worldClocks)
        results = catalog.search(query, limit: 12).filter { !added.contains($0) }.prefix(8).map { $0 }
    }

    private func add(_ clock: WorldClock) {
        container.preferences.worldClocks.append(clock)
        query = ""
        results = []
    }

    private func remove(_ clock: WorldClock) {
        container.preferences.worldClocks.removeAll { $0 == clock }
    }

    private func move(_ clock: WorldClock, by step: Int) {
        var clocks = container.preferences.worldClocks
        guard let index = clocks.firstIndex(of: clock), clocks.indices.contains(index + step) else { return }
        clocks.swapAt(index, index + step)
        container.preferences.worldClocks = clocks
    }
}
