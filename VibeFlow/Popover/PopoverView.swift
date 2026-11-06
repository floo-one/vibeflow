import AppKit
import KeyboardShortcuts
import SwiftUI
import VibeFlowCore

/// The VibeFlow menu bar panel (docs/designs/menu-bar-popover.md; prototype in
/// docs/designs/menu-bar-popover-prototype.dc.html). From the top: what VibeFlow is doing or
/// the most important problem (PanelState), Keep Awake and Pomodoro tiles, the next meeting,
/// History, the transcription drop zone, and the footer. Shortcuts are not listed: they are
/// learned in Settings, the notch tip and the empty History hint (D16).
/// Fixed 330 pt wide; every text is one truncated line, so the width never changes.
struct PopoverView: View {
    let controller: StatusItemController
    @Environment(AppContainer.self) private var container

    var body: some View {
        let state = PanelState(container.panelInput)
        VStack(alignment: .leading, spacing: 12) {
            TopSlotView(slot: state.top, controller: controller)
            TilesView()
            MeetingCardView(controller: controller)
            HistoryRowView(controller: controller)
            FileRowView(controller: controller)
            Divider().padding(.horizontal, 4)
            FooterView(footer: state.footer, controller: controller)
        }
        .padding(12)
        .frame(width: 330)
        .background(PanelBackground(cornerRadius: 18))
        .background {
            // ⌘, opens Settings from anywhere in the panel, also while a card hides the gear.
            Button("Settings") {
                controller.close()
                container.presentSettings(tab: nil)
            }
            .keyboardShortcut(",")
            .hidden()
        }
    }
}

// MARK: - Top slot (D3, D4)

struct TopSlotView: View {
    let slot: PanelState.TopSlot
    let controller: StatusItemController
    @Environment(AppContainer.self) private var container

    var body: some View {
        switch slot {
        case .ready:
            HStack(spacing: 8) {
                Circle()
                    .fill(LinearGradient(colors: [Palette.brandTop, Palette.brandBottom], startPoint: .top, endPoint: .bottom))
                    .frame(width: 8, height: 8)
                Text("Ready").fontWeight(.semibold)
                Spacer()
                Button {
                    controller.close()
                    container.presentSettings(tab: nil)
                } label: {
                    Image(systemName: "gearshape")
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Settings (⌘,)")
                .accessibilityLabel("Settings")
            }
            .frame(height: 28)
            .padding(.horizontal, 4)
        case .activity(let card):
            CardView(card: card, isProblem: false, controller: controller)
        case .problem(let card):
            CardView(card: card, isProblem: true, controller: controller)
        }
    }
}

private struct CardView: View {
    let card: PanelState.Card
    let isProblem: Bool
    let controller: StatusItemController
    @Environment(AppContainer.self) private var container

    var body: some View {
        let tone = Palette.color(for: card.tone)
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                if card.showsMeter {
                    LevelMeter(color: tone)
                } else if isProblem {
                    Image(systemName: card.tone == .setup ? "exclamationmark.triangle" : "xmark.octagon")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(tone)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(card.title).fontWeight(.semibold).lineLimit(1)
                    Text(card.detail)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(isProblem ? 2 : 1)
                        .truncationMode(.tail)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if !isProblem, let first = card.actions.first {
                    actionButton(first, prominent: true)
                }
            }
            if isProblem || card.actions.count > 1 {
                HStack(spacing: 12) {
                    ForEach(Array((isProblem ? card.actions : Array(card.actions.dropFirst())).enumerated()), id: \.offset) { index, action in
                        actionButton(action, prominent: index == 0 && isProblem)
                    }
                }
                .padding(.leading, isProblem ? 27 : 0)
                .disabled(!card.actionsEnabled)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(tone.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    private func actionButton(_ action: PanelState.Action, prominent: Bool) -> some View {
        let tone = Palette.color(for: card.tone)
        let button = Button { perform(action) } label: {
            Text(PanelActions.label(action))
                .font(.system(size: 12, weight: prominent ? .semibold : .regular))
                .padding(.horizontal, prominent ? 12 : 0)
                .frame(height: 26)
                .foregroundStyle(prominent ? Palette.onFill : .secondary)
                .background(prominent ? tone : .clear, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        if action == .stop {
            button.keyboardShortcut(".", modifiers: .command)
        } else {
            button
        }
    }

    private func perform(_ action: PanelState.Action) {
        if PanelActions.handsOff(action) { controller.close() }
        PanelActions.perform(action, container: container)
    }
}

/// Bars that move while VibeFlow listens or speaks; still under Reduce Motion.
private struct LevelMeter: View {
    let color: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.12)) { context in
            let t = reduceMotion ? 0 : context.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: 2) {
                ForEach(0..<5, id: \.self) { i in
                    Capsule()
                        .fill(color)
                        .frame(width: 3, height: 8 + 12 * abs(sin(t * 3.1 + Double(i) * 1.3)))
                }
            }
            .frame(height: 22)
        }
        .accessibilityHidden(true)
    }
}

/// What each card button says and does; the same actions the old menu offered (R4 item 2).
enum PanelActions {
    static func label(_ action: PanelState.Action) -> String {
        switch action {
        case .stop: return "Stop  ⌘."
        case .readAnyway: return "Read anyway"
        case .grantAccessibility, .read(.grantAccessibility): return "Grant access"
        case .openMicrophoneSettings, .dictation(.openMicrophoneSettings): return "Open Microphone settings"
        case .read(.openKeys), .dictation(.openKeys): return "Open Settings > Accounts"
        case .read(.readOriginal): return "Read original instead"
        case .dictation(.retry): return "Retry"
        case .dictation(.copyText): return "Copy text"
        case .dictation(.discard): return "Discard"
        case .dictation(.openDictationSettings): return "Open Settings > Dictation"
        }
    }

    /// Actions that open a window or System Settings close the panel first (D13).
    static func handsOff(_ action: PanelState.Action) -> Bool {
        switch action {
        case .stop, .readAnyway, .read(.readOriginal), .dictation(.retry), .dictation(.copyText), .dictation(.discard):
            return false
        default:
            return true
        }
    }

    @MainActor
    static func perform(_ action: PanelState.Action, container: AppContainer) {
        switch action {
        case .stop: container.stopAll()
        case .readAnyway: container.session.readAnyway()
        case .grantAccessibility, .read(.grantAccessibility): NSWorkspace.shared.open(Accessibility.settingsURL)
        case .openMicrophoneSettings, .dictation(.openMicrophoneSettings): NSWorkspace.shared.open(Microphone.settingsURL)
        case .read(.openKeys), .dictation(.openKeys): container.presentSettings(tab: .accounts)
        case .read(.readOriginal): container.session.readOriginal()
        case .dictation(.retry): container.dictation.retry()
        case .dictation(.copyText): Task { await container.dictation.copyText() }
        case .dictation(.discard): container.dictation.discard()
        case .dictation(.openDictationSettings): container.presentSettings(tab: .dictation)
        }
    }
}

// MARK: - Footer (D7)

struct FooterView: View {
    let footer: PanelState.Footer
    let controller: StatusItemController
    @Environment(AppContainer.self) private var container

    var body: some View {
        HStack(spacing: 6) {
            if footer.showsFeedback {
                Button {
                    controller.close()
                    if let openWindow = container.openWindow { FeedbackWindow.present(openWindow) }
                } label: {
                    Image(systemName: "ladybug")
                        .frame(width: 26, height: 26)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Send Feedback…")
                .accessibilityLabel("Send Feedback")
            }
            version
            Spacer(minLength: 8)
            Button("Quit") { NSApplication.shared.terminate(nil) }
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .keyboardShortcut("q")
                .help("Quit \(appName)")
        }
        .padding(.horizontal, 2)
    }

    @ViewBuilder private var version: some View {
        if footer.offersBackToStable {
            Menu {
                Button("Check for Updates…") { checkForUpdates() }
                Button(StableInstaller.shared.step ?? "Back to Stable") {
                    StableInstaller.shared.install(preferences: container.preferences)
                }
                .disabled(StableInstaller.shared.step != nil)
            } label: {
                versionLabel
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        } else if footer.checksForUpdates {
            Button { checkForUpdates() } label: { versionLabel }
                .buttonStyle(.plain)
                .help(footer.isUpdatePill ? "Install the update now and relaunch" : "Check for Updates…")
        } else {
            versionLabel
        }
    }

    private var versionLabel: some View {
        Text(footer.label)
            .font(.system(size: 12, weight: footer.isUpdatePill ? .semibold : .regular))
            .lineLimit(1)
            .truncationMode(.middle)
            .foregroundStyle(footer.isUpdatePill ? Palette.brandText : .secondary)
            .padding(.horizontal, footer.isUpdatePill ? 10 : 6)
            .frame(height: 24)
            .background(footer.isUpdatePill ? Palette.brandTint : .clear, in: Capsule())
    }

    private func checkForUpdates() {
        controller.close()
        container.updater?.checkForUpdates()
    }

    private var appName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "Maagical"
    }
}

// MARK: - Background

/// The popover material behind the panel, with rounded corners and a hairline edge.
struct PanelBackground: View {
    let cornerRadius: CGFloat

    var body: some View {
        VisualEffect(material: .popover)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
            }
    }
}

private struct VisualEffect: NSViewRepresentable {
    let material: NSVisualEffectView.Material

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}
