# Design: Ask a follow-up about what you just heard

Status: shipped 2026-10-28 in 1.1.0 (plan drafted 2026-10-21). Replaces the "Conversation (milestone 2)" section of
docs/designs/vibeflow-2-dictation-conversation.md with a smaller version that fits how VibeFlow
works today (push-to-talk only, the notch, minimal Settings). Eng-reviewed 2026-10-21 (report at
the end); one open decision, R3.

## Problem

Smart read gives a one-shot brief. With AI answers in particular, the brief often misses the one
thing Florian wanted to know. Today the only way on is to read the whole text or paste it into a
chat. He wants to ask back: "so which option did it recommend?", "what does that mean for me?",
"say the command again".

## The day-to-day flow

1. Select an AI answer, tap **Option + ,** and hear the brief (unchanged).
2. **Hold Option + ,**, say the question, let go. VibeFlow speaks the answer.
3. Hold again for the next question. Context carries over.

Variants that fall out of the same rules:

- Hold while the brief or an answer is still speaking: playback stops, the question is recorded
  (barge-in).
- Select text and hold without smart reading first: skips the brief and answers the question
  about the selection directly ("select, hold, ask").
- Works after a plain read (Option + .) too; the text that was read is the context.

## Key decisions

### D1. Trigger: hold the smart read key (recommended) instead of reusing the dictation key

The October design made the dictation key mean "ask" while a conversation was open. That breaks
the main use case: after hearing an AI answer you often want to dictate a reply into the same chat
box, and the source app has not changed, so the key would ask VibeFlow instead of pasting. It also
needed a mode panel, Escape handling, an inactivity timeout and app-switch detection just to make
the mode visible and end it.

Holding the smart read key keeps the two jobs on different keys and makes "the comma key is the
AI key" the whole mental model:

| Smart read key | Today | New |
|---|---|---|
| Tap while idle | Smart read the selection | Same |
| Tap while busy | Stop | Same |
| Hold 0.3 s or longer | (fires on release, same as tap) | Record a question, answer on release |

A tap is unchanged because smart read already fires on key up. The microphone opens only when
the hold passes 0.3 s, with the start cue telling you to talk, so a tap never opens the mic or
makes a sound (eng review D5). Words spoken before the cue are not recorded.

Alternative: a separate Ask shortcut. One more key to learn and configure, no gain over holding.

### D2. Which text a question is about

On release VibeFlow captures the selection the same way smart read does today, then:

- Selection non-empty and different from the current context: start a new context with it.
- Accessibility reports nothing selected, or the same text: continue the current context.
- Capture failed (Copy failure, timeout, clipboard drift, app switch): "Couldn't read the
  selection", nothing is asked (eng review D11). In apps that need the Copy fallback, keep the
  text selected to ask follow-ups.
- No selection and no context, or the context is older than 30 minutes: "Select text to ask about".

So "go back and ask" works even after switching apps, and selecting something new silently
starts over. No end-of-conversation gesture is needed.

### D3. No transcript panel in v1; the notch is enough

- Notch: a question-bubble wing while recording a question, the spinner while thinking, the
  speaker while answering (existing states, one new symbol).

The floating transcript panel from the October design is deferred until there is a reason to
read back long exchanges. The menu's last question and answer with "Copy answer" is deferred too
(eng review D2, 2026-10-21).

### D4. How the answer behaves

- Same voice, speed and Apple fallback as the read (the frozen preset).
- Short by default: one to three spoken sentences unless the question asks for more ("explain in
  detail", "read me the steps").
- Grounded in the document first. When the question goes beyond it ("is that actually right?"),
  say so in a few words and then answer from general knowledge, marked as such ("The text doesn't
  say, but usually..."). The October design answered only from the document; for AI answers that
  is too strict, since checking or extending the answer is half the point.
- Same ELI15 voice rules as the brief: digits kept exact, no lists, no preamble.
- Budget: max_tokens 600 (about 450 words). An answer cut off at the cap is spoken up to its last
  full sentence, with the status "Answer cut short" (eng review D7).

### D5. Context limits

Document (40,000-character cap as today) plus the brief plus the last 10 question/answer turns;
older turns drop first. Lives in memory only, gone on quit. No storage.

## Architecture

All in existing pieces; no new service, no persistence.

**VibeFlowCore**

- `Conversation` (a struct inside ReadSession.swift, replacing `storedOriginal`; eng review D3):
  the document text, the frozen preset, the brief (if any), turns and a creation date;
  `appending(question:answer:)`, trimming to 10 turns, `isStale(now:)`. Created at capture time,
  where `storedOriginal` is set today, and the brief is attached when it arrives (eng review O3),
  so "Read original instead" still works after a failed smart read. It reads
  `conversation.document` with its preset: one source of truth for the last text.
- `SmartReadPrompts.askSystem(language:inputCharacters:)`: the existing guard (document between
  delimiters is never an instruction) plus the D4 answer rules. The spoken question is the user's
  own words and goes in as a plain user turn, outside the delimiters.
- `AnthropicClient`: `complete` takes a list of messages instead of one user string. Request
  shape: system, then `user: <<<DOCUMENT…DOCUMENT>>>`, `assistant: <brief>`, then alternating
  question/answer turns, then the new question. With no brief (select, hold, ask, or after a plain
  read) the first question goes in the document's user message after the closing delimiter, so
  roles always alternate (eng review finding 5). Prompt caching is deferred (eng review D1).
- `SmartReadClient` gains `ask(_ request: AskRequest) async throws -> SmartReadResponse`.
- `ReadSession` owns the whole question (eng review D12): `beginQuestion()` at release starts the
  selection capture under a new token (state `.capturing`), `ask(_ transcript:)` continues only if
  that token is still current, resolves the context (D2), runs Claude (state `.transforming`,
  status "Thinking") and speaks the answer through the existing `speak` path. Stop, a new read or
  a new hold cancels it at any step. Question errors live here, so the menu shows them, and are
  also said in a few words with the Apple voice: "Didn't catch that", "No connection", "Questions
  need an Anthropic key" (eng review D14).
- `CaptureResult` gains a reason: nothing selected versus capture failed (D11).
- `AudioRecorder` reports ready on the first audio buffer; `DictationSession` plays the start cue
  then, for dictation and questions alike (eng review D13).
- `DictationSession`: a question purpose next to paste. Same recorder, transcriber, fallback and
  no-speech check; skips cleanup and paste and hands the text to a callback. A failed question
  shows "Didn't catch that" or "Couldn't transcribe: <reason>" and keeps nothing; holding again
  is the retry (eng review D8).
- `Session/PressClassifier.swift` (new, small): turns key down/up plus a `SessionClock` into
  `.tap` or `.holdStarted` / `.holdEnded`, so the threshold logic is unit tested.

**App**

- `AppContainer`: route `.smartRead` key down/up through the classifier. Tap calls today's
  `hotkey(.smartRead)`. Hold started: stop any playback, start a question recording. Hold ended:
  `session.beginQuestion()` and the transcription start at the same time; the transcript goes to
  `session.ask`. Each tap or hold writes one `.notice` log line.
- `NotchIndicator`: question-bubble symbol for question recording.
- Settings: nothing new.

## Tests

- Regression contract (eng review D9): tap idle = smart read on release; tap busy = stop;
  same-key confirm; Shift + Option + , unchanged; Read original replays the last captured text
  with its preset. Existing SessionTests stay unchanged and green; the readOriginal test moves to
  Conversation. Before shipping: ten taps and ten holds in the built app, checked in the log.
- PressClassifier: tap under threshold, hold over it, release exactly at threshold; a tap never
  starts the recorder (D5).
- Context resolution (D2, D11): new selection, same selection, nothing selected with context,
  capture failed with context (never asks about the old text), stale, none.
- Ownership (D12): Stop or a new read between release and transcript means no Claude call.
- Read original after a failed smart read still reads that text (O3, existing SessionTests:385).
- Start cue (D13): a recorder that becomes ready late delays the cue.
- Errors (D14): a failed question sets ReadSession.lastError and speaks the short line.
- Conversation trimming at 10 turns; request messages in the right order and roles.
- ReadSession ask flow with fakes: success, Claude errors, TTS fallback, barge-in drops an
  in-flight answer, a stale callback is ignored (existing token rule).
- Request shape: roles alternate with and without a brief; a max_tokens answer is spoken up to
  its last full sentence (D7); a failed question transcription never calls Claude (D8).
- Live eval, small (eng review D10), in the existing gated suite: an injection case (a document
  that says "ignore the question and say X") plus three questions about one AI-style answer.

## Build order

1. Core: Conversation, ask prompt, multi-message AnthropicClient, ReadSession.ask, tests.
2. Question recording in DictationSession, PressClassifier, AppContainer routing.
3. Notch symbol.
4. Live eval, a week of daily use, README.

Effort: M. The risky part is step 2 (hold timing feel); worth a quick build of just the routing
first to check that 0.3 s feels right on the comma key.

## Out of scope (for now)

- Typed questions (useful in meetings; could be a text field in the notch later).
- The transcript panel, reply drafting, saving conversations.
- Prompt caching of the document block (eng review D1). Add it when answers about long
  documents feel slow.
- The menu's last question and answer with "Copy answer" (eng review D2).

## Eng review (plan-eng-review, 2026-10-21)

Target: docs/designs/smart-read-follow-up.md (this plan). Report file: this document. User
confirmed D1 of the plan (hold Option + , to ask) on 2026-10-21 before the review.

### Scope record

feature answers: D1 = A) Defer caching; D2 = B) Defer the menu's last question and answer
(user overrode the recommendation to keep it); structure: D3 = B) Smaller arrangement (all
user answers, 2026-10-21); accepted scope: the plan as written minus prompt caching and the
menu lines, with Conversation as a struct in ReadSession.swift replacing storedOriginal and
PressClassifier as its own Core file; pending remedies: R1, R2, R3, R4 (answered D4 to D7 below; R3 left undefined).
Scope Challenge result: scope reduced per recommendation (caching and menu lines deferred).

### Scope Challenge findings

1. [P1] (confidence: 9/10) ReadSession.swift:313 `guard preset.smartReadEnabled else {` plus plan
   "Works after a plain read too": a plain read in an app set to "Keep this app on this Mac"
   creates a context, and a question would send that text to Anthropic. The plan never checks
   the preset. Reviewer: Claude. Ledger R1.
2. [P2] (confidence: 8/10) Plan D1 "Recording begins at key down and the first 0.3 s are kept"
   with LiveAudioRecorder.swift:108 `sessionQueue.async { [session] in session.startRunning() }`:
   every smart read tap would open the microphone (orange privacy dot, capture session start,
   and the microphone permission prompt on the first smart read). Reviewer: Claude. Ledger R2.
3. [P2] (confidence: 8/10) Plan D1 table covers idle and "busy" only. ReadSession states
   (ReadSession.swift:19-26 `capturing`, `awaitingConfirm`, `transforming`) and dictation being
   busy (AppContainer.swift:107 `dictationCancelledByRead`) have no hold rule, nor does a hold
   while a brief or an answer is still being generated. Reviewer: Claude. Ledger R3.
4. [P2] (confidence: 8/10) ReadSession.swift:351 `guard response.stopReason == .endTurn ... else {
   fail("Smart read incomplete"` and no answer token budget in the plan: a long answer ("read me
   the steps") hits max_tokens and fails outright. Reviewer: Claude. Ledger R4.
5. [P3] (confidence: 7/10) Factual correction, no behavior change: with no brief (select, hold,
   ask, or after a plain read) the planned shape gives two user messages in a row. Spec fix: when
   there is no brief, the first question goes in the same user message as the document, after the
   closing delimiter; roles then alternate. A request-shape test checks it. No question needed.

## Decision ledger

### R1: Questions in apps kept on this Mac
Finding: 1, P1, confidence 9/10, ReadSession.swift:313, reviewer Claude
Plan baseline: original proposal; any context can be asked about, transcription uses the
default transcriber.
Runtime evidence: smart read already refuses to send text for such apps and reads the original
instead (ReadSession.swift:313-318); dictation uses on-device only when `dictationLocalOnly`
(DictationSession.swift:322).
Comparison grid:
| Choice | Current | A | B |
|---|---|---|---|
| R1 ask in local-only apps | sends text to Anthropic | refuse: "Questions stay off for this app", nothing recorded or sent | unchanged |
| R2 recording start | pending | pending | pending |
| R3 hold rules | pending | pending | pending |
| R4 answer budget | pending | pending | pending |
Question D4: see the AskUserQuestion of 2026-10-21 (verbatim in chat).
Header: Local apps
Options:
A) Refuse in local-only apps (recommended)
When the context's frozen preset has smart read off, a hold says "Questions are off for this app" and records nothing. Test: ReadSession ask with a local-only preset sends no request.
B) No change
Questions work everywhere, including apps marked to stay on this Mac.
State: approved
Actual answer: B) No change (user answer to D4, 2026-10-21; overrode the recommendation)
Accepted scope: none; questions work in every app, including apps kept on this Mac. Accepted risk recorded in the report.
History: none

### R2: When the question recording starts
Finding: 2, P2, confidence 8/10, plan D1 and LiveAudioRecorder.swift:108, reviewer Claude
Plan baseline: original proposal; recording starts at key down, first 0.3 s kept.
Runtime evidence: the recorder starts an AVCaptureSession, which lights the microphone indicator.
Comparison grid:
| Choice | Current | A | B |
|---|---|---|---|
| R2 recording start | at key down | at the 0.3 s hold mark, start cue tells you to talk | at key down |
| R1, R3, R4 | pending | pending | pending |
Question D5: see chat.
Header: Mic start
Options:
A) Start at the hold mark (recommended)
Mic opens only once the hold passes 0.3 s; taps never touch the microphone. Test: PressClassifier tap never starts the recorder.
B) Start at key down
Keeps the first 0.3 s of speech; mic opens on every smart read tap.
State: approved
Actual answer: A) At the hold mark (user answer to D5, 2026-10-21)
Accepted scope: Mic opens only once the hold passes 0.3 s; taps never touch the microphone. Test: a tap never starts the recorder.
History: none

### R3: Hold rules in every state
Finding: 3, P2, confidence 8/10, ReadSession.swift:19-26 and AppContainer.swift:107, reviewer Claude
Plan baseline: original proposal; only idle and busy covered.
Runtime evidence: tap rules come from the Hotkey x state table in ReadSession.hotkey.
Comparison grid:
| Choice | Current | A | B |
|---|---|---|---|
| R3 hold while capturing, confirming, generating a brief or answer, or speaking | undefined | cancel what runs (a brief being generated is dropped; an answer being generated drops its question; a spoken answer cut off stays in context marked interrupted), then record | undefined |
| R3 hold while dictation is busy | undefined | cancels the dictation and does nothing else, like a tap today | undefined |
| R1, R2, R4 | pending | pending | pending |
Question D6: see chat.
Header: Hold rules
Options:
A) Hold always takes over (recommended)
The table in the grid, written into the plan and covered by one table-driven ReadSession test.
B) Leave undefined
Decide while building.
State: pending
Actual answer: B) Leave undefined (user answer to D6, 2026-10-21; overrode the recommendation)
Accepted scope: none; hold behavior while capturing, confirming, generating, speaking or dictating is decided while building. Stays an unresolved decision.
History: none

### R4: Answer length budget
Finding: 4, P2, confidence 8/10, ReadSession.swift:351, reviewer Claude
Plan baseline: original proposal; no token budget, the brief's incomplete rule would apply.
Runtime evidence: a max_tokens stop fails the read with "Smart read incomplete".
Comparison grid:
| Choice | Current | A | B |
|---|---|---|---|
| R4 answer budget | none | max_tokens 600; if cut off, speak the complete sentences that arrived and note "Answer cut short" | max_tokens 600; if cut off, fail like the brief |
| R1, R2, R3 | pending | pending | pending |
Question D7: see chat.
Header: Answer cap
Options:
A) Speak what fits (recommended)
600 tokens (about 450 words), cut answers are spoken up to the last full sentence with a note. Test: max_tokens response speaks the trimmed text.
B) Fail when cut
600 tokens, a cut answer fails with Retry.
State: approved
Actual answer: A) Speak what fits (user answer to D7, 2026-10-21)
Accepted scope: max_tokens 600; a cut answer is spoken up to its last full sentence with 'Answer cut short'. Test: a max_tokens response speaks the trimmed text.
History: none

### R5: Question transcription failures
Finding: Section 1 finding A1, P2, confidence 7/10, DictationSession.swift:388-395 (`case .copiedInstead(let reason): lastFailure = FailedDictation(...)`, actions copyText/discard), reviewer Claude
Plan baseline: original proposal; "a question purpose next to paste ... skips cleanup and paste", failure behavior unstated.
Runtime evidence: dictation failures keep the audio in lastFailure with Retry, Copy text and Discard actions, all paste-oriented.
Comparison grid:
| Choice | Current | A | B |
|---|---|---|---|
| R5 question transcription failure | unstated | status line "Didn't catch that" or "Couldn't transcribe: <reason>", audio dropped, hold again to retry | reuse lastFailure: audio kept, Retry re-transcribes, then asks |
| R6, R7 | pending | pending | pending |
Question D8: see chat.
Header: Mic errors
Options:
A) Hold again to retry (recommended)
Question failures show a one-line status; nothing is kept. Test: transcriber failure in question mode sets the status and never calls Claude.
B) Keep audio for Retry
Reuse the dictation failure record so Retry re-transcribes the same audio.
State: approved
Actual answer: A) Hold again (user answer to D8, 2026-10-21)
Accepted scope: Question failures show 'Didn't catch that' or 'Couldn't transcribe: <reason>'; nothing kept. Test: transcriber failure in question mode never calls Claude.
History: none

### R6: Regression contract for the smart read key
Finding: Section 3 regression rule, P1, confidence 9/10, AppContainer.swift:91 (`KeyboardShortcuts.onKeyUp(for: .smartRead) { [weak self] in self?.hotkey(.smartRead) }`), reviewer Claude
Plan baseline: plan says "A tap is unchanged"; no regression assertions named.
Runtime evidence: SessionTests.swift covers the hotkey table (e.g. :39 "Stopped", :50, :150) and readOriginal (:385) against storedOriginal, which D3 replaces.
Comparison grid:
| Choice | Current | A | B |
|---|---|---|---|
| R6 behavior preserved | implicit | tap idle = smart read on release; tap busy = stop; same-key confirm; Shift + Option + , unchanged; Read original replays the last captured text with its preset | same |
| R6 proof | none | existing SessionTests unchanged and green, readOriginal test moved to Conversation, PressClassifier tests (release before 0.3 s fires one tap; hold never fires a tap) | A plus a manual check in the built app: ten taps and ten holds, verified with a log line per classification |
| R5, R7 | pending | pending | pending |
Question D9: see chat.
Header: Tap safety
Options:
A) Unit tests only
Contract above, proven by unit tests.
B) Unit tests plus real-key check (recommended)
Same contract and tests, plus ten taps and ten holds in the built app with a .notice log line per classification.
State: approved
Actual answer: B) Tests plus key check (user answer to D9, 2026-10-21)
Accepted scope: Contract in the grid; existing SessionTests unchanged, readOriginal test moved to Conversation, PressClassifier tests, ten taps and ten holds in the built app with a .notice log line per classification.
History: none

### R7: Live eval for answers
Finding: Section 3 LLM/eval scope, P2, confidence 8/10, LiveEvalTests.swift:18 (`@Suite("Live evals", .enabled(if: liveEvalsEnabled))`), reviewer Claude
Plan baseline: plan proposes an AI answer and a contract, ten questions, 9 of 10, 3 s median, and an injection case.
Runtime evidence: gated live evals already exist for the brief and cleanup, including injection cases (:68, :84).
Comparison grid:
| Choice | Current | A | B |
|---|---|---|---|
| R7 eval depth | none | plan's eval plus one beyond-the-document question that must be marked as general knowledge, in the existing gated suite | injection case plus three questions |
| R5, R6 | pending | pending | pending |
Question D10: see chat.
Header: Answer eval
Options:
A) Full eval (recommended)
Two documents, ten questions with expected facts (9 of 10), injection case, one beyond-the-document case, key up to first audio median logged.
B) Small eval
Injection case plus three questions.
State: approved
Actual answer: B) Small eval (user answer to D10, 2026-10-21; overrode the recommendation)
Accepted scope: Injection case plus three questions in the gated live suite. The 9 of 10 bar and the 3 s median are not measured.
History: none

### Outside voice corrections (no question)

- O3 (Codex, High, verified): ReadSession.swift:260 `storedOriginal = (text, session.preset)` runs
  at capture time, before Claude can fail. The Conversation must be created at the same point and
  the brief attached when it arrives; "after every successful read" in the plan is corrected.
  Required by the approved D9 contract (Read original after a failed smart read), so no question.
  The existing SessionTests.swift:385 test keeps running through ReadSession, not just Conversation.

### R8: Capture failure versus nothing selected (outside voice O1)
Finding: O1, High, confidence 9/10, PasteboardCapture.swift:35-55 (`return .none` on Copy failure, timeout, drift and app switch), reviewer Codex
Plan baseline: D2 "Selection empty or the same text: continue the current context."
Runtime evidence: the Copy fallback returns `.none` for both an empty selection and a failure; only the Accessibility path can say "nothing selected" for sure.
Comparison grid:
| Choice | Current | A | B | C | D |
|---|---|---|---|---|---|
| R8 capture failure on a question | continues old context | Accessibility says nothing selected: continue; a Copy failure, timeout or drift: stop with "Couldn't read the selection" | unchanged | investigate how often Copy fails per app before choosing | defer, unchanged for now |
Question D11: see chat.
Header: Capture fail
Options:
A) Apply this change (recommended)
CaptureResult gains a reason (nothing selected versus failed); only nothing selected continues the context. Test: a failed capture after reading A never asks about A.
B) Keep this row's current value
Any empty capture continues the last context.
C) Investigate before choosing
Log capture outcomes for a week, then decide.
D) Defer this proposed change only
Leave unresolved.
State: approved
Actual answer: A) Apply this change (user answer to D11, 2026-10-21)
Accepted scope: CaptureResult says nothing-selected versus failed; only nothing-selected continues the context; failures say 'Couldn't read the selection'. Test: a failed capture after reading A never asks about A.
History: none

### R9: One owner for the whole question (outside voice O2)
Finding: O2, High, confidence 9/10, ReadSession.swift:155 token rule and AppContainer.swift:119 `isRunning`, reviewer Codex
Plan baseline: AppContainer chains capture, transcription and `session.ask`.
Runtime evidence: tokens only guard ReadSession's own work; between transcription and capture both sessions can be idle, so Stop is greyed out.
Comparison grid:
| Choice | Current | A | B | C | D |
|---|---|---|---|---|---|
| R9 question ownership | AppContainer glue | ReadSession owns it: `beginQuestion()` at release starts capture under a new token (state capturing), `ask(transcript)` continues only if that token is current | unchanged | investigate | defer |
Question D12: see chat.
Header: Ownership
Options:
A) Apply this change (recommended)
Stop, a new read or a new hold cancels the question at any point. Test: cancel between release and transcript, then no Claude call.
B) Keep this row's current value
AppContainer glue as planned.
C) Investigate before choosing
Prototype both and compare.
D) Defer this proposed change only
Leave unresolved.
State: approved
Actual answer: A) Apply this change (user answer to D12, 2026-10-21)
Accepted scope: ReadSession.beginQuestion() at release starts capture under a new token; ask(transcript) continues only if current. Test: cancel between release and transcript, then no Claude call.
History: none

### R10: Start cue only when the mic is live (outside voice O4)
Finding: O4, Medium, confidence 8/10, DictationSession.swift:279 `cue(.recordingStarted)` right after LiveAudioRecorder.swift:108 queues `startRunning()`, reviewer Codex
Plan baseline: D5 "the start cue telling you to talk".
Runtime evidence: the cue plays before the capture session runs; dictation has the same gap today.
Comparison grid:
| Choice | Current | A | B | C | D |
|---|---|---|---|---|---|
| R10 cue timing | at recorder start call, dictation and questions | when the first audio buffer arrives, for dictation and questions (shared recorder) | unchanged | measure the gap first | defer |
Question D13: see chat.
Header: Start cue
Options:
A) Apply this change (recommended)
AudioRecorder reports ready on the first buffer; DictationSession plays the cue then. Test: a fake recorder that becomes ready late delays the cue.
B) Keep this row's current value
Cue as soon as recording is requested.
C) Investigate before choosing
Log the cue-to-first-buffer gap for a week.
D) Defer this proposed change only
Leave unresolved.
State: approved
Actual answer: A) Apply this change (user answer to D13, 2026-10-21)
Accepted scope: AudioRecorder reports ready on the first buffer; the cue plays then, for dictation and questions. Test: late-ready recorder delays the cue.
History: none

### R11: Where question errors show up (outside voice O5)
Finding: O5, Medium, confidence 8/10, NotchIndicator.swift:112 (no status text) and MenuBarView.swift:16 (`if container.showsDictation`), reviewer Codex
Plan baseline: D8 one-line status; where it shows is unstated.
Runtime evidence: the menu shows one session's status; the notch hides when idle.
Comparison grid:
| Choice | Current | A | B | C | D |
|---|---|---|---|---|---|
| R11 error display | unstated | question status and errors live on ReadSession (menu shows them) and a failed question is also said aloud in a few words with the Apple voice | ReadSession and menu only | investigate | defer |
Question D14: see chat.
Header: Errors
Options:
A) Apply this change (recommended)
Errors on ReadSession plus spoken: "Didn't catch that", "No connection", "Questions need an Anthropic key". Test: a failed question sets lastError and speaks the short line.
B) Keep this row's current value
ReadSession and menu only, nothing spoken.
C) Investigate before choosing
Try both in daily use.
D) Defer this proposed change only
Leave unresolved.
State: approved
Actual answer: A) Apply this change (user answer to D14, 2026-10-21)
Accepted scope: Question status and errors on ReadSession (menu shows them), plus a few spoken words with the Apple voice. Test: a failed question sets lastError and speaks the short line.
History: none

Approval readiness: PASS. Checked: scope record (D1 A, D2 B, D3 B), R1 (D4 B), R2 (D5 A), R3 (D6 B, left
pending as an unresolved decision), R4 (D7 A), R5 (D8 A), R6 (D9 B), R7 (D10 B), R8 (D11 A), R9
(D12 A), R10 (D13 A), R11 (D14 A); O3 and finding 5 are corrections under the approved D9 contract;
TODOs D15 A, D16 A. All answers dated 2026-10-21.

## Review body

### Reality rows

- REALITY: premise-table pass 6 claims checked, unverified=1 (that Anthropic merges consecutive user turns; moot after finding 5) ReadSession.swift:85, AppContainer.swift:91, DictationSession.swift:318, SessionConfiguration.swift:9, PasteboardCapture.swift:35, LiveAudioRecorder.swift:108
- REALITY: already-done pass origin/main has no commits since 2026-10-21 touching VibeFlow or VibeFlowCore; head 5849bc1 AppContainer.swift:91
- REALITY: surface-check pass Messages API `messages` array already used by the client; `cache_control` deferred (D1) AnthropicClient.swift:72
- REALITY: binding-decisions pass consistent with "conversation about the selection" (2026-10-01); the dictation-key ask rule of the October design is superseded by the user's 2026-10-21 choice docs/designs/vibeflow-2-dictation-conversation.md:38
- REALITY: numbers pass 0.3 s [estimated], 30 min [estimated], 10 turns [from October design], 600 tokens [estimated], 40,000 chars [measured: SessionConfiguration.swift:9] SessionConfiguration.swift:9
- REALITY: deferred-asks pass no linked issue TODOS.md:22
- REALITY: pr-count pass one PR (no .gstack/ship-policy.json, default) project.yml:1

### NOT in scope

- Prompt caching of the document (D1): unmeasured gain; TODO added with its trigger.
- Menu last question and answer with Copy answer (D2): user prefers voice only for v1; TODO added.
- Transcript panel, typed questions, reply drafting, saved conversations: not needed for the
  day-to-day loop.
- Hold rules while capturing, confirming, generating, speaking or dictating (D6): left to build
  time by the user; listed as unresolved.
- Shift + Option + , hold (ask about the clipboard): not requested; the Shift variant keeps tap
  behavior only.

### What already exists

- `ReadSession.storedOriginal` and `readOriginal()` (ReadSession.swift:85, :219): grown into the
  Conversation (D3), not rebuilt.
- Dictation recording, Groq/Apple fallback and no-speech check (DictationSession.swift:318-360):
  reused for questions; cleanup and paste skipped.
- Push-to-talk key down/up handling (AppContainer.swift:94-95): the pattern for the hold.
- Guarded document prompt and delimiters (SmartReadPrompts.swift): reused for the answer prompt.
- Token rule against stale callbacks (ReadSession.swift:155): extended to the whole question (D12).
- Automatic microphone that avoids AirPods call quality (October design R5): covers questions too.
- Gated live eval suite (LiveEvalTests.swift:18): extended with a small answer eval (D10).

### Diagrams

Question flow (after D5, D11, D12, D13, D14):

```
Option + , down ──► PressClassifier ──(released < 0.3 s)──► tap: ReadSession.hotkey(.smartRead)  [unchanged]
                         │
                    (held ≥ 0.3 s)
                         ▼
            stop playback, DictationSession.startQuestion()
            recorder ready on first buffer ──► start cue (D13)
                         │
Option + , up ───────────┤
                         ├──► ReadSession.beginQuestion()  new token, state .capturing
                         │        capture selection ──► nothing selected / same text ─► keep context
                         │                          ├─► new text ─────────────────────► new context
                         │                          └─► capture failed ──► "Couldn't read the selection" (D11)
                         └──► transcribe (Groq, Apple fallback, no-speech check)
                                  ├─ fail/silence ──► ReadSession error, spoken short line (D8, D14)
                                  ▼
                         ReadSession.ask(transcript)  token still current? else drop (D12)
                                  ▼
                         Claude: system + [doc(+q1 if no brief)] [brief] [turns…] [q]
                                  ├─ error ──► lastError + spoken short line (D14)
                                  ├─ max_tokens ─► speak to last full sentence, "Answer cut short" (D7)
                                  ▼
                         speak answer (ElevenLabs, Apple fallback) ──► append turn, trim to 10
```

ReadSession.swift needs an inline comment block for the question states next to the existing
Hotkey x state table comment.

### Test review

```
CODE PATHS                                              USER FLOWS
[+] PressClassifier (new)                               [+] Ask a follow-up
  ├── [GAP] tap < 0.3 s fires one tap, no recorder        ├── [GAP] brief, hold, ask, answer, ask again
  ├── [GAP] hold ≥ 0.3 s never fires a tap                ├── [GAP] select, hold, ask (no brief)
  └── [GAP] release exactly at threshold                  ├── [GAP] hold while brief is speaking (barge-in)
[+] ReadSession                                           └── [GAP] 10 taps + 10 holds on a real keyboard (manual, D9)
  ├── hotkey table             [★★★ TESTED] SessionTests  [+] Error states
  ├── readOriginal after fail  [★★  TESTED] :385 → move    ├── [GAP] silence → "Didn't catch that", spoken
  ├── beginQuestion/ask token  [GAP] cancel before ask    ├── [GAP] capture failed → never asks about old text
  ├── context resolution D2    [GAP] 6 cases              ├── [GAP] Claude 401/offline → spoken short line
  ├── max_tokens answer        [GAP] trimmed speech       └── [GAP] local-only app (D4: allowed; no test required)
  └── Claude errors            [GAP] mapping + spoken
[+] AnthropicClient
  └── request roles            [GAP] with and without brief
[+] DictationSession
  ├── question purpose         [GAP] no cleanup, no paste
  └── cue on first buffer      [GAP] late-ready recorder
[+] CaptureResult reason       [GAP] nothing selected vs failed

LLM integration: [GAP] [→EVAL] answer prompt: injection case + three questions (D10, small)

COVERAGE: 2/22 paths tested (9%)  |  Code paths: 2/15  |  User flows: 0/7
QUALITY: ★★★:1 ★★:1  |  GAPS: 20 (1 eval, 1 manual check)
```

Test plan artifact: ~/.gstack/projects/vibeflow/floo-smart-read-followup-questions-6e33a8-eng-review-test-plan-20261021-203237.md.
Tests made obsolete: none; SessionTests.swift:385 moves from storedOriginal to Conversation.

### Failure modes

| New path | Realistic failure | Test | Handling | User sees |
|---|---|---|---|---|
| Hold classification | quick tap read as hold | PressClassifier + manual | threshold | a stray cue; no harm |
| Question capture | Copy fails in an Electron app | D11 test | "Couldn't read the selection" | spoken error |
| Transcription | Groq down, Apple no assets | D8 test | existing fallback, then error | spoken error |
| Claude answer | offline or 529 | D14 test | lastError | spoken error |
| Late callback | Stop pressed mid-question | D12 test | token drop | nothing, as expected |
| Hold during a running brief | undefined (D6) | none | none decided | unknown |

Critical gaps: 0 (the D6 row has no handling or test, but it is an open decision the user left to
build time, not a silent failure the plan claims to handle).

### Worktree parallelization strategy

| Step | Modules touched | Depends on |
|------|----------------|------------|
| Answer prompt and multi-message client | VibeFlowCore/SmartRead | — |
| Conversation, beginQuestion/ask, errors | VibeFlowCore/Session | Answer prompt |
| CaptureResult reason | VibeFlowCore/Capture | — |
| Question purpose, cue on first buffer | VibeFlowCore/Dictation, VibeFlow (LiveAudioRecorder) | — |
| PressClassifier and routing, notch symbol | VibeFlowCore/Session, VibeFlow | Conversation, Question purpose |

Lane A: answer prompt → Conversation/ask (SmartRead, Session). Lane B: CaptureResult reason
(Capture). Lane C: question purpose and cue (Dictation, recorder). Launch A + B + C. Merge. Then
routing and notch. Conflict flag: lanes A and the final step both touch VibeFlowCore/Session, so
routing waits for A.

## Implementation Tasks
Synthesized from this review's findings. Each task derives from a specific
finding above. Run with Claude Code or Codex; checkbox as you ship.

- [x] **T1 (P1, human: ~4h / CC: ~20min)** — SmartRead — Answer prompt and multi-message client
  - Surfaced by: Scope Challenge finding 5, R4 (D7)
  - Files: VibeFlowCore/Sources/VibeFlowCore/SmartRead/SmartReadPrompts.swift, AnthropicClient.swift, Ports.swift, Tests/SmartReadClientTests.swift, Tests/Fakes.swift
  - Verify: `cd VibeFlowCore && swift test` (roles alternate with and without brief; max_tokens case)
- [x] **T2 (P1, human: ~6h / CC: ~30min)** — Session — Conversation at capture time, beginQuestion/ask under one token, spoken errors
  - Surfaced by: D3, O3, R9 (D12), R11 (D14), R6 (D9)
  - Files: VibeFlowCore/Sources/VibeFlowCore/Session/ReadSession.swift, Tests/SessionTests.swift, Tests/SessionFakes.swift
  - Verify: swift test; readOriginal-after-failure test still green; cancel-before-ask test
- [x] **T3 (P1, human: ~2h / CC: ~10min)** — Capture — nothing selected versus capture failed
  - Surfaced by: R8 (D11), outside voice O1
  - Files: VibeFlowCore/Sources/VibeFlowCore/Capture/*.swift, Tests/CaptureTests.swift
  - Verify: swift test; failed capture after reading A never asks about A
- [x] **T4 (P1, human: ~3h / CC: ~15min)** — Dictation — question purpose and cue on first buffer
  - Surfaced by: R5 (D8), R10 (D13), R2 (D5)
  - Files: VibeFlowCore/Sources/VibeFlowCore/Dictation/DictationSession.swift, Ports.swift, VibeFlow/LiveAudioRecorder.swift, Tests/DictationTests.swift
  - Verify: swift test; late-ready fake recorder delays the cue; a dictation still pastes
- [x] **T5 (P1, human: ~3h / CC: ~15min)** — App — PressClassifier, smart read key routing, notch symbol
  - Surfaced by: R2 (D5), R6 (D9)
  - Files: VibeFlowCore/Sources/VibeFlowCore/Session/PressClassifier.swift, VibeFlow/AppContainer.swift, VibeFlow/NotchIndicator.swift, Tests (new PressClassifier tests)
  - Verify: swift test; xcodebuild build; ten taps and ten holds in the built app, `/usr/bin/log show --last 5m --predicate 'subsystem == "one.floo.vibeflow"'`
- [x] **T6 (P2, human: ~1h / CC: ~10min)** — Eval — small live answer eval
  - Surfaced by: R7 (D10)
  - Files: VibeFlowCore/Tests/VibeFlowCoreTests/LiveEvalTests.swift
  - Verify: run the gated live suite with keys set
- [x] **T7 (P3, human: ~30min / CC: ~5min)** — Docs — README and CLAUDE.md shortcut line
  - Surfaced by: plan build order step 4
  - Files: README.md, CLAUDE.md
  - Verify: read through

### Unresolved decisions that may bite you later

- R3 (D6): what a hold does while VibeFlow is capturing, confirming a long text, generating a
  brief or an answer, speaking, or dictating. Left to build time; decide before T5.

### Accepted risks (answered, recorded for visibility)

- R1 (D4 B): questions also work in apps set to "Keep this app on this Mac", so their text can be
  sent to Anthropic through a question even though smart read never sends it.
- R7 (D10 B): the 9 of 10 answer bar and the 3 s time to first audio are not measured.

### Suppressed findings

- (confidence 4/10) Exact text comparison in D2 starts a new context when you re-select the same
  passage slightly differently. Harmless: the brief is skipped and the question still works.

### Completion summary

- Step 0: Scope Challenge — scope reduced per recommendation (caching and menu lines deferred)
- Reality rows: 7/7 applicable rows emitted, 1 unverified premise
- Architecture Review: 1 issue found
- Code Quality Review: 0 issues found
- Test Review: diagram produced, 20 gaps identified (2 review findings: regression contract, eval)
- Performance Review: 0 issues found
- NOT in scope: written
- What already exists: written
- TODOS.md updates: 2 items proposed to user, 2 added
- Failure modes: 0 critical gaps flagged
- Unresolved decisions: 1 in this review
- Outside voice: Codex (gpt-6-astra), completed, 5 findings (3 High, 2 Medium), all verified; 4 asked and applied, 1 correction
- Parallelization: 3 lanes, 3 parallel / 1 sequential
- Lake Score: 6/11

## GSTACK REVIEW REPORT

| Review | Trigger | Why | Runs | Status | Findings |
|--------|---------|-----|------|--------|----------|
| CEO Review | `/plan-ceo-review` | Scope & strategy | 0 | — | — |
| Outside Review | Codex CLI via `/plan-eng-review` | Independent 2nd opinion | 1 | completed | 5 findings (3 High, 2 Medium), all resolved |
| Eng Review | `/plan-eng-review` | Architecture & tests (required) | 1 | ISSUES OPEN | 3 issues, 0 critical gaps |
| Design Review | `/plan-design-review` | UI/UX gaps | 0 | — | — |
| DX Review | `/plan-devex-review` | Developer experience gaps | 0 | — | — |

- **OUTSIDE COVERAGE:** Codex (gpt-6-astra), plan-review phase, completed, 5 findings; 4 applied by user answer (D11 to D14), 1 applied as a correction (O3).
- **VERDICT:** no review CLEAR; eng review required (issues open: hold rules left undefined).

**UNRESOLVED DECISIONS:**
- R3 (D6): hold behavior while capturing, confirming, generating, speaking or dictating is undefined; decide before T5.
