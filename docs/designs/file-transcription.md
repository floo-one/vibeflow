# Design: Transcribe a file

Status: revised 2026-11-04 after the design canvas
(https://claude.ai/artifact/55Sq6xJC5bDbAhr4wQCqZe, 4 screens). The first draft (one text block,
Groq or Apple only) went through half an eng review; that review resumes on this version (see the
end). Branch `file-transcribe-option-261219`. Builds on the dictation transcribers from
docs/designs/vibeflow-2-dictation-conversation.md and the smart read Claude client. No server, no
database, no new Settings pane.

## Problem

The audio Florian wants as text is mostly recorded calls and meetings, plus some voice memos and
talks. For calls, one block of text is not enough: he needs who said what, when, and what was
agreed. Today that means a separate app or a web upload. VibeFlow already has the pieces: Groq
Whisper and Apple on-device transcription, an ElevenLabs key, and Claude for smart reads.

## The day-to-day flow

1. Menu bar → Voice → **Transcribe File…** → pick a file (audio or video).
2. A small **Transcribe File** window: what is it (**Call or meeting** / **Voice memo or talk**),
   for calls the number of speakers (Detect automatically, 2, 3, 4 or more) and **Channels are
   speakers**, then **Summary and action items** and **Copy the transcript to the clipboard**.
   The bottom line names the engine. **Transcribe**.
3. The menu shows progress at the top ("Transcribing sales-call.m4a · 18:20 of 42:10 · 2
   speakers so far"); the item becomes **Stop Transcribing** (keeps what is done). Read, smart
   read and dictation keep working.
4. Done: notification "Transcript ready: sales-call.m4a · 42 min · 2 speakers"; the transcript
   is on the clipboard (if ticked) and in History under a new **Transcripts** filter.
5. Clicking the notification or the History row opens the **transcript window**: speaker turns
   with timestamps, speakers to rename or merge, search, summary with action items (each linked
   to the moment it was said), a speaker-coloured timeline with playback, Copy and Save as Text.

Second way in (later, T-OpenWith): Finder → Open With → VibeFlow opens step 2 with the file.

## Key decisions

### D1. Entry point: a menu item, then a small options window

Transcribing a file is rare and starts with picking a file, so no global shortcut and no Settings
pane. The options window is per file, not Settings: it remembers the last choices (kind, summary,
copy) in UserDefaults so the second time is one click. Summary starts unticked (O1).

### D2. Its own job, not part of DictationSession

`DictationSession` is a held-key state machine (2-minute cap, 0.3 s floor, paste into the
frontmost app). A new `FileTranscriptionJob` reuses transcribers and the Claude client and runs
beside dictation. One file at a time; a second request while one runs shows "Already
transcribing sales-call.m4a".

### D3. Two kinds, and the kind picks the engine

| Kind | Option | Engine | Speakers |
|---|---|---|---|
| Call or meeting | default | ElevenLabs Scribe, `diarize=true`, `num_speakers` from the picker (Detect = not sent) | labelled Speaker 1, 2… |
| Call or meeting | Channels are speakers (offered only for 2-channel files) | the call engine's multichannel mode (eng review D7); no split of our own | Me (channel 0), Other (channel 1) |
| Voice memo or talk | | Groq Whisper in pieces, Apple on-device when there is no Groq key or Groq is down | none |

Upload (eng review R6): audio files go as they are; for videos the audio track is exported to a
temporary m4a first (about 1 MB per minute). The upload streams from disk through a new
`HTTPClient.upload(_:fromFile:)`, so memory stays small. T1 records each engine's byte limits.
`AudioFileDecoder.probe` reads duration, channel count and whether there is audio for every
kind before the options window opens, so the 2-hour cap and the stereo option apply to calls too.

Call engine: **ElevenLabs Scribe**, chosen by Florian on 2026-11-04 after the T1 bake-off (eng
review D11; results below). Groq Whisper and
Apple's SpeechAnalyzer return no speakers, so calls need a diarizing engine. Two candidates, both
one upload of the original file with speaker ids and word timestamps, so calls need no 10-minute
pieces and no decoding:

- ElevenLabs Scribe: key already in the Keychain (`SecretKey.elevenLabs`); `diarize`,
  `num_speakers` 1 to 32, uploads under 5 GB (API reference); a multichannel mode appears in a
  community example only; about $0.22 per audio hour (third-party price lists).
- Deepgram Nova-3: new account and key (`SecretKey.deepgram`, Settings > Accounts); `diarize` and
  `multichannel` are documented features; German support to confirm; about $0.26 to $0.31 per
  audio hour (third-party lists).

T1 run 1 (2026-11-04, a real 36-minute German two-person meeting, mp4 with mono 16 kHz audio;
audio exported to an 18.2 MB m4a in 0.4 s, 70.1 MB video): Deepgram nova-3 with auto language
detected German (0.99), finished in 17.2 s, found 2 speakers (74 % / 26 % talk share), 716
utterances, 3,890 words, mean utterance confidence 0.94. Scribe was refused with HTTP 401
`missing_permissions` (the ElevenLabs key is scoped without Speech to Text); rerun with
`--engines scribe` once that permission is on. VibeFlow must surface this case as "ElevenLabs
key lacks Speech to Text permission", not a generic 401.

T1 runs the same real 40-minute German two-person call through both; Florian judges speaker
labels and text; the winner is built behind the `FileTranscriber` protocol, the loser is not.
T1 run 2 (same meeting, ElevenLabs key with Speech to Text permission): Scribe (`scribe_v2`)
detected German (0.997), finished in 25.0 s, 2 speakers, 4,140 words (Deepgram 3,890), mean word
probability 0.99, 138 turns (Deepgram 65). The two engines agree on the speaker for 97.4 % of
3,929 time-matched words. Differences: Scribe gives short replies ("Mhm.") their own turn (46
turns of two words or fewer, Deepgram 10) where Deepgram sometimes folds the listener's "Mhm"
into the speaker's turn; Scribe is verbatim ("ähm", "'n", broken-off words), Deepgram's
smart_format reads cleaner. Decision: Scribe, for the better short-turn labels, the more
complete text, no second account or key, and the lower price. Fillers are shown as returned in
v1; a "hide fillers" display toggle is a candidate if they get in the way. Deepgram is not built
(no `SecretKey.deepgram`).

No key for the chosen call engine: the Call option still works, without speaker labels, through
the memo engine; the window's engine line says "No <provider> key: no speaker labels".

### D4. Decoding (memo engine only)

`AudioFileDecoder` uses AVFoundation to read any audio or video file (m4a, mp3, wav, aiff, caf,
mp4, mov audio track) into 16 kHz 16-bit mono PCM in a temporary WAV. It also reports the
channel count, which decides whether the options window offers "Channels are speakers". If T1
shows the winning call engine has no multichannel mode, that option is hidden and stereo calls
get normal speaker labels (eng review D7). T1 result (2026-11-04, macOS 26, Spike/file-decode-probe.swift on
stereo 48 kHz m4a, mono m4a and an mp4 video): `AVAssetReaderTrackOutput` with LPCM 16 kHz,
1 channel, 16-bit starts and delivers exactly that format on all three, so no `AVAudioConverter`
step is needed; the concern below did not reproduce. `AVAssetReaderTrackOutput` reportedly rejects the channel-count key; T1
checks the delivered format and falls back to reading native PCM plus `AVAudioConverter`. No audio
track: "No audio in interview.mov". Unreadable (DRM, iCloud placeholder): "Couldn't read
interview.m4a". Temp files are deleted when the job ends, fails or is cancelled, and leftovers
(`vibeflow-file-*.wav`) on the next launch. Length cap: 2 hours for every engine.

### D5. Memo engine: Groq pieces or Apple whole file

- Groq: pieces of up to 10 minutes (19.2 MB of WAV, under Groq's 25 MB upload cap), each cut at
  the quietest 200 ms in the last 30 s before the mark; no overlap; sent one after another; 60 s
  timeout per piece (`OpenAITranscriber` gets the timeout as an init parameter, 10 s default so
  dictation is unchanged); language detected per piece. Segment start times are kept (verbose_json
  `segments[].start`, offset by the piece's start) so memo transcripts have timestamps too.
- Silence (eng review R2, D12): a piece is skipped without a request only when every 1-second
  window's RMS is below `NoSpeech.silenceRMS`; within a piece, segments with no_speech_prob above 0.6, or a known Whisper
  hallucination (`NoSpeech.hallucinations`) with prob above 0.3, are dropped.
- Apple: `AppleTranscriber.transcribe(fileAt:locale:)` runs the whole file in one pass, system
  language; the existing `transcribe(_:language:)` calls it. Progress from result time ranges.

### D6. Failures

Decided once per file, never mixed: a transcript never has two engines in it.

- Groq fails on the first piece (offline, timeout, 5xx) and Apple is available: the whole file
  switches to Apple, status "Transcribing on device: Groq unavailable".
- 401/403 (Groq or ElevenLabs): stop, "<Provider> key rejected", with the Accounts action.
- 429 (rate limit): wait 30 s, 60 s, then 120 s, retrying after each; still 429 → stop with the
  partial text, status "Stopped at 58:00: Groq hourly limit" (eng review R1). `HTTPResponse` has
  no headers, so `retry-after` is not read. Groq's free tier allows about 7,200 audio seconds per
  hour, so a 2-hour memo can use the whole hour's budget.
- Scribe is one request: failure means no transcript, the status names the reason, nothing is
  partial. Scribe's timeout is long (upload plus processing of up to 2 hours of audio); T1 measures
  it and sets the number.
- Any other Groq failure after the first piece: retry the piece once, then stop with the partial
  text marked "Stopped at 30:00: <reason>".
- Cancel: partial text marked "Cancelled at 30:00" (Groq), nothing (call engine, Apple). The menu
  item says what Stop keeps: "Stop Transcribing (keeps 18 min)" for Groq, "Stop Transcribing"
  otherwise.
- Progress (outside voice 8): Groq shows "18:20 of 42:10" from finished pieces; Apple from result
  time ranges; the call engine shows "Uploading 34%" then "Transcribing · 2:10" (elapsed), since
  one request reports no progress. No "speakers so far".
- Apple availability (outside voice 7): before offering Apple (as engine or fallback), the job
  checks the on-device assets for the system locale, not the preset language that
  `OnDeviceModelStatus.prepare` uses for dictation; missing assets show the download remedy.
- Sleep (eng review R3): the job holds a `PowerAssertion` against idle system sleep (the display
  may sleep) from its first step until it finishes, fails or is cancelled.

### D7. Summary and action items

Optional, off by default and ticked per file in the options window (O1). The transcript is saved
(D8) before the summary starts, so a failed or cancelled summary never loses it. After the transcript is done, one non-streaming Claude
request through `AnthropicClient` with the Smart Read model: the transcript (with speaker names
and mm:ss times) goes inside the document delimiters, as smart read does, so nothing said in the
call is taken as an instruction. Output: a short summary (two to four sentences) and action items,
each with an owner when one was named and the mm:ss where it was said. The output is structured (outside
voice 6): Claude returns JSON with the summary text using speaker tokens (`{S1}`) and action items
as `{owner: speaker id?, text, segment id}`; tokens and ids are validated against the transcript,
invalid ones are dropped, and names are rendered at display time, so a rename never edits text. No Anthropic key: the option is
disabled with "Needs an Anthropic key". A failed summary keeps the transcript and says "Summary
failed: <reason>" with Retry in the window.

### D8. Storage: one file per transcript, one History entry

A transcript is a document, read and written whole: `Transcript` = id, date, source file name,
source bookmark, duration, engine, completion (`complete`, `stopped(at:reason:)`,
`cancelled(at:)`, outside voice 3; shown in the window, the notification, Copy and Save), speakers `[id: name]`, segments `[speaker id?, start, end,
text]`, summary, action items. Each is saved to
`~/Library/Application Support/<bundle id>/Transcripts/<id>.json`. History gets a
`HistoryEntry.Kind.transcription` row with `text` = the first 200 characters, a
`sourceFileName` and the transcript id; the History window gains a Transcripts filter. Transcripts
are kept until deleted (eng review R5, D13): retention never prunes `.transcription` entries;
deleting one removes its file; Clear History asks "Also delete N transcripts?". Writes are
atomic; a transcript file is written before its History entry, and on launch any transcript file
with no History entry is re-added (outside voice 4); a failed write is shown, not only logged. Old History JSON still
decodes (new fields optional).

Forward compatibility (found while building, 2026-11-04): a release from before this feature
cannot decode a `transcription` row, starts with an empty History and overwrites history.json on
its next save. So VibeFlow Dev, which shares Application Support with the release, writes
history-dev.json and Transcripts-dev/ (like focus-dev.json), and HistoryStore now skips rows it
cannot decode instead of dropping the whole file, so the next new row type is safe. Once the
first release with file transcription ships, every later version reads these rows.

### D9. The transcript window

A new window like History (brought to the front explicitly, VibeFlow has no Dock icon).

- Turns: consecutive segments of one speaker form one turn with the start time. Click a time to
  play from there.
- Speakers: rename (every turn and the summary update), merge two labels into one (when one voice
  was split). Saved to the transcript file. Per file only; recognising a voice across calls is
  out of scope.
- Search: filters and highlights turns.
- Long transcripts: turns render in a lazy list (`List`/`LazyVStack`); a 2-hour call is about
  1,500 turns.
- Playback: `AVAudioPlayer` on the source file through a bookmark (a plain bookmark: VibeFlow is
  not sandboxed); source moved or
  deleted → Play is disabled with "Source file not found". The audio is never copied.
- Timeline: one coloured bar per turn, click to seek.
- Copy: plain text lines "Name [mm:ss]: text", summary first when there is one. Save as Text…:
  the same text through `NSSavePanel` (Q1 said later; the canvas shows it and it is about 20 lines,
  so it is in v1 unless dropped in review).
- "Ask about this call" (on the canvas): later. The smart read follow-up caps the document at
  40,000 characters (`SessionConfiguration.hardMax`), about 45 minutes of talk, so long calls need
  their own design.

### D10. Notification

"Transcript ready" through a notifier shared with the Pomodoro timer (eng review D1): permission is
asked the first time a file is transcribed; clicking opens the transcript window. Clicks route
through a pure `NotificationRoute` in VibeFlowCore (`.startFocusPhase`, `.openTranscript`, `.none`)
so the Pomodoro Start button is pinned by tests (eng review R4). Partial results
say so ("Stopped at 30:00: Groq hourly limit").

## Architecture

**VibeFlowCore**

- `Transcription/AudioFileDecoder.swift`: decode to temp WAV (mono or per channel), and the pure
  `pieces(of:max:searchWindow:)` cutting function.
- `Transcription/ScribeTranscriber.swift`: ElevenLabs Scribe (`scribe_v2`) behind
  `FileTranscriber`: streamed multipart upload, `diarize`, `num_speakers`, word timestamps →
  segments with speaker ids; HTTP 401 `missing_permissions` maps to "Your ElevenLabs key lacks
  the Speech to Text permission" with the Accounts action (seen in T1).
- `Transcription/Transcript.swift`: the document model, turns from segments, rename and merge,
  plain-text export, `TranscriptStore` (one JSON file per transcript).
- `Transcription/FileTranscriptionJob.swift`: `@MainActor @Observable`; states `idle`,
  `decoding`, `transcribing(progress)`, `summarizing`, `finished(Transcript)`, `failed`; picks the
  engine (D3), runs pieces, channel split and merge, failures (D6), summary (D7).
- `SmartRead/SmartReadPrompts.swift`: a `callSummarySystem` prompt; `AnthropicClient` reused.
- `Dictation/OpenAITranscriber.swift`: timeout init parameter; segment start times in the result.
- `Dictation/AppleTranscriber.swift`: `transcribe(fileAt:locale:)`.
- `History/HistoryStore.swift`: `.transcription` kind, `sourceFileName`, `transcriptID`, deleting
  the transcript file on prune.
- `Ports.swift`: `FileTranscriber` protocol for the whole-file engines (Scribe, Apple);
  file-level errors are a separate `AudioFileError` (`noAudio`, `unreadable`, `tooLong`), so
  dictation's exhaustive switches over `TranscriptionFailure` stay untouched (changed in T2).

**VibeFlow (app)**

- `TranscribeFileWindow.swift`: the options window (NSOpenPanel first, then the window).
- `TranscriptWindow.swift`: the transcript window (turns, speakers, search, summary, timeline,
  playback, copy, save).
- `AppContainer`: owns the job and the store; `MenuBarView`: the item and progress rows;
  `HistoryViews`: the Transcripts filter and row; notifications shared with `FocusTimer.swift`.
- Later: Open With (`CFBundleDocumentTypes` in project.yml, `application(_:open:)`).

## Tests (Swift Testing, VibeFlowCore)

- Cutting: silence at 9:45 → cut there; no silence → cut at 10:00; under 10 minutes → one piece.
- Scribe: request shape (diarize, num_speakers only when set, model), response with words and
  speaker ids → segments; 401, 429, 5xx, malformed.
- Transcript: turns from segments (same speaker merges, a gap splits), rename updates turns and
  summary, merge two speakers, plain-text export format, JSON round trip.
- Multichannel: a stereo response maps channel 0 to Me and channel 1 to Other; turns interleave
  by start time.
- Memo timestamps: a segment in piece 3 starting at 0:12 lands at 20:12 (piece offsets).
- Job with fakes: engine choice per kind and keys, Groq first-piece failure → Apple whole file,
  401 stops, 429 back-off then partial, cancel, summary success, summary failure keeps transcript,
  temp files removed on every path.
- History: old JSON without the new fields decodes; retention never prunes transcripts; delete
  removes the file; clear with transcripts; orphan transcript re-added on launch (R5).
- Silent piece rule (D12): 10 s of speech in 600 s of silence is sent; a fully silent piece is
  skipped.
- Upload (R6): video → audio-only m4a; upload uses the file-streaming port method (fake).
- Completion status round-trips and appears in the export text.
- Summary JSON: invalid speaker tokens and segment ids are dropped; rename changes rendered
  names only.
- Ordering: transcript saved before summary; summary failure leaves the saved transcript.
- Summary prompt: transcript inside the delimiters, never outside.
- Silence filter (R2): table of segments (prob, text) → kept or dropped; a silent piece sends no
  request.
- NotificationRoute (R4): focus break Start, focus Start, transcript click, unknown category.
- OpenAITranscriber default timeout stays 10 s (dictation regression).
- Live eval (opt-in): a real 2-speaker call through Scribe; a 25-minute German memo through Groq.

## Tasks

- T1. Spike and bake-off (D11): one real 40-minute German 2-person call (mono and, if available,
  stereo) through ElevenLabs Scribe and Deepgram Nova-3 (trial key): speaker accuracy, text
  quality, time, timeout, price, multichannel; Florian picks. Also Groq upload cap and rate
  limits; `AVAssetReader` 16 kHz mono output; Apple `SpeechAnalyzer` on a 1-hour file.
- T2. `AudioFileDecoder` and cutting, with tests.
- T3. `ScribeTranscriber`; `OpenAITranscriber` timeout and segment times; `AppleTranscriber` file
  entry point.
- T4. `Transcript` and `TranscriptStore`, with tests.
- T5. `FileTranscriptionJob` with fakes and tests, including the summary.
- T6. History kind, filter and prune.
- T7. App: menu item and progress, options window, notification.
- T8. App: transcript window.
- Later: Open With; "Ask about this call"; voices remembered across calls.

## Resolved questions (2026-11-04, Florian)

- Q1. Save as text: wanted later, clipboard enough for v1. Superseded by the canvas: Save as
  Text… is in the transcript window (D9), confirm in review.
- Q2. Length cap: 2 hours.
- Q3. Apple path language: the system language, no picker.
- Q4. Cleanup of Whisper text: none, until raw transcripts prove too rough.

## Canvas questions, resolved 2026-11-04 (Florian)

- O1. Summary and action items: always off by default; tick it per file. The window remembers
  the last choice.
- O2. Transcripts live in History with a Transcripts filter (D8).
- O3. Playback links the source file through a bookmark; the audio is never copied (D9).
- O4. Speaker names are per file; voices across calls are later.

## Eng review 2026-11-04

Paused 2026-11-04 after D3 so the feature could be designed first (canvas). Resumed the same day
on the revised design above.

Target: docs/designs/file-transcription.md (this file, the plan above). Reviewer: /plan-eng-review
(Claude). The plan text above is the working plan; accepted changes are applied to it and listed
here.

### Scope record

feature answers: D1 = A, keep the "Transcript ready" notification (user, 2026-11-04);
structure: A, original arrangement (AudioFileDecoder.swift + FileTranscriptionJob.swift +
FileTranscriber protocol) (user, 2026-11-04); accepted scope: the plan as written plus a shared
notifier (permission asked on the first file transcription, click opens History); pending
remedies: R1 Groq rate limit, R2 silent-stretch hallucinations, R3 sleep during a job, R4
notification routing regression coverage. Scope Challenge result: scope accepted as-is.

Revised scope record (resumed 2026-11-04 on the canvas-based design; the first record above is
superseded): feature answers: D7 = engine's multichannel, no own channel split; D8 = playback and
timeline in v1; D9 = Save as Text… in v1; D11 = bake-off of ElevenLabs Scribe and Deepgram in
T1, winner built (all Florian, 2026-11-04); structure: D10 = original arrangement (Architecture
section); accepted scope: the design above; pending remedies: R2, R3, R4. Scope Challenge result:
scope accepted as-is.

Factual corrections (no behavior change, no question):
- D6 said "Same choice as dictation: Groq primary with Apple fallback, or Apple only". There is
  no Apple-only setting: a Groq key present means Groq with Apple fallback, no key means Apple
  (DictationSetupFactory.swift:21-27). FallbackTranscriber falls back per call, so the job uses
  the raw OpenAITranscriber and AppleTranscriber to keep D6's one decision per file.
- D8 said notification permission was already asked for the focus timer. It is asked only on the
  first focus Start (FocusTimer.swift:170) and Focus is off by default; FocusNotifications'
  didReceive handles only the focus Start action. Covered by D1 (shared notifier).
- D3 decoding: AVAssetReaderTrackOutput reportedly rejects AVNumberOfChannelsKey. T1 checks the
  delivered format; if mono 16 kHz cannot be requested, read native PCM and convert with
  AVAudioConverter. Required proof of D3, not a new choice.

## Decision ledger

### R1: What happens when Groq's hourly audio budget runs out mid-file
Finding: 1, CRITICAL, 8/10, D6 "429 (rate limit): wait for retry-after (or 20 s), retry the piece, at most 3 times" and Ports.swift:214-216 (`public struct HTTPResponse: Sendable { public let status: Int; public let body: Data`), reviewer Claude.
Plan baseline: original proposal, retry-after or 20 s, at most 3 retries, then stop with partial text.
Runtime evidence: HTTPResponse carries no headers, so retry-after cannot be read today. Groq free tier: 7,200 audio seconds per hour, 28,800 per day, 20 requests per minute (dev.to and localaimaster.com, 2026; confirm in T1). A 2-hour file is the whole hourly budget.
Comparison grid:
| Choice | Current | A | B | C |
|---|---|---|---|---|
| R1 on 429 | retry-after or 20 s x3, unreadable header | wait 30 s, 60 s, 120 s, then stop with partial text, status names the Groq hourly limit | add headers to HTTPResponse, wait retry-after up to 10 min, then stop with partial | as A, and files over 60 min go to Apple when available |
| R2 silent stretches | pending | pending | pending | pending |
| R3 sleep | pending | pending | pending | pending |
| R4 notification tests | pending | pending | pending | pending |
Question D3:
D3 — What should happen when Groq's hourly limit runs out mid-file?
Project/branch/task: file-transcribe-option-261219, design D6 rate-limit rule.
ELI10: Groq's free plan allows about 2 hours of audio per hour. A 2-hour file uses all of it, so any dictation in that hour makes the last pieces fail with "rate limited". The doc's plan was to wait for Groq's suggested delay, but VibeFlow's HTTP layer throws the response headers away, so it can't read that delay.
Stakes if we pick wrong: Long files fail near the end, or the app waits silently for many minutes.
Recommendation: A because it needs no change to the shared HTTP layer, and the partial text plus a clear status is honest.
Completeness: A=8/10, B=9/10, C=7/10
Pros / cons:
A) Back off, then partial (recommended)
  ✅ No change to HTTPResponse or the fakes every client test uses
  ✅ About 3.5 minutes of waiting covers a per-minute limit hiccup
  ❌ An hourly limit still ends the job early with partial text
B) Read retry-after
  ✅ Waits exactly as long as Groq asks, up to 10 minutes
  ✅ Headers become available to later features too
  ❌ Touches the HTTP port, URLSession client and all test fakes
C) Long files on device
  ✅ Files over an hour never hit Groq's hourly limit
  ✅ Works offline and costs no Groq budget
  ❌ Paid Groq users get Apple's weaker mixed-language text on long files
Net: simple, honest failure versus exact waits versus routing around Groq.
Header: Rate limit
Options:
A) Back off, then partial (recommended)
On 429 wait 30 s, 60 s, 120 s and retry the piece; then stop, keep the partial text in History and on the clipboard, status "Stopped at <time>: Groq hourly limit". (human: ~1h / CC: ~5min)
B) Read retry-after
Add response headers to HTTPResponse and the URLSession client, wait retry-after (max 10 min) per 429, then stop with partial text. (human: ~3h / CC: ~15min)
C) Long files on device
As A, plus files longer than 60 minutes use Apple on-device for the whole file when it is available. (human: ~1.5h / CC: ~8min)

State: approved
Actual answer: A) Back off, then partial (user, D3, 2026-11-04)
Accepted scope: On 429 wait 30 s, 60 s, 120 s and retry the piece; then stop, keep the partial text in History and on the clipboard, status "Stopped at <time>: Groq hourly limit". HTTPResponse unchanged. D6 updated; job tests cover 429 then success and 429 four times then partial.
History: none

### R2: Whisper hallucinations on silent stretches
Finding: 4, INFORMATIONAL, 7/10, OpenAITranscriber.swift VerboseJSON (`struct Segment: Decodable { let no_speech_prob: Double? }`) and NoSpeech.swift:24 (`isSilence(_ transcription:, audio:)` judges the whole transcript), reviewer Claude.
Plan baseline: original proposal, no silence handling for files.
Runtime evidence: segment text is not decoded; NoSpeech only decides whole-dictation silence.
Comparison grid:
| Choice | Current | A | B | C |
|---|---|---|---|---|
| R1 | pending | pending | pending | pending |
| R2 silent stretches | none | skip silent pieces before upload, drop segments by NoSpeech thresholds | NoSpeech.isSilence per piece only | none |
| R3 | pending | pending | pending | pending |
| R4 | pending | pending | pending | pending |
Question D4:
D4 — How should VibeFlow keep invented phrases out of long transcripts?
Project/branch/task: file-transcribe-option-261219, OpenAITranscriber and NoSpeech.
ELI10: Whisper makes up phrases like "Untertitel im Auftrag des ZDF" when it hears silence. Dictation already filters these, but only for a whole short clip. A recording with a long pause would get the phrase in the middle of the text.
Stakes if we pick wrong: Transcripts with made-up sentences in the middle that you only notice later.
Recommendation: A because it reuses NoSpeech's thresholds per segment, and skipping silent pieces also saves Groq budget.
Completeness: A=9/10, B=6/10, C=3/10
Pros / cons:
A) Per-segment filter (recommended)
  ✅ Silent pieces are never uploaded, which saves the hourly Groq budget
  ✅ Made-up phrases inside a piece are dropped with the same thresholds as dictation
  ❌ VerboseJSON parsing grows segment text; one more table-driven test
B) Per-piece only
  ✅ Reuses NoSpeech.isSilence unchanged, no parsing change
  ✅ Catches fully silent 10-minute pieces
  ❌ A phrase invented inside a piece that has speech stays in
C) No filter
  ✅ No extra code or tests at all
  ✅ Raw Whisper output, nothing dropped by mistake
  ❌ Invented phrases land in transcripts and History
Net: a small parsing change buys clean transcripts and saved budget.
Header: Silence
Options:
A) Per-segment filter (recommended)
Pieces with RMS below NoSpeech.silenceRMS are skipped without a request; segments with no_speech_prob above 0.6, or a known hallucination with prob above 0.3, are dropped. Apple path unchanged. (human: ~2h / CC: ~10min)
B) Per-piece only
Apply NoSpeech.isSilence to each piece's transcription and drop the piece when it is silence. (human: ~45min / CC: ~5min)
C) No filter
Join Whisper output as returned.

State: approved
Actual answer: A) Per-segment filter (user, D4, 2026-11-04)
Accepted scope: Memo engine (Groq) only: pieces with RMS below NoSpeech.silenceRMS are skipped without a request; VerboseJSON decodes segment text, start and no_speech_prob; segments with no_speech_prob above 0.6, or a known hallucination with prob above 0.3, are dropped. Apple and the call engine unchanged. Table-driven test in TranscriberTests plus a job test for a skipped silent piece.
History: none

### R3: The Mac sleeping during a long job
Finding: 6, INFORMATIONAL, 7/10, D5 "the whole file in one pass" and LiveServices.swift:186 (`// MARK: - PowerAssertion on IOPMAssertion`), reviewer Claude.
Plan baseline: original proposal, no sleep handling.
Runtime evidence: PowerAssertion exists for Keep Awake; idle system sleep can suspend a long on-device run or drop a Groq upload.
Comparison grid:
| Choice | Current | A | B |
|---|---|---|---|
| R1 | pending | pending | pending |
| R2 | pending | pending | pending |
| R3 sleep | none | hold PowerAssertion (system idle sleep, display may sleep) while the job runs | none |
| R4 | pending | pending | pending |
Question D5:
D5 — Keep the Mac awake while a file is transcribing?
Project/branch/task: file-transcribe-option-261219, AppContainer job wiring.
ELI10: A 2-hour file on device can take several minutes. If you walk away and the Mac idles to sleep, the job pauses or a Groq upload fails. VibeFlow already has the code Keep Awake uses to hold the Mac awake.
Stakes if we pick wrong: You come back to a half-finished or failed transcript.
Recommendation: A because it reuses PowerAssertion and is released as soon as the job ends.
Completeness: A=9/10, B=6/10
Pros / cons:
A) Hold awake (recommended)
  ✅ Long jobs finish while you are away from the Mac
  ✅ Reuses Keep Awake's PowerAssertion, display can still sleep
  ❌ One more lifetime to release on finish, failure and cancel
B) Allow sleep
  ✅ No change to power behavior at all
  ✅ Nothing to release on every exit path of the job
  ❌ Idle sleep pauses on-device runs and can fail a Groq upload
Net: a few lines buy jobs that finish unattended.
Header: Sleep
Options:
A) Hold awake (recommended)
Hold a PowerAssertion preventing idle system sleep (not display sleep) from decode start until the job finishes, fails or is cancelled. (human: ~30min / CC: ~3min)
B) Allow sleep
No assertion; the job may pause or fail while the Mac sleeps.

State: approved
Actual answer: A) Hold awake (user, D5, 2026-11-04)
Accepted scope: The job holds a PowerAssertion preventing idle system sleep (display may sleep) from the first step until it finishes, fails or is cancelled; released on every exit path. Covers the call-engine upload and the summary too.
History: none

### R4: Regression coverage for focus notifications after the split
Finding: 2 follow-up, CRITICAL (regression rule), 8/10, FocusTimer.swift:200-209 (`guard response.actionIdentifier == startAction else { return }` then decodes session, block, phase), reviewer Claude.
Plan baseline: D1 approved a shared notifier; regression proof not yet settled.
Runtime evidence: the focus Start button routes through the only notification delegate; no tests exist for it (the app target has no tests; VibeFlowCore does).
Comparison grid:
| Choice | Current | A | B |
|---|---|---|---|
| R1 | pending | pending | pending |
| R2 | pending | pending | pending |
| R3 | pending | pending | pending |
| R4 regression proof | none | pure NotificationRoute in VibeFlowCore with tests (focus break, focus start, transcript open, unknown) + manual check | manual check of the focus Start button only |
Question D6:
D6 — How do we prove the focus timer's notification button still works after sharing the notifier?
Project/branch/task: file-transcribe-option-261219, FocusNotifications split.
ELI10: Sharing the notification code with file transcription changes how a click on a notification is routed. If the routing breaks, "Start break" in a Pomodoro notification would silently stop working.
Stakes if we pick wrong: The Pomodoro "Start break" button stops working and nothing tells you.
Recommendation: A because routing becomes a tiny pure function that tests can pin, like the rest of VibeFlowCore.
Completeness: A=9/10, B=5/10
Pros / cons:
A) Pure route + tests (recommended)
  ✅ Focus break, focus start and transcript clicks are each pinned by a test
  ✅ The delegate shrinks to one switch over the route
  ❌ One small new type in VibeFlowCore plus a test file
B) Manual check only
  ✅ No new type, smallest diff to FocusTimer.swift
  ✅ One click in the dev app confirms the happy path
  ❌ A later change can break the button with no failing test
Net: a small pure function buys a permanent guard on Pomodoro.
Header: Regression
Options:
A) Pure route + tests (recommended)
NotificationRoute.from(category:action:userInfo:) in VibeFlowCore returns .startFocusPhase(session, block, phase), .openHistory(entry) or .none; tests cover each; the delegate switches over it; plus one manual click in the dev app. (human: ~1.5h / CC: ~8min)
B) Manual check only
Split the delegate by category without tests; click "Start break" in the dev app once.

State: approved
Actual answer: A) Pure route + tests (user, D6, 2026-11-04)
Accepted scope: NotificationRoute.from(category:action:userInfo:) in VibeFlowCore returns .startFocusPhase(session, block, phase), .openTranscript(id) (the transcript window per the revised D10, in place of .openHistory) or .none; tests for focus break, focus start, transcript and unknown; the delegate switches over it; one manual click on Pomodoro Start break in the dev app.
History: Option text said .openHistory(entry); the revised design opens the transcript window, so the route is .openTranscript(id). Same behavior class, no new choice.

### R2 reopened: what counts as a silent piece
Finding: outside voice 1, High, 8/10, NoSpeech.swift:15 (`public static let silenceRMS = 0.005`) applied to a whole 10-minute piece, reviewer Codex (outside voice), verified by Claude.
Plan baseline: R2 approved A (D4): skip a piece whose RMS is below NoSpeech.silenceRMS.
Runtime evidence: 10 s of speech at RMS 0.03 in a 600 s piece averages about 0.0039, below 0.005, so real speech would be skipped. Reopened for contradictory evidence; segment filtering stays approved.
Comparison grid:
| Choice | Current | A | B | C | D |
|---|---|---|---|---|---|
| R2 piece skip rule | whole-piece RMS < 0.005 | skip only if every 1 s window is below 0.005 | keep whole-piece rule | investigate thresholds in T1 first | drop piece skipping, keep segment filter |
| R5 transcript lifetime | pending | pending | pending | pending | pending |
| R6 large uploads | pending | pending | pending | pending | pending |
Question D12: see the AskUserQuestion of the same number (same text).
Header: Silent piece
Options:
A) Apply: 1-second windows (recommended)
Skip a piece only when every 1-second window's RMS is below NoSpeech.silenceRMS; any louder second sends the piece. Test: 10 s of speech in 600 s of silence is sent.
B) Keep whole-piece rule
As approved in D4; sparse speech in a quiet piece can be lost.
C) Investigate in T1 first
Measure RMS of real quiet call audio in T1, then choose; piece skipping stays pending.
D) Defer piece skipping
No piece is skipped in v1; the segment filter alone handles hallucinations.
State: approved
Actual answer: A) Apply: 1-second windows (user, D12, 2026-11-04)
Accepted scope: skip a piece only when every 1-second window's RMS is below NoSpeech.silenceRMS; segment filter from D4 unchanged; test: 10 s of speech in 600 s of silence is sent.
History: D4 answer A (2026-11-04) approved whole-piece RMS skipping; reopened after the outside voice.

### R5: How long transcripts live
Finding: outside voice 2, High, 9/10, HistoryStore.swift:60 (`public static let \`default\` = HistoryRetention.entries(100)`) and HistoryStore.swift:127,133 (`delete`, `clear`), reviewer Codex, verified by Claude.
Plan baseline: D8, a transcript file is deleted when History retention drops its entry.
Runtime evidence: retention is shared with reads and questions, default 100 entries; delete and clear exist and do not know transcript files.
Comparison grid:
| Choice | Current | A | B | C | D |
|---|---|---|---|---|---|
| R5 lifetime | pruned with History (100 shared entries) | transcripts exempt from retention; kept until you delete them; Delete/Clear also remove files (Clear asks) | keep shared retention | investigate | defer |
Question D13: see the AskUserQuestion of the same number.
Header: Lifetime
Options:
A) Apply: keep until deleted (recommended)
Retention never prunes .transcription entries; deleting one (or Clear History, which then asks "Also delete N transcripts?") removes its file; a launch sweep re-adds transcript files that have no History entry.
B) Keep shared retention
As planned: the 101st read can delete a meeting transcript.
C) Investigate
Look at real usage for a week before choosing; plan stays as is meanwhile.
D) Defer
Leave lifetime undecided; T6 blocked until decided.
State: approved
Actual answer: A) Apply: keep until deleted (user, D13, 2026-11-04)
Accepted scope: retention never prunes .transcription entries; History delete removes the transcript file; Clear History asks "Also delete N transcripts?"; on launch, transcript files with no History entry are re-added. Tests for each.
History: none

### R6: Large files to the call engine
Finding: outside voice 5, High, 8/10, Ports.swift:225 (`func send(_ request: URLRequest) async throws -> HTTPResponse`, body in memory), reviewer Codex, verified by Claude.
Plan baseline: D3, upload of the original file.
Runtime evidence: a 2-hour screen recording can be several GB; the only HTTP port sends an in-memory body.
Comparison grid:
| Choice | Current | A | B | C | D |
|---|---|---|---|---|---|
| R6 upload | original file, in-memory body | extract the audio track to a temp m4a (video only), then stream it from disk via a new HTTPClient upload(fromFile:) | keep in-memory original | investigate in T1 | defer, cap uploads at 200 MB |
Question D14: see the AskUserQuestion of the same number.
Header: Uploads
Options:
A) Apply: audio-only, streamed (recommended)
Videos get their audio track exported to a temporary m4a (AVAssetExportSession, about 1 MB per minute); the upload streams from disk through a new HTTPClient.upload(_:fromFile:) so memory stays small; T1 records byte limits.
B) Keep in-memory original
As planned; a 2 GB video means 2 GB in memory.
C) Investigate in T1
T1 measures memory and limits first; choose after.
D) Defer with a size cap
Refuse call files over 200 MB in v1 with a clear message.
State: approved
Actual answer: A) Apply: audio-only, streamed (user, D14, 2026-11-04)
Accepted scope: videos get their audio exported to a temporary m4a (AVAssetExportSession); uploads stream from disk through a new HTTPClient.upload(_:fromFile:) with a fake for tests; T1 records the engines' byte limits.
History: none

Approval readiness: PASS. Checked R1 (D3), R2 (D4, reopened D12), R3 (D5), R4 (D6), R5 (D13),
R6 (D14), scope answers D7 to D11 and O1 to O4; every accepted change cites its own answer.

## Review findings by section

### Architecture
- [INFORMATIONAL] (confidence: 9/10) HistoryStore.swift:60 `public static let \`default\` = HistoryRetention.entries(100)` — transcripts pruned with reads; resolved by R5 (D13).
- [INFORMATIONAL] (confidence: 7/10) design D9 said "security bookmark" — VibeFlow is not sandboxed, so a plain bookmark is used; corrected in D9.
- Design twice. Shape A (chosen, D10): `FileTranscriptionJob` picks the engine, persists, summarizes; engines sit behind `Transcriber` (pieces) and `FileTranscriber` (whole file). Shape B: every engine, including the Groq piece runner, behind one `FileTranscriber` that reports progress, so the job never sees pieces. Pick: A's files with B's interface: the Groq piece runner conforms to `FileTranscriber` too, so the job has one engine interface and the piece policy lives in one place. No new file, no behavior change.
- Red flags: none open. Two ways to one task avoided (`transcribe(_:)` calls `transcribe(fileAt:)`); Me/Other naming lives only in `Transcript`; speaker ids, not names, cross module boundaries.
Dispositions: retention, accepted (D13); bookmark, factual correction; interface note, applied (within D10).

### Code quality
- [INFORMATIONAL] (confidence: 7/10) design D7 "change the names in the stored summary text by replacing the label" — "Speaker 1" also matches "Speaker 10"; same as outside voice 6; resolved by structured summary with ids.
- [INFORMATIONAL] (confidence: 8/10) OpenAITranscriber.swift `public static let timeout: TimeInterval = 10` used by the static `buildRequest` — becomes an init parameter with 10 s default; dictation regression test added.
Dispositions: both applied as required proof of approved behavior.

### Test review

```
CODE PATHS                                              USER FLOWS
[+] AudioFileDecoder                                    [+] Call file → transcript window
  ├── probe (duration, channels, no audio) [GAP→T2]       ├── [GAP] [→E2E] live eval, opt-in (real call)
  ├── decode 16 kHz mono / video audio     [GAP→T2]       └── [GAP] manual: notification click opens window
  └── pieces(): silence at 9:45, none, <10 min [GAP→T2] [+] Memo file → transcript
[+] Call engine client (T1 winner)                        ├── [GAP] job test with fake Groq
  ├── request shape, diarize, speakers     [GAP→T3]       └── [GAP] Stop keeps partial, "Cancelled at"
  ├── multichannel → Me/Other              [GAP→T3]     [+] Transcript window
  └── 401 / 429 / 5xx / malformed          [GAP→T3]       ├── [GAP] rename, merge (unit, Transcript)
[+] OpenAITranscriber                                     ├── [GAP] manual: playback, moved source
  ├── default timeout 10 s (regression)    [GAP→T12]      └── [GAP] manual: Save as Text = Copy text
  ├── segments text/start/no_speech_prob   [GAP→T2]     [+] Error states
  └── existing dictation parsing   [★★ TESTED TranscriberTests]  ├── [GAP] no key → no speakers line
[+] Silence filter (D12)                   [GAP→T2]       ├── [GAP] Groq hourly limit → partial
[+] Transcript / TranscriptStore                          └── [GAP] summary failed → transcript kept
  ├── turns, rename, merge, export, JSON   [GAP→T4]
  └── completion status round trip         [GAP→T6]
[+] FileTranscriptionJob
  ├── engine choice per kind/keys          [GAP→T5]
  ├── Groq first-piece fail → Apple        [GAP→T5]
  ├── 429 back-off → partial (R1)          [GAP→T3]
  ├── save before summary (OV4)            [GAP→T6]
  └── temp files removed on every path     [GAP→T5]
[+] HistoryStore: never prune transcripts, delete, clear, orphan re-add [GAP→T4]
[+] NotificationRoute: focus break, focus start, transcript, unknown [GAP→T11]
[+] Summary: JSON ids validated, prompt inside delimiters [GAP→T7] [→EVAL] summary quality on a real call

COVERAGE: 1/32 paths tested today (new feature) | every GAP above is a planned test in the Tests section
QUALITY: ★★★:0 ★★:1 ★:0 | GAPS: 31 planned (1 E2E live eval, 1 eval, 4 manual app checks)
```

Regression contracts (carried from approved behavior, no new question): dictation keeps a 10 s
transcription timeout and identical parsing; Pomodoro Start break keeps working (R4); old History
JSON decodes. Test plan artifact:
~/.gstack/projects/vibeflow/floo-file-transcribe-option-261219-eng-review-test-plan-20261104-165737.md
Dispositions: all planned tests accepted under the approved design; eval for summary quality noted for T1/live eval.

### Performance
- [INFORMATIONAL] (confidence: 6/10) Medium confidence, verify this is actually an issue: a 2-hour call is about 1,500 turns; a plain VStack in the transcript window would lay out all of them at once — lazy list required (applied in D9).
- In-memory upload of large videos: resolved by R6 (D14).
- History file stays small: only a 200-character excerpt per transcript goes into history.json.
Dispositions: lazy list applied; upload accepted (D14).

## Outside voice (Codex, gpt-6-astra, completed)

Eight findings, all verified against the code and resolved: 1 silence gate (reopened R2, D12 A);
2 transcript lifetime (R5, D13 A); 3 partial status persisted (applied, D8); 4 save before summary,
atomic writes, orphan re-add, visible write failures (applied, D7/D8); 5 large uploads (R6, D14 A)
and probing every kind (applied, D3); 6 structured summary with ids (applied, D7); 7 Apple assets
for the system locale (applied, D6); 8 honest progress and Stop text (applied, D6; canvas updated).
Recommendation from the outside voice: revise before implementation; done in this review.

## NOT in scope
- Our own stereo channel split: the winning engine's multichannel mode instead (D7).
- Ask about this call, Open With, voices across calls: TODOS.md (File transcription).
- Cleanup of Whisper text (Q4), language picker (Q3), files over 2 hours (Q2).
- Building both call engines: only the T1 winner is built (D11).

## What already exists
- `Transcriber`, `OpenAITranscriber`, `AppleTranscriber`, `FallbackTranscriber` (fallback logic not reused for files: one decision per file), `NoSpeech` thresholds, `RecordedAudio.wav/.rms`.
- `AnthropicClient` and the smart read document delimiters for the summary.
- `HistoryStore` and the History window (extended, not replaced); `PowerAssertion` (Keep Awake); `FocusNotifications` (shared via NotificationRoute); `SecretKey.elevenLabs` and the Accounts pane.
- New: decoder, call engine client, Transcript document and store, job, two windows, upload-from-file port method.

## Failure modes
| Path | Realistic failure | Handling | Test | User sees |
|---|---|---|---|---|
| Decode | DRM or iCloud placeholder file | "Couldn't read <file>" | T2 | clear error |
| Call upload | engine timeout on a 2-hour file | status names the reason, no partial | T3 (fake), T1 (live timeout) | clear error |
| Groq pieces | hourly limit | back-off, partial, "Stopped at" | T3 | clear partial |
| Summary | Claude error | transcript already saved, Retry | T6 | clear error |
| Storage | disk write fails | shown, not only logged | T6 | clear error |
| Playback | source moved | Play disabled, message | manual | clear message |
| Notification | permission denied | menu status line only | manual | silent but visible in menu |
No critical gaps (no path is untested, unhandled and silent).

## Worktree parallelization strategy
| Step | Modules touched | Depends on |
|---|---|---|
| T1 spike and bake-off | none (scripts in Spike/) | — |
| Decoder and silence filter | VibeFlowCore/Transcription, Dictation | — |
| Transcript, store, History | VibeFlowCore/Transcription, History | — |
| NotificationRoute | VibeFlowCore (new file), VibeFlow/FocusTimer | — |
| Call engine client, upload port | VibeFlowCore/Transcription, Ports, Support | T1 |
| Job (pieces, failures, summary) | VibeFlowCore/Transcription, SmartRead | all above |
| App: menu, options, transcript windows | VibeFlow/ | Job |
Parallel lanes: A: decoder → silence filter; B: Transcript → History; C: NotificationRoute; D: T1 → call client. Launch A + B + C with T1. Merge. Then D, then the job, then the app. Conflict flags: lanes A and B both add files under Transcription/ (different files) and both may touch Ports.swift: coordinate the `TranscriptionFailure` additions.

## Implementation Tasks
Synthesized from this review's findings. Each task derives from a specific finding above. Run with Claude Code or Codex; checkbox as you ship.

- [ ] **T1 (P1, human: ~3h / CC: ~30min)** — Spike — Bake-off Scribe vs Deepgram on a real German call; engine byte limits and timeouts
  - Surfaced by: D11, R6, outside voice 5
  - Files: Spike/
  - Verify: Florian picks the engine; limits written into D3
- [ ] **T2 (P1, human: ~3h / CC: ~15min)** — Memo engine — Per-segment silence filter and 1-second-window piece skip
  - Surfaced by: R2 (D4, D12), outside voice 1
  - Files: VibeFlowCore/Sources/VibeFlowCore/Dictation/OpenAITranscriber.swift, NoSpeech.swift, Transcription/AudioFileDecoder.swift
  - Verify: cd VibeFlowCore && swift test
- [ ] **T3 (P1, human: ~1h / CC: ~5min)** — Job — 429 back-off 30/60/120 s then partial with status
  - Surfaced by: R1 (D3)
  - Files: VibeFlowCore/Sources/VibeFlowCore/Transcription/FileTranscriptionJob.swift
  - Verify: swift test (fake HTTP: 429 then 200; 429 x4)
- [ ] **T4 (P1, human: ~2h / CC: ~10min)** — History — Transcripts never pruned; delete and clear remove files; orphan re-add on launch
  - Surfaced by: R5 (D13), outside voice 2
  - Files: VibeFlowCore/Sources/VibeFlowCore/History/HistoryStore.swift, Transcription/Transcript.swift, VibeFlow/HistoryViews.swift
  - Verify: swift test
- [ ] **T5 (P1, human: ~3h / CC: ~15min)** — Upload — Audio-only export for videos; HTTPClient.upload(_:fromFile:) streaming
  - Surfaced by: R6 (D14), outside voice 5
  - Files: VibeFlowCore/Sources/VibeFlowCore/Ports.swift, Support/URLSessionClients.swift, Transcription/
  - Verify: swift test with the fake; manual 1 GB video in the dev app
- [ ] **T6 (P1, human: ~2h / CC: ~10min)** — Transcript — Completion status persisted; save before summary; atomic writes; visible write errors
  - Surfaced by: outside voice 3 and 4
  - Files: VibeFlowCore/Sources/VibeFlowCore/Transcription/Transcript.swift, FileTranscriptionJob.swift
  - Verify: swift test
- [ ] **T7 (P2, human: ~2h / CC: ~10min)** — Summary — Structured JSON with speaker tokens and segment ids, validated
  - Surfaced by: Code quality finding, outside voice 6
  - Files: VibeFlowCore/Sources/VibeFlowCore/SmartRead/SmartReadPrompts.swift, Transcription/
  - Verify: swift test; live eval on one real call
- [ ] **T8 (P2, human: ~1h / CC: ~5min)** — Apple — Preflight on-device assets for the system locale
  - Surfaced by: outside voice 7
  - Files: VibeFlowCore/Sources/VibeFlowCore/Dictation/AppleTranscriber.swift, OnDeviceModelStatus.swift
  - Verify: swift test with a fake asset store
- [ ] **T9 (P2, human: ~1h / CC: ~5min)** — Menu — Honest progress per engine and Stop text
  - Surfaced by: outside voice 8
  - Files: VibeFlow/MenuBarView.swift, FileTranscriptionJob.swift
  - Verify: dev app with a memo and a call
- [ ] **T10 (P2, human: ~30min / CC: ~3min)** — Job — PowerAssertion for the job's lifetime
  - Surfaced by: R3 (D5)
  - Files: VibeFlow/AppContainer.swift, VibeFlow/LiveServices.swift
  - Verify: pmset -g assertions during a job
- [ ] **T11 (P1, human: ~1.5h / CC: ~8min)** — Notifications — NotificationRoute pure function with tests; shared delegate
  - Surfaced by: R4 (D6), Architecture finding 2 in scope challenge
  - Files: VibeFlowCore (new NotificationRoute.swift), VibeFlow/FocusTimer.swift
  - Verify: swift test; click Pomodoro Start break in the dev app
- [ ] **T12 (P2, human: ~30min / CC: ~3min)** — Dictation — Timeout as init parameter, 10 s default pinned by a test
  - Surfaced by: Code quality finding 2
  - Files: VibeFlowCore/Sources/VibeFlowCore/Dictation/OpenAITranscriber.swift, Tests/TranscriberTests.swift
  - Verify: swift test

## Unresolved decisions
None.

## Completion summary
- Step 0: Scope Challenge — scope accepted as-is (revised design; cuts offered in D7 to D9, D11)
- Reality rows: 7/7 tier-1 rows emitted (see below), 0 unverified premises outside T1 (engine limits, Groq numbers marked "confirm in T1")
- Architecture Review: 2 issues found
- Code Quality Review: 2 issues found
- Test Review: diagram produced, 31 gaps identified (all planned tests)
- Performance Review: 1 issue found
- NOT in scope: written
- What already exists: written
- TODOS.md updates: 3 items proposed to user, 3 added
- Failure modes: 0 critical gaps flagged
- Unresolved decisions: 0 in this review
- Outside voice: Codex (gpt-6-astra), completed, 8 findings, all resolved
- Parallelization: 4 lanes, 3 parallel / 1 sequential (call client after T1)
- Lake Score: 9/9 = answers picking the highest-completeness option / answers scored

Reality rows:
REALITY: premise-table pass claims checked against code (VibeFlowCore/Sources/VibeFlowCore/Ports.swift:214, VibeFlowCore/Sources/VibeFlowCore/History/HistoryStore.swift:60, VibeFlowCore/Sources/VibeFlowCore/Dictation/NoSpeech.swift:15, VibeFlow/AppContainer.swift:123, VibeFlow/FocusTimer.swift:170) docs/designs/file-transcription.md:1
REALITY: already-done pass origin/main has no file transcription (git log --grep transcri) docs/designs/file-transcription.md:1
REALITY: surface-check finding engine parameters (diarize, num_speakers, multichannel) verified only partly; T1 confirms docs/designs/file-transcription.md:57
REALITY: binding-decisions pass Transcriber protocol decision (2026-10-01) kept docs/designs/file-transcription.md:57
REALITY: numbers finding Groq 7,200 s/h and engine prices are third-party [estimated]; re-measure in T1 docs/designs/file-transcription.md:110
REALITY: deferred-asks pass no linked issue; user's .txt ask now in v1 (D9) docs/designs/file-transcription.md:176
REALITY: pr-count pass one PR for v1 (default policy) docs/designs/file-transcription.md:1

## GSTACK REVIEW REPORT

| Review | Trigger | Why | Runs | Status | Findings |
|--------|---------|-----|------|--------|----------|
| CEO Review | `/plan-ceo-review` | Scope & strategy | 0 | — | — |
| Outside Review | Codex (`codex exec`, from /plan-eng-review) | Independent 2nd opinion | 1 | issues_found (completed) | 8 findings, all resolved |
| Eng Review | `/plan-eng-review` | Architecture & tests (required) | 1 | ISSUES OPEN | 5 issues, 0 critical gaps (all mapped to tasks) |
| Design Review | `/plan-design-review` | UI/UX gaps | 0 | — | — |
| DX Review | `/plan-devex-review` | Developer experience gaps | 0 | — | — |

- **OUTSIDE COVERAGE:** codex, plan-review, completed, 8 findings (silence gate, transcript lifetime, partial status, commit ordering, large uploads, summary ids, Apple locale, progress honesty); all resolved in this review.
- **CROSS-MODEL:** Claude and Codex agree on summary rename by string replacement (Claude code quality 1, Codex 6) and in-memory uploads (Claude R6 framing, Codex 5). Codex alone found the silence-gate math, partial status, commit ordering, Apple locale and progress gaps.
- **VERDICT:** no review CLEAR yet (Eng Review has resolved issues mapped to tasks T1 to T12); eng review required
NO UNRESOLVED DECISIONS
