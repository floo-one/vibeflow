import Foundation
import Testing
@testable import MaagicalCore

/// The menu bar panel's rules (docs/designs/menu-bar-popover.md, eng review R2 and R4).
struct PanelStateTests {
    private let readFailed = LastError(message: "ElevenLabs didn't answer.", actions: [.openKeys, .readOriginal])
    private let pasteFailed = DictationError(message: "Couldn't paste.", actions: [.retry, .copyText, .discard])

    @Test func idleWithNothingWrongIsReady() {
        #expect(PanelState(.init()).top == .ready)
    }

    @Test func renameNoticeShowsOnlyWhenNothingElseDoes() {
        let notice = PanelState(.init(showsRenameNotice: true)).top.card
        #expect(notice?.title == "VibeFlow is now Maagical")
        #expect(notice?.tone == .brand)
        #expect(notice?.actions == [.dismissRenameNotice])
        #expect(PanelState(.init(accessibilityTrusted: false, showsRenameNotice: true)).top.card?.title == "Allow Accessibility access")
        #expect(PanelState(.init(readState: .speaking, readStatus: "Speaking", showsRenameNotice: true)).top.card?.title == "Speaking")
    }

    @Test func runningActivityOutranksEveryProblem() {
        let input = PanelState.Input(readState: .speaking, readStatus: "Speaking", readError: readFailed,
                                     dictationError: pasteFailed, accessibilityTrusted: false, microphoneDenied: true)
        guard case .activity(let card) = PanelState(input).top else { Issue.record("expected activity"); return }
        #expect(card.title == "Speaking")
        #expect(card.actions == [.stop])
    }

    @Test func dictationActivityComesBeforeARead() {
        let input = PanelState.Input(readState: .speaking, dictationState: .recording(handsFree: false),
                                     dictationStatus: "Listening")
        #expect(PanelState(input).top.card?.title == "Listening")
        #expect(PanelState(input).top.card?.tone == .dictation)
    }

    @Test func pastingCannotBeStopped() {
        let card = PanelState(.init(dictationState: .pasting)).top.card
        #expect(card?.title == "Pasting")
        #expect(card?.actions == [])
    }

    @Test(arguments: [
        // (accessibility, microphone denied, read error, expected title)
        (false, true, true, "Allow Accessibility access"),
        (true, true, true, "Allow Microphone access"),
        (true, false, true, "Read failed"),
    ])
    func problemOrder(trusted: Bool, micDenied: Bool, hasError: Bool, expected: String) {
        let input = PanelState.Input(readError: hasError ? readFailed : nil,
                                     accessibilityTrusted: trusted, microphoneDenied: micDenied)
        guard case .problem(let card) = PanelState(input).top else { Issue.record("expected problem"); return }
        #expect(card.title == expected)
    }

    @Test func lastUsedSessionsErrorComesFirst() {
        let both = PanelState.Input(readError: readFailed, dictationError: pasteFailed, showsDictation: true)
        #expect(PanelState(both).top.card?.title == "Dictation failed")
        var reading = both
        reading.showsDictation = false
        #expect(PanelState(reading).top.card?.title == "Read failed")
    }

    @Test func errorActionsKeepAtMostTwo() {
        let card = PanelState(.init(dictationError: pasteFailed, showsDictation: true)).top.card
        #expect(card?.actions == [.dictation(.retry), .dictation(.copyText)])
        #expect(PanelState(.init(readError: readFailed)).top.card?.actions == [.read(.openKeys), .read(.readOriginal)])
    }

    @Test func readAnywayOnlyForAMenuRead() {
        let menu = PanelState(.init(readState: .awaitingConfirm(kind: .read, origin: .menu, characters: 42_000))).top.card
        #expect(menu?.actions == [.readAnyway, .stop])
        let hotkey = PanelState(.init(readState: .awaitingConfirm(kind: .read, origin: .hotkey, characters: 42_000))).top.card
        #expect(hotkey?.actions == [.stop])
    }

    @Test func dictationErrorActionsDisabledWhileBusy() {
        // Not visible while busy (the activity outranks it), but the card itself is disabled.
        let card = PanelState.dictationProblemForTesting(.init(dictationState: .transcribing,
                                                               dictationError: pasteFailed))
        #expect(card?.actionsEnabled == false)
        #expect(PanelState.dictationProblemForTesting(.init(dictationError: pasteFailed))?.actionsEnabled == true)
    }

    @Test func footerPlainVersion() {
        let footer = PanelState(.init(version: "1.5.0")).footer
        #expect(footer == .init(showsFeedback: true, label: "1.5.0", isUpdatePill: false, offersBackToStable: false,
                                checksForUpdates: true))
    }

    @Test func footerPillOnlyWithAWaitingUpdate() {
        #expect(PanelState(.init(updateWaiting: "1.6.0")).footer.label == "Update to 1.6.0")
        #expect(PanelState(.init(updateWaiting: "1.6.0")).footer.isUpdatePill)
        #expect(PanelState(.init(updateWaiting: "1.6.0", build: .debug, version: "dev")).footer.isUpdatePill == false)
    }

    @Test func footerNightlyAndFeedback() {
        #expect(PanelState(.init(build: .nightly)).footer.offersBackToStable)
        #expect(PanelState(.init(feedbackEnabled: false)).footer.showsFeedback == false)
        #expect(PanelState(.init(build: .debug)).footer.checksForUpdates == false)
    }

    @Test func keepAwakeTileRemembersTheLastDuration() {
        #expect(KeepAwakeTile.duration(lastMinutes: nil) == .indefinitely)
        #expect(KeepAwakeTile.duration(lastMinutes: 0) == .indefinitely)
        #expect(KeepAwakeTile.duration(lastMinutes: 60) == .minutes(60))
        #expect(KeepAwakeTile.minutes(of: .minutes(120)) == 120)
        #expect(KeepAwakeTile.minutes(of: .indefinitely) == 0)
    }

    @Test func keepAwakeTileSubtitle() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        #expect(KeepAwakeTile.subtitle(isActive: false, endsAt: nil, now: now) == "Off")
        #expect(KeepAwakeTile.subtitle(isActive: true, endsAt: .distantFuture, now: now) == "On")
        #expect(KeepAwakeTile.subtitle(isActive: true, endsAt: now.addingTimeInterval(105 * 60), now: now) == "1:45 left")
    }

    @Test func holdTipShowsThreeTimesAndNeverAfterAHold() {
        #expect(HoldTip.shows(tapsSoFar: 0, hasHeld: false))
        #expect(HoldTip.shows(tapsSoFar: 2, hasHeld: false))
        #expect(HoldTip.shows(tapsSoFar: 3, hasHeld: false) == false)
        #expect(HoldTip.shows(tapsSoFar: 0, hasHeld: true) == false)
    }
}
