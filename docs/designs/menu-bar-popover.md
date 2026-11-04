# Menu bar popover

Status: built 2026-11-05 on branch modal-size-tabs-58d315 (not committed yet): VibeFlow/Popover,
VibeFlowCore Panel/PanelState.swift with PanelStateTests (15 tests). Canvas: https://claude.ai/artifact/K7Gon1ujsXysCeTDPwYyrn
(frames "Recommended: Control Center popover" and "Recommended, while speaking and focusing").

## Problem

The VibeFlow menu (`VibeFlow/MenuBarView.swift`, a native NSMenu) grew as wide as the last
smart read answer, and listed every read and dictation action as a row even though they are
used through shortcuts. The first fix (shortened lines, a grey shortcut line, a Shortcuts
submenu) is built on this branch. The user prefers a Control Center style popover.

## Direction (accepted 2026-11-04)

Replace the VibeFlow menu with a SwiftUI `MenuBarExtra` in `.window` style, like the
Pomodoro popup (`FocusMenuView`, docs/designs/focus-timer.md). Fixed width, every text in a
fixed slot that truncates with "…", so the panel never changes width.

Draft content, top to bottom:

1. Status line ("Ready" with a dot) and a Settings button.
2. (Removed by D16: no shortcuts in the panel.)
3. Two tiles: Keep Awake and Pomodoro, one click toggles, subtitle shows time left.
4. Next meeting card with Join.
5. Rows: History, Transcribe File…
6. Footer: version, Quit.

While speaking, the status line becomes a card with a Stop button (⌘.).

## Review decisions

Made one at a time in /plan-design-review (2026-11-05).

- **D2 Recent list inline (Pass 1).** The History row is replaced by a "Recent" section with
  the last 3 history items, below the meeting card. Each row: kind symbol (read, question,
  transcript), one-line excerpt truncated with "…", relative time on the right ("2 min").
  Click does what today's History submenu does: a read plays again, a question opens the
  History window on it, a transcript opens its window. "Show all" on the section heading
  opens the History window.

- **D3 One activity card (Pass 2).** The top slot is one card that follows the app's state:
  Ready (a quiet line, no card chrome) → Listening (live mic level, Stop) → Transcribing →
  Thinking → Answering → Speaking (Stop ⌘.). A selection over the size limit shows
  "Read anyway" as the card's button. Stop never moves.
- **D4 Problem card (Pass 2).** Problems take the same top slot: orange tint for missing
  setup, red for a failure. One sentence plus the main fix button (Grant access, Add key,
  Retry); an error that offers a second action today (Copy text, Read original) keeps it as a
  quiet text button. Only the most important problem shows: Accessibility, Microphone,
  API key, then the last error. An activity in progress outranks a past error.
- **D5 Empty states (Pass 2).** The meeting card is hidden when Meetings is off or no meeting
  is left today. An empty Recent shows one line with the user's real key:
  "Select text anywhere and press ⌥ . to hear it".
- **D6 File transcription in its row (Pass 2).** The Transcribe File row becomes file name,
  thin progress bar and Stop while a file runs, then "Open Transcript" until the next file.
- **D7 Footer (Pass 2, user's variant).** Footer: bug icon (Send Feedback…, hidden when the
  Sentry DSN is empty), then the version text, then Quit on the right. The version text is the
  update control: "VibeFlow 1.5.0" checks for updates on click; when Sparkle has an update it
  becomes an "Update to 1.6.0" pill. On a nightly, clicking the version opens a small menu
  with Check for Updates and Back to Stable. Dev builds show branch · commit as the version.

- **D8 No card behind the key caps (Pass 4).** Key caps, their labels and the hint line sit
  on the panel background. Only clickable things get a surface (tiles, meeting, Recent rows),
  so a surface means "you can click this".
- **D9 VibeFlow palette (Pass 5).** Reuse the website's feature colours
  (website/src/styles/global.css) instead of system accent colours:

  | Token        | Light     | Dark      | Used for                                         |
  |--------------|-----------|-----------|--------------------------------------------------|
  | read         | #0064D2   | #4C9BFF   | Read key cap tint, Speaking card                 |
  | smart        | #5B4FE0   | #8F86FF   | Smart read key cap, Thinking/Answering card      |
  | dictation    | #D93025   | #FF6B5E   | Dictate key cap, Listening card, mic level       |
  | tools        | #0F7B5F   | #3CC59A   | "On" tiles (Keep Awake), Join button             |
  | brand        | #4030C7→#6B70FF (icon) | same | the Ready dot only                      |
  | text / text-2| #1D1D1F / #6E6E73 | #F5F5F7 / #AEAEB2 | labels, subtitles                  |
  | surface      | white 80% | white 8%  | clickable modules on the panel material          |
  | problem      | #C2410C (setup) / #D93025 (failure) on a 12% tint | lighter in dark | D4 cards |

  Pomodoro keeps its existing phase colours. White text on every fill meets 4.5:1 in light
  mode; dark mode uses dark text on the lighter fills. Panel background stays the system
  popover material so it blends with the menu bar. Type: SF Pro 13 pt body, 12 pt
  subtitles, 11 pt hint; key caps SF Pro Rounded 15 pt semibold. Radii: panel 18, modules 12,
  key caps 7, pills full.

- **D10 Full keyboard and VoiceOver (Pass 6; user: no preference, recommendation taken).**
  Esc closes. Tab and arrow keys move through the top-slot button, tiles and their chevrons,
  Join, Recent rows, Transcribe row and footer, with the system focus ring. Return or Space
  activates. ⌘, opens Settings, ⌘Q quits. VoiceOver: each tile reads name, state, time left
  and "button" ("Keep Awake, on, 1 hour 45 minutes left"); key caps read as text
  ("Read: Option period"). The mic level animation stops under Reduce Motion; Increase
  Contrast adds a 1 pt border to modules. Dark mode uses the D9 dark column.
- **D11 Keep Awake tile (Pass 7; user: no preference, recommendation taken).** Click turns
  it on with the last duration picked (first time: Indefinitely); click again turns it off.
  A ⌄ chevron at the tile's right edge, or a right-click, opens the duration list and Allow
  Display Sleep.
- **D12 Pomodoro tile (Pass 7; decided by the reviewer, open to veto).** Idle: click starts a
  focus round with the current rhythm. Running: click pauses or resumes. The ⌄ chevron opens
  Skip, Stop, Rhythm and Pomodoro Settings. The separate Pomodoro menu bar popup stays as is.
- **D13 Closing and focus (Pass 7; decided by the reviewer, open to veto).** The panel closes
  when it sends the user elsewhere (History window, Settings, Transcribe File, Join,
  Open Transcript, Feedback); toggles and chevron menus keep it open. Any VibeFlow global
  shortcut closes the panel before capturing a selection. A dictation that finishes while
  the panel is open pastes into the app that was frontmost, never into the panel
  (see learning dictation-target-resolved-late, DictationSession focusedTarget). Verify in
  the Dev build before release.

- **D14 History row with a hover flyout (user, 2026-11-05; replaces D2).** No inline Recent
  list. One "History" row; hovering it (or Return / → with the keyboard) opens a flyout to
  the left of the panel with the last 5 items (kind symbol, excerpt, relative time) and
  "Show All History…". Clicking an item does what D2 described. An empty history shows the
  D5 hint line inside the flyout instead of items.
- **D15 Drop zone for file transcription (user, 2026-11-05; replaces the idle half of D6).**
  The Transcribe File row becomes a dashed drop zone: "Transcribe a recording / Drop audio or
  video here, or click to choose". A file dragged over it turns the zone violet with
  "Release to transcribe" and the file's name and length. While a file runs, the zone is
  replaced by the D6 progress row. Requirement: dragging a file from Finder means clicking
  in Finder, which closes the panel, so the menu bar icon must accept file drops too: a file
  held over the icon opens the panel with the zone ready, and a file dropped on the icon
  starts transcription directly. MenuBarExtra gives no access to its status item, so this
  needs MenuBarExtraAccess or an own NSStatusItem; check during the eng review.

- **D16 No shortcuts in the panel (user, 2026-11-05; replaces item 2 and three drafts:
  captions, dot/bar marks with a Selection | Clipboard switch, a keyboard strip with hover
  cards).** Shortcuts are used from the keyboard, so the menu bar panel does not show them.
  They are listed and changed in Settings. Teaching happens where the keys are used: the
  notch tip (D17) and the empty-history hint in the History flyout (D5, D14). The top slot
  is followed directly by the tiles.
- **D17 Hold is taught in the notch (user, 2026-11-05).** The first 3 times the user taps
  the smart read key, the notch indicator adds one line under the Smart read status:
  "⌥ , Hold it next time to ask a question" (with the real key), then never again. A count
  in UserDefaults; holding the key once also ends the tips. Canvas: "Hold is taught in the
  notch" (row 4).

### Hierarchy (Pass 1)

```
┌ Popover, 330 pt wide ───────────────────┐
│ 1  Status line / activity card          │  what is happening now, Stop
│ 3  Tiles: Keep Awake | Pomodoro         │  one-click toggles
│ 4  Next meeting card (Join)             │
│ 5  History ‹  (hover: flyout, D14)      │
│ 6  Drop zone: Transcribe a recording    │
│ 7  Footer: version · Quit   (Settings ⚙ in 1) │
└─────────────────────────────────────────┘
```

### States (Pass 2)

```
  PART            | IDLE / EMPTY                | BUSY                         | PROBLEM                     | DONE
  ----------------|-----------------------------|------------------------------|-----------------------------|-----------------------
  Top slot        | "Ready" line + ⚙            | activity card, Stop (D3)     | problem card, fix (D4)      | back to Ready
  Keep Awake tile | grey, "Off"                 | accent, "1:45 left"/"On"     | n/a                         | grey again
  Pomodoro tile   | grey, "Start 25 min"        | phase colour, "18:22 left"   | "Couldn't save focus data"  | "Break?"/"Focus?"
  Meeting card    | hidden (D5)                 | "in 18 min", Join            | sign-in expired: hidden     | hidden after end
  History row     | flyout shows hint (D5, D14) | newest item on top of flyout | n/a                         | n/a
  Drop zone       | dashed zone (D15)           | name, bar, Stop (D6)         | failure line in the row     | "Open Transcript"
  Drop zone drag  | violet, "Release to…" (D15) | n/a                          | unsupported file: grey, "Only audio or video" | n/a
  Footer          | 🐞 version · Quit           | n/a                          | n/a                         | "Update to x" pill (D7)
```

### Journey (Pass 3)

```
  STEP | USER DOES                          | USER FEELS             | DESIGN SUPPORTS IT WITH
  -----|------------------------------------|------------------------|-------------------------------
  1    | First launch, clicks the icon      | "what is this?"        | problem card: Grant access (D4)
  2    | Grants access, opens again         | ready to try           | History hint (D5), notch tip (D17)
  3    | Selects text, presses ⌥ .          | delight, it talks      | activity card Speaking, Stop
  4    | Week 2: opens panel mid-meeting day| "what's next, stay on" | meeting Join, Keep Awake tile
  5    | Something fails                    | annoyed                | one red card, one fix (D4)
  6    | Month 3: rarely opens it           | it stays out of my way | panel unchanged, keys = muscle memory
```

5-second read: status and Stop. 5-minute: toggles and Join. Long term: the keys are learned,
so the panel is mostly a remote for Keep Awake, Pomodoro and meetings.

## Canvas

Reviewed design, third row of the canvas: Idle light, Idle dark, Busy (dictating, focusing,
transcribing, update ready), First run, Keep Awake chevron open, History hover flyout, file
dragged over the drop zone, and the Panel component
whose state and dark mode switch in Tweaks. The first two rows are earlier drafts.

## NOT in scope

- Dictation and smart read results inside the panel (answers stay in History and the paste
  shortcuts; the panel shows state, not content).
- Replacing the separate Pomodoro, Meetings and Keep Awake menu bar items or their popups.
- A DESIGN.md for the whole app: the palette lives here until /design-consultation runs.
- Settings redesign (planned separately after the nightly channel, see memory).

## What already exists

- `MenuBarView.swift` actions, error actions and the `line(_:)` shortening helper.
- `KeepAwakeMenuItems`, `PomodoroMenuItems`, `PomodoroControls`: the content of both chevron
  menus, reused as-is inside SwiftUI `Menu`.
- `FocusMenuView` (`.menuBarExtraStyle(.window)` precedent, stays open after clicks).
- `HistoryFormat.menuTitle`, `HistoryWindow.present`, `TranscriptWindow.present`,
  `FeedbackWindow.present`, `Updater`, `StableInstaller`, `BuildStamp`, `NextMeetingMenu` data.
- Website palette in website/src/styles/global.css (D9).

## TODOS.md updates

None proposed: every gap found was decided in this review.

## Implementation Tasks

Synthesized from this review's findings. Effort assumes features ~30x human ÷ CC.

- [ ] **T1 (P1, human: ~1d / CC: ~30min)** — Popover shell — replace the NSMenu with a
  `.window` MenuBarExtra at 330 pt, hierarchy and D9 tokens (light and dark)
  - Surfaced by: Pass 1 hierarchy, Pass 5 D9
  - Files: VibeFlow/MenuBarView.swift, VibeFlow/VibeFlowApp.swift
  - Verify: build; panel width fixed with a 2,000-character answer in history
- [ ] **T2 (P1, human: ~4h / CC: ~15min)** — Top slot — Ready line, activity card, problem
  card with priority order
  - Surfaced by: Pass 2 D3, D4
  - Files: VibeFlow/MenuBarView.swift (or a new PopoverView.swift)
  - Verify: Dev build: dictate, smart read, long selection (Read anyway), revoke Accessibility
- [ ] **T3 (P1, human: ~4h / CC: ~15min)** — Tiles — Keep Awake and Pomodoro toggles with
  chevron menus reusing the existing menu items; remember last Keep Awake duration
  - Surfaced by: Pass 7 D11, D12
  - Files: VibeFlow/MenuBarView.swift, VibeFlow/KeepAwakeViews.swift, Preferences
  - Verify: click toggles, chevron menus open inside the panel without closing it
- [ ] **T4 (P1, human: ~2h / CC: ~10min)** — Closing and focus — close on hand-off and on
  any global shortcut; paste target never the panel
  - Surfaced by: Pass 7 D13, learning dictation-target-resolved-late
  - Files: VibeFlow/AppContainer.swift, VibeFlow/MenuBarView.swift
  - Verify: Dev build: open panel, finish a dictation, text lands in the previous app
- [ ] **T5 (P2, human: ~3h / CC: ~10min)** — History row with hover flyout and empty hint,
  meeting card hiding
  - Surfaced by: D14 (replaces D2), Pass 2 D5
  - Files: VibeFlow/MenuBarView.swift, VibeFlow/HistoryViews.swift, VibeFlow/MeetingsViews.swift
  - Verify: fresh history file shows the hint with the user's real key
- [ ] **T6 (P2, human: ~2h / CC: ~10min)** — Transcribe row progress and footer (bug icon,
  version as update control, nightly menu, Dev stamp)
  - Surfaced by: Pass 2 D6, D7
  - Files: VibeFlow/MenuBarView.swift, VibeFlow/Updater.swift
  - Verify: Release and Debug builds show the right footer
- [ ] **T8 (P1, human: ~4h / CC: ~20min)** — Drop zone and menu bar icon as a drop target
  - Surfaced by: D15
  - Files: VibeFlow/MenuBarView.swift, VibeFlow/VibeFlowApp.swift, VibeFlow/FileTranscriptions.swift
  - Verify: drag a .m4a from Finder onto the icon: panel opens, drop starts the job; drop a
    .pdf: refused with "Only audio or video"
- [ ] **T9 (P2, human: ~2h / CC: ~10min)** — Notch hold tip
  - Surfaced by: D17
  - Files: VibeFlow/NotchIndicator.swift, VibeFlow/AppContainer.swift
  - Verify: the tip shows on smart read taps 1 to 3 with the real key, and never after a hold
- [ ] **T7 (P2, human: ~3h / CC: ~15min)** — Keyboard and VoiceOver
  - Surfaced by: Pass 6 D10
  - Files: VibeFlow/MenuBarView.swift
  - Verify: Tab through every control, VoiceOver reads tile state, Reduce Motion stops the meter

## Design Review Completion Summary

```
  +====================================================================+
  |         DESIGN PLAN REVIEW — COMPLETION SUMMARY                    |
  +====================================================================+
  | System Audit         | no DESIGN.md; UI scope: menu bar popover    |
  | Step 0               | 5/10, all 7 passes                          |
  | Pass 1  (Info Arch)  | 6/10 → 9/10 after fixes                     |
  | Pass 2  (States)     | 3/10 → 9/10 after fixes                     |
  | Pass 3  (Journey)    | 6/10 → 8/10 after fixes                     |
  | Pass 4  (AI Slop)    | 6/10 → 8/10 after fixes                     |
  | Pass 5  (Design Sys) | 3/10 → 8/10 after fixes                     |
  | Pass 6  (Responsive) | 2/10 → 8/10 after fixes                     |
  | Pass 7  (Decisions)  | 3 resolved (2 by reviewer, open to veto), 0 deferred |
  +--------------------------------------------------------------------+
  | NOT in scope         | written (4 items)                           |
  | What already exists  | written                                     |
  | TODOS.md updates     | 0 items proposed                            |
  | Approved Mockups     | 0 generated (designer has no image key); canvas used |
  | Decisions made       | 10 by the user (D2–D11), 2 by the reviewer (D12, D13) |
  | Decisions deferred   | 0                                           |
  | Overall design score | 2/10 → 8/10                                 |
  +====================================================================+
```

Pass 4 notes: classified OPERATE (app UI). SF Pro is kept on purpose: it is the platform
face of a native Mac app, not a skipped choice. Coloured circles on tiles carry on/off state,
as in Control Center, so they stay. The indigo is the app icon's colour, not a default.

### Unresolved Decisions

- D12 Pomodoro tile behaviour: decided by the reviewer after two "no preference" answers;
  stands unless the user vetoes.
- D13 Closing and focus: decided by the reviewer; stands unless the user vetoes. The paste
  part needs a Dev build check (T4).

## Eng review (2026-11-05)

Target: docs/designs/menu-bar-popover.md (this plan), reviewed by /plan-eng-review.

Scope record: feature answers: none proposed (no cuts); structure: A (Original arrangement,
D1 answered after a bounded investigation); accepted scope: D3–D17 as designed, built as a new
VibeFlow/Popover/ folder (StatusItemController, PopoverView, parts file), Core PanelState plus
tests, edits to VibeFlowApp, StatusItemRightClick, FileTranscriptions, Updater, AppContainer,
NotchIndicator, Preferences, KeepAwakeViews, HistoryViews, MeetingsViews; pending remedies:
R1, R2, R3, R4.

Reality rows:
```
REALITY: premise-table finding 8 claims, unverified=3 (Finder click closes panel; SwiftUI Menu inside a popover panel; hover flyout) docs/designs/menu-bar-popover.md:D13-D15
REALITY: already-done finding origin/main 0d03f0b (#40) adds StatusItemRightClick indexed by status window order; branch must merge it VibeFlow/StatusItemRightClick.swift:24
REALITY: surface-check finding MenuBarExtraAccess exists (1.3.0) but PR #26 reports macOS 27 breakage; NSStatusItem/NSPanel are stable AppKit
REALITY: binding-decisions pass no branch decisions; memory "menu bar model" (Focus/Meetings/Keep Awake items only while active) kept
REALITY: numbers pass all efforts and sizes tagged [estimated]; no measured baselines cited
REALITY: deferred-asks pass no linked issue
REALITY: pr-count pass one PR (no ship-policy file)
```

## Decision ledger

### R1: Who owns the VibeFlow menu bar icon and panel
Finding: 1, CRITICAL, confidence 8/10, VibeFlowApp.swift:17 (`MenuBarExtra {`) and
StatusItemRightClick.swift:12 on main ("MenuBarExtra hands out no NSStatusItem"); reviewer:
Claude (Scope Challenge, surface-check)
Plan baseline: D13 (close from code, close on shortcuts) and D15 (icon accepts file drops) assume
access SwiftUI's MenuBarExtra does not give; no mechanism chosen.
Runtime evidence: MenuBarExtra has no status item or close API (main's StatusItemRightClick works
around it with an event monitor). MenuBarExtraAccess 1.3.0 adds both, but its PR #26 reports that
macOS 27 "broke pretty much everything" and programmatic presentation is flaky. Whether a
`.window` MenuBarExtra makes VibeFlow the frontmost app while open: unknown (not probed).
Comparison grid:

| Choice | Current | A) Own status item and panel | B) MenuBarExtra + MenuBarExtraAccess |
|---|---|---|---|
| R1 owner of icon and panel | MenuBarExtra (VibeFlowApp.swift:17) | own NSStatusItem + NSPanel hosting the SwiftUI view | MenuBarExtra(.window) + MenuBarExtraAccess package |
| Close from code (D13) | impossible | panel.orderOut, reliable | isPresented binding, reported flaky on macOS 27 |
| Icon accepts file drops (D15) | impossible | dragging-destination view on the status button | same view, via the package's status item closure |
| Frontmost app while open | unknown | stays the user's app (non-activating panel, like NotchIndicator) | unknown |
| New dependency | none | none | +1 SPM package |
| Effort | — | human ~1d / CC ~40 min [estimated] | human ~4h / CC ~20 min [estimated] |
| R3 right-click on new icon | pending | pending | pending |
| R2 panel state in Core | pending | pending | pending |

Question D2:
D2 — Who should own the VibeFlow menu bar icon and panel?
Project/branch/task: modal-size-tabs-58d315, menu bar popover (docs/designs/menu-bar-popover.md, D13, D15).
ELI10: Two approved behaviours need control SwiftUI's MenuBarExtra doesn't give: closing the panel from code (D13) and accepting a file dropped on the icon (D15). The MenuBarExtraAccess package adds both, but its own pull request says macOS 27 broke most of it. Owning the icon and panel ourselves uses plain AppKit that VibeFlow already uses for the notch, and it also keeps your app frontmost while the panel is open, so reads and pastes never target VibeFlow.
Stakes if we pick wrong: with the package, closing, shortcuts and drops can silently break on the next macOS, which is exactly the "does it work reliably" risk.
Recommendation: A because it relies only on stable AppKit, adds no dependency and fixes the focus question at the source.
Completeness: A=10/10, B=6/10
Pros / cons:
A) Own status item and panel (recommended)
  ✅ NSStatusItem and NSPanel are long-stable AppKit; NotchIndicator already uses a non-activating panel
  ✅ Panel never activates VibeFlow, so the selection and the paste target stay in your app
  ❌ About 150 more lines of AppKit glue than the package route (human ~1d / CC ~40 min)
B) MenuBarExtra + MenuBarExtraAccess
  ✅ Smallest change: keep the SwiftUI scene and add one modifier (human ~4h / CC ~20 min)
  ✅ Package also exposes the status item, so the drop view can attach to it
  ❌ New dependency whose PR #26 reports macOS 27 breaking presentation; focus behaviour unknown
Net: a day of AppKit now versus depending on a package that already broke on the next macOS.
Header: Icon owner
Options:
A) Own status item (recommended)
NSStatusItem plus a non-activating NSPanel hosting the SwiftUI panel (like NotchIndicator). Close from code, file drops on the icon, focus stays in your app. No new dependency. Human ~1d / CC ~40 min.
B) MenuBarExtraAccess
Keep MenuBarExtra(.window) and add the MenuBarExtraAccess package for closing and the status item. Smaller change (human ~4h / CC ~20 min), but its PR #26 reports macOS 27 breakage and the focus behaviour is unknown.

State: approved
Actual answer: A) Own status item (D2, 2026-11-05)
Accepted scope: Replace the VibeFlow MenuBarExtra with an own NSStatusItem and a non-activating
NSPanel hosting the SwiftUI panel (pattern of NotchIndicator). The panel closes from code
(D13), the status button carries a dragging-destination view (D15), and opening the panel never
makes VibeFlow the frontmost app. No new dependency. The other four MenuBarExtras stay.
History: none

### R3: Right-click on the new VibeFlow icon (from main #40)
Finding: 2, CRITICAL, confidence 9/10, StatusItemRightClick.swift:18 on main
(`private static let tabs: [SettingsTab?] = [nil, .clocks, .meetings, .pomodoro, .keepAwake]`)
and :26 (`statusWindows().firstIndex(of: window)`); reviewer: Claude (Scope Challenge, already-done)
Plan baseline: the plan does not mention right-click; main's #40 makes right-click on any VibeFlow
item open or close Settings, mapping items by the order of the app's status bar windows.
Runtime evidence: with R1 the VibeFlow icon is no longer MenuBarExtra #0, so the window order
the monitor relies on changes; behaviour after the change: unknown until built.
Comparison grid:

| Choice | Current (main) | A) Icon handles its own right-click | B) Monitor maps the new icon by identity |
|---|---|---|---|
| R3 who handles right-click on the VibeFlow icon | StatusItemRightClick, index 0 | StatusItemController (button sends on right mouse up) | StatusItemRightClick, matching statusItem.button.window |
| Other four items' right-click | index 1–4 | monitor skips the VibeFlow window, tabs list drops its nil entry | unchanged list, VibeFlow window special-cased |
| Behaviour kept | right-click toggles Settings (last tab) | same | same |
| R1 owner | — | approved A (D2) | approved A (D2) |
| R2 panel state in Core | pending | pending | pending |

Question D3:
D3 — How should right-click on the new VibeFlow icon keep opening Settings (from main's #40)?
Project/branch/task: modal-size-tabs-58d315, menu bar popover after merging main's right-click feature.
ELI10: Main just added "right-click any VibeFlow menu bar item opens or closes Settings". It finds the clicked item by counting the app's menu bar windows in a fixed order, and the VibeFlow icon is number 0. Our new own icon changes that order, so the count would point at the wrong items. Either the new icon handles its own right-click, or the old counter learns to recognise it.
Stakes if we pick wrong: right-clicking the clock could open the wrong Settings tab, or right-clicking VibeFlow could open its panel instead.
Recommendation: A because one owner per click is explicit, and the counter stays a plain list of the four SwiftUI items.
Note: options differ in kind, not coverage — no completeness score.
Pros / cons:
A) Icon handles its own right-click (recommended)
  ✅ The controller that owns the icon decides left vs right click, no window counting for it
  ✅ StatusItemRightClick keeps a simple list of the four remaining SwiftUI items
  ❌ Two places implement "right-click opens Settings", one for the icon and one for the others
B) Monitor recognises the new icon
  ✅ One place still handles every right-click in the menu bar
  ❌ The monitor needs a special case for the VibeFlow window next to its order-based list
Net: explicit ownership per icon versus one monitor with a special case.
Header: Right-click
Options:
A) Icon handles it (recommended)
The new status item controller opens or closes Settings on right-click or Control-click (last tab used); StatusItemRightClick drops the VibeFlow entry and maps only the clock, meetings, Pomodoro and Keep Awake items. Human ~1h / CC ~5 min.
B) Monitor recognises it
StatusItemRightClick keeps handling all right-clicks and special-cases the VibeFlow window by identity (statusItem.button.window) before its order-based list. Human ~1h / CC ~5 min.

State: approved
Actual answer: A) Icon handles it (D3, 2026-11-05)
Accepted scope: StatusItemController opens or closes Settings on right-click or Control-click of
the VibeFlow icon (Settings on its last tab); StatusItemRightClick's tabs list drops the VibeFlow
entry and maps only the clock, meetings, Pomodoro and Keep Awake items. Merge origin/main (#40)
into the branch first.
History: none

Scope Challenge result: scope accepted as-is.

### R2: Where the panel's rules live
Finding: 3, INFORMATIONAL, confidence 8/10, MenuBarView.swift:31-48 (status and error branches
inline in the view: `if container.showsDictation { Text(line(dictation.status))`); reviewer:
Claude (Section 2)
Plan baseline: D3/D4 define a priority order (activity outranks a past error; Accessibility,
Microphone, API key, last error), D7 footer states, D11 last duration, D17 tip count. The plan
names no home for these rules; the D1 layout lists a Core PanelState but D1 approved no remedy.
Runtime evidence: today the equivalent rules sit inside MenuBarView's body and have no tests;
VibeFlowCore has Swift Testing with 40 test files (e.g. KeepAwakeTests, FocusTests).
Comparison grid:

| Choice | Current | A) PanelState in VibeFlowCore | B) Rules inside the SwiftUI view |
|---|---|---|---|
| R2 home of priority and state rules | inline in MenuBarView body | pure `PanelState` value built from inputs, in VibeFlowCore | computed properties in PopoverView |
| Tests | none | swift test cases for priority order, footer, tile text, tip count | none (manual QA only) |
| Effort | — | human ~4h / CC ~20 min [estimated] | human ~2h / CC ~10 min [estimated] |
| R1, R3 | — | approved (D2, D3) | approved (D2, D3) |

Question D4:
D4 — Where should the panel's rules live (which card shows, problem order, footer and tile text)?
Project/branch/task: modal-size-tabs-58d315, menu bar popover rules from D3, D4, D7, D11, D17.
ELI10: The panel has real rules: a running dictation beats an old error, missing Accessibility beats a missing API key, the footer shows an update pill only when one exists, the tip shows three times. Put them in a small pure type in VibeFlowCore and they get fast unit tests like the rest of Core; leave them in the SwiftUI view and only clicking around can check them.
Stakes if we pick wrong: a wrong priority shows an old error over a running dictation, or hides a missing permission, and nothing catches it.
Recommendation: A because every rule then has a test that fails when the order breaks, at little extra cost.
Completeness: A=10/10, B=5/10
Pros / cons:
A) PanelState in VibeFlowCore (recommended)
  ✅ Priority, footer and tile rules run under swift test in seconds, like KeepAwakeTests
  ✅ The SwiftUI view stays a thin renderer of one value, easier to read and change
  ❌ One more type and a mapping from app objects into it (human ~4h / CC ~20 min)
B) Rules inside the SwiftUI view
  ✅ Fewer types: the view reads container state directly (human ~2h / CC ~10 min)
  ❌ No automated test for any priority or footer rule; regressions surface only by hand
Net: a small type with tests versus untested rules in the view.
Header: Panel rules
Options:
A) PanelState in Core (recommended)
A pure PanelState value in VibeFlowCore, built from session, dictation, permissions, files, updater and preferences; it decides the top slot, problem order, tile text, footer and tip display. Swift Testing cases cover each rule. Human ~4h / CC ~20 min.
B) Rules in the view
PopoverView reads the container directly and decides everything in computed properties. No new type, no automated tests for the rules. Human ~2h / CC ~10 min.

State: approved
Actual answer: A) PanelState in Core (D4, 2026-11-05)
Accepted scope: A pure PanelState value in VibeFlowCore, built from session, dictation,
permissions, files, updater and preferences; it decides the top slot, problem order, tile text,
footer and tip display. Swift Testing cases cover each rule.
History: none

### R4: Regression contract for replacing today's menu
Finding: 4, CRITICAL, confidence 9/10, MenuBarView.swift:25-160 (the whole current menu body,
e.g. `Button(label(for: action)) { perform(action) }.disabled(dictation.state.isBusy)` and
`if case .awaitingConfirm(_, .menu, _) = session.state { Button("Read anyway")`); reviewer:
Claude (Section 3, regression rule)
Plan baseline: D3–D17 describe the new panel; no list of today's behaviours that must survive.
Runtime evidence: today's menu (this branch) has the behaviours listed below; none has an
automated test (no app-target tests exist).
Contract (behaviour to preserve → where it lives after the change → acceptance):
1. Status text for read and dictation, shortened to one line → top slot → PanelState test + QA
2. Error actions (Open Settings > Accounts, Read original, Grant access, Retry, Copy text, Discard,
   Open Dictation settings, Open Microphone settings); dictation actions disabled while dictation
   is busy → problem card → PanelState test for action list + disabled flag
3. Stop (⌘.) only while something runs → activity card → PanelState test
4. Read anyway only for `.awaitingConfirm(_, .menu, _)` → activity card button → PanelState test
5. Grant Accessibility / Microphone when missing → problem card (D4 order) → PanelState test
6. File transcription: status and detail lines, Stop, Open Transcript after finishing, one job at a
   time (a second drop or icon drop while running is refused) → drop zone / progress row →
   PanelState test + QA
7. History: a read plays again, a question opens the History window on it, a transcript opens its
   window → History flyout → QA
8. Send Feedback hidden when the Sentry DSN is empty; Settings ⌘,; Quit ⌘Q naming the app (Dev too)
   → footer → PanelState test (feedback flag) + QA
9. Release: version, Check for Updates, nightly Back to Stable with its progress step; Debug: the
   build stamp → footer (D7) → PanelState test
10. Pomodoro and Keep Awake controls, next meeting Join and Open in Google Calendar (card click)
    → tiles, chevrons, meeting card → QA
11. Right-click opens or closes Settings → R3 → QA
Intentional changes (approved earlier): read, smart read, clipboard read, dictation and paste
actions leave the panel (D16, keyboard only); the last-answer block and Copy answer go (removed
earlier this session); History list becomes the flyout (D14); Transcribe File row becomes the drop
zone (D15).
Comparison grid:

| Choice | Current | A) Adopt the contract | B) Adopt without item 10's calendar link |
|---|---|---|---|
| R4 behaviours preserved | implicit, untested | items 1–11 with the listed acceptance | items 1–11 except "Open in Google Calendar" |
| Tests | none | PanelState tests for 1–6, 8, 9; QA checklist for 7, 10, 11 | same minus the calendar link check |
| R1, R2, R3 | — | approved (D2, D4, D3) | approved (D2, D4, D3) |

Question D5:
D5 — Adopt this list of today's menu behaviours that the new panel must keep?
Project/branch/task: modal-size-tabs-58d315, replacing MenuBarView's menu with the popover.
ELI10: Replacing the whole menu risks quietly losing small things it does today: the error buttons, "Read anyway", the nightly "Back to Stable", hiding Feedback when it's off. I listed 11 behaviours that must survive, where each lives in the new panel, and how each is checked (unit tests for the rules, a short manual checklist for clicks). The removals you already chose (read actions, Copy answer) are listed as intentional.
Stakes if we pick wrong: a rarely used action, like Back to Stable on a broken nightly, disappears and nobody notices until it is needed.
Recommendation: A because each item is cheap to keep and the list turns "nothing got lost" into a checkable claim.
Completeness: A=10/10, B=9/10
Pros / cons:
A) Adopt the contract (recommended)
  ✅ All 11 behaviours named with a home and a check; nothing survives by luck
  ✅ Rules 1–6, 8 and 9 get unit tests through PanelState (D4)
  ❌ The meeting card needs a second action (card click opens Google Calendar) besides Join
B) Adopt without the calendar link
  ✅ Meeting card keeps one action (Join), slightly simpler to build and explain
  ❌ Opening the event in Google Calendar from the menu bar disappears, which works today
Net: keep everything the menu does today, or drop the one link that complicates the card.
Header: Regressions
Options:
A) Adopt the contract (recommended)
Keep behaviours 1–11 as listed, each with its new home; PanelState tests cover 1–6, 8 and 9, a manual QA checklist covers 7, 10 and 11. Human ~2h / CC ~15 min for the tests.
B) Without calendar link
Same contract, but the meeting card only offers Join; "Open in Google Calendar" is dropped from the menu bar. Human ~2h / CC ~15 min.

State: approved
Actual answer: A) Adopt the contract, in the user's words: "We need to implement all those
features" (message in place of the D5 buttons, 2026-11-05)
Accepted scope: Keep behaviours 1–11 as listed, including Open in Google Calendar on the meeting
card; PanelState tests cover 1–6, 8 and 9, a manual QA checklist covers 7, 10 and 11. The user
also asked for an interactive prototype of the panel before building (see Prototype below).
History: none

### R5: Hidden panel re-rendering every second
Finding: 5, INFORMATIONAL, confidence 6/10 (medium confidence, verify), FocusTimer.swift:135-137
(`try? await Task.sleep(for: .seconds(1))` then `now = Date()`); reviewer: Claude (Section 4)
Plan baseline: none; with R1 the panel is an NSPanel that could keep its SwiftUI view alive while
hidden.
Runtime evidence: FocusTimer advances `now` every second while a round runs; a live hosting view
reading it would re-render while the panel is hidden. Cost unmeasured.
Proposed remedy (unasked; the user moved to the prototype): build the hosting view when the panel
opens and release it when it closes, so nothing renders while hidden (human ~30 min / CC ~5 min).
State: built as recommended (StatusItemController.open/close create and drop the hosting view);
the user approved building the prototype as a whole ("Let's build it out"), not R5 by itself.
Actual answer: none to R5 itself
Accepted scope: hosting view exists only while the panel is open
History: none

Approval readiness: PASS for R1 (D2), R2 (D4), R3 (D3), R4 (D5 message); R5 pending.

## Eng review sections

**Section 1, Architecture:** no findings beyond R1 and R3. Flow:

```
 left click ─┐                          ┌─▶ panel.orderFront (non-activating NSPanel, canBecomeKey)
 right click ┼─▶ StatusItemController ──┼─▶ SettingsWindow open/close (R3)
 file drag ──┘   (owns NSStatusItem,    └─▶ drag enters: open panel, zone highlights (D15)
                  panel, flyout)              drop on icon: files.use(url) → options window
 global shortcut ─▶ AppContainer.hotkey ─▶ controller.close() first (D13) ─▶ capture selection
 outside click / Esc / Space change ─▶ controller.close()
 hover "History" ─▶ child NSPanel flyout (addChildWindow), hover intent keeps it open
```

Design twice: StatusItemController owns all panel state (picked) versus AppContainer holding
`isPanelOpen` (rejected: two writers of one state, red flag 5). No other red flags.

**Section 2, Code quality:** R2 (approved). One-job-at-a-time for file transcription is existing
behaviour, kept by R4 item 6.

**Section 3, Tests:** framework Swift Testing in VibeFlowCore (`cd VibeFlowCore && swift test`);
the app target has no tests.

```
CODE PATHS (proposed)                                   USER FLOWS
[+] VibeFlowCore PanelState                              [+] Open panel, act, close
  ├── topSlot: ready / activity / problem               ├── [GAP] [QA] click icon → panel, Esc closes
  │   ├── [GAP] activity outranks past error (D4)       ├── [GAP] [QA] outside click closes
  │   ├── [GAP] Accessibility > Mic > key > error       ├── [GAP] [QA] shortcut closes panel first
  │   ├── [GAP] Read anyway only for .menu confirm      ├── [GAP] [QA] dictation finishing while
  │   └── [GAP] dictation actions disabled while busy   │          open pastes into previous app
  ├── tiles: Keep Awake / Pomodoro text                 [+] History flyout
  │   └── [GAP] last duration, first time Indefinitely  ├── [GAP] [QA] hover opens, pointer can
  ├── fileRow: idle / dragging / running / done          │          travel into it
  │   └── [GAP] second drop refused while running       └── [GAP] [QA] empty history hint
  ├── footer: feedback flag, version / pill / nightly   [+] Drop zone and icon drop
  │   └── [GAP] pill only when update known             ├── [GAP] [QA] drag over icon opens panel
  └── notchTip: taps 1–3, never after a hold            └── [GAP] [QA] non-audio refused
      └── [GAP] counter stops after a hold              [+] Right-click icon toggles Settings [QA]
COVERAGE: 0/9 code paths, 0/9 flows (all proposed)  |  GAPS: 9 unit, 9 manual QA
```

Proposed tests (one Swift Testing file, VibeFlowCore/Tests/VibeFlowCoreTests/PanelStateTests.swift,
table-driven):
- Value: protects=activity card outranks a past error; fails_when=priority order is swapped; why_new=no test covers menu state; seam=none; no_claim=real AppKit panel behaviour
- Value: protects=problem order Accessibility, Microphone, API key, last error; fails_when=order changes or one is dropped; why_new=none exists; seam=none; no_claim=permission prompts themselves
- Value: protects=Read anyway only for .menu confirms; fails_when=shown for hotkey confirms; why_new=MenuBarView logic untested; seam=none; no_claim=none beyond protects
- Value: protects=dictation error actions disabled while busy; fails_when=Retry clickable mid-paste; why_new=untested today; seam=none; no_claim=clipboard behaviour
- Value: protects=Keep Awake tile uses last duration, Indefinitely first; fails_when=default changes; why_new=KeepAwakeTests cover timing only; seam=none; no_claim=IOKit assertion
- Value: protects=second file refused while a job runs; fails_when=two jobs start; why_new=FileTranscriptionJobTests cover one job; seam=none; no_claim=decoding real files
- Value: protects=footer feedback hidden without DSN, pill only with a known update, nightly menu; fails_when=pill shows with no update; why_new=untested; seam=none; no_claim=Sparkle network check
- Value: protects=notch tip on taps 1–3 and never after a hold; fails_when=tip shows forever; why_new=new rule; seam=none; no_claim=notch drawing
Tests made obsolete: none.

**Section 4, Performance:** R5 (pending). No other per-request or looped paths; the History
flyout reads the 5 newest of an in-memory list.

**Outside voice:** skipped; the user redirected to building the prototype.

## Prototype (requested 2026-11-05)

An interactive panel on the canvas ("Prototype: click everything", row 5), source copied to
docs/designs/menu-bar-popover-prototype.dc.html. Left: the menu bar and panel, all clickable
(icon click, right-click, file drag onto the icon or the zone, tiles and chevrons, meeting card
and Join, History hover, footer). Right: a simulator for activity, problems, context and build,
the PanelState rules in effect, and a log of what the real app would do.

Port map:
- `panelState(s)` → `PanelState.make(...)` in VibeFlowCore; its `ACT` and `PROB` tables and the
  problem `order` array become the Swift enums and ordering; each `rules.push` line is a
  PanelStateTests case.
- Elements marked `data-swift="…"` name the SwiftUI view or AppKit piece: TopSlotView,
  TilesView (chevrons reuse KeepAwakeMenuItems and PomodoroMenuItems), MeetingCardView,
  HistoryRowView + HistoryFlyout (child NSPanel), FileRowView, FooterView, and
  StatusItemController.button for the icon.
- Colour tokens are the D9 table; sizes are the D9 type and radius values.

## Eng review: NOT in scope

- MenuBarExtraAccess (rejected in R1).
- Changing the four other menu bar items beyond R3's right-click list.
- App-target UI tests (no UI test target exists; manual QA covers clicks).

## Eng review: failure modes

| Path | Realistic failure | Covered by | User sees |
|---|---|---|---|
| Panel open/close | outside click not seen | global mouse monitor + QA | panel stays, visible |
| Shortcut while open | capture reads the panel | close first (D13), non-activating panel (R1) | correct text |
| Dictation finishes while open | paste into panel | non-activating panel keeps frontmost app (R1) + QA | text in the right app |
| Flyout | closes while pointer travels | hover intent + QA | flyout flickers, visible |
| Icon drop | non-audio file | D15 refusal + PanelState test | "Only audio or video" |
| Hidden panel | per-second re-render | R5 (pending) | nothing visible, CPU only |

Critical gaps: 0.

## Eng review: parallelization

| Step | Modules touched | Depends on |
|---|---|---|
| Merge main (#40) | app | — |
| PanelState + tests | VibeFlowCore | — |
| StatusItemController, panel, flyout, drop | VibeFlow/Popover | merge |
| PopoverView and parts | VibeFlow/Popover | PanelState |
| Notch tip | VibeFlow (NotchIndicator), VibeFlowCore Preferences | PanelState |

Lane A: PanelState + tests (VibeFlowCore). Lane B: merge main, then StatusItemController
(VibeFlow/Popover). Then PopoverView, then the notch tip. Conflict flag: both lanes touch
Preferences only if the tip counter lands in Lane A; keep it in Lane A.

## Eng review: Implementation Tasks

- [ ] **E1 (P1, human: ~30min / CC: ~5min)** — Branch — merge origin/main (#40) before building
  - Surfaced by: Scope Challenge, already-done (0d03f0b)
  - Verify: build passes; right-click on the clock still opens Settings > Clocks
- [ ] **E2 (P1, human: ~1d / CC: ~40min)** — StatusItemController — own NSStatusItem, non-activating panel, flyout, icon drop, right-click
  - Surfaced by: R1, R3
  - Files: VibeFlow/Popover/StatusItemController.swift, VibeFlow/VibeFlowApp.swift, VibeFlow/StatusItemRightClick.swift
  - Verify: QA items 7, 10, 11 and the open/close flows
- [ ] **E3 (P1, human: ~4h / CC: ~20min)** — PanelState in VibeFlowCore with PanelStateTests
  - Surfaced by: R2, R4
  - Files: VibeFlowCore/Sources/VibeFlowCore/Settings/PanelState.swift (or a Panel/ folder), VibeFlowCore/Tests/VibeFlowCoreTests/PanelStateTests.swift
  - Verify: `cd VibeFlowCore && swift test`
- [ ] **E4 (P2, human: ~30min / CC: ~5min)** — Release the panel's view while hidden (only if R5 is approved)
  - Surfaced by: R5
  - Files: VibeFlow/Popover/StatusItemController.swift

## GSTACK REVIEW REPORT

| Review | Trigger | Why | Runs | Status | Findings |
|--------|---------|-----|------|--------|----------|
| CEO Review | `/plan-ceo-review` | Scope & strategy | 0 | — | — |
| Outside Review | not run | Independent 2nd opinion | 0 | skipped | — |
| Eng Review | `/plan-eng-review` | Architecture & tests (required) | 1 | issues_open | 3 issues, 0 critical gaps (R2, R4 approved; R5 pending; 9 coverage gaps planned as tests and QA) |
| Design Review | `/plan-design-review` | UI/UX gaps | 1 | issues_open | score: 5/10 → 8/10, 10 decisions |
| DX Review | `/plan-devex-review` | Developer experience gaps | 0 | — | — |

- **OUTSIDE COVERAGE:** design phase: not offered. Eng phase: skipped, the user redirected to the
  prototype. Missing coverage, not a pass.
- **VERDICT:** no review CLEAR; eng review has one pending decision (R5). D15's feasibility
  question is settled by R1 (own status item accepts drops).

**UNRESOLVED DECISIONS:**
- R5 built as recommended without its own answer (eng); revert is one line if unwanted
- D12 Pomodoro tile behaviour (design, reviewer's call, open to veto)
- D13 Closing and focus (design, reviewer's call, open to veto; R1 makes the paste-target risk structural)
