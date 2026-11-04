# TODOS

## Speech

### Chunking for selections over 40,000 characters

**What:** Reintroduce a TextChunker with previous_text/next_text continuity so selections above the Flash v2.5 limit can be read, including chunk-aware resume and prefetch failure rules.

**Why:** v1 refuses anything over 40,000 characters (about 25 minutes of audio). Long PDFs and transcripts exceed it.

**Context:** Cut in the 2026-10-01 eng review (D1) because the default 10,000 cap never reaches the chunker. The drafted design lives in the git history of docs/designs/vibeflow-v1.md (Chunking section) and in reviewer concerns R3-1 and R3-2 at the end of that doc. Needs the (sessionID, attempt) guard from D11 so a failed prefetch cannot leak audio. Start by counting "Selection too long" refusals above 40k to see if anyone hits it.

**Effort:** M
**Priority:** P3
**Depends on:** v1 shipped and in daily use; evidence of >40k selections being attempted.

## File transcription

Follow-ups to docs/designs/file-transcription.md (eng review 2026-11-04). Build v1 first.

### Open With → VibeFlow for audio and video files

**What:** Register VibeFlow for audio and movie files (role Viewer, rank Alternate in project.yml `CFBundleDocumentTypes`) and handle `application(_:open:)` by opening the Transcribe File window with that file.

**Why:** A second way in from Finder, without going through the menu and the open panel.

**Pros:** Small; feels native. **Cons:** VibeFlow appears in every audio file's Open With list.

**Context:** Deferred in the design until v1 has been used for a week. Rank Alternate keeps VibeFlow from becoming the default app. Start in AppDelegate and project.yml.

**Effort:** S
**Priority:** P3
**Depends on:** file transcription v1 shipped.

### Ask about this call

**What:** Follow-up questions on a transcript, the way smart read's hold-to-ask works on a selection ("what did we agree on the budget?").

**Why:** The summary answers the common questions; follow-ups answer the rest without rereading 40 minutes of text.

**Pros:** Reuses the follow-up pipeline and the Claude client. **Cons:** The smart read document cap is 40,000 characters (`SessionConfiguration.hardMax`), about 45 minutes of talk, so long calls need chunking, retrieval or a bigger cap first.

**Context:** Shown on the design canvas (https://claude.ai/artifact/55Sq6xJC5bDbAhr4wQCqZe, transcript window) and cut from v1 in the 2026-11-04 eng review. Start with the cap problem, not the UI.

**Effort:** M
**Priority:** P3
**Depends on:** file transcription v1 shipped.

### Recognise voices across calls

**What:** Speaker names carry over between transcripts by matching voices (speaker embeddings), so "Florian" is named automatically next time.

**Why:** Renaming speakers on every call gets old for recurring calls.

**Pros:** Removes a repeated chore. **Cons:** Needs voice fingerprints stored locally, a matching threshold and a correction flow; much bigger than v1's per-file names.

**Context:** v1 keeps names per file (design O4). Check first whether the chosen call engine (T1 bake-off) offers speaker identification before building anything.

**Effort:** L
**Priority:** P4
**Depends on:** file transcription v1 shipped and the call engine chosen.

## Interaction

### Conversational mode: talk with an AI through VibeFlow and Flow

**Status:** designed 2026-10-01 in docs/designs/vibeflow-2-dictation-conversation.md (dictation plus conversation in one app). Milestone 1 (dictation) passed eng review 2026-10-02; milestone 2 (conversation) still needs its own eng review after a week of dictation use. Revised 2026-10-21: level one is now "hold the smart read key to ask a follow-up", planned and eng-reviewed in docs/designs/smart-read-follow-up.md. Level one shipped 2026-10-28 in 1.1.0: hold Option + , to ask, streamed answers, ten turns of context, History. Still open from the October design: typed questions, a transcript panel, reply drafting.

**What:** A flowing back-and-forth where VibeFlow speaks an AI reply, you answer by voice (Wispr Flow) or by selecting text, and the conversation keeps context across turns: follow-up questions about what was just read, "more detail", "read the original", "what should I reply".

**Why:** Florian after the first working build (2026-10-01): "a more communicative and flowy way of interacting with an AI using this software". Smart read is one-shot; this makes VibeFlow the voice of an assistant rather than a reader.

**Context:** Builds on the smart read pipeline (AnthropicClient, guarded prompts) and the Codex "depth dial" idea in docs/designs/vibeflow-v1.md. Open questions to settle in /office-hours: where the conversation state lives, how a turn starts (hotkey, hold-to-talk, auto after Flow dictation), how to interrupt mid-answer, and whether Flow can be detected or the mic is read directly. Start with a design session, not code.

**Effort:** L
**Priority:** P2
**Depends on:** v1 shipped; one week of daily use of smart read.

### Prompt caching for follow-up questions

**What:** Mark the document block of a follow-up question with `cache_control` so repeat questions about the same text reuse it.

**Why:** Every question re-sends the whole selection, up to 40,000 characters. Deferred in the follow-up eng review (D1, 2026-10-21) because the gain is unmeasured.

**Context:** docs/designs/smart-read-follow-up.md. Start in AnthropicClient's message builder. Trigger: answers about long documents feel slow.

**Effort:** S
**Priority:** P3
**Depends on:** follow-up questions (shipped 2026-10-28).

### Reply drafting loop

**What:** Hear an email, say what you want to answer, hear the draft read back, say "change X" or "use it", and the draft is pasted into the reply.

**Why:** Florian, 2026-10-01: wanted later, low priority. Builds on dictation and conversation.

**Context:** See docs/designs/vibeflow-2-dictation-conversation.md premise 6. Needs TextInserter from VibeFlow 2 milestone 1 and the conversation turn list from milestone 2.

**Effort:** M
**Priority:** P3
**Depends on:** VibeFlow 2 milestones 1 and 2.

### Meeting heads-up in the notch

**What:** One minute before a meeting, show its title in the notch indicator for a few seconds, with a click to join.

**Why:** The menu bar nudge can be pushed off a full menu bar on notched Macs (eng review D11); the notch cannot. A second, harder-to-miss signal.

**Context:** Out of scope for the first meetings version (docs/designs/upcoming-meetings.md, Q4; eng review D14). NotchIndicator.swift already animates in and out for reading and dictation; reuse it. Decide after a week of using the menu bar nudge.

**Effort:** S
**Priority:** P3
**Depends on:** upcoming meetings shipped.

### Focus timer extras only VibeFlow can do

**What:** Build on the focus timer: sessions that end before your next meeting (MeetingsStore), the VibeFlow voice announcing focus and break ends, focus progress in the notch (NotchIndicator), and a dictated session title.

**Why:** Parked on 2026-11-02 when the focus timer was designed as a plain Flow clone ("doesnt have to be super special for the start"). Each extra reuses something only VibeFlow has.

**Context:** docs/designs/focus-timer.md, section "What Makes This Cool". Start with meeting-aware sessions, because no other timer has them. FocusEngine takes `now` and a preset, so a meeting-shortened block is one more input.

**Effort:** M
**Priority:** P3
**Depends on:** the focus timer shipped and a week of daily use.

## Clipboard

### One clipboard owner across reads, dictation and paste again

**What:** A single clipboard owner that every clipboard transaction (a read's Copy capture, a dictation paste, paste again, Copy dictated text) must hold for its whole life, including writes that land late, so no two can overlap.

**Why:** Each session guards only its own steps today. Known edges left from the menu/paste-again PR (#10): a read stopped mid-capture goes idle while its Copy can still land (~300 ms) and paste again passes its guard; Copy dictated text checks idle once but does not hold the clipboard while its write is in flight, so a paste again started then can collide. Both need a slow or hanging clipboard or a sub-second double action.

**Context:** Same family as the inherited TextInsertion issues found in that review: a clipboard write that times out keeps running and can land after the paste gave up; ClipboardSnapshot keeps plain text only, so image, file and rich-text clipboards are replaced by any paste; focus is not re-checked after the async snapshot and write right before Cmd-V; and the restore writes the user's text back as transient, so ClipboardSourceTracker loses the AI-app source and the next clipboard smart read uses the narrator voice. Start from DictationSession.pasteAgain, TextInsertion.insert, PasteboardCapture and AppContainer's readIsCapturing / dictationCancelledByRead.

**Effort:** M
**Priority:** P2
**Depends on:** None

## Completed

### Last question and answer in the menu, with Copy answer

**What:** Two menu lines with the last spoken question and VibeFlow's answer, plus a Copy answer button.

**Why:** Commands, numbers and names in a spoken answer can't be pasted. Deferred in the follow-up eng review (D2, 2026-10-21).

**Context:** docs/designs/smart-read-follow-up.md. Start with a published `lastExchange` on ReadSession and MenuBarView.

**Effort:** S
**Priority:** P3
**Depends on:** follow-up questions shipped.

**Completed:** 2026-10-28, in 1.1.0 with the follow-up questions: `ReadSession.lastExchange`, two menu lines and Copy answer; the History window keeps older exchanges.

### Only give clipboard text the assistant voice when it was copied in the AI app

**What:** Remember NSPasteboard.changeCount while ChatGPT, Codex, Claude or Gemini is frontmost, and set aiReply for Shift + smart read only when the clipboard last changed there.

**Why:** Today Shift + smart read with an AI app in front treats any clipboard text as that assistant's reply. A phishing email copied in Mail and read with ChatGPT in front is voiced as "I'd reset your password at...". Both review models flagged it while shipping the assistant voice (2026-10-27).

**Context:** ReadSession.startClipboardRead sets session.aiReply from the frontmost app. Same pass noted: clipboard reads use the default preset, not the AI app's, and the attribution guard in SmartReadPrompts.aiReplyRule only covers links and payments a reply visibly quotes.

**Effort:** S
**Priority:** P2
**Depends on:** nothing.

**Completed:** 2026-10-28. ClipboardSourceTracker attributes each clipboard change to the app that was frontmost while NSPasteboard.changeCount moved (fed by NSWorkspace activations), and ReadSession gives Shift + smart read the assistant voice only when that app is the AI app in front. Transient pasteboard contents (VibeFlow's own restores) count as unknown.

## Distribution

### Guided onboarding for keys

**What:** A first-run window that explains the three keys, links to where to get each, and shows what already works without them (Apple voice, on-device dictation on macOS 26).

**Why:** The first users are non-technical friends who set up their own keys (office hours 2026-10-06). Today they must find Settings > Keys on their own.

**Effort:** S
**Priority:** P2

### Publish the Google app (In production)

**What:** Move the VibeFlow app in Google Auth Platform (floo.one project `vibeflow-513107`) from Testing to In production.

**Why:** In Testing, a Google sign-in expires after 7 days and only listed test users can sign in, so a release with Meetings is unusable for anyone else.

**Context:** Deferred from plan: docs/designs/upcoming-meetings.md (T1). Google's "Publish app" button stays disabled until Branding has a privacy policy link on the authorized floo.one domain. After publishing, any account can sign in with the unverified-app warning, up to 100 users until verification.

**Effort:** S
**Priority:** P1
**Depends on:** the privacy page from "Website on floo.one".

### Website on floo.one

**What:** A small static site at floo.one/vibeflow: what VibeFlow does, download link, privacy policy.

**Why:** Going public needs a home page, and Google's verification of the Calendar scope (upcoming meetings) requires a homepage and privacy policy on the verified floo.one domain.

**Context:** Requirements listed in docs/designs/upcoming-meetings.md ("Verification prerequisites"). Static pages, no CMS. The privacy policy must cover calendar data (read-only, stays on the Mac, in memory) and Google's Limited Use terms.

**Effort:** S
**Priority:** P2
**Depends on:** deciding to go public; pairs with the downloadable build.

### Downloadable build: notarized DMG and Homebrew cask

**What:** Sign with a Developer ID, notarize, attach a DMG to GitHub Releases, then publish a Homebrew cask.

**Why:** Without it, only people who can build from source can run VibeFlow, and Homebrew casks now require notarized apps.

**Context:** Needs the paid Apple Developer Program ($99/year). Deferred until people beyond friends want to run it (docs/designs/vibeflow-github-v1.md).

**Effort:** M
**Priority:** P3

## Settings

### Bring back vocabulary and per-app settings

**What:** UI for the dictation vocabulary and per-app presets (voice, speed, "Keep this app on this Mac", smart read instructions). Storage and logic still exist (Preferences.vocabulary, AppPreset, AppPresetStore).

**Why:** Removed from Settings on 2026-10-06 to keep it minimal; wanted long term.

**Effort:** S
**Priority:** P3


## Desktops

### Drift fixing for Desktop Roles

**What:** A dot on the role tag when a role's window sits on another desktop; a click sends it home.

**Why:** The third gap from the 2026-11-02 office hours ("fix drift later"); v1 only does the morning setup and the glance.

**Context:** docs/designs/desktop-roles.md. Reuses DesktopSetup's inventory and planner. macOS blocks moving windows between Spaces with SIP on, so "send home" may have to close and reopen the window in place; check that first.

**Effort:** M
**Priority:** P2
**Depends on:** Desktop Roles v1 morning walk.

### Clock out when switching to Personal

**What:** Entering the Personal role hides work apps (Slack, Mail) and turns on a Focus.

**Why:** Makes the desktops a line between work and home, not only a layout.

**Context:** Out of scope for v1 (premise 6 in docs/designs/desktop-roles.md). There is no public API to set a Focus; it would go through a user Shortcut.

**Effort:** S
**Priority:** P3
**Depends on:** Desktop Roles v1.

### Per-role VibeFlow context

**What:** A role also switches VibeFlow's own context: dictation vocabulary, project links, a "resume here" note.

**Why:** Codex's "coolest version" in the office hours second opinion.

**Context:** docs/designs/desktop-roles.md, Cross-Model Perspective. Shape it after two weeks of using v1 roles.

**Effort:** M
**Priority:** P3
**Depends on:** Desktop Roles v1 in daily use.

### Snapshot-first role setup

**What:** Arrange a desktop by hand and choose "Remember as Comms"; VibeFlow records apps, Chrome profile and tabs.

**Why:** Setup by doing instead of filling in a form (Approach C in the design).

**Context:** docs/designs/desktop-roles.md, Approaches Considered. Tab URLs need the Automation permission per browser. Sits on the v1 engine.

**Effort:** L
**Priority:** P3
**Depends on:** Desktop Roles v1.

## Feedback

### Link feedback to the crash that preceded it

**What:** When feedback is sent within 10 minutes of a captured crash or error, pass that event's id as `associatedEventId` so Sentry shows the note on the crash.

**Why:** Deferred in the feedback eng review (D2, 2026-11-02). Today a note and its crash are two items you match by install id.

**Pros:** "It just crashed" notes become actionable from one Sentry screen.

**Cons:** Persisted last-event id plus a time-window rule, both to test.

**Context:** docs/designs/feedback.md (F9, R-ledger D2). Start in FeedbackSender: remember the event id in `beforeSend`, keep it across relaunch, read it when the form opens.

**Effort:** S
**Priority:** P3
**Depends on:** the feedback PR shipped and a first real crash-plus-note pair.

### Show and send a screenshot in the feedback preview

**What:** Optional window screenshot that appears in the "What gets sent" preview, and send exactly those bytes.

**Why:** Dropped from the first version (D9, 2026-11-02) because pixels bypassed the text preview and Settings shows the Google email and calendar names.

**Pros:** Layout and visual bugs arrive with a picture.

**Cons:** Needs an image preview, a decision on which window to capture, and care with panes that show account data.

**Context:** docs/designs/feedback.md (R6). `NSView.cacheDisplay` on the window's content view needs no screen-recording permission; check how the sidebar's visual effect view renders.

**Effort:** S
**Priority:** P3
**Depends on:** the feedback PR shipped; a visual bug that was hard to describe.

## Context

### Suggest context learned from history

**What:** VibeFlow proposes additions to Context (About you, Terms and people, per-app rules) from what you read, ask and dictate, for example a name it keeps hearing or an app whose briefs you always follow up the same way. Each suggestion waits for your approval in the Context window; nothing is added on its own.

**Why:** Context only helps if it is filled in, and most people never write a profile or a term list by hand.

**Context:** Asked for on 2026-11-05 when the Context window was built (PR floo-one/vibeflow#43); deliberately left for later. The suggestions have to be computed from History on the Mac and must never reach the logs (CLAUDE.md: never log user text), so any model call that finds them needs the same guard as smart read. Start from the History entries (text, question, source app).

**Effort:** M
**Priority:** P3
**Depends on:** the Context window in daily use for a while.
