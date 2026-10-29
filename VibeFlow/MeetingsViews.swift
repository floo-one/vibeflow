import AppKit
import SwiftUI
import VibeFlowCore

/// The meetings item's menu (M3): the meeting in the label with Join, the rest of today,
/// and ways into Google Calendar and the Meetings tab.
struct MeetingsMenuView: View {
    @Environment(AppContainer.self) private var container
    @Environment(\.openSettings) private var openSettings
    let now: Date

    var body: some View {
        let store = container.meetings
        let current = Self.meeting(in: store.nudge(at: now))
        if let current {
            Text(current.title)
            Text(Self.details(current))
            if let joinURL = current.joinURL {
                Button("Join") { NSWorkspace.shared.open(joinURL) }
            }
        }
        let later = MeetingSchedule.restOfToday(store.state.meetings, at: now).filter { $0 != current }
        if !later.isEmpty {
            Divider()
            Text("Today")
            ForEach(later) { meeting in
                Button("\(ClockFormat.time(meeting.start, in: .current))  \(meeting.title)") { open(meeting) }
            }
        }
        Divider()
        Button("Open in Google Calendar") {
            NSWorkspace.shared.open(current?.htmlLink ?? URL(string: "https://calendar.google.com/calendar/r/day")!)
        }
        Button("Meetings Settings…") { SettingsWindow.present(openSettings, container: container, tab: .meetings) }
    }

    /// Join when there is a call link, otherwise the event in Google Calendar.
    private func open(_ meeting: Meeting) {
        if let url = meeting.joinURL ?? meeting.htmlLink { NSWorkspace.shared.open(url) }
    }

    static func meeting(in nudge: MeetingNudge) -> Meeting? {
        switch nudge {
        case .hidden: nil
        case .soon(let meeting, _), .now(let meeting): meeting
        }
    }

    /// "09:00–09:30 · Alex · no call link"
    static func details(_ meeting: Meeting) -> String {
        let zone = TimeZone.current
        var parts = ["\(ClockFormat.time(meeting.start, in: zone))–\(ClockFormat.time(meeting.end, in: zone))"]
        if let organizer = meeting.organizer { parts.append(organizer) }
        if meeting.joinURL == nil { parts.append("no call link") }
        return parts.joined(separator: " · ")
    }
}

/// Settings > Meetings (R1, R6): Google sign-in with its status line, the on/off switch,
/// lead time and the calendars to watch.
struct MeetingsTab: View {
    @Environment(AppContainer.self) private var container

    var body: some View {
        @Bindable var prefs = container.preferences
        let store = container.meetings
        Form {
            Section {
                if store.config == nil {
                    LabeledContent("Google Calendar", value: MeetingsStatus.notConfigured.line())
                } else {
                    LabeledContent("Google Calendar") {
                        Text(store.state.status.line()).foregroundStyle(statusColor(store.state.status))
                    }
                    HStack {
                        if store.isSigningIn {
                            ProgressView().controlSize(.small)
                            Text("Waiting for the browser…").foregroundStyle(.secondary)
                            Spacer()
                            Button("Cancel") { store.cancelSignIn() }
                        } else if store.state.email != nil {
                            Spacer()
                            Button("Sync Now") { store.sync() }
                            Button("Sign Out") { store.signOut() }
                        } else {
                            Spacer()
                            Button("Sign in with Google…") { store.signIn() }
                        }
                    }
                    if let message = store.signInMessage {
                        Text(message).foregroundStyle(.red)
                    }
                }
            } footer: {
                if store.config == nil {
                    Text("This build has no Google client. Copy Config/Google.xcconfig.example to Config/Google.xcconfig, fill it in and rebuild.")
                        .foregroundStyle(.secondary)
                } else {
                    Text("Read-only access to your calendars. Events stay on this Mac, in memory.")
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Toggle("Show upcoming meetings in the menu bar", isOn: $prefs.meetingsEnabled)
                    .onChange(of: prefs.meetingsEnabled) { if prefs.meetingsEnabled { store.sync() } }
                Picker("Appear", selection: $prefs.meetingsLeadMinutes) {
                    ForEach(MeetingSchedule.leadTimes, id: \.self) { Text("\($0) minutes before").tag($0) }
                }
                .disabled(!prefs.meetingsEnabled)
            }

            if let email = store.state.email, !store.state.calendars.isEmpty {
                Section("Calendars") {
                    ForEach(sortedCalendars(store.state.calendars, email: email)) { calendar in
                        Toggle(name(calendar, email: email), isOn: watching(calendar.id, email: email))
                    }
                }
                .disabled(!prefs.meetingsEnabled)
            }
        }
        .formStyle(.grouped)
    }

    private func statusColor(_ status: MeetingsStatus) -> Color {
        switch status {
        case .signedIn, .syncing: .primary
        case .signedOut, .notConfigured: .secondary
        default: .orange
        }
    }

    private func sortedCalendars(_ calendars: [GoogleCalendarEntry], email: String) -> [GoogleCalendarEntry] {
        calendars.sorted { a, b in
            if (a.id == email) != (b.id == email) { return a.id == email }
            return name(a, email: email).localizedCaseInsensitiveCompare(name(b, email: email)) == .orderedAscending
        }
    }

    private func name(_ calendar: GoogleCalendarEntry, email: String) -> String {
        calendar.id == email ? "\(email) (you)" : (calendar.summary ?? calendar.id)
    }

    /// nil in Preferences means "your own calendar"; the first change writes the full list.
    private func watching(_ id: String, email: String) -> Binding<Bool> {
        let prefs = container.preferences
        return Binding(
            get: { (prefs.meetingsCalendars ?? [email]).contains(id) },
            set: { on in
                var ids = prefs.meetingsCalendars ?? [email]
                ids.removeAll { $0 == id }
                if on { ids.append(id) }
                prefs.meetingsCalendars = ids
                container.meetings.sync()
            }
        )
    }
}
