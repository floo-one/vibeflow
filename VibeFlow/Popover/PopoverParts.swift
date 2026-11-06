import AppKit
import KeyboardShortcuts
import SwiftUI
import VibeFlowCore

// MARK: - Palette (D9)

/// Maagical's feature colours from the website (website/src/styles/global.css), each with a
/// dark variant so they read on the dark popover material.
enum Palette {
    static let read = Color(light: 0x0064D2, dark: 0x4C9BFF)
    static let smart = Color(light: 0x5B4FE0, dark: 0x8F86FF)
    static let dictation = Color(light: 0xD93025, dark: 0xFF6B5E)
    static let tools = Color(light: 0x0F7B5F, dark: 0x3CC59A)
    static let setup = Color(light: 0xC2410C, dark: 0xFB923C)
    /// Maagical indigo (docs/designs/maagical-brand.md): the Ready dot, the update pill, the rename card.
    static let brand = Color(light: 0x3A2FBF, dark: 0x3A2FBF)
    static let brandText = Color(light: 0x3A2FBF, dark: 0x9B8CFF)
    static let brandTint = brand.opacity(0.14)
    /// Text on a filled button: white in light mode, near-black on the lighter dark-mode fills.
    static let onFill = Color(light: 0xFFFFFF, dark: 0x111114)
    static let surface = Color(light: 0xFFFFFF, dark: 0xFFFFFF, lightAlpha: 0.75, darkAlpha: 0.07)
    static let idleDot = Color.primary.opacity(0.08)

    static func color(for tone: PanelState.Tone) -> Color {
        switch tone {
        case .read: return read
        case .smart: return smart
        case .dictation, .failure: return dictation
        case .setup: return setup
        case .brand: return brand
        }
    }
}

extension Color {
    /// A colour that follows light and dark mode.
    init(light: UInt32, dark: UInt32, lightAlpha: CGFloat = 1, darkAlpha: CGFloat = 1) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let hex = isDark ? dark : light
            return NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                           blue: CGFloat(hex & 0xFF) / 255, alpha: isDark ? darkAlpha : lightAlpha)
        })
    }
}

/// A round icon badge: filled with a colour when on, a faint grey when off.
private struct Badge: View {
    let symbol: String
    let fill: Color?
    var size: CGFloat = 30

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.43, weight: .semibold))
            .foregroundStyle(fill == nil ? Color.primary : Palette.onFill)
            .frame(width: size, height: size)
            .background(fill ?? Palette.idleDot, in: Circle())
    }
}

// MARK: - Tiles (D11, D12)

struct TilesView: View {
    @Environment(AppContainer.self) private var container

    var body: some View {
        HStack(spacing: 8) {
            keepAwake
            pomodoro
        }
    }

    private var keepAwake: some View {
        let awake = container.keepAwake
        return TimelineView(.everyMinute) { context in
            Tile(symbol: "cup.and.saucer", fill: awake.isActive ? Palette.tools : nil,
                 title: "Keep Awake",
                 subtitle: KeepAwakeTile.subtitle(isActive: awake.isActive, endsAt: awake.endsAt, now: context.date),
                 action: {
                     if awake.isActive {
                         awake.stop()
                     } else {
                         let duration = KeepAwakeTile.duration(lastMinutes: container.preferences.keepAwakeLastMinutes)
                         _ = awake.start(duration)
                     }
                 },
                 menu: { KeepAwakeMenuItems() })
        }
    }

    private var pomodoro: some View {
        let focus = container.focus
        let title: String
        let subtitle: String
        switch focus.session?.stage {
        case nil:
            title = "Pomodoro"
            subtitle = "Start \(focus.rhythm.focusMinutes) min"
        case .running?:
            title = focus.session?.phase == .focus ? "Focus" : "Break"
            subtitle = "\(FocusStats.countdown(focus.session?.remaining(at: focus.now) ?? 0)) left"
        case .paused(_, let remaining)?:
            title = "Paused"
            subtitle = "\(FocusStats.countdown(remaining)) left"
        case .awaiting(let phase)?:
            title = phase.isBreak ? "Break?" : "Focus?"
            subtitle = "Start \(focus.rhythm.minutes(for: phase)) min"
        }
        let active = focus.session != nil
        return Tile(symbol: "timer", fill: active ? Palette.setup : nil, title: title, subtitle: subtitle,
                    action: {
                        switch focus.session?.stage {
                        case nil, .awaiting?: focus.send(.start)
                        case .running?: focus.send(.pause)
                        case .paused?: focus.send(.resume)
                        }
                    },
                    menu: { PomodoroMenuItems() })
    }
}

/// A Control Center style toggle: the left part acts, the chevron opens the full menu.
private struct Tile<MenuContent: View>: View {
    let symbol: String
    let fill: Color?
    let title: String
    let subtitle: String
    let action: () -> Void
    @ViewBuilder let menu: () -> MenuContent

    var body: some View {
        HStack(spacing: 0) {
            Button(action: action) {
                HStack(spacing: 8) {
                    Badge(symbol: symbol, fill: fill, size: 26)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(title).fontWeight(.semibold).lineLimit(1)
                        Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1).monospacedDigit()
                    }
                    .layoutPriority(1)
                    Spacer(minLength: 0)
                }
                .padding(.leading, 8)
                .padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(title), \(subtitle)")
            Menu { menu() } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 20, height: 48)
            .padding(.trailing, 2)
            .accessibilityLabel("\(title) options")
        }
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

// MARK: - Meeting (D5, R4 item 10)

struct MeetingCardView: View {
    let controller: StatusItemController
    @Environment(AppContainer.self) private var container

    var body: some View {
        // Decided outside the timeline, so no meeting means no view at all (and no stack gap).
        if container.preferences.meetingsEnabled,
           let next = MeetingSchedule.restOfToday(container.meetings.state.meetings, at: .now).first {
            TimelineView(.everyMinute) { context in
                card(next, now: context.date)
            }
        }
    }

    private func card(_ meeting: Meeting, now: Date) -> some View {
        HStack(spacing: 10) {
            Button {
                guard let link = meeting.htmlLink else { return }
                controller.close()
                NSWorkspace.shared.open(link)
            } label: {
                HStack(spacing: 10) {
                    Badge(symbol: "calendar", fill: nil)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(meeting.title).fontWeight(.semibold).lineLimit(1).truncationMode(.tail)
                        Text("\(ClockFormat.time(meeting.start, in: .current)) · \(Self.relative(meeting, now: now))")
                            .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(meeting.htmlLink == nil ? "" : "Open in Google Calendar")
            if let join = meeting.joinURL {
                Button {
                    controller.close()
                    NSWorkspace.shared.open(join)
                } label: {
                    Text("Join")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Palette.onFill)
                        .padding(.horizontal, 14)
                        .frame(height: 26)
                        .background(Palette.tools, in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(10)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    /// "in 18 min", "now", "started 4 min ago".
    static func relative(_ meeting: Meeting, now: Date) -> String {
        let minutes = Int((meeting.start.timeIntervalSince(now) / 60).rounded(.up))
        if minutes > 0 { return minutes < 60 ? "in \(minutes) min" : "in \(minutes / 60) h \(minutes % 60) min" }
        if minutes == 0 { return "now" }
        return "started \(-minutes) min ago"
    }
}

// MARK: - History (D14)

struct HistoryRowView: View {
    let controller: StatusItemController
    @Environment(AppContainer.self) private var container
    @State private var frame: CGRect = .zero
    @State private var hovering = false

    var body: some View {
        Button { controller.showFlyout(rowFrame: frame) } label: {
            HStack(spacing: 10) {
                Image(systemName: "clock.arrow.circlepath").foregroundStyle(.secondary).frame(width: 16)
                Text("History")
                Spacer()
                Image(systemName: "chevron.left").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)
            .frame(height: 30)
            .background(hovering || controller.model.flyoutOpen ? Color.primary.opacity(0.08) : .clear,
                        in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(GeometryReader { proxy in
            Color.clear
                .onAppear { frame = proxy.frame(in: .global) }
                .onChange(of: proxy.frame(in: .global)) { _, new in frame = new }
        })
        .onHover { inside in
            hovering = inside
            if inside { controller.showFlyout(rowFrame: frame) } else { controller.scheduleFlyoutHide() }
        }
        .accessibilityHint("Shows recent reads, questions and transcripts")
    }
}

struct HistoryFlyoutView: View {
    let controller: StatusItemController
    @Environment(AppContainer.self) private var container

    var body: some View {
        let recent = Array(container.history.entries.prefix(5))
        VStack(alignment: .leading, spacing: 1) {
            if recent.isEmpty {
                Text(emptyHint)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(10)
            }
            ForEach(recent) { entry in
                FlyoutRow {
                    open(entry)
                } label: {
                    Image(systemName: HistoryFormat.symbol(entry))
                        .foregroundStyle(color(for: entry))
                        .frame(width: 16)
                    Text(HistoryFormat.shorten(HistoryFormat.rowTitle(entry), to: 60))
                        .lineLimit(1).truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(RelativeTime.short(entry.date))
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            Divider().padding(.horizontal, 8).padding(.vertical, 4)
            FlyoutRow {
                controller.close()
                if let openWindow = container.openWindow { HistoryWindow.present(openWindow, container: container) }
            } label: {
                Text("Show All History…")
                Spacer()
            }
        }
        .padding(6)
        .frame(width: 290)
        .background(PanelBackground(cornerRadius: 12))
        .onHover { inside in inside ? controller.keepFlyout() : controller.scheduleFlyoutHide() }
    }

    private var emptyHint: String {
        let key = KeyboardShortcuts.getShortcut(for: .read).map { "\($0)" } ?? "the Read shortcut"
        return "Select text anywhere and press \(key) to hear it."
    }

    private func color(for entry: HistoryEntry) -> Color {
        switch entry.kind {
        case .read: return entry.smart ? Palette.smart : Palette.read
        case .question: return Palette.smart
        case .transcription: return .secondary
        }
    }

    /// The old History submenu's behaviour (R4 item 7).
    private func open(_ entry: HistoryEntry) {
        controller.close()
        switch entry.kind {
        case .read: container.readAgain(entry)
        case .question:
            if let openWindow = container.openWindow { HistoryWindow.present(openWindow, container: container, select: entry.id) }
        case .transcription:
            if let id = entry.transcriptID { container.openTranscript(id) }
        }
    }
}

private struct FlyoutRow<Label: View>: View {
    let action: () -> Void
    @ViewBuilder let label: () -> Label
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) { label() }
                .padding(.horizontal, 8)
                .frame(height: 30)
                .background(hovering ? Color.primary.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 8))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

enum RelativeTime {
    /// "now", "2 min", "1 h", "Yesterday", "3 Nov".
    static func short(_ date: Date, now: Date = .now, calendar: Calendar = .current) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds < 60 { return "now" }
        if seconds < 3600 { return "\(Int(seconds / 60)) min" }
        if calendar.isDateInToday(date) { return "\(Int(seconds / 3600)) h" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        return date.formatted(.dateTime.day().month(.abbreviated))
    }
}

// MARK: - File transcription (D6, D15)

struct FileRowView: View {
    let controller: StatusItemController
    @Environment(AppContainer.self) private var container
    @State private var targeted = false

    var body: some View {
        let files = container.files
        VStack(alignment: .leading, spacing: 6) {
            if let id = files.finishedTranscriptID, !files.job.isRunning {
                Button {
                    controller.close()
                    container.openTranscript(id)
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "checkmark").foregroundStyle(Palette.tools).frame(width: 16)
                        Text(files.statusLine(now: .now) ?? "Transcript ready").lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 4)
                        Text("Open Transcript").font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.tools)
                    }
                    .padding(.horizontal, 8)
                    .frame(height: 30)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            if files.job.isRunning {
                running(files)
            } else {
                if let problem = failure(files) {
                    Text(problem).font(.system(size: 12)).foregroundStyle(Palette.dictation).lineLimit(2).padding(.horizontal, 8)
                }
                dropZone
            }
        }
    }

    private func running(_ files: FileTranscriptions) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(files.statusLine(now: context.date) ?? "Transcribing…")
                        .font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
                    if let fraction = Self.fraction(files.job.state) {
                        ProgressView(value: fraction).controlSize(.small)
                    } else {
                        ProgressView().progressViewStyle(.linear).controlSize(.small)
                    }
                    ForEach(files.detailLines, id: \.self) {
                        Text($0).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Button("Stop") { files.stop() }
                    .controlSize(.small)
                    .help(files.stopTitle)
            }
            .padding(.horizontal, 8)
        }
    }

    private var dropZone: some View {
        let highlighted = targeted || controller.model.isDragging
        let message = controller.model.dropMessage
        return Button {
            controller.close()
            container.files.chooseFile {
                if let openWindow = container.openWindow { TranscribeFileWindow.present(openWindow) }
            }
        } label: {
            HStack(spacing: 12) {
                Badge(symbol: "square.and.arrow.down", fill: highlighted ? Palette.smart : nil)
                VStack(alignment: .leading, spacing: 1) {
                    Text(highlighted ? "Release to transcribe" : (message == nil ? "Transcribe a recording" : "Not this file"))
                        .fontWeight(.semibold)
                    Text(message ?? "Drop audio or video here, or click to choose")
                        .font(.system(size: 12))
                        .foregroundStyle(message == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(Palette.dictation))
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(highlighted ? Palette.brandTint : .clear, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(highlighted ? Palette.smart : (message == nil ? Color.primary.opacity(0.2) : Palette.dictation),
                                  style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .dropDestination(for: URL.self) { urls, _ in
            controller.handleDrop(urls)
        } isTargeted: { targeted = $0 }
        .accessibilityLabel("Transcribe a recording: drop a file here or click to choose")
    }

    /// The pick error or the last failed job, shown above the zone until the next file.
    private func failure(_ files: FileTranscriptions) -> String? {
        if case .failed = files.job.state { return files.statusLine(now: .now) }
        if case .idle = files.job.state { return files.pickError }
        return nil
    }

    /// Groq memos report pieces done; other engines run as one call without a fraction.
    static func fraction(_ state: FileTranscriptionJob.State) -> Double? {
        if case .running(_, .transcribingPieces(let done, let total), _, _) = state, total > 0 {
            return min(1, done / total)
        }
        return nil
    }
}
