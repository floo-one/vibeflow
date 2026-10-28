import AppKit
import Observation
import SwiftUI
import VibeFlowCore

// MARK: - NotchIndicator

/// Black wings that grow out of the notch whenever VibeFlow is busy, like FreeFlow. The left
/// wing says what is happening (microphone, sparkles, speaker), the right wing how it is going:
/// the chosen listening style while dictating, a spinner while working, a moving waveform
/// symbol while speaking. Screens without a notch get the same shape hanging from the middle
/// of the menu bar.
///
/// One transparent, click-through panel stays on screen; the SwiftUI view inside it reads the
/// dictation and read states and draws nothing while idle.
@MainActor
final class NotchIndicator {
    private let panel: NSPanel
    private let layout = NotchLayout()
    private var screenObserver: NSObjectProtocol?

    init(dictation: DictationSession, reading: ReadSession, preferences: Preferences, level: @escaping @MainActor () -> Float) {
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        // Above the menu bar and full-screen apps, on every Space, never in Cmd-Tab or Exposé.
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]

        let layout = layout
        let view = NotchIndicatorView(dictation: dictation, reading: reading, preferences: preferences, layout: layout, level: level) { [weak self] in
            self?.place()
        }
        panel.contentView = NSHostingView(rootView: view.environment(\.colorScheme, .dark))
        place()
        panel.orderFrontRegardless()

        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.place() }
        }
    }

    /// Centres the panel on the top edge of the screen the user is working on.
    private func place() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        layout.update(for: screen)
        let width = layout.notchWidth + 2 * NotchLayout.wingWidth
        panel.setFrame(NSRect(x: screen.frame.midX - width / 2, y: screen.frame.maxY - layout.height,
                              width: width, height: layout.height), display: true)
    }
}

/// The notch geometry of the current screen. Zero notch width on screens without one.
@MainActor
@Observable
final class NotchLayout {
    static let wingWidth: CGFloat = 40
    private(set) var notchWidth: CGFloat = 0
    private(set) var height: CGFloat = 24

    func update(for screen: NSScreen) {
        if screen.safeAreaInsets.top > 0,
           let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            notchWidth = screen.frame.width - left.width - right.width
            height = screen.safeAreaInsets.top
        } else {
            notchWidth = 0
            // The menu bar height; 24 pt when the menu bar hides itself.
            let menuBar = screen.frame.maxY - screen.visibleFrame.maxY
            height = menuBar > 0 ? menuBar : 24
        }
    }
}

// MARK: - View

private enum NotchPhase: Equatable {
    case hidden
    /// Dictation is recording.
    case listening
    /// A follow-up question is recording.
    case asking
    /// Dictation is transcribing, cleaning or pasting.
    case dictationWorking
    /// A read is capturing the selection or waiting for the first audio.
    case preparing
    /// Smart read is waiting for the model.
    case thinking
    case speaking

    var symbol: String? {
        switch self {
        case .hidden: return nil
        case .listening, .dictationWorking: return "mic.fill"
        case .asking: return "questionmark.bubble.fill"
        case .preparing, .speaking: return "speaker.wave.2.fill"
        case .thinking: return "sparkles"
        }
    }
}

private struct NotchIndicatorView: View {
    let dictation: DictationSession
    let reading: ReadSession
    let preferences: Preferences
    let layout: NotchLayout
    let level: @MainActor () -> Float
    let willShow: @MainActor () -> Void

    /// Dictation wins: it stops a running read (D3), so both are rarely busy at once.
    private var phase: NotchPhase {
        guard preferences.notchIndicator else { return .hidden }
        switch dictation.state {
        case .recording: return dictation.isAskingQuestion ? .asking : .listening
        case .transcribing, .cleaning, .pasting: return dictation.isAskingQuestion ? .thinking : .dictationWorking
        case .idle: break
        }
        switch reading.state {
        case .idle, .awaitingConfirm: return .hidden
        case .capturing: return reading.isAnsweringQuestion ? .thinking : .preparing
        case .buffering: return .preparing
        case .transforming: return .thinking
        case .speaking: return .speaking
        }
    }

    var body: some View {
        let phase = phase
        let shown = phase != .hidden
        let wing = NotchLayout.wingWidth
        HStack(spacing: 0) {
            Group {
                if let symbol = phase.symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(phase == .listening || phase == .asking || phase == .speaking ? 1 : 0.7))
                        .contentTransition(.symbolEffect(.replace))
                }
            }
            .frame(width: wing)
            Color.clear.frame(width: layout.notchWidth)
            Group {
                switch phase {
                case .listening, .asking: ListeningIndicator(style: preferences.listeningStyle, level: level)
                case .dictationWorking, .preparing, .thinking: ProgressView().controlSize(.mini)
                case .speaking:
                    Image(systemName: "waveform")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                        .symbolEffect(.variableColor.iterative.dimInactiveLayers, options: .repeating)
                case .hidden: EmptyView()
                }
            }
            .frame(width: wing)
        }
        .frame(width: shown ? layout.notchWidth + 2 * wing : max(layout.notchWidth, 1), height: layout.height)
        .background(.black)
        .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: 10, bottomTrailingRadius: 10))
        .opacity(shown ? 1 : 0)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(.spring(response: 0.32, dampingFraction: 0.8), value: phase)
        .onChange(of: shown) { _, isShown in if isShown { willShow() } }
    }
}

private struct ListeningIndicator: View {
    let style: ListeningStyle
    let level: @MainActor () -> Float

    var body: some View {
        switch style {
        case .dot: Circle().fill(.red).frame(width: 8, height: 8)
        case .pulse: Pulse(level: level)
        case .bars: Waveform(level: level)
        }
    }
}

/// The red dot with a soft ring around it. The ring follows a smoothed level, so it swells
/// with speech instead of flickering with every syllable.
private struct Pulse: View {
    let level: @MainActor () -> Float
    @State private var smoothed: Double = 0

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { context in
            ZStack {
                Circle()
                    .fill(.red.opacity(0.35))
                    .frame(width: 8 + 10 * smoothed, height: 8 + 10 * smoothed)
                Circle().fill(.red).frame(width: 8, height: 8)
            }
            .onChange(of: context.date) {
                // Rise quickly, fall slowly.
                let target = Double(level())
                smoothed += (target - smoothed) * (target > smoothed ? 0.35 : 0.08)
            }
        }
    }
}

/// Five bars that follow the microphone level, each with its own rhythm so silence still
/// breathes a little. Redraws only while it is on screen.
private struct Waveform: View {
    let level: @MainActor () -> Float
    private static let weights: [Double] = [0.55, 0.85, 1.0, 0.8, 0.6]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let loudness = Double(level())
            HStack(spacing: 2.5) {
                ForEach(Self.weights.indices, id: \.self) { i in
                    let wobble = 0.5 + 0.5 * sin(t * 9 + Double(i) * 1.3)
                    let amount = min(1, 0.12 + loudness * Self.weights[i] * (0.7 + 0.3 * wobble))
                    Capsule()
                        .fill(.white)
                        .frame(width: 2.5, height: 3 + 11 * amount)
                }
            }
            .animation(.linear(duration: 1 / 30), value: loudness)
        }
    }
}
