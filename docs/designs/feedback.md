# Design: Send Feedback, with the context to fix it

Drafted 2026-11-02
Status: ENG REVIEWED 2026-11-02 (decisions D1 to D12, see "Eng review decision ledger"); ready to implement after T0
Builds on: BuildStamp (branch, commit, build date), the pinned Settings sidebar, the Stable / Nightly channel

## Problem

VibeFlow has two users: Florian and a friend on the release build. When something breaks
for the friend ("smart read just stopped", "dictation pasted nothing"), the report arrives
as a chat message without the version, channel, the action that failed or the logs, and
the trail is cold by the time Florian looks. Good feedback ("the German clock is great")
gets lost the same way. Crashes are not reported at all.

Goal: one button that sends a short note plus everything needed to reproduce it, and
readable crash reports, into an inbox Florian (and Claude Code, through the Sentry tools)
can work through. Free, no server, nothing for the friend to set up.

## What it does

- **Send Feedback** in two places:
  - a row pinned at the bottom of the Settings sidebar (bottom left), under the pane list;
  - an item in the menu bar menu, because most problems happen after a shortcut, with
    Settings closed.
- Both open the same **Send Feedback window** (its own `Window` scene, opened like
  `HistoryWindow`; a sheet would need a host window, which the menu bar does not have):
  - a kind picker: **Bug** / **Idea** / **Love it**;
  - a text field (dictation works in it, it is a normal text field);
  - **"What gets sent"**, collapsed by default: the exact report text, read-only, so
    nothing leaves the Mac unseen. Logs are captured once, when the window opens (D8), off
    the main thread; while that runs the preview says "Collecting logs…";
  - one line: "VibeFlow also sends crash reports, without your text." (D10);
  - **Copy report**, always available (pastes into any chat);
  - **Send**: the window says "Thanks. It sends now, or as soon as you are online." and
    closes (D6). The SDK keeps unsent reports on disk and retries.
- No screenshot attachment in this version (D9).
- Crashes go to Sentry on their own (D10). A note sent after a crash is not linked to it
  automatically (F9 deferred, D2); both carry the same install id.

## Account and cost (stays at $0)

| | |
|---|---|
| Sentry organization | New personal org (e.g. `floo`), separate from any work organization. EU region (de.sentry.io). Login: a personal or floo.one email (open, decided in T0). |
| Plan | Free **Developer** plan. **No credit card on file**: Sentry cannot bill, events over quota are dropped. A new org may start on a paid-plan trial; with no card it falls back to Developer. |
| Members | Florian only (Developer allows one user). The friend never logs in: the app sends through the DSN. |
| Project | One project, `vibeflow`, platform Apple macOS. |
| Quota guards | Tracing, profiling and replay off in the SDK. A DSN rate limit in project settings (Client Keys > Rate Limiting, e.g. 60 events/hour [estimated]) so a crash loop or abuse of the public DSN cannot use up the month. Spike protection on. |
| Retention | Short on the free plan (verify the current number when the org exists). Sentry is the **inbox, not the archive**: anything worth keeping becomes a GitHub issue or a fix. |

Approximate free quotas at the time of writing (third-party pricing pages, unverified): one
user, about 5,000 errors a month, 1 GB of attachments. Two people send a handful of events a
week. Unverified: whether feedback counts against the error quota; check under Stats once
the org exists.

## What a report contains

Sentry fields are the transport; the content is decided by `FeedbackReport` in
MaagicalCore, not by SDK defaults. Every kind has the same shape (D12).

| Field | Source | Example |
|---|---|---|
| Release | `CFBundleShortVersionString` + `CFBundleVersion` | `vibeflow@1.4.0+3.52` |
| Environment | the running build (D5): Debug → `dev`; Release with a non-empty `VFGitCommit` → `nightly`; else `stable` | `nightly` |
| Tags | kind, channel setting (`update.newestMain` → `stable`/`nightly`), Settings pane open (`AppContainer.settingsTab`), keyboard layout, Accessibility / microphone granted, macOS version | `kind:bug`, `channel:nightly`, `pane:smartRead` |
| BuildStamp | branch, commit, build date (Dev and nightly) | `main @ 7dfb43b, 2026-11-01` |
| Settings snapshot | an explicit allowlist from Preferences: voice provider and model, speed, smart read model, dictation models, shortcuts, channel, world clocks; the dictation vocabulary only as a count | `vocabulary: 12 words` |
| Logs | `vibeflow-log.txt`: last 10 minutes of subsystem `one.floo.vibeflow` via `OSLogStore(scope: .currentProcessIdentifier)`, captured when the window opens, scrubbed, capped at 200 KB keeping the newest lines. If the read fails, the report says "Logs unavailable: <reason>" and still sends. | |
| Message | the note, prefixed with the kind | `[Bug] smart read stops after…` |

"Last action" comes from the log, not from a separate breadcrumb system (D1). The log must
therefore record every action end (D8): VibeFlow adds notice lines for read finish
(provider, voice model, duration, characters), smart read finish (model, duration, outcome)
and voice fallback (from, to, reason). Failures already log.

**Never sent** (enforced in MaagicalCore, unit tested):
- **Rule: logs ship with feedback, so never log user text** (selected text, dictated text,
  smart-read answers, vocabulary words, meeting titles). Written into CLAUDE.md and as a
  comment at FeedbackReport (D4). A probe showed that in-process `OSLogStore` reads return
  every value unredacted, including ones marked private, so the rule, not Logger privacy,
  is what protects reports.
- Provider error bodies: a failure log line carries the provider's JSON `error.message`
  capped at 160 characters; a non-JSON body logs only "non-JSON body, N bytes" (D7). The
  on-screen status text is unchanged.
- The scrub inside `FeedbackReport.render()`: anything shaped like an API key or token is
  replaced (patterns for `sk-`, `sk_`, `gsk_`, `ya29.`, `1//`, long base64 runs), and the
  home folder path becomes `~`. API keys and OAuth tokens live in the Keychain and are
  never read for a report.
- `sendDefaultPii = false`: no IP address, no user name. `user.id` is a random UUID made on
  first launch (UserDefaults), so reports from the same Mac group together.

The same scrub (`FeedbackReport.scrub(_:)`) runs as the SDK's `beforeSend` for crash events.

## Architecture

```
MaagicalCore/Feedback/                 pure, Swift Testing
  FeedbackReport.swift                 the one way to get sendable text:
                                         init(kind, note, facts, logLines)
                                         render() -> scrubbed preview text == sent text
                                         static environment(config:, commit:) -> dev/nightly/stable
                                         static scrub(_:) -> keys and home path removed
                                         log cap (200 KB, newest lines kept)
  FeedbackReportTests.swift
Maagical/Feedback/
  FeedbackSender.swift                 SentrySDK.start (options below), reads OSLogStore off
                                       the main thread, gathers facts, capture(feedback:)
                                       with the log attachment; no-op when no DSN
  FeedbackWindow.swift                 the window (swiftui-pro for review)
Maagical/Settings/SettingsView.swift   sidebar bottom row (safeAreaInset on the List)
Maagical/MenuBarView.swift             "Send Feedback…" item
Maagical/MaagicalApp.swift             Window scene + SDK start
MaagicalCore/Session/ReadSession.swift, smart read path   finish and fallback log lines (D8)
MaagicalCore/Dictation/OpenAITranscriber.swift (+ Anthropic error path)   no raw bodies in logs (D7)
```

Flow:

```
 menu item ─┐                         ┌─ OSLogStore (10 min, off main) ─┐
 sidebar ───┴─> FeedbackWindow opens ─┤                                 ├─> FeedbackReport.render()
                                      └─ facts (build, tags, settings) ─┘         │
                                                                         preview == sent text
                                   Send ─> FeedbackSender.capture(feedback:) ─> SDK disk queue ─> Sentry
                                   Copy report ─> NSPasteboard
 crash ─> SDK crash handler ─> next launch ─> beforeSend: FeedbackReport.scrub ─> Sentry
 release.sh / nightly ─> sentry-cli debug-files upload (dSYMs) ─> Sentry
```

- SDK: `getsentry/sentry-cocoa` via SPM in project.yml, `from:` the current 8.x. Send with
  `SentrySDK.capture(feedback:)`; confirm the `SentryFeedback` initializer and its
  fire-and-forget shape against the installed version in T2.
- DSN: committed as `SENTRY_DSN` in `Config/Maagical.xcconfig`, read through Info.plist
  `SentryDSN: $(SENTRY_DSN)` (F6). xcconfig treats `//` as a comment, so write it as
  `https:/$()/<key>@o<org>.ingest.de.sentry.io/<project>`. Empty DSN → feedback hidden,
  SDK never started (forks, tests).
- Start the SDK in `MaagicalApp.init` after `quitOlderCopies`, in Debug too (environment
  `dev`, D11); `enableAutoSessionTracking` off, `tracesSampleRate = 0`, crash handler on,
  `enableAppHangTracking` on.

## Crash symbols (same PR, D10)

`scripts/release.sh` uploads the archive's dSYMs right after the export, for releases and
nightlies, before anything deletes `build/release` on the next run (release.sh:124):
`sentry-cli debug-files upload --org <org> --project vibeflow <archive>/dSYMs`. `sentry-cli`
is not installed yet (`brew install getsentry/tools/sentry-cli`). The auth token lives in
the login keychain (like the notary profile), read only by release.sh, never in the app.
No token → warning, not failure, unless `--publish` (a published build must have symbols).
`nightly.sh` runs release.sh from a LaunchAgent; check in T5 that it can read the token.

## Decision ledger (design)

| # | Decision | Why |
|---|----------|-----|
| F1 | Sentry User Feedback, personal org, free Developer plan, no card | Chosen 2026-11-02 over a GitHub-token app (token per user, token in a public DMG) and a mail draft (no structure, hard to hand to Claude). No server to run. |
| F2 | Florian is the only member; the friend only sends | Fits the one-user limit; zero setup for the friend. |
| F3 | Crash reporting on, with symbol upload in the same PR and a notice in the form and README | Confirmed in review (D10). Tracing, profiling and replay off. |
| F4 | VibeFlow Dev sends too, as environment `dev` | Confirmed in review (D11). |
| F5 | Preview of the exact report before sending | Nothing hand-sent leaves unseen; crash reports are disclosed instead (D10). |
| F6 | DSN committed, not gitignored | A DSN is send-only and already readable from the shipped app; committing it avoids another file for nightly.sh to copy. Guarded by rate limit. Forks building with it would send to this project: acceptable at this scale, revisit if it happens. |
| F7 | No user text, no keys, no IP; random install id | Enforced by the never-log-user-text rule (D4), the provider body fix (D7) and the scrub. |
| F8 | Sentry is the inbox, GitHub issues are the archive | Free retention is short. |
| F9 | Linking feedback to a preceding crash | Deferred (D2), in TODOS.md. |
| F10 | Copy report always available; Send shows "queued" wording | D6: the SDK queues offline and gives no delivery result. |

## Implementation tasks (from the design; review tasks below refine them)

| # | Task | Done when |
|---|------|-----------|
| T0 | Florian: create the personal Sentry org and `vibeflow` project, no card, set the DSN rate limit and spike protection, create an auth token for dSYM upload and store it in the keychain, `brew install getsentry/tools/sentry-cli` | DSN and token exist |
| T1 | MaagicalCore/Feedback/FeedbackReport.swift with tests | `swift test` green |
| T2 | sentry-cocoa in project.yml, `SENTRY_DSN` plumbing, SDK start, `beforeSend` scrub | Dev build starts, a test event shows up as `dev` |
| T3 | FeedbackWindow + sidebar row + menu item + Copy report + crash notice | Feedback with log attachment visible in Sentry; offline send arrives after reconnect |
| T4 | ~~Breadcrumbs~~ cut (D1); replaced by the log lines of D7 and D8 | |
| T5 | dSYM upload in release.sh (and nightly path), same PR | A test crash in a Release build shows a symbolicated stack trace |
| T6 | Docs: CLAUDE.md (Sentry org, DSN, token, never-log-user-text rule), docs/DEVELOPMENT.md, README data-handling line (feedback and crash reports), CHANGELOG | |

One PR: T1, T2, T3, the log changes, T5, T6.

## Open questions

1. Login for the personal Sentry org: new personal / floo.one email, or the existing Sentry
   login? Decided by Florian in T0; it changes nothing in the code.

## Eng review (2026-11-02)

Target: docs/designs/feedback.md (this file), reviewed with /plan-eng-review.

### Scope record

feature answers: D1 cut breadcrumbs (T4 and the Telemetry seam; "last action" comes from the
existing notice log lines), D2 defer F9 (crash-to-feedback linking becomes a TODO);
structure: B, smaller arrangement (D3): MaagicalCore/Feedback/FeedbackReport.swift (+ tests),
Maagical/Feedback/FeedbackSender.swift, Maagical/Feedback/FeedbackSheet.swift;
accepted scope: T0, T1 (as one FeedbackReport type), T2, T3, T5, T6; T4 cut; F9 deferred;
pending remedies: S2.
Scope Challenge result: scope reduced per recommendation.

### Scope findings

- S1 [CRITICAL] (confidence: 9/10) feedback.md:41 — named the author's two work Sentry
  organizations by name in a public repo (names removed here too).
  Prior learning applied: public-repo-personal-data-in-history. Factual correction, no
  behavior change: replaced with "separate from any work organization". Applied.
- S2 [INFORMATIONAL] (confidence: 9/10) feedback.md "Never sent" — the log privacy model
  is wrong in both directions. Probe (swiftc binary, OSLogStore scope
  .currentProcessIdentifier): `log.notice("default privacy: \(secret)")` came back as
  `default privacy: selected text here`, and `.info` lines were returned too, so Logger
  privacy does not redact in-process reads. Grep: all 31 interpolating log calls in
  VibeFlow and MaagicalCore use `privacy: .public` with metadata only (counts, bundle ids,
  error strings, device names, one app path, AppDelegate.swift:28), none carry selected or
  dictated text. See R1.

## Eng review decision ledger

### R1: How the report keeps user text and keys out of attached logs
Finding: S2, INFORMATIONAL, 9/10, feedback.md "Never sent", reviewer plan-eng-review
Plan baseline: original proposal: "log lines from categories that carry user text are
reduced to metadata (length, language, timing), and any quoted payload is replaced by
`‹N chars›`", plus key-pattern scrub and a 200 KB cap.
Runtime evidence: probe above; no current log line carries user text; in-process reads
are unredacted; AppDelegate.swift:28 logs the app bundle path (contains the home folder,
i.e. the macOS user name).
Comparison grid:
| Choice | Current (draft) | A) Rule + simple scrub | B) Keep as drafted |
|---|---|---|---|
| Category payload redaction | planned | dropped (nothing to redact today) | kept |
| Key-pattern scrub | planned | kept | kept |
| Home folder path → `~` | none | added | none |
| 200 KB cap | planned | kept | kept |
| "Never log user text" rule | none | added to CLAUDE.md and as a comment at FeedbackReport | none |
| Preview before send (F5) | approved in draft | unchanged | unchanged |
Question D4:
D4 — Replace the log redaction plan with a "never log user text" rule plus a simple scrub?
Project/branch/task: feedback-feature-design-af3465, reviewing docs/designs/feedback.md.
ELI10: The plan promised to find your selected or dictated text inside the attached logs and blank it out. A test showed two things: VibeFlow's logs today never contain your text (only counts, app names and errors), and when VibeFlow reads its own logs, macOS hands back everything, even values marked private. So the blanking-out step has nothing to work on today and could not catch a future mistake anyway. The real protection is a rule ("never log user text") plus the preview before sending.
Stakes if we pick wrong: Keep the draft and you build and test a redactor for text that never appears; drop it without the rule and a future log line could quietly ship text in a report.
Recommendation: A because the rule matches how the code already behaves, the preview catches mistakes, and the scrub keeps only checks that have real input (keys, home folder).
Completeness: A=9/10, B=7/10
Pros / cons:
A) Rule + simple scrub (recommended)
  ✅ Scrub covers what can really appear: key-shaped strings and the home folder path (AppDelegate.swift:28)
  ✅ CLAUDE.md rule tells every future change, human or agent, that logs leave the Mac with feedback
  ❌ Protection against a future text log line is a rule plus the preview, not code (human: ~1h / CC: ~10 min)
B) Keep as drafted
  ✅ Redaction code exists in case a future log line does carry text in a recognisable shape
  ✅ No new rule for contributors to remember
  ❌ Builds and tests a redactor with no input today, still misses unquoted text, and leaks the user name
Net: a rule that matches reality versus code that guards an imagined case.
Header: Log privacy
Options:
A) Rule + simple scrub
Drop category redaction. FeedbackReport scrubs key patterns, replaces the home folder with ~, caps at 200 KB. CLAUDE.md gains "logs ship with feedback: never log user text". Tests cover each scrub rule.
B) Keep as drafted
Keep category-based payload redaction to ‹N chars› plus key scrub and cap, with tests for a redaction that has no input today.

State: approved
Actual answer: A) Rule + simple scrub (D4, 2026-11-02)
Accepted scope: drop category-based payload redaction; FeedbackReport scrubs key-shaped
strings, replaces the home folder path with `~`, caps logs at 200 KB; add "logs ship with
feedback: never log user text" to CLAUDE.md and as a comment at FeedbackReport; unit tests
for each scrub rule. Preview before send (F5) unchanged.
History: none

### R2: Which build a report says it came from (environment)
Finding: A1, INFORMATIONAL, 8/10, feedback.md "Environment | Debug build → `dev`; Release
with channel Nightly → `nightly`; else `stable`", reviewer plan-eng-review
Plan baseline: original proposal: environment from build config plus the channel setting
(`update.newestMain`, Preferences.swift:46).
Runtime evidence: the channel setting says what Sparkle will install next, not what is
running: right after switching to Nightly, the stable build still runs. release.sh:139-144
stamps every nightly with `VF_GIT_COMMIT` ("A nightly carries its build number and, like
VibeFlow Dev, the commit it came from"); a stable release has no commit (BuildStamp.swift:16
requires a non-empty `VFGitCommit`).
Comparison grid:
| Choice | Current (draft) | A) From the build | B) From the channel setting |
|---|---|---|---|
| Debug build | dev | dev | dev |
| Release with VFGitCommit | depends on channel | nightly | depends on channel |
| Release without VFGitCommit | depends on channel | stable | depends on channel |
| Channel shown at all | as environment | as a separate `channel` tag | as environment |
| Tests | environment table | environment table on (config, commit) | environment table on (config, channel) |
Question D5:
D5 — Tag reports by the build that is running, not by the update channel setting?
Project/branch/task: feedback-feature-design-af3465, reviewing docs/designs/feedback.md.
ELI10: Each report is labelled dev, nightly or stable so you know which build broke. The plan reads that from the Stable/Nightly setting, but that setting only says what the next update will be. Switch to Nightly and, until the update lands, you are still running stable, yet the report would say nightly. Nightly builds already carry their commit inside the app (release.sh adds it), so the build itself can say what it is.
Stakes if we pick wrong: Reports get the wrong label exactly when someone just switched channels, which is when bugs are most likely, and you chase the wrong build.
Recommendation: A because the label must describe the code that produced the bug, and the build already knows it.
Completeness: A=10/10, B=7/10
Pros / cons:
A) From the build (recommended)
  ✅ Always matches the running code: Debug → dev, Release with a commit stamp → nightly, else stable
  ✅ Channel setting still sent as its own tag, so "switched but not updated yet" is visible
  ❌ Relies on release.sh keeping the commit stamp on nightlies; a test pins the mapping (CC: ~5 min)
B) From the channel setting
  ✅ Matches what the user chose in Settings > General > Updates
  ✅ No dependency on build stamps
  ❌ Mislabels every report sent between switching channel and the update landing
Net: label by what runs versus by what was chosen.
Header: Environment
Options:
A) From the build
Debug → dev, Release with a VFGitCommit stamp → nightly, else stable. The channel setting goes in a separate `channel` tag. Table test in FeedbackReportTests.
B) From the channel setting
Keep the draft: Debug → dev, else nightly or stable from update.newestMain.

State: approved
Actual answer: A) From the build (D5, 2026-11-02)
Accepted scope: environment = Debug → `dev`; Release with a non-empty VFGitCommit →
`nightly`; else `stable`. The channel setting (update.newestMain) is sent as a separate
`channel` tag. Table test in FeedbackReportTests.
History: none

### R3: What the form tells the sender after Send
Finding: A2, INFORMATIONAL, 6/10 (medium confidence, verify against the installed SDK),
feedback.md "Success: \"Sent. Thanks.\" and the sheet closes. Failure: the error inline,
the note kept, and **Copy report** as the fallback", reviewer plan-eng-review
Plan baseline: original proposal: synchronous success or failure, Copy report as F10.
Runtime evidence: unverified. Sentry's Apple SDK hands events to a transport that stores
envelopes on disk and retries when the network returns; the documented
`SentrySDK.capture(feedback:)` call is fire-and-forget (no delivery callback in the docs
example). So "failure inline" has no signal to show, and offline sends are not lost.
Comparison grid:
| Choice | Current (draft) | A) Queued, Copy always offered | B) Keep success/failure UI |
|---|---|---|---|
| After Send | "Sent. Thanks." or inline error | "Thanks. It sends now, or as soon as you are online." and close | as drafted |
| Offline send | error shown, note kept | queued by the SDK on disk, sent later | error shown (needs own reachability check) |
| Copy report | fallback on failure (F10) | always available in the form | fallback on failure |
| Own network check | none | none | needed to detect "failure" |
| Tests | none named | manual check: send offline, reconnect, report arrives | manual check plus reachability code |
Question D6:
D6 — Show "queued" after Send and keep Copy report always available, instead of a success/failure screen?
Project/branch/task: feedback-feature-design-af3465, reviewing docs/designs/feedback.md.
ELI10: The plan shows "Sent" or an error after you press Send. But Sentry's library does not tell the app whether a report arrived: it saves the report on disk and keeps retrying until the Mac is online. So there is no real "failed" moment to show, and an offline report is not lost. Honest wording is "it sends now or as soon as you are online", and Copy report can just always be there for anyone who wants to paste it into a chat.
Stakes if we pick wrong: Keep the draft and you write network-checking code to fake a failure state the library already handles, or show "Sent" for a report still waiting offline.
Recommendation: A because it matches what the library really does and removes code with nothing to detect.
Completeness: A=9/10, B=7/10
Pros / cons:
A) Queued, Copy always offered (recommended)
  ✅ Offline reports are kept on disk by the SDK and arrive later, with no extra code in VibeFlow
  ✅ Copy report sits in the form at all times, so pasting into a chat never depends on an error
  ❌ The sender never gets a hard "delivered" confirmation inside the app (verify retry in T3, CC: ~10 min)
B) Keep success/failure UI
  ✅ The sender sees an explicit error when the Mac is offline at that moment
  ✅ Matches the draft's wording exactly
  ❌ Needs own reachability code, and "failure" would be wrong since the SDK still delivers later
Net: honest "queued" with zero extra code versus a failure state the library does not have.
Header: After Send
Options:
A) Queued, Copy always offered
After Send: "Thanks. It sends now, or as soon as you are online." and the form closes. Copy report is always in the form. F10 changes accordingly. Manual check in T3: send offline, reconnect, report arrives.
B) Keep success/failure UI
Keep "Sent. Thanks." or an inline error, with VibeFlow's own reachability check to decide failure; Copy report only on failure.

State: approved
Actual answer: A) Queued, Copy always offered (D6, 2026-11-02)
Accepted scope: after Send the form says "Thanks. It sends now, or as soon as you are
online." and closes; Copy report is always in the form (F10 reworded); no reachability
code; manual check in T3: send offline, reconnect, the report arrives in Sentry. Confirm the
fire-and-forget shape of `capture(feedback:)` against the installed SDK in T2.
History: none

### R4: Provider error bodies in logged failure messages
Finding: O1, CRITICAL (Codex: High), 9/10 verified, OpenAITranscriber.swift:92-95
(`return String(decoding: body.prefix(200), as: UTF8.self)`) and DictationSession.swift:504
(`fail("\(name) error \(status): \(message)", …)` → logged with `privacy: .public` at :561),
reviewer Codex (outside voice), verified by plan-eng-review
Plan baseline: R1/D4 approved: "never log user text" rule plus key / home-path scrub. Its
premise "metadata only" is partly false for provider error strings.
Runtime evidence: provider JSON `error.message` strings are logged as-is; for a non-JSON
body the first 200 raw bytes are logged. No observed case of a provider echoing user input.
Comparison grid:
| Choice | Current (D4 approved) | A) Apply | B) Keep | C) Investigate | D) Defer |
|---|---|---|---|---|---|
| Raw body fallback in logs | logged (≤200 bytes) | replaced by "non-JSON body, N bytes" in the log line | logged | unchanged until checked | logged |
| Provider JSON error.message | logged | logged, capped at 160 chars | logged | unchanged | logged |
| UI status text | unchanged | unchanged (user still sees the full message) | unchanged | unchanged | unchanged |
| Test | none | Core test: raw body with a secret-looking sentence never reaches the logged string | none | none | none |
| D4 rule and scrub | approved | unchanged | unchanged | unchanged | unchanged |
Question D7:
D7 — Stop logging raw provider response bodies on failures?
Project/branch/task: feedback-feature-design-af3465, reviewing docs/designs/feedback.md.
ELI10: When Groq, OpenAI or Anthropic return an error, VibeFlow writes the error text to its log, and if the reply is not the usual JSON it writes the first 200 raw characters of whatever came back. Those logs now travel with feedback. Provider error messages are almost always fixed sentences ("model not found"), but a raw body is anything. The fix keeps the readable error message (capped) and logs only "non-JSON body, 512 bytes" for raw replies, while the on-screen message stays the same.
Stakes if we pick wrong: Keep it and an odd proxy or captive-portal page, or a provider that echoes a request, ends up in a report you then store in Sentry.
Recommendation: A because it closes the one real path for uncontrolled text into the logs at the cost of a few lines and one test.
Note: options differ in kind, not coverage — no completeness score.
Pros / cons:
A) Apply this change (recommended)
  ✅ Raw bodies never reach the log, so never reach a report; readable provider messages still do
  ✅ One Core test with a body containing a private sentence pins it (human: ~2h / CC: ~10 min)
  ❌ A strange non-JSON failure is harder to diagnose from a report; you see only its size
B) Keep this row's current value
  ✅ Full diagnostic text of odd failures stays in the log
  ✅ No change to transcriber or read error paths
  ❌ Uncontrolled bytes can ship with feedback; the D4 rule cannot stop it
C) Investigate before choosing
  ✅ Bounded to reading the three provider clients' error paths (about 30 min) and listing what each can log
  ✅ Keeps every other decision as is
  ❌ No change lands until the investigation is answered
D) Defer this proposed change only
  ✅ First PR stays smaller
  ✅ Decision recorded as open
  ❌ Feedback ships while raw bodies can still be logged
Net: a few lines and a test versus leaving one uncontrolled path open.
Header: Error bodies
Options:
A) Apply this change
Log provider JSON error.message capped at 160 chars; a non-JSON body logs only "non-JSON body, N bytes". UI text unchanged. Core test proves a raw body sentence never reaches the logged string.
B) Keep this row's current value
Keep logging provider messages and up to 200 raw body bytes as today.
C) Investigate before choosing
Read the Groq/OpenAI, Anthropic and ElevenLabs error paths (about 30 min), list what each can log, then ask again. Nothing changes meanwhile.
D) Defer this proposed change only
Leave error logging as is for the first PR; keep this row open.

State: approved
Actual answer: A) Apply this change (D7, 2026-11-02)
Accepted scope: logged failure lines carry the provider JSON error.message capped at 160
chars; a non-JSON body logs only "non-JSON body, N bytes"; on-screen status text unchanged;
Core test proves a raw-body sentence never reaches the logged string.
History: none

### R5: Logs must actually record the last action
Finding: O2, CRITICAL (Codex: High), 9/10 verified, ReadSession.swift:849-853
(`private func finishIdle(status: String) { tearDown(); state = .idle; self.status = status }`
has no log line, unlike DictationSession.swift:554), reviewer Codex, verified by
plan-eng-review
Plan baseline: D1 approved: no breadcrumbs, "last action" from the existing notice log lines.
Runtime evidence: a successful read, the provider fallback (ElevenLabs → Apple voice) and
smart read model/duration leave no log line, so a report about "it sounded wrong" or "it
silently used the robot voice" has nothing to show. Logs read when the form opens would
also include the dictation used to type the feedback itself.
Comparison grid:
| Choice | Current (D1 approved) | A) Apply | B) Keep | C) Investigate | D) Defer |
|---|---|---|---|---|---|
| Breadcrumbs | cut (D1) | still cut | still cut | still cut | still cut |
| Read finish log line | none | notice: provider, voice model, duration, chars | none | unchanged until audit | none |
| Smart read finish log line | none | notice: model, duration, outcome | none | unchanged | none |
| Provider fallback log line | none | notice: from → to and why | none | unchanged | none |
| When logs are captured | at send | once, when the form opens (frozen) | at send | at send | at send |
| Test | none | Core tests on the finish/fallback messages (no text content) | none | none | none |
Question D8:
D8 — Add the missing "what just happened" log lines and freeze the logs when the form opens?
Project/branch/task: feedback-feature-design-af3465, reviewing docs/designs/feedback.md.
ELI10: You chose to skip breadcrumbs and rely on the log instead. But today a read that works, or one that quietly falls back to the Apple voice, writes nothing to the log, so the report cannot say what happened. Three short log lines (read finished, smart read finished, voice fallback) close that gap without bringing breadcrumbs back. Grabbing the logs the moment the form opens also stops your own dictation of the feedback from becoming "the last action".
Stakes if we pick wrong: Reports about silent problems ("it used the robot voice", "it was slow") arrive with an empty trail, which is the case this feature exists for.
Recommendation: A because it keeps D1's single trail and makes it complete for the cases people actually report.
Note: options differ in kind, not coverage — no completeness score.
Pros / cons:
A) Apply this change (recommended)
  ✅ Every read, smart read and fallback leaves one metadata line (provider, model, duration, characters)
  ✅ Logs frozen at form open, so the feedback dictation does not hide the real last action (CC: ~15 min)
  ❌ Three more log calls to keep text-free under the D4 rule; tests check they carry no content
B) Keep this row's current value
  ✅ No change to ReadSession or the smart read path
  ✅ Smallest first PR
  ❌ Successful-but-wrong and fallback cases leave nothing in the report
C) Investigate before choosing
  ✅ Bounded audit (about 30 min) of every session end and fallback for a missing log line
  ✅ Keeps D1 and every other decision unchanged
  ❌ Nothing lands until the audit is answered
D) Defer this proposed change only
  ✅ Ship the form first, add lines when a report proves them missing
  ✅ Row stays open and visible
  ❌ The first real bug reports are the ones that lack context
Net: three metadata log lines versus reports that cannot explain silent failures.
Header: Last action
Options:
A) Apply this change
Add notice lines for read finish (provider, voice model, duration, chars), smart read finish (model, duration, outcome) and provider fallback (from, to, reason); capture logs once when the form opens. Core tests check the lines carry no text content.
B) Keep this row's current value
No new log lines; logs captured at send time as drafted.
C) Investigate before choosing
Audit every session end and fallback for missing log lines (about 30 min), then ask again. Nothing changes meanwhile.
D) Defer this proposed change only
Ship without the new lines; keep this row open.

State: approved
Actual answer: A) Apply this change (D8, 2026-11-02)
Accepted scope: notice log lines for read finish (provider, voice model, duration, chars),
smart read finish (model, duration, outcome) and provider fallback (from, to, reason), with
no text content; logs captured once when the feedback form opens; Core tests check the new
lines carry no text content. Breadcrumbs stay cut (D1).
History: none

### R6: Settings screenshot attachment
Finding: O3, INFORMATIONAL (Codex: Medium), 8/10, feedback.md "Screenshot | only if
toggled: the Settings window"; MeetingsViews.swift:140 shows the Google account email and
calendar names in Settings, reviewer Codex, verified by plan-eng-review
Plan baseline: original proposal: opt-in screenshot of the Settings window, not shown in
the text preview.
Runtime evidence: the text scrubber and text preview cannot see pixels; the Meetings and
Accounts panes show an email address and calendar names.
Comparison grid:
| Choice | Current (draft) | A) Apply | B) Keep | C) Investigate | D) Defer |
|---|---|---|---|---|---|
| Screenshot in first PR | opt-in toggle | dropped | opt-in toggle, unseen | unchanged until checked | unchanged, row open |
| Preview shows image | no | n/a | no | unchanged | no |
| Later option | none | TODO: preview the captured image and send those exact bytes | none | none | none |
Question D9:
D9 — Drop the Settings screenshot from the first version?
Project/branch/task: feedback-feature-design-af3465, reviewing docs/designs/feedback.md.
ELI10: The form can attach a picture of the Settings window. The privacy promise is "you see everything before it is sent", but the preview shows only text, and Settings can show your Google email and calendar names. A text filter cannot blank out pixels. Dropping the screenshot for now keeps the promise; a later version can show the actual picture in the preview before sending.
Stakes if we pick wrong: Keep it and an email or calendar name can leave in a picture nobody looked at.
Recommendation: A because two people can describe or paste a screenshot themselves, and the promise stays true.
Note: options differ in kind, not coverage — no completeness score.
Pros / cons:
A) Apply this change (recommended)
  ✅ Preview shows everything that leaves the Mac, no exceptions
  ✅ Less code: no window capture, no attachment toggle (saves CC: ~15 min)
  ❌ Visual bugs need a manual screenshot pasted into the note or a chat
B) Keep this row's current value
  ✅ One click attaches what the Settings window looked like
  ✅ Helpful for layout bugs in Settings
  ❌ Pixels bypass the preview and scrubber; email and calendar names can leave unseen
C) Investigate before choosing
  ✅ Bounded check (about 20 min) of what each Settings pane can show
  ✅ Keeps every other decision unchanged
  ❌ Nothing lands until it is answered
D) Defer this proposed change only
  ✅ Row stays open
  ✅ No code change now
  ❌ The draft's unseen screenshot stays in the plan
Net: a true "you see everything" promise versus one-click screenshots.
Header: Screenshot
Options:
A) Apply this change
Drop the screenshot toggle from the first PR. Add a TODO: show the captured image in the preview and send those exact bytes.
B) Keep this row's current value
Keep the opt-in Settings screenshot as drafted, not shown in the preview.
C) Investigate before choosing
Check what each Settings pane can display (about 20 min), then ask again. Nothing changes meanwhile.
D) Defer this proposed change only
Leave the screenshot as drafted; keep this row open.

State: approved
Actual answer: A) Apply this change (D9, 2026-11-02)
Accepted scope: no screenshot toggle in the first PR; TODO: show the captured image in the
preview and send those exact bytes.
History: none

### R7: Crash reporting (F3) and how it ships
Finding: O4 CRITICAL (Codex: High), 9/10 verified, release.sh:124 (`rm -rf "$OUT"` with
`OUT="build/release"`, :44) deletes the previous archive and its dSYMs on every build, and
nightly.sh publishes each qualifying main commit; plus O5 INFORMATIONAL (Codex: Medium),
8/10, F3 sends crashes without the F5 preview. Reviewer Codex, verified by plan-eng-review.
Plan baseline: F3 "Crash reporting on … **Open: confirm.**" (never answered); T5 (symbol
upload) planned as a follow-up PR after T1-T4.
Runtime evidence: with T5 later, nightlies built between the two PRs ship crash reporting
whose symbols are deleted by the next build, so their crashes can never be symbolicated.
Comparison grid:
| Choice | Current (draft) | A) Include | B) Defer | C) Cut | D) Hold |
|---|---|---|---|---|---|
| Crash reporting in first PR | on (unconfirmed) | on | off (SDK sends feedback only) | never | undecided |
| Symbol upload (T5) | later PR | same PR as crash reporting | ships with crash reporting later | dropped | undecided |
| Disclosure | README line (T6) | README line + one line in the feedback form | README line when it ships | n/a | undecided |
| Payload check | none | inspect one real crash event in Sentry before merge | at that later PR | n/a | undecided |
| beforeSend scrub on crashes | planned | kept | kept for later | n/a | undecided |
Question D10:
D10 — Crash reporting: ship it now with symbol upload in the same PR, or later?
Project/branch/task: feedback-feature-design-af3465, reviewing docs/designs/feedback.md.
ELI10: Besides the feedback form, Sentry can report crashes on its own. To read a crash you need the build's "symbols" file, and VibeFlow's release script deletes the previous build's files every time it runs. If crash reporting ships before the symbol upload, every nightly in between crashes unreadably, forever. Crash reports also leave without the preview, so they need to be mentioned openly. Include means: crash reporting, symbol upload and a one-line notice all land together, and you check one real crash in Sentry before merging.
Stakes if we pick wrong: Ship crash reporting without symbols and you collect crashes you can never read; defer it and a crash at your friend's is only known if they write a note.
Recommendation: A because two users rarely write after a crash, and the symbol upload is one sentry-cli call in a script you already run.
Note: options differ in kind, not coverage — no completeness score.
Pros / cons:
A) Include (recommended)
  ✅ Every crash on both Macs arrives readable, with version, build and channel, without anyone writing
  ✅ Notice in the form and README keeps the "nothing leaves unseen" promise honest (human: ~1 day / CC: ~40 min with T5)
  ❌ First PR grows by release.sh changes, sentry-cli install and an auth token in the keychain
B) Defer
  ✅ First PR is only the feedback form; smaller to review and ship
  ✅ Crash reporting can arrive later as its own PR with T5, no rework
  ❌ Crashes until then are known only if someone writes a note
C) Cut
  ✅ No automatic data leaves the Mac at all; only what someone sends by hand
  ✅ No symbol upload, token or sentry-cli to maintain
  ❌ Crashes stay invisible unless reported by hand, for good
D) Hold
  ✅ Stops here to discuss crash reporting before anything is decided
  ✅ Nothing changes
  ❌ The first PR's scope stays open
Net: readable crashes from day one versus a smaller first PR.
Header: Crash reports
Options:
A) Include
Crash reporting ships in the first PR together with symbol upload (T5) in release.sh, a one-line notice in the form and README, and one real crash event inspected in Sentry before merge.
B) Defer
First PR sends feedback only (crash handler off). Crash reporting plus T5 come later as one PR.
C) Cut
No crash reporting; only hand-sent feedback, now and later.
D) Hold
Stop and discuss crash reporting before deciding; scope stays open.

State: approved
Actual answer: A) Include (D10, 2026-11-02)
Accepted scope: crash reporting ships in the first PR together with symbol upload (T5) in
release.sh (releases and nightlies), a one-line notice in the feedback form and the README,
the beforeSend scrub on crash events, and one real crash event inspected in Sentry before
merge. F3 confirmed.
History: F3 was "Open: confirm" in the draft.

### R8: Does VibeFlow Dev send too (F4)
Finding: open product question F4 in the draft, reviewer plan-eng-review
Plan baseline: F4 "VibeFlow Dev sends too, as environment `dev`. **Open: confirm.**"
Runtime evidence: Debug builds are "VibeFlow Dev" (one.floo.vibeflow.dev), installed by
scripts/dev.sh and run daily by the author.
Comparison grid:
| Choice | Current (draft) | A) Dev sends | B) Dev silent |
|---|---|---|---|
| Debug build starts the SDK | yes (unconfirmed) | yes, environment `dev` | no; feedback item hidden |
| Crashes from Dev builds | sent | sent, filterable as `dev` | not sent |
| Quota use | small | small (author only) | none |
Question D11:
D11 — Should VibeFlow Dev send feedback and crashes too, tagged `dev`?
Project/branch/task: feedback-feature-design-af3465, reviewing docs/designs/feedback.md.
ELI10: You run the Dev build every day. If it sends too, you use the same button and pipeline you ship, so you notice right away when feedback breaks, and Dev crashes land in Sentry under `dev` where you can filter them out. If it stays silent, the first test of the real pipeline is your friend.
Stakes if we pick wrong: Silent Dev means a broken feedback pipeline is found by your friend; sending Dev adds your own test noise you have to filter.
Recommendation: A because exercising the shipped pipeline daily is the cheapest test there is.
Note: options differ in kind, not coverage — no completeness score.
Pros / cons:
A) Dev sends, tagged dev (recommended)
  ✅ You use the real form and SDK every day, so breakage shows up before your friend sees it
  ✅ One filter (environment != dev) hides your own reports when you triage
  ❌ Your test sends and dev crashes take a little of the free quota and need filtering
B) Dev stays silent
  ✅ Sentry holds only reports from release builds
  ✅ No quota spent on your own experiments
  ❌ Feedback pipeline is first exercised by your friend; Dev crashes go unseen
Net: dogfooding the pipeline versus a cleaner inbox.
Header: Dev builds
Options:
A) Dev sends, tagged dev
Debug builds start the SDK with environment `dev`; feedback item visible; crashes sent.
B) Dev stays silent
Debug builds never start the SDK; feedback item hidden in Dev.

State: approved
Actual answer: A) Dev sends, tagged dev (D11, 2026-11-02)
Accepted scope: Debug builds start the SDK with environment `dev`; feedback item visible in
VibeFlow Dev; Dev crashes sent. F4 confirmed.
History: F4 was "Open: confirm" in the draft.

### R9: Should "Love it" feedback attach logs
Finding: open product question 3 in the draft, reviewer plan-eng-review
Plan baseline: one report shape for every kind (draft), with the question left open.
Runtime evidence: logs are metadata only after R1/R4/R5; the preview shows them.
Comparison grid:
| Choice | Current (draft) | A) Same shape | B) Love it skips logs |
|---|---|---|---|
| Bug / Idea | logs attached | logs attached | logs attached |
| Love it | open question | logs attached | note + build info only |
| Code paths | one | one | two (kind-dependent attachment) |
Question D12:
D12 — Keep one report shape for every kind, including "Love it"?
Project/branch/task: feedback-feature-design-af3465, reviewing docs/designs/feedback.md.
ELI10: A "Love it" note ("the German clock is great") does not need logs to be useful. But the logs are only metadata now, the preview shows them, and one shape for every kind means one code path and one test. Praise sometimes also explains how someone uses a feature, which the logs make concrete.
Stakes if we pick wrong: Skipping logs adds a second path to test for a small privacy gain; keeping them sends a little extra metadata with praise.
Recommendation: A because one shape is simpler and the logs carry no personal text after the earlier decisions.
Note: options differ in kind, not coverage — no completeness score.
Pros / cons:
A) Same shape for every kind (recommended)
  ✅ One code path and one rendering test cover Bug, Idea and Love it alike
  ✅ Praise arrives with the context of how the feature was used
  ❌ A short thank-you carries a 10-minute log excerpt it did not need
B) Love it skips logs
  ✅ Praise sends only the note and build info, the smallest possible report
  ✅ Feels lighter to the sender in the preview
  ❌ Kind-dependent attachments add a branch and a test for little gain
Net: one simple path versus slightly leaner praise.
Header: Love it logs
Options:
A) Same shape for every kind
Every kind attaches the same build info and frozen logs; one rendering path.
B) Love it skips logs
"Love it" sends the note and build info only; Bug and Idea attach logs.

State: approved
Actual answer: A) Same shape for every kind (D12, 2026-11-02)
Accepted scope: every kind attaches the same build info and frozen logs; one rendering path.
History: none

Approval readiness: PASS. Checked R1 (D4), R2 (D5), R3 (D6), R4 (D7), R5 (D8), R6 (D9),
R7 (D10), R8 (D11), R9 (D12); scope answers D1, D2, D3. TODOs for F9 and the screenshot
preview carry the approval of D2 and D9.

## Eng review: sections

### 1. Architecture

- [INFORMATIONAL] (confidence: 8/10) feedback.md "Environment" row — environment taken from
  the channel setting, not the running build. Resolved: D5 (R2).
- [INFORMATIONAL] (confidence: 6/10) feedback.md "Success … Failure: the error inline" —
  medium confidence, verify against the installed SDK: `capture(feedback:)` gives no
  delivery result and the SDK queues offline. Resolved: D6 (R3).
- [INFORMATIONAL] (confidence: 8/10) feedback.md "Both open the same sheet" — a sheet needs
  a host window; the menu bar entry has none (MenuBarView.swift:98
  `HistoryWindow.present(openWindow, container: container)` is the existing pattern).
  Correction, no behavior change: the form is its own `Window` scene. Applied.

Design-twice (new module: FeedbackReport). Shape 1 (chosen): a pure MaagicalCore type whose
`render()` returns the scrubbed text that is both previewed and sent. Shape 2: no own type;
set tags and context on the Sentry scope and attach the log file, preview built separately.
Shape 1 hides scrub, environment, cap and layout behind one call and is unit-testable; shape
2 spreads that policy across the SDK scope and the window, and the preview could differ from
what is sent. Red flags on shape 1: hand-synced list (the settings snapshot allowlist does
not follow new Preferences keys automatically; accepted, a new setting is simply absent from
reports until added); information leakage avoided by having FeedbackSender call
`FeedbackReport.environment` and `FeedbackReport.scrub` instead of re-deriving them.

Dispositions: A1 accepted (D5), A2 accepted (D6), A3 applied as correction.

### 2. Code quality

- [INFORMATIONAL] (confidence: 8/10) Preferences.swift:53 `static let vocabulary =
  "dictation.vocabulary"` — the custom vocabulary is user text (names, terms). Correction
  under F7: the snapshot uses an explicit allowlist and sends the vocabulary as a count.
  Applied.
- [INFORMATIONAL] (confidence: 7/10) feedback.md "Logs" row — no behavior defined when
  `OSLogStore` throws. Correction under F10 ("never lose a note"): report says "Logs
  unavailable: <reason>" and still sends. Applied.

Shared code: no extraction proposed; BuildStamp (MaagicalCore/Support/BuildStamp.swift) is
reused for branch, commit and date. Dispositions: both applied as corrections.

### 3. Tests

Framework: Swift Testing in MaagicalCore (`cd MaagicalCore && swift test`, CLAUDE.md).

```
CODE PATHS                                              USER FLOWS
[+] MaagicalCore/Feedback/FeedbackReport.swift          [+] Send feedback
  ├── render()                                            ├── [GAP→manual] open from menu bar, no Settings window
  │   ├── [PLANNED ★★★] all fields, every kind (D12)      ├── [GAP→manual] preview == event in Sentry
  │   ├── [PLANNED ★★★] logs unavailable branch          ├── [GAP→manual] offline send, reconnect, arrives (D6)
  │   └── [PLANNED ★★★] 200 KB cap keeps newest lines     └── [GAP→manual] Copy report == preview
  ├── scrub(_:)                                         [+] Crash
  │   ├── [PLANNED ★★★] each key pattern                  └── [GAP→manual] test crash symbolicated (D10)
  │   └── [PLANNED ★★★] home folder → ~                 [+] Builds
  ├── environment(config:commit:)                         └── [GAP→manual] DSN-less build hides the feature
  │   └── [PLANNED ★★★] dev / nightly / stable table
  └── settings snapshot
      └── [PLANNED ★★] vocabulary as count only
[+] provider error logging (D7)
  └── [PLANNED ★★★] non-JSON body with a private sentence → "non-JSON body, N bytes"
[+] action end log lines (D8)
  └── [PLANNED ★★] read finish / smart read finish / fallback lines carry no text
[+] Maagical/Feedback/FeedbackSender.swift
  └── [GAP→manual] SDK start options, capture(feedback:), attachment (SDK boundary)

COVERAGE (planned): unit 9/9 Core paths | user flows 0/6 automated, 6/6 manual checks
GAPS: 6, all app/SDK boundary or UI, each with a manual check in the test plan artifact
```

Legend: ★★★ behavior + edge + error | ★★ happy path | [GAP→manual] no automated test,
manual check listed in the test plan artifact.

No regression risk to existing behavior beyond the log lines and error-message logging,
which D7 and D8 cover with tests. LLM/eval scope: none (no prompt changes).
Test plan artifact: ~/.gstack/projects/vibeflow/floo-feedback-feature-design-af3465-eng-review-test-plan-20261102-005323.md

Dispositions: all planned tests are required proof of approved decisions (D4, D5, D7, D8,
D12, F7); no new test policy needed a separate answer.

### 4. Performance

- [INFORMATIONAL] (confidence: 7/10) feedback.md "Logs" row — reading 10 minutes of
  `OSLogStore` entries on the main thread can stall the window (scale unknown, not
  measured). Correction: read off the main thread when the window opens, preview shows
  "Collecting logs…". Applied.

No other hot paths: the feature runs only when a person opens the form or the app crashes.
Dispositions: P1 applied as correction.

## NOT in scope

- Breadcrumbs / Telemetry seam: cut (D1); the log is the single trail.
- Feedback-to-crash linking (F9): deferred (D2), in TODOS.md.
- Screenshot attachment: dropped (D9), preview-and-send version in TODOS.md.
- Tracing, profiling, replay: off to stay inside the free quota.
- Own server, database or GitHub issue sync: Sentry is the inbox (F1, F8).

## What already exists

- BuildStamp (MaagicalCore/Support/BuildStamp.swift): branch, commit, build date; reused.
- AppContainer.settingsTab (AppContainer.swift:40): current pane; reused as a tag.
- Preferences keys (Preferences.swift:44-60): source of the snapshot allowlist.
- HistoryWindow.present (MenuBarView.swift:98): pattern for opening a window from the menu.
- Notice log lines for failures and capture (ReadSession.swift:856, DictationSession.swift:554/561, SelectionCapture.swift:29): the action trail D1 relies on, extended by D8.
- release.sh export step and the keychain-profile pattern (notarytool): where symbol upload and its token go.

## Failure modes

| Path | Realistic failure | Handling | Test | User sees |
|---|---|---|---|---|
| Send | Mac offline | SDK disk queue, retries | manual (offline send) | "sends … as soon as you are online" |
| Logs | OSLogStore throws | "Logs unavailable: <reason>", still sends | unit (render) | the line in the preview |
| DSN | missing in a fork or CI build | feature hidden, SDK not started | manual | no button |
| Scrub | new key format not matched | preview shows it before Send | unit per known pattern | the key in the preview (can cancel) |
| Crash symbols | upload fails in release.sh | warning; `--publish` fails | manual | unreadable crash in Sentry only for unpublished builds |
| Quota | crash loop | DSN rate limit, events dropped | none (Sentry setting) | nothing; extra events dropped |

Critical gaps (no test, no handling, silent): none.

## Worktree parallelization strategy

| Step | Modules touched | Depends on |
|---|---|---|
| Report core (T1, D7, D8 tests) | MaagicalCore/Feedback, Session, Dictation | — |
| SDK + window (T2, T3) | Maagical/, project.yml, Config/ | T0, T1 |
| Symbol upload (T5) | scripts/ | T0 |
| Docs (T6) | CLAUDE.md, docs/, README, CHANGELOG | T1-T5 |

Lane A: T1 → T2 → T3 (shared app target). Lane B: T5 (scripts only, independent).
Execution order: T0 by Florian first. Launch A + B. Merge both. Then T6.
Conflict flags: none between lanes; project.yml is touched only in lane A.

## Implementation Tasks
Synthesized from this review's findings. Each task derives from a specific
finding above. Run with Claude Code or Codex; checkbox as you ship.

- [ ] **T1 (P1, human: ~4h / CC: ~20min)** — MaagicalCore — FeedbackReport with render, scrub, environment, cap, snapshot
  - Surfaced by: Scope D3, R1/D4, R2/D5, R9/D12, Code quality vocabulary finding
  - Files: MaagicalCore/Sources/MaagicalCore/Feedback/FeedbackReport.swift, MaagicalCore/Tests/MaagicalCoreTests/FeedbackReportTests.swift
  - Verify: `cd MaagicalCore && swift test`
- [ ] **T2 (P1, human: ~2h / CC: ~10min)** — MaagicalCore — no raw provider bodies in failure logs
  - Surfaced by: Outside voice O1, R4/D7 (OpenAITranscriber.swift:92, DictationSession.swift:504, Anthropic error path)
  - Files: MaagicalCore/Sources/MaagicalCore/Dictation/OpenAITranscriber.swift, DictationSession.swift, the Anthropic client
  - Verify: unit test with a non-JSON body containing a private sentence
- [ ] **T3 (P1, human: ~2h / CC: ~15min)** — MaagicalCore — finish and fallback log lines
  - Surfaced by: Outside voice O2, R5/D8 (ReadSession.swift:849)
  - Files: MaagicalCore/Sources/MaagicalCore/Session/ReadSession.swift, smart read path
  - Verify: unit tests on the line builders; read a real log after a read
- [ ] **T4 (P1, human: ~1 day / CC: ~30min)** — App — Sentry SDK, sender, window, entry points, crash notice
  - Surfaced by: Architecture A2/A3, R3/D6, R8/D11, Performance P1
  - Files: project.yml, Config/Maagical.xcconfig, Maagical/MaagicalApp.swift, Maagical/Feedback/*, Settings/SettingsView.swift, MenuBarView.swift
  - Verify: `xcodegen generate`, Debug build, feedback and test crash visible in Sentry as `dev`; offline send arrives
- [ ] **T5 (P1, human: ~3h / CC: ~15min)** — scripts — dSYM upload in release.sh and nightly path
  - Surfaced by: Outside voice O4, R7/D10 (release.sh:124)
  - Files: scripts/release.sh, scripts/nightly.sh (token access check)
  - Verify: Release build test crash shows a symbolicated stack trace
- [ ] **T6 (P2, human: ~1h / CC: ~10min)** — docs — rule, setup and disclosure
  - Surfaced by: R1/D4 (rule), R7/D10 (disclosure), Scope S1
  - Files: CLAUDE.md, docs/DEVELOPMENT.md, README.md, CHANGELOG.md
  - Verify: read-through

## Unresolved decisions that may bite you later

- Sentry login for the personal org (personal / floo.one email or the existing login):
  Florian decides in T0; no code depends on it.

## Completion summary

- Step 0: Scope Challenge — scope reduced per recommendation
- Reality rows: 7/7 applicable rows emitted, 5 unverified premises
- Architecture Review: 3 issues found
- Code Quality Review: 2 issues found
- Test Review: diagram produced, 6 gaps identified (all with manual checks)
- Performance Review: 1 issue found
- NOT in scope: written
- What already exists: written
- TODOS.md updates: 2 items added (approved by D2 and D9)
- Failure modes: 0 critical gaps flagged
- Unresolved decisions: 1 in this review
- Outside voice: codex (gpt-6-astra), completed, 5 findings (3 High, 2 Medium), all resolved (D7-D10)
- Parallelization: 2 lanes, 1 parallel / 1 sequential
- Lake Score: 1/5 (D5 picked a 10/10 option; D1, D2, D4, D6 picked recommended options scored 8-9)

Reality rows:
- REALITY: premise-table finding 12 premises, unverified=5 (SentryFeedback initializer, free retention, feedback vs error quota, LaunchAgent token access, free plan limits) feedback.md:50
- REALITY: already-done pass no feedback or Sentry work on origin/main; #23 touches sidebar pinning, not SettingsView.swift (git log origin/main)
- REALITY: surface-check finding sentry-cli not installed; `SentrySDK.capture(feedback:)` documented, initializer unverified feedback.md:131
- REALITY: binding-decisions pass no prior branch decisions; global "confirm infrastructure first" satisfied (Sentry chosen by Florian 2026-11-02) feedback.md:151
- REALITY: numbers pass 60 events/hour, 200 KB, 10 min, 160 chars tagged [estimated]; 5,000 errors unverified third-party feedback.md:50
- REALITY: deferred-asks pass no linked issue; the request came from chat, open items listed at feedback.md:180
- REALITY: pr-count pass one PR (no ship-policy.json, default 1) feedback.md:178

## Suppressed findings

- (confidence: 4/10) App hang tracking may report the known first-launch Keychain dialog
  (CLAUDE.md "Keychain gotcha") as a hang if the SDK starts before AppContainer reads keys.
  Unverified; watch for it in the first Dev events.

## GSTACK REVIEW REPORT

| Review | Trigger | Why | Runs | Status | Findings |
|--------|---------|-----|------|--------|----------|
| CEO Review | `/plan-ceo-review` | Scope & strategy | 0 | — | — |
| Outside Review | codex (gpt-6-astra) via `/plan-eng-review` | Independent 2nd opinion | 1 | completed (issues_found) | 5 findings (3 High, 2 Medium), all resolved by D7-D10 |
| Eng Review | `/plan-eng-review` | Architecture & tests (required) | 1 | ISSUES OPEN | 9 issues, 0 critical gaps (all decided and mapped to tasks T1-T6) |
| Design Review | `/plan-design-review` | UI/UX gaps | 0 | — | — |
| DX Review | `/plan-devex-review` | Developer experience gaps | 0 | — | — |

- **OUTSIDE COVERAGE:** codex, phase plan-review, completed, 5 findings: provider error bodies in logs (D7), missing action-end log lines (D8), screenshot outside the preview (D9), symbol loss if T5 ships late and crash reporting disclosure (D10).
- **CROSS-MODEL:** Codex and the native review agreed the log trail is the privacy and context boundary; Codex found two gaps the native pass missed (raw error bodies, silent read finish), both verified in code before deciding.
- **VERDICT:** no review CLEAR yet; every finding is decided and mapped to T1-T6, status issues_open. eng review required

**UNRESOLVED DECISIONS:**
- Sentry login for the personal org (Florian, T0; no code depends on it)
