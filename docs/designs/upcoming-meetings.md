# Design: Upcoming meetings in the menu bar

Drafted 2026-10-27
Status: ENG REVIEWED 2026-10-27 (14 decisions, see Decision ledger); ready to implement
Builds on: the Clocks feature (MenuBarClock, a second MenuBarExtra shown only while needed)

## Problem

A meeting starts and you notice two minutes late. Calendar notifications are easy to
dismiss and gone once dismissed. VibeFlow already owns a spot in the menu bar, so it can
show the next meeting there shortly before it starts, and give a one-click way in.

## What it does

- From 10 minutes before a meeting (lead time configurable: 5 / 10 / 15), a third menu bar
  item appears: `📅 Standup in 8m` (title capped at 18 characters with "…", R10). At start it reads `📅 Standup now`. Five minutes after
  start it disappears.
- Clicking it opens a menu: title, start to end time, organizer, a **Join** button when a
  Meet / Zoom / Teams link is found, then the rest of today's meetings (each with Join),
  and "Open in Google Calendar".
- Two meetings overlapping: the label shows the one starting soonest; the menu lists both.
- Nothing upcoming: the item is not in the menu bar at all (same `isInserted` trick as the clocks).

## Decisions (from the 2026-10-27 planning chat)

| # | Decision | Why |
|---|----------|-----|
| M1 | Read **Google Calendar directly** via its REST API, not EventKit | Your choice. Upside: the API gives `conferenceData` / `hangoutLink`, so Meet links are exact, not regex-guessed. |
| M2 | Show from lead time until **5 min after start**, then hide | Short nudge; keeps the bar clean during the meeting. |
| M3 | Click opens a **menu with Join** plus today's remaining meetings | One click from the nudge into the call. |
| M4 | Settings: **on/off, calendar picker, lead time** (5/10/15) plus a sync status line | Your choice. Own **Meetings** tab, 8th tab (R6). Status line is the only failure signal (R1). |
| M5 | Only real meetings: keep `eventType` default/fromGmail; drop cancelled, all-day, declined by you, "free", and events with nobody but you. "You" = the signed-in email, not `attendees[].self`. Exception (review fix): an invite from someone else with a hidden guest list still counts | R5, R9. |
| M6 | No database, no server. Fetched events live in memory; tokens in the Keychain; settings in UserDefaults | Matches the repo rule. |

## Architecture

```
VibeFlowCore/Meetings/            pure, tested with Swift Testing (structure: R0 smaller arrangement)
  Meetings.swift                  Meeting (id, title, start, end, calendarID, joinURL, organizer)
                                  JoinLink: conferenceData/hangoutLink first, then Zoom/Teams/Webex URL in location/description
                                  MeetingSchedule: (meetings, now, leadTime) -> .hidden / .soon(m, mins) / .now(m);
                                  filter (R5, R9: match "you" by signed-in email); title cap 18 chars (R10); rest of today
  GoogleCalendar.swift            OAuth request building: PKCE S256, state, token exchange (with client_secret), refresh;
                                  callback parsing: state mismatch, error=access_denied, admin_policy_enforced (R3)
                                  Calendar client: calendarList.list + events.list, follows nextPageToken to the end (R11)
                                  MeetingsSync reducer: (state, fetch result + generation, now) -> state + status line;
                                  drops stale generations (R8); signed out / blocked / offline / keychain unavailable (R1, R4, R12)

VibeFlow/                         app target
  GoogleSignIn.swift              NWListener on 127.0.0.1, ephemeral port, one callback then close, 5 min timeout,
                                  a new Sign in cancels the old one; browser success/failure page (R3)
  MeetingsStore.swift             @Observable, thin: timers (5 min, wake, network back, settings change), one fetch in
                                  flight, cancels the old one, bumps the generation (R8), calls MeetingsSync;
                                  reads the Google token from the Keychain on demand (R12)
  MeetingsViews.swift             menu bar label + menu (Join, today's list, Open in Google Calendar)
  SettingsView.swift              8th tab "Meetings": sign in/out, status line, toggle, calendars, lead time (R1, R6)
  VibeFlowApp.swift               third MenuBarExtra(isInserted:) driven by MeetingSchedule, ticked by MenuBarClock
  Config/Google.xcconfig          gitignored GOOGLE_CLIENT_ID / GOOGLE_CLIENT_SECRET; .example committed;
                                  project.yml maps them into Info.plist; empty = "Not configured in this build" (R2)
```

Sync flow:

```
 trigger (5 min | wake | network back | settings change | Sign in)
    │
    ▼
 MeetingsStore: cancel running fetch, generation += 1
    │
    ├─ Keychain read ── error ──► reducer: "Keychain unavailable, retrying"   (R12)
    │       └─ no token ────────► reducer: "Signed out"
    ▼
 refresh access token ── invalid_grant ──► "Signed out: sign in again"
    │                  └─ admin_policy_enforced ──► "Blocked by your Workspace admin"
    ▼
 calendarList (all pages) ─► events.list per selected calendar (all pages)   (R11)
    │        └─ network error ──► "Offline, last synced HH:MM", keep last good list
    ▼
 reducer: generation stale? drop (R8) : replace snapshot, "Signed in as …, last synced HH:MM"
    │
    ▼
 MenuBarClock minute tick ─► MeetingSchedule(filtered meetings, now, lead) ─► label / hidden
```

Ticking: the existing `MenuBarClock` minute tick is enough for "in 8m". The label is
recomputed from the cached event list each tick; the network is only hit on the 5-minute
refresh.

## Google OAuth: the part that makes this heavier than EventKit

- **Client type:** "Desktop app" OAuth client in a Google Cloud project, loopback redirect,
  PKCE. Google treats the desktop client secret as not secret, so it ships in the built binary,
  but never in git: it lives in a gitignored xcconfig (R2).
- **Scope:** `https://www.googleapis.com/auth/calendar.readonly` (needed for calendarList
  plus events). It is a *sensitive* scope.
- **Where it lives (decided 2026-10-27):** a Google Cloud project in the **floo.one**
  Google Workspace, owned by the floo.one admin account. Personal project, nothing in the
  GLE org. The bundle ID `one.floo.vibeflow` already matches the domain.
- **The 7-day trap:** while the consent screen is in "Testing" mode, refresh tokens expire
  after 7 days and you have to sign in again weekly. So never stay in Testing.
- **Path (decided 2026-10-27), in two stages.** The meetings live on the
  work (GLE) Google Workspace calendar, so a floo.one-only (Internal) consent screen cannot work.
  1. **Now — External, In production, unverified:** user type External, publishing status
     In production (never Testing). The work account signs in and sees the
     "unverified app" warning once ("Advanced" → "Go to VibeFlow"). No token expiry.
     Cap: 100 new users over the project's whole lifetime, never reset (Google, Manage
     App Audience). Friends can use it too.
  2. **Verified:** submit for Google's sensitive-scope verification so the warning goes
     away and the 100-user cap lifts. Needs the website (see "Verification prerequisites").
     Same project, same client ID, no code change.
- **Risk: the GLE Workspace admin.** Workspace admins can block unverified third-party
  apps or apps not on an allowlist (Admin console → Security → API controls). If sign-in
  fails with "access blocked by your admin" or "admin_policy_enforced", the GLE admin must
  trust the VibeFlow client ID (by OAuth client ID, in API controls → App access
  control). Check this first, in T1, before writing OAuth code.
- **Tokens:** refresh token in the Keychain via `KeychainSecretsStore` (new `SecretKey`
  case, read on demand for sync, R12), access token only in memory.
- **Forks:** the repo is public; forks need their own client. They copy
  `Config/Google.xcconfig.example` to `Config/Google.xcconfig` and fill in their own ID and
  secret; without it the build works and the Meetings tab says "Not configured in this build" (R2).
- **Multiple Google accounts:** v1 supports one.

## Verification prerequisites (later, when going public)

Google's review for `calendar.readonly` asks for:

- **Verified domain:** floo.one, proven in Google Search Console with the same Workspace
  admin account. Probably already done for Workspace, but check in Search Console.
- **Homepage** on that domain, e.g. `floo.one/vibeflow`: what the app does, a download
  link, a link to the privacy policy. Must be public and must not need a sign-in.
- **Privacy policy** on the same domain: what calendar data is read (titles, times,
  attendees, conference links), that it stays on the Mac and in memory, that nothing goes
  to a server, how to revoke access (myaccount.google.com/permissions). Must also state
  compliance with the Google API Services User Data Policy, including Limited Use.
- **App name and logo** on the consent screen, matching the website.
- **Demo video** (unlisted YouTube): the sign-in, the consent screen with the scope
  shown, and the feature using the data.
- **Scope justification:** one paragraph on why `calendar.readonly` is needed and why a
  narrower scope does not work. `calendar.events.readonly` cannot list calendars, so the
  picker needs `calendar.readonly`.
- Review usually takes a few days to a few weeks. Readonly scopes need no paid security
  assessment, which only restricted scopes (Gmail, Drive) require.

The website is its own small project (static pages; no CMS). Tracked as a TODO, not part
of this feature.

## Implementation tasks

| # | Task | Size |
|---|------|------|
| T1 | Google Cloud project in floo.one, Calendar API on, External consent screen In production, desktop OAuth client; values into gitignored `Config/Google.xcconfig` (R2) | S (you, in the console) |
| T1b | `Spike/google-calendar-spike.swift`: loopback sign-in with the shipping client ID on the GLE account, one refresh, list today's events. Stop here if the GLE admin blocks it (R7) | S |
| T2 | `GoogleCalendar.swift` OAuth + calendar client + `MeetingsSync` reducer, with tests (R3, R4, R8, R11, R12) | M |
| T3 | `Meetings.swift` Meeting, JoinLink, MeetingSchedule + table-driven tests (R5, R9, R10, lead-time edges, DST, midnight) | S |
| T4 | `GoogleSignIn.swift` loopback listener (R3) + `MeetingsStore.swift` timers, generation, on-demand Keychain read (R8, R12); new `SecretKey` case for the refresh token | M |
| T5 | Menu bar item + menu with Join and today's list; project.yml xcconfig wiring | S |
| T6 | Meetings settings tab: sign in/out, status line, toggle, calendar picker, lead time (R1, R6) | S |
| T7 | README + CHANGELOG; `swift test`, xcodebuild; run on this Mac with clocks on and confirm the item shows (R10); a day of real use | S |

## Open questions

- ~~Q1 Which calendar~~: the work (GLE) Workspace account, so External from the start (decided 2026-10-27).
- ~~Q2 Whose Google Cloud project~~: floo.one Workspace (decided 2026-10-27).
- ~~Q3 Filters~~: only real meetings (D6, R5).
- ~~Q4 Notch~~: out of scope; TODO added (D14).

## Not in scope

EventKit / Outlook / iCloud sources, multiple Google accounts, notifications or sounds,
joining automatically, writing to the calendar.

## Eng review (2026-10-27, /plan-eng-review)

Target: docs/designs/upcoming-meetings.md (this file). Branch upcoming-meetings-menubar-dae865, base 949e40c.

### Scope record

feature answers: none (no cuts proposed; the calendar picker and lead time were chosen by the user earlier the same day and are binding); structure: B Smaller arrangement (D1, answered 2026-10-27); accepted scope: Core `Meetings/Meetings.swift` (Meeting, JoinLink, MeetingSchedule) + `Meetings/GoogleCalendar.swift` (OAuth requests, calendar client); App `GoogleSignIn.swift`, `MeetingsStore.swift`, `MeetingsViews.swift`; Tests `MeetingsTests.swift`, `GoogleCalendarTests.swift`; pending remedies: none.

Scope Challenge result: scope accepted as-is (smaller arrangement preserves scope).

### Scope Challenge findings

- S1 [INFORMATIONAL] (confidence: 9/10) upcoming-meetings.md:76 "No token expiry, up to 100 users" — Google's Manage App Audience page: the unverified cap is 100 new users over the project's whole lifetime and cannot be reset. Factual correction, applied to the OAuth section. Reviewer: Claude.
- S2 [INFORMATIONAL] (confidence: 8/10) — Already-done check: `git log origin/main --since=2026-10-26` shows only #7 and #8 (smart read, dictation); nothing meetings-related exists. No action.

## Decision ledger

### R1: What the user sees when Google stops answering
Finding: A1 [CRITICAL] (confidence: 8/10) upcoming-meetings.md "MeetingsStore.swift ... keeps last good list on failure" — Architecture, Claude. A revoked token (`invalid_grant` after a password change or removing access), a GLE admin block, or a long offline stretch leaves the cached list stale; the item simply never appears and you assume the calendar is free.
Plan baseline: original proposal: keep the last good list on failure; no user-visible state.
Runtime evidence: unknown (no code yet). Google returns HTTP 400 `invalid_grant` for a revoked refresh token (documented OAuth behavior).
Comparison grid:
| Choice | Current | A | B |
|---|---|---|---|
| R1 failure visibility | silent, stale list | menu bar shows `📅 !` while signed out or no successful sync for 30 min; its menu says why and offers "Sign in again"; Meetings tab shows the same status | status only in the Meetings tab |
| R2 secret storage | Info.plist (pending) | pending | pending |
| R3 loopback hardening | "loopback, PKCE" (pending) | pending | pending |
Question D2: see AskUserQuestion D2 (copied verbatim below in Actual answer when answered).
Header: Sync failure
Options:
A) Warn in menu bar (recommended)
`📅 !` item while signed out or no successful sync for 30 min; menu explains and offers Sign in again; Meetings tab shows status. human ~3h / CC ~10 min.
B) Settings status only
Status line in the Meetings tab only; the menu bar stays empty on failure. human ~1h / CC ~5 min.
State: approved
Actual answer: B) Settings status only (D2, user, 2026-10-27; recommendation was A)
Accepted scope: the Meetings tab shows a status line: "Signed in as …, last synced HH:MM", "Signed out: sign in again", "Blocked by your Google Workspace admin", or "Offline, last synced HH:MM". The menu bar stays empty on failure. Known accepted risk: a broken sign-in is silent in the menu bar (listed under Failure modes).
History: none

### R2: Where the Google client ID and secret live
Finding: A2 [CRITICAL] (confidence: 6/10) upcoming-meetings.md "Read it from Info.plist (`GoogleClientID`)" and "the client secret ... can ship in the binary" — Architecture/security, Claude. Info.plist properties come from project.yml, which is public on GitHub. A `GOCSPX-` client secret committed to a public repo is the pattern secret scanners flag; even though Google calls desktop secrets non-confidential, a flagged or reused secret lets anyone run their own app under the floo.one consent screen and use up the 100-user lifetime cap. Medium confidence: verify whether GitHub push protection blocks it.
Plan baseline: original proposal: client ID (and secret) in Info.plist via project.yml.
Runtime evidence: project.yml `info.properties` is committed (read 2026-10-27). Forum reports say Google's token exchange returns invalid_request without client_secret even with PKCE, so the secret is needed at runtime.
Comparison grid:
| Choice | Current | A | B |
|---|---|---|---|
| R1 failure visibility | approved: Settings status only | unchanged | unchanged |
| R2 secret storage | Info.plist via project.yml (public) | gitignored `Config/Google.xcconfig` (+ committed `Google.xcconfig.example`), project.yml maps it into Info.plist; empty values make the Meetings tab say "Not configured in this build"; CI builds with the empty example | commit ID and secret in project.yml |
| R3 loopback hardening | pending | pending | pending |
Question D3: as sent.
Header: Client secret
Options:
A) Gitignored xcconfig (recommended)
Values in a gitignored Config/Google.xcconfig, example file committed, empty = feature off with a clear message. human ~1h / CC ~10 min.
B) Commit in project.yml
Simplest; ID and secret public in the repo. human ~10 min / CC ~2 min.
State: approved
Actual answer: A) Gitignored xcconfig (D3, user, 2026-10-27)
Accepted scope: `Config/Google.xcconfig` gitignored with GOOGLE_CLIENT_ID and GOOGLE_CLIENT_SECRET; committed `Config/Google.xcconfig.example` with empty values; project.yml uses the xcconfig and maps both into Info.plist; empty values make the Meetings tab say "Not configured in this build" and the feature stays off; CI builds with the example.
History: none

### R3: Loopback sign-in hardening
Finding: A3 [INFORMATIONAL] (confidence: 7/10) upcoming-meetings.md "loopback redirect: listen on 127.0.0.1:<random port>, open the consent URL in the default browser, catch the code" — Architecture/security, Claude. The plan names PKCE but not the `state` check, the listener's lifetime, or what happens on a second click of "Sign in".
Plan baseline: original proposal: loopback + PKCE.
Runtime evidence: Google installed-app docs: always use PKCE; use 127.0.0.1 not localhost. Forum reports: token exchange needs client_secret even with PKCE.
Comparison grid:
| Choice | Current | A | B |
|---|---|---|---|
| R1 | approved B | unchanged | unchanged |
| R2 | approved A | unchanged | unchanged |
| R3 loopback hardening | loopback + PKCE | PKCE S256 + random `state` checked on callback; NWListener on 127.0.0.1, ephemeral port; accepts one callback then closes; closes after 5 min; a new Sign in cancels the old listener; send client_secret on exchange; success/failure page in the browser; tests for state mismatch, `error=access_denied`, `admin_policy_enforced`, timeout | as written: PKCE only, details left to implementation |
Question D4: as sent.
Header: Sign-in flow
Options:
A) Harden and test (recommended)
State check, one-shot listener with 5 min timeout, cancel on re-click, error pages, tests for each. human ~4h / CC ~15 min.
B) As written
PKCE loopback only; edge cases left to implementation. human ~2h / CC ~10 min.
State: approved
Actual answer: A) Harden and test (D4, user, 2026-10-27)
Accepted scope: PKCE S256 + random `state` checked on callback; NWListener on 127.0.0.1 with an ephemeral port; one callback then close; 5 min timeout; a new Sign in cancels the old listener; client_secret sent on exchange; success/failure page in the browser; tests for state mismatch, `error=access_denied`, `admin_policy_enforced`, timeout.
History: none

Section 1 dispositions: A1 → R1 approved B (D2); A2 → R2 approved A (D3); A3 → R3 approved A (D4).

### R4: Where the sync rules live (testability)
Finding: C1 [INFORMATIONAL] (confidence: 8/10) upcoming-meetings.md "MeetingsStore.swift @Observable; refreshes every 5 min ... keeps last good list on failure" — Code quality, Claude. project.yml has one test target, `VibeFlowCore/VibeFlowCoreTests`; app-target code is untested. The sync rules (invalid_grant → signed out, admin_policy_enforced → blocked, network error → offline with last good list, status text from R1) would sit untested in the app.
Plan baseline: original proposal: rules inside app MeetingsStore.
Runtime evidence: project.yml `test: targets: - package: VibeFlowCore/VibeFlowCoreTests` (read 2026-10-27).
Comparison grid:
| Choice | Current | A | B |
|---|---|---|---|
| R1-R3 | approved | unchanged | unchanged |
| R4 sync rules | app MeetingsStore | pure `MeetingsSync` reducer in Core GoogleCalendar.swift: (state, fetch result, now) → state + status line; MeetingsStore only runs timers and calls it; tested | as written |
Question D5: as sent.
Header: Sync rules
Options:
A) Rules in Core (recommended)
Pure reducer in GoogleCalendar.swift, tested; MeetingsStore is a thin timer wrapper. human ~2h / CC ~10 min.
B) Rules in app
Everything in MeetingsStore; checked by hand only. human ~1h / CC ~5 min.
State: approved
Actual answer: A) Rules in Core (D5, user, 2026-10-27)
Accepted scope: pure `MeetingsSync` reducer in Core GoogleCalendar.swift: (state, fetch result, now) → new state + status line; cases signed in / signed out (invalid_grant) / blocked (admin_policy_enforced) / offline with last good list / recovered; unit tested; app MeetingsStore only runs timers and calls it.
History: none

### R5: Which events count as meetings
Finding: C2 [INFORMATIONAL] (confidence: 8/10) upcoming-meetings.md M5 "Skip all-day events, events you declined, events marked free ... and events with no other attendees?" — Code quality / edge cases, Claude. Google's events resource has `eventType` (default, focusTime, outOfOffice, workingLocation, birthday, fromGmail) and `status` (confirmed, tentative, cancelled). The plan ignores both, so Focus time blocks and a "Working from home" location would trigger the nudge.
Plan baseline: M5 as an open question.
Runtime evidence: unknown until a fixture from the real calendar; field names from the Calendar API v3 events reference (in-distribution knowledge).
Comparison grid:
| Choice | Current | A | B |
|---|---|---|---|
| R1-R4 | approved | unchanged | unchanged |
| R5 filter | open | keep `eventType` default/fromGmail, drop cancelled, all-day, declined, transparent, AND events where you are the only attendee (or no attendees) | same, but keep solo events (only drop by eventType/status/all-day/declined/transparent) |
Question D6: as sent.
Header: Event filter
Options:
A) Only real meetings (recommended)
Drop focus time, out of office, working location, birthdays, cancelled, all-day, declined, free, and events with nobody else invited. human ~1h / CC ~5 min.
B) Keep solo events
Same type/status filters, but a solo block you created (e.g. "Prep for call") still shows. human ~1h / CC ~5 min.
State: approved
Actual answer: A) Only real meetings (D6, user, 2026-10-27)
Accepted scope: keep events with `eventType` default or fromGmail; drop cancelled, all-day (start.date), declined by you (attendee self=true, responseStatus=declined), transparent ("free"), and events with no attendee other than you. Table-driven tests in MeetingsTests.swift for each rule.
History: none

### R6: Where the meetings settings go
Finding: C3 [INFORMATIONAL] (confidence: 7/10) upcoming-meetings.md M4 "Lives in a new Meetings tab (8th tab)" — Code quality, Claude. SettingsView.swift:7 `case general, reading, smartRead, dictation, clocks, lookAndFeel, keys` is 7 tabs, kept deliberately small (opinionated settings). The Meetings tab holds sign-in, status (R1), toggle, calendar picker, lead time.
Plan baseline: M4: new 8th tab (written by Claude in the draft, not chosen by the user).
Runtime evidence: SettingsView.swift:7 (read 2026-10-27).
Comparison grid:
| Choice | Current | A | B |
|---|---|---|---|
| R1-R5 | approved | unchanged | unchanged |
| R6 placement | 8th tab "Meetings" | 8th tab "Meetings" (calendar icon) | merge into the Clocks tab, renamed "Time" (clocks list, then a Meetings section) |
Question D7: as sent.
Header: Settings tab
Options:
A) Own Meetings tab (recommended)
8th tab; sign-in, status, toggle, calendars, lead time in one place. human ~1h / CC ~5 min.
B) Merge into Clocks as "Time"
Stays at 7 tabs; Clocks tab gets a Meetings section below the clocks list. human ~1h / CC ~5 min.
State: approved
Actual answer: A) Own Meetings tab (D7, user, 2026-10-27)
Accepted scope: 8th Settings tab "Meetings" (calendar icon) with sign-in/out, status line (R1), on/off toggle, calendar picker, lead time 5/10/15.
History: none

Section 2 dispositions: C1 → R4 approved A (D5); C2 → R5 approved A (D6); C3 → R6 approved A (D7).

### Outside voice (Codex, gpt-6-astra, completed)

Six findings, each resolved below as R7 to R12. Verified by Claude: O6 against KeychainSecretsStore.swift:12-18 (`if let value = try? keychain.get(...)`), O2's reference against ReadSession.swift:58 "(sessionID, attempt) token and dropped on mismatch (D11)". O1, O3, O5 rest on Google docs Codex cited (OAuth Playground, events resource `attendees[].self`, events.list/calendarList.list paging); O4 on Apple's NSStatusItem.isVisible docs.

All R7 to R12 use the four-option menu: A) Apply this change; B) Keep current value; C) Investigate before choosing; D) Defer this proposed change only.

### R7: T1 smoke test cannot use OAuth Playground
Finding: O1 [CRITICAL] (confidence: 8/10) upcoming-meetings.md T1 "Smoke test: sign the GLE account in once via the OAuth Playground with this client" — Codex. Playground needs a Web client with its own redirect URI; a desktop client cannot be tested there, so it proves nothing about the shipping client ID under GLE policy.
Plan baseline: T1 Playground smoke test. Runtime evidence: Google OAuth Playground docs (cited by Codex).
Comparison grid: | R7 | Playground test | A: replace with `Spike/google-calendar-spike.swift`: loopback sign-in with the shipping client ID, refresh once, list today's events from the GLE account | B: keep Playground | C: investigate | D: defer |
State: approved
Actual answer: A) Apply this change (recommended) (D8, user, 2026-10-27)
Accepted scope: Replace the Playground check with `Spike/google-calendar-spike.swift`: loopback sign-in with the shipping client ID on the GLE account, one token refresh, list today's events. Runs right after T1, before feature code.
History: none

### R8: Overlapping fetches
Finding: O2 [CRITICAL] (confidence: 8/10) upcoming-meetings.md MeetingsStore "refreshes every 5 min, on wake, on network back, on settings change" — Codex. Fetches can overlap; a fetch started before sign-out or a calendar change can land afterwards and restore old events or signed-in state. ReadSession.swift:58 already solves this with an attempt token (D11).
Plan baseline: R4 reducer with no generation check. Runtime evidence: ReadSession.swift:58, 125-150.
Comparison grid: | R8 | none | A: one fetch at a time (a new trigger cancels the running one); every fetch carries a generation number; the reducer drops results whose generation is stale; token refresh serialized; tests for sign-out-during-fetch and calendar-change-during-fetch | B | C | D |
State: approved
Actual answer: A) Apply this change (recommended) (D9, user, 2026-10-27)
Accepted scope: One fetch in flight; a new trigger cancels the running one; each fetch carries a generation number; the Core reducer drops stale results; token refresh serialized; tests for sign-out during fetch and calendar change during fetch.
History: none

### R9: `attendees[].self` is the calendar, not you
Finding: O3 [CRITICAL] (confidence: 8/10) R5 accepted scope "declined by you (attendee self=true ...)" — Codex. On a colleague's or shared calendar, `self` marks that calendar's owner, so their decline or solo status would decide your nudge.
Plan baseline: R5 approved filter. Runtime evidence: Google events resource docs (cited).
Comparison grid: | R9 | self=true | A: "you" = the signed-in account's email (primary calendar id, stored at sign-in); declined and solo rules match attendees by that email; the R5 filter policy is unchanged; tests with a shared-calendar fixture | B | C | D |
State: approved
Actual answer: A) Apply this change (recommended) (D10, user, 2026-10-27)
Accepted scope: Store the signed-in email at sign-in (primary calendar id); declined and solo rules match attendees by that email, not `self`; R5 policy unchanged; shared-calendar fixture test.
History: none

### R10: The nudge can be hidden by a full menu bar
Finding: O4 [CRITICAL] (confidence: 7/10) upcoming-meetings.md "a third menu bar item appears: `📅 Standup in 8m`" — Codex. The clocks label already grows per clock (VibeFlowApp.swift MenuBarExtra with ClockFormat.label); on a notched MacBook macOS hides overflowing items, even while reporting them visible. An untruncated title makes this likelier.
Plan baseline: separate third item, title untruncated. Runtime evidence: unknown on this Mac; Apple NSStatusItem.isVisible docs (cited).
Comparison grid: | R10 | third item, full title | A: keep the third item, cap the title at 18 characters with "…", and check on this Mac with clocks on | A2: show the nudge inside the existing VibeFlow item (its icon becomes `📅 8m`), no third item | B | C | D |
State: approved
Actual answer: A) Apply this change (recommended) (D11, user, 2026-10-27)
Accepted scope: Keep the third menu bar item; cap the title at 18 characters with "…"; done check includes running on this Mac with clocks on and confirming the item shows.
History: none

### R11: Paging and full-snapshot replacement
Finding: O5 [INFORMATIONAL] (confidence: 8/10) T3 "calendarList.list, events.list" — Codex. Both endpoints page (nextPageToken); a short or empty first page can come with more results. Treating page one as the whole day silently drops meetings; merging without removal keeps cancelled ones.
Plan baseline: T3 without paging. Runtime evidence: events.list / calendarList.list docs (cited).
Comparison grid: | R11 | page one only | A: follow nextPageToken to the end for both endpoints; replace a calendar's events only after all its pages succeed; tests with a two-page fixture and an empty first page | B | C | D |
State: approved
Actual answer: A) Apply this change (recommended) (D12, user, 2026-10-27)
Accepted scope: Follow nextPageToken to the end for calendarList and events; replace a calendar's events only after all its pages succeed; tests with a two-page fixture and an empty first page.
History: none

### R12: Keychain read errors look like "signed out"
Finding: O6 [INFORMATIONAL] (confidence: 9/10) KeychainSecretsStore.swift:14 `if let value = try? keychain.get(key.rawValue), !value.isEmpty` — Codex, verified by Claude. A failed read at launch caches nothing, so a valid refresh token reads as missing for the whole run and the tab says "Signed out".
Plan baseline: reuse SecretsStore as is. Runtime evidence: KeychainSecretsStore.swift:12-18 (read 2026-10-27).
Comparison grid: | R12 | try? at init, cache only | A: the Google token is read from the Keychain on demand (not only at init), a read error is reported as "Keychain unavailable" (retry next sync), distinct from "Signed out"; existing API keys unchanged | B | C | D |
State: approved
Actual answer: A) Apply this change (recommended) (D13, user, 2026-10-27)
Accepted scope: Read the Google token from the Keychain on demand; a read error reports "Keychain unavailable, retrying" (retried next sync), distinct from Signed out; existing API-key caching unchanged.
History: none

Outside voice dispositions: O1 → R7 approved (D8); O2 → R8 approved (D9); O3 → R9 approved (D10); O4 → R10 approved (D11); O5 → R11 approved (D12); O6 → R12 approved (D13). TODO: notch heads-up added to TODOS.md (D14, A).

Approval readiness: PASS. Checked R1 (D2), R2 (D3), R3 (D4), R4 (D5), R5 (D6), R6 (D7), R7 (D8), R8 (D9), R9 (D10), R10 (D11), R11 (D12), R12 (D13); structure D1; TODO D14. Each accepted remedy cites its own answer.

## Review sections

### 1. Architecture
- A1 [CRITICAL] (8/10) silent stale list on sync failure → R1 (B, Settings status only).
- A2 [CRITICAL] (6/10) client secret in public project.yml → R2 (A, gitignored xcconfig).
- A3 [INFORMATIONAL] (7/10) loopback flow details unspecified → R3 (A, harden and test).
Dispositions: all accepted as recorded.

### 2. Code quality
- C1 [INFORMATIONAL] (8/10) sync rules in the untested app target → R4 (A, reducer in Core).
- C2 [INFORMATIONAL] (8/10) eventType/status ignored, Focus time would nudge → R5 (A, only real meetings).
- C3 [INFORMATIONAL] (7/10) 8th Settings tab vs the 7-tab minimum → R6 (A, own tab).
Shared code: reuse the existing `HTTPClient` port and `URLSessionHTTPClient` (Ports.swift:195, URLSessionClients.swift:30) for every Google call, the `SecretsStore`/`KeychainSecretsStore` for the refresh token, `MenuBarClock` for ticking, and the ReadSession attempt-token idea (ReadSession.swift:58) for R8. No extraction proposed: no two existing callers share new behavior.

### 3. Tests

Framework: Swift Testing in VibeFlowCore (`cd VibeFlowCore && swift test`); the app target has no tests (project.yml test target is VibeFlowCore/VibeFlowCoreTests only). No LLM or prompt changes, so no eval scope.

```
CODE PATHS (all proposed)                              USER FLOWS
[+] Meetings.swift                                     [+] First sign-in (GLE account)
  ├── MeetingSchedule                                    ├── [GAP→T1b spike] [→E2E] consent + unverified warning
  │   ├── [GAP] hidden before lead time (lead-1m)        ├── [GAP] browser tab closed → timeout message (R3)
  │   ├── [GAP] .soon at exactly lead time, "in 8m"      └── [GAP] admin block → "Blocked by your Workspace admin"
  │   ├── [GAP] .now at start, hidden at start+5m      [+] Daily use
  │   ├── [GAP] two overlapping, soonest wins            ├── [GAP] nudge 10m before, Join opens Meet (manual, T7)
  │   ├── [GAP] DST night, event crossing midnight       ├── [GAP] item visible with clocks on (manual, R10)
  │   └── [GAP] title > 18 chars truncated with …        └── [GAP] lead time 5/15 changes the label
  ├── filter (R5, R9)                                  [+] Errors the user sees (Settings only, R1)
  │   ├── [GAP] eventType focusTime/outOfOffice/         ├── [GAP] revoked token → "Signed out: sign in again"
  │   │         workingLocation/birthday dropped         ├── [GAP] offline → "Offline, last synced HH:MM"
  │   ├── [GAP] cancelled, all-day, transparent dropped  └── [GAP] keychain error → "Keychain unavailable"
  │   ├── [GAP] declined by signed-in email dropped
  │   ├── [GAP] solo event dropped
  │   └── [GAP] shared calendar: owner's decline ignored
  └── JoinLink
      ├── [GAP] hangoutLink / conferenceData entryPoint
      ├── [GAP] Zoom/Teams/Webex URL in location or description
      └── [GAP] no link → no Join button
[+] GoogleCalendar.swift
  ├── OAuth: [GAP] PKCE S256 + state in auth URL; [GAP] callback state mismatch rejected;
  │          [GAP] error=access_denied; [GAP] admin_policy_enforced; [GAP] exchange includes client_secret
  ├── refresh: [GAP] invalid_grant → signed out
  ├── paging: [GAP] two pages merged; [GAP] empty first page + token followed
  └── MeetingsSync: [GAP] stale generation dropped; [GAP] sign-out mid-fetch; [GAP] calendar change mid-fetch;
                    [GAP] offline keeps last list; [GAP] recovery clears the error

COVERAGE: 0/40 paths tested today (feature not built)  |  every [GAP] above is required proof of an approved decision
```

Proposed tests (all required by approved decisions, none new policy):
- `VibeFlowCoreTests/MeetingsTests.swift` (unit): table-driven MeetingSchedule cases, filter cases incl. shared-calendar fixture, JoinLink cases, title cap.
  Value: protects=nudge timing and which events count; fails_when=a boundary is off by one or a filter rule flips; why_new=no meetings code exists; seam=none; no_claim=real Google payload shape (JSON fixtures)
- `VibeFlowCoreTests/GoogleCalendarTests.swift` (unit, fake HTTPClient from Fakes.swift): OAuth URL/state/callback/exchange, refresh errors, paging, MeetingsSync transitions.
  Value: protects=sign-in safety, error mapping, complete snapshots, stale-result guard; fails_when=state unchecked, invalid_grant mislabeled, page two skipped, late fetch applied; why_new=no Google code exists; seam=none; no_claim=Google's live behavior and GLE policy (fake HTTP; the T1b spike covers live)
- Manual (T7): run on this Mac with clocks on, confirm the item shows (R10); join a real Meet from the menu; revoke access at myaccount.google.com/permissions and check the status line.
Tests to retire: none.

### 4. Performance
No issues found. Scale: one calendarList call plus one events.list per selected calendar every 5 min (about 1 to 5 small requests, [estimated]); the minute tick filters an in-memory list of at most a few dozen events. Every request goes through URLSession with the default 60 s timeout; MeetingsStore cancels a running fetch before starting another (R8), so requests never pile up.

## NOT in scope
- EventKit / Outlook / iCloud: you chose Google directly (M1).
- Multiple Google accounts: one account covers the GLE calendar.
- Menu bar warning when sync fails: considered and declined (D2); the Settings status line is the signal.
- Notch heads-up: TODO (D14).
- Google verification and the floo.one website: needed only when going public (TODOS.md).
- Notifications, sounds, auto-join, writing to the calendar.

## What already exists
- `HTTPClient` / `URLSessionHTTPClient` (Ports.swift:195, URLSessionClients.swift:30): reused for all Google requests, and its fakes for tests.
- `SecretsStore` / `KeychainSecretsStore`: reused for storage; the Google token gets an on-demand read path (R12).
- `MenuBarClock` and the `MenuBarExtra(isInserted:)` pattern from Clocks (VibeFlowApp.swift): reused for ticking and showing/hiding.
- ReadSession's (sessionID, attempt) guard (ReadSession.swift:58): the model for R8's generation number.
- `Spike/` folder: home of the T1b spike.

## Failure modes
| Path | Realistic failure | Handled | Tested | User sees |
|---|---|---|---|---|
| Sign-in | GLE admin blocks the client | yes, admin_policy_enforced mapped | unit + T1b spike | browser page + tab status |
| Sign-in | browser tab closed | 5 min timeout | unit | tab: "Sign-in timed out" |
| Refresh | token revoked / password changed | invalid_grant → signed out | unit | **Settings only; menu bar silent** (accepted, D2) |
| Fetch | offline | keep last list | unit | Settings only; stale list keeps nudging from cache |
| Fetch | page two skipped | follow nextPageToken | unit | none (prevented) |
| Fetch | late result after sign-out | generation check | unit | none (prevented) |
| Keychain | read error at launch | on-demand read, distinct status | unit | Settings: "Keychain unavailable" |
| Menu bar | item pushed off a full bar | 18-char cap | manual (T7) | nothing: hidden item (residual risk, notch TODO) |

Critical gaps (no test AND no handling AND silent): 0. Accepted silent risks: a broken sign-in is visible only in Settings (D2), and an overflowing menu bar can still hide the item (D11, mitigated, not eliminated).

## Worktree parallelization strategy
| Step | Modules touched | Depends on |
|---|---|---|
| T1/T1b console + spike | Config/, Spike/ | — |
| T2 GoogleCalendar + tests | VibeFlowCore/Meetings, Tests | T1b (confirms the flow) |
| T3 Meetings + tests | VibeFlowCore/Meetings, Tests | — |
| T4-T6 app wiring | VibeFlow/, project.yml | T2, T3 |
| T7 docs + verify | README, CHANGELOG | T4-T6 |

Lane A: T1 → T1b → T2. Lane B: T3 (independent, pure). Launch A + B; merge both; then T4 → T5 → T6 → T7. Conflict flag: T2 and T3 both add files under VibeFlowCore/Meetings/ and Tests/ but touch different files.

## Implementation Tasks
Synthesized from this review's findings. Each task derives from a specific finding above. Run with Claude Code or Codex; checkbox as you ship.

- [ ] **T1 (P1, human: ~30min / CC: n/a, you in the console)** — Google Cloud — floo.one project, External In production, desktop client, gitignored xcconfig
  - Surfaced by: Scope/R2 (client secret out of git)
  - Files: Config/Google.xcconfig (gitignored), Config/Google.xcconfig.example, .gitignore
  - Verify: `git check-ignore Config/Google.xcconfig`
  - Status 2026-10-29: project `vibeflow-513107` in floo.one, Calendar API on, consent screen External (VibeFlow, homepage https://floo.one, authorized domain floo.one), scope calendar.readonly, desktop client "VibeFlow macOS", GLE account as test user. **Still in Testing:** Google requires a privacy policy link before "Publish app"; floo.one has no privacy page yet. Blocks real use (7-day tokens, test users only), not the spike.
- [x] **T1b (P1, human: ~3h / CC: ~20min)** — Spike — real loopback sign-in on the GLE account, refresh, list today's events
  - Surfaced by: Outside voice O1 → R7
  - Files: Spike/google-calendar-spike.swift
  - Verify: run it; today's GLE meetings print; no admin_policy_enforced
  - Done 2026-10-29: PASS on the work account. No admin block; code exchange, refresh, revoke OK; calendarList paged (11 calendars, 4 pages at size 3); filter dropped a workingLocation event and kept a 2-attendee meeting. Open: that meeting had no join link, so check where its link lives before T5 (the spike now prints hints).
- [x] **T2 (P1, human: ~2d / CC: ~45min)** — Core — GoogleCalendar.swift: OAuth requests, callback parsing, paging client, MeetingsSync reducer
  - Surfaced by: R3, R4, R8, R11, R12
  - Files: VibeFlowCore/Sources/VibeFlowCore/Meetings/GoogleCalendar.swift, VibeFlowCore/Tests/VibeFlowCoreTests/GoogleCalendarTests.swift
  - Verify: `cd VibeFlowCore && swift test`
  - Done 2026-10-29: OAuth request building + callback parsing, GoogleCalendarClient (refresh, calendarList and events with paging, all-or-nothing fetch; `selected` nil = your own calendar), MeetingsSync reducer with status lines. 285 Core tests pass; app builds.
- [x] **T3 (P1, human: ~1d / CC: ~20min)** — Core — Meetings.swift: Meeting, JoinLink, MeetingSchedule, filter, title cap
  - Surfaced by: R5, R9, R10
  - Files: VibeFlowCore/Sources/VibeFlowCore/Meetings/Meetings.swift, VibeFlowCore/Tests/VibeFlowCoreTests/MeetingsTests.swift
  - Verify: `cd VibeFlowCore && swift test`
  - Done 2026-10-29. Two rules the plan left open, decided in code: rooms (attendees with resource=true) do not count as other people; when two meetings are in the window, the next one to start wins over one already running. A meeting on two selected calendars shows once (same event id), your copy first. Events are fetched for today and tomorrow so a meeting just after midnight still nudges.
- [x] **T4 (P1, human: ~1d / CC: ~30min)** — App — GoogleSignIn loopback listener, MeetingsStore timers + generation + on-demand Keychain read, SecretKey case
  - Surfaced by: R3, R8, R12
  - Files: VibeFlow/GoogleSignIn.swift, VibeFlow/MeetingsStore.swift, VibeFlow/KeychainSecretsStore.swift, VibeFlowCore/Sources/VibeFlowCore/Ports.swift, VibeFlow/AppContainer.swift
  - Verify: xcodebuild build; sign in from the app
  - Done 2026-10-29 (code; sign-in from the app waits for the T6 tab): GoogleSignIn (NWListener 127.0.0.1, one callback, 5 min timeout, new sign-in cancels the old), MeetingsStore (5 min timer, wake, network back, one fetch in flight that waits for the cancelled one, generation via MeetingsSync, invalid_grant deletes the token), SecretKey.googleRefreshToken read on demand, meetings preferences (enabled, lead minutes, calendars). Pulled forward from T5: Config/VibeFlow.xcconfig with `#include? "Google.xcconfig"`, project.yml maps GoogleClientID/GoogleClientSecret into Info.plist; a build without the file works with empty values. The Google sign-in first shared the Keychain service with VibeFlow Dev, like the API keys; the review fixes moved it to a per-app service (`<bundle id>.google`), so Dev and the release keep separate sign-ins while API keys stay shared.
- [x] **T5 (P1, human: ~4h / CC: ~15min)** — App — menu bar item + menu, project.yml xcconfig wiring
  - Surfaced by: R2, R10
  - Files: VibeFlow/MeetingsViews.swift, VibeFlow/VibeFlowApp.swift, project.yml
  - Verify: `xcodegen generate` + xcodebuild; item shows with clocks on
  - Done 2026-10-29: third MenuBarExtra(isInserted:) from MeetingsStore.nudge on the minute tick; menu with the meeting, time, organizer, Join (or "no call link"), the rest of today (each opens its call or the event), Open in Google Calendar, Meetings Settings. xcconfig wiring landed in T4. Still to check by eye (T7): the item shows next to the clocks on this Mac.
- [x] **T6 (P1, human: ~4h / CC: ~15min)** — Settings — Meetings tab with status line
  - Surfaced by: R1, R6
  - Files: VibeFlow/SettingsView.swift, VibeFlowCore/Sources/VibeFlowCore/Settings/Preferences.swift
  - Verify: revoke access, status line says "Signed out"
  - Done 2026-10-29: Meetings tab between Clocks and Look & Feel: status line, Sign in / Sign out / Sync Now, sign-in error, on/off, lead time 5/10/15, a toggle per calendar (nil = your own). Signed in from the app on the GLE account; first sync 2 meetings; after a relaunch it synced from the stored token. Revoke check is in T7.
- [ ] **T7 (P2, human: ~2h / CC: ~10min)** — Docs + verify — README, CHANGELOG, a day of real use
  - Surfaced by: R10 manual check
  - Files: README.md, CHANGELOG.md
  - Verify: swift test + xcodebuild green; a day of nudges on the GLE calendar
  - Docs done 2026-10-29: README (Meetings, privacy, Google sign-in caveats), CHANGELOG Unreleased, docs/DEVELOPMENT.md "Google Calendar (Meetings)", release.sh refuses `--publish` without the Google client and warns on local builds.
  - Real-use checklist (open; tick each as you see it):
    - [ ] The item appears at lead time next to the clocks on this Mac (R10, O4: not hidden by the notch)
    - [ ] It counts down each minute, says "now" at start, and is gone 5 minutes after start
    - [ ] Join opens a real Meet call; a Zoom or Teams invite shows Join too
    - [ ] A meeting without a call link says "no call link" (the 16:30 on 2026-10-29 had none; find out where its link lives)
    - [ ] Focus time, OOO and working location never show; a meeting you declined disappears after the next sync
    - [ ] Two overlapping meetings: the next one is shown, both are in the menu
    - [ ] Lead time 5 / 15 changes when it appears; switching Meetings off hides it at once
    - [ ] A second watched calendar (a colleague's) adds its meetings without duplicates
    - [ ] Sleep the Mac, wake it: a sync runs (log "Meetings synced") and the label is right
    - [ ] Wi-Fi off: status says "Offline, last synced …" and the nudge keeps working from the list
    - [ ] Revoke VibeFlow at myaccount.google.com/permissions: the next sync says "Signed out: sign in again" and the item disappears
    - [ ] Sign out and in again from the tab
  - Not shippable yet: the Google app is still in Testing (7-day sign-ins, test users only) until floo.one has a privacy page and the app is published (see T1).

## Reality rows
- REALITY: premise-table pass 9 premises, unverified=2 (O4 notch overflow on this Mac; Google paging frequency) upcoming-meetings.md:353
- REALITY: already-done pass nothing meetings-related on origin/main since 2026-10-26 (#7, #8 only) upcoming-meetings.md:183
- REALITY: surface-check finding OAuth Playground cannot test a desktop client (O1, fixed by R7) upcoming-meetings.md:326
- REALITY: binding-decisions pass calendar picker + lead time (user, 2026-10-27) kept; no reintroduced default upcoming-meetings.md:30
- REALITY: numbers pass sizes and request counts tagged [estimated]; the 100-user cap re-derived from Google docs upcoming-meetings.md:76
- REALITY: deferred-asks pass no linked issue upcoming-meetings.md:1
- REALITY: pr-count pass one PR (default policy, no .gstack/ship-policy.json) upcoming-meetings.md:145

## Unresolved decisions
None.

## Completion summary
- Step 0: Scope Challenge — scope accepted as-is (smaller arrangement, D1)
- Reality rows: 7/7 applicable rows emitted, 2 unverified premises
- Architecture Review: 3 issues found
- Code Quality Review: 3 issues found
- Test Review: diagram produced, 40 gaps identified (all required proof of approved decisions; feature not built)
- Performance Review: 0 issues found
- NOT in scope: written
- What already exists: written
- TODOS.md updates: 1 item proposed to user (notch heads-up, added)
- Failure modes: 0 critical gaps flagged (2 accepted silent risks)
- Unresolved decisions: 0 in this review
- Outside voice: Codex (gpt-6-astra), completed, 6 findings, all accepted
- Parallelization: 2 lanes, 2 parallel / 5 sequential
- Lake Score: 6/10 = answers picking a 10/10 option / answers scored for Completeness (D4, D5, D8, D9, D10, D12 at 10/10; D3 9/10, D13 9/10, D11 8/10, D2 6/10)

## GSTACK REVIEW REPORT

| Review | Trigger | Why | Runs | Status | Findings |
|--------|---------|-----|------|--------|----------|
| CEO Review | `/plan-ceo-review` | Scope & strategy | 0 | — | — |
| Outside Review | Codex (gpt-6-astra) via `/plan-eng-review` | Independent 2nd opinion | 1 | completed | 6 findings, all accepted (R7-R12) |
| Eng Review | `/plan-eng-review` | Architecture & tests (required) | 1 | ISSUES OPEN (all resolved into the plan) | 6 issues, 0 critical gaps |
| Design Review | `/plan-design-review` | UI/UX gaps | 0 | — | — |
| DX Review | `/plan-devex-review` | Developer experience gaps | 0 | — | — |

- **OUTSIDE COVERAGE:** Codex, plan-review phase, completed, 6 findings (2 High→CRITICAL feasibility/identity, 2 High sync/visibility, 2 Medium paging/keychain); all accepted.
- **CROSS-MODEL:** Claude and Codex agree on the silent-failure theme (A1 vs O4/O5); Codex alone found the Playground client mismatch, the `attendees[].self` meaning, paging, and the Keychain init swallow. No disagreements left open.
- **VERDICT:** No review CLEAR: Eng Review logged issues_open because it found 6 issues, all resolved into the plan with approved decisions; ready to implement. Eng review required (status is not "clean" by definition when issues were found).

NO UNRESOLVED DECISIONS
