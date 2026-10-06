# VibeFlow

Select text anywhere on your Mac, press a shortcut, hear it read aloud in a voice you
actually want to listen to. Hold another shortcut, talk, and the text is typed where your
cursor is. Speech out and speech in, in one small menu bar app.

- **Read** (Option + . by default): the selection, spoken with an ElevenLabs voice,
  first audio in well under a second. Apple's built-in voices are the free, offline fallback.
  Tables, links and Markdown are rewritten for listening: a table row is read as
  "Campaign: X, Budget: Y", a link as its text, a bare URL as its domain.
- **Smart read** (Option + ,): Claude explains the selection like you are 10, in a few short
  sentences, then it is spoken. Add per-app instructions such as "what do they want from me".
- **Dictate** (Option + - by default): hold to talk and release to paste, or tap once to
  dictate hands-free until the next press (2-minute cap). Groq Whisper transcribes, a quick
  cleanup fixes punctuation, casing and misheard names from your vocabulary, and the text is
  pasted into the field you were typing in. About 0.8 s from release to text.
- **Clipboard**: add Shift (Shift + Option + . or ,) to read or smart read whatever is on the clipboard.
- **Per app**: its own voice and speed, or one switch, "Keep this app on this Mac", for apps
  whose content must never leave the Mac.
- Press a read shortcut again to stop. Everything lives in the menu bar.

Native Swift 6 / SwiftUI, macOS 15 or later. No accounts, no server, no telemetry. Bring your
own API keys.

## What leaves your Mac

- A **read** sends the selected text to ElevenLabs. Without a key or a connection it uses
  an Apple voice and sends nothing.
- A **smart read** also sends the selected text to Anthropic.
- A **dictation** sends your recording to Groq for transcription, then the transcript and
  your vocabulary list to Groq again for cleanup. If Groq is offline, rate limited or down,
  or no Groq key is set, Apple's on-device recognizer transcribes instead and nothing is sent
  (macOS 26; on macOS 15 there is no on-device fallback).
- **Recordings stay in memory.** The last failed dictation is kept only so you can Retry,
  Copy or Discard it from the menu; the next dictation or quitting the app removes it. Apple
  on-device transcription writes a temporary audio file that is deleted as soon as it is read.
- **Keep this app on this Mac** (Settings > Apps) means the Apple voice, no smart read and
  on-device dictation for that app: nothing from it leaves the Mac.
- API keys are stored in your login Keychain and never written to a file.

## Clipboard note

When an app does not expose its selection through Accessibility, VibeFlow falls back to
pressing that app's Edit > Copy for you and then puts your previous clipboard text back.
This is best-effort: the copy itself shows up in clipboard managers, only plain text is
restored, and if another app writes the clipboard in the same instant the read is refused
rather than guessed.

Dictation pastes through the clipboard too: it writes the text (marked transient, so
clipboard managers skip it), presses the app's Paste menu item (or Cmd-V), and restores your
previous clipboard text 750 ms later unless something else was copied in between. Right
before pasting it checks that the same app and the same text field still have focus and that
no password field is active; otherwise the text is left on the clipboard instead, with a note
in the menu.

## Microphone

Settings > Dictation > Microphone defaults to Automatic: the built-in microphone while you
listen on Bluetooth headphones (opening a headset's microphone drops it to phone-call sound
quality), the built-in microphone when the system input is a virtual or aggregate device,
and the system input otherwise. Pick a specific microphone there to override it.

## Setup

1. Install [Xcode](https://apps.apple.com/app/xcode/id497799835) and XcodeGen:
   `brew install xcodegen`.
2. Sign in to Xcode with an Apple ID (Settings > Accounts). A free personal team is enough;
   it gives the app a stable signature so the Accessibility permission survives rebuilds.
   Put your team id into `DEVELOPMENT_TEAM` in `project.yml`.
3. Generate and build:

   ```bash
   xcodegen generate
   xcodebuild -project VibeFlow.xcodeproj -scheme VibeFlow -configuration Debug -derivedDataPath build/DerivedData build
   open build/DerivedData/Build/Products/Debug/VibeFlow.app
   ```

4. Grant Accessibility when asked, and Microphone on the first dictation. Add your keys under
   Settings > Keys: ElevenLabs for the voice, Anthropic for smart read, Groq for dictation.

## Development

The logic lives in the `VibeFlowCore` Swift package behind small protocols (pasteboard,
accessibility, speech provider, audio player, audio recorder, transcriber, clock, smart read
client, secrets), so everything from both state machines to the paste and Copy fallbacks is
tested with in-memory fakes:

```bash
cd VibeFlowCore && swift test
```

Live goldens that call the real Anthropic API (injection resistance, brief keeps
qualifications, cleanup keeps numbers and names) run only on request:

```bash
VIBEFLOW_RUN_EVALS=1 ANTHROPIC_API_KEY=... swift test --filter LiveEvalTests
```

The dictation cleanup golden (a dictated question is cleaned, never answered) runs the same
way with `GROQ_API_KEY` set and `--filter CleanupEvals`.

`Spike/elevenlabs-spike.swift` measures ElevenLabs first-audio and stop latency and
`Spike/dictation-spike.swift` measures Groq transcription and cleanup on your machine; run
them with `swift Spike/<name>.swift` and keys in a local `.env`.

The designs, every review decision and the task lists are in `docs/designs/vibeflow-v1.md`
(reading) and `docs/designs/vibeflow-2-dictation-conversation.md` (dictation).

## License

MIT, see `LICENSE`.
