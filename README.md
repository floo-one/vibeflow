# VibeFlow

**Hear anything. Say anything.**

[![CI](https://github.com/floo-one/vibeflow/actions/workflows/ci.yml/badge.svg)](https://github.com/floo-one/vibeflow/actions/workflows/ci.yml)

A tiny Mac menu bar app for both directions of voice. Select text anywhere and press a
shortcut to hear it in a voice you actually want to listen to. Hold another shortcut, talk,
and your words are typed where your cursor is.

- **Read** (Option + .): the selection, spoken with an ElevenLabs voice, usually in well
  under a second. Tables, links and Markdown are rewritten for listening: a table row is read
  as "Campaign: X, Budget: Y", a link as its text, a bare URL as its domain.
- **Smart read** (Option + ,): Claude explains the selection like a sharp friend talking to a
  curious 15-year-old, in a few spoken sentences that grow with the selection, then it is spoken.
- **Dictate** (Option + -): hold to talk, release to paste. For longer dictation, press
  Shift + Option + - once to start and again to stop. Groq Whisper transcribes, a quick cleanup fixes
  punctuation, casing and misheard words, and the text lands in the field you were typing in.
  About 0.8 s from release to text.
- **Clipboard**: add Shift (Shift + Option + . or ,) to read or smart read the clipboard.
- **Paste again**: Control + Option + V pastes your last dictation again, Shift + Control +
  Option + V pastes the last smart read result. The menu bar menu lists every action with the
  shortcut it is set to.
- Press a read shortcut again to stop. Every shortcut can be changed in Settings.
- **Clocks**: other time zones in the menu bar, each with its flag (🇩🇪 14:05  🇺🇸 08:05).
  Add them in Settings > Clocks by searching a city, country, abbreviation or time zone.

Native Swift 6 and SwiftUI, macOS 15 or later. No accounts, no server, no telemetry. You
bring your own API keys.

## Keys

Add them in Settings > Keys. Each one is optional; here is what you get with and without it.

| Key | Enables | Get one | Without it |
|---|---|---|---|
| ElevenLabs | The natural reading voice | [elevenlabs.io](https://elevenlabs.io/app/settings/api-keys), free monthly allowance | Reads use the best Apple voice installed for the text's language |
| Anthropic | Smart read | [console.anthropic.com](https://console.anthropic.com/settings/keys), pay as you go | Smart read is unavailable |
| Groq | Dictation and its cleanup | [console.groq.com](https://console.groq.com/keys), free tier | macOS 26: dictation uses Apple's on-device recognizer, without cleanup. macOS 15: no dictation |

Smallest setups:
- **No keys:** reading aloud with an Apple voice, plus dictation on macOS 26.
- **Groq (free):** dictation on macOS 15, and better transcription with cleanup everywhere.
- **ElevenLabs:** the premium voice.
- **Anthropic:** smart read.

## What leaves your Mac

- A **read** sends the selected text to ElevenLabs. Without a key or a connection it uses an
  Apple voice and sends nothing.
- A **smart read** also sends the selected text to Anthropic.
- A **dictation** sends your recording to Groq for transcription, then the transcript to Groq
  again for cleanup. If Groq is offline, rate limited or down, or no Groq key is set, Apple's
  on-device recognizer transcribes instead and nothing is sent (macOS 26; on macOS 15 there is
  no on-device fallback).
- **Recordings stay in memory.** The last failed dictation is kept only so you can Retry, Copy
  or Discard it from the menu; the next dictation or quitting the app removes it. Apple
  on-device transcription writes a temporary audio file that is deleted as soon as it is read.
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

## Microphone and speaker

Settings > Dictation > Microphone defaults to Automatic: the built-in microphone while you
listen on Bluetooth headphones (opening a headset's microphone drops it to phone-call sound
quality), the built-in microphone when the system input is a virtual or aggregate device,
and the system input otherwise. Pick a specific microphone there to override it.
Settings > Reading > Speaker sends the ElevenLabs voice to a specific output; the Apple
fallback voice always uses the system output.

## Build it yourself

There is no downloadable build yet, so VibeFlow is built from source.

1. Install [Xcode 26](https://apps.apple.com/app/xcode/id497799835) and XcodeGen:
   `brew install xcodegen`.
2. Sign in to Xcode with an Apple ID (Settings > Accounts). A free personal team is enough.
   It gives the app a stable signature, so the Accessibility and Microphone permissions
   survive rebuilds. In `project.yml`, set `DEVELOPMENT_TEAM` to your team id and change
   `PRODUCT_BUNDLE_IDENTIFIER` (for example to `com.yourname.vibeflow`), since
   `one.floo.vibeflow` belongs to the author's team.
3. Generate and build:

   ```bash
   xcodegen generate
   xcodebuild -project VibeFlow.xcodeproj -scheme VibeFlow -configuration Debug -derivedDataPath build/DerivedData build
   open build/DerivedData/Build/Products/Debug/VibeFlow.app
   ```

4. Grant Accessibility when asked, and Microphone on the first dictation, then add your keys
   in Settings > Keys.

An ad-hoc build (`CODE_SIGN_IDENTITY=-`, as CI does) works too, but macOS forgets its
Accessibility permission on every rebuild; remove the old entry and grant it again each time.

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

The designs, every review decision and the task lists are in `docs/designs/`:
`vibeflow-v1.md` (reading), `vibeflow-2-dictation-conversation.md` (dictation) and
`vibeflow-github-v1.md` (this repo). Changes are listed in `CHANGELOG.md`.

## License

MIT, see `LICENSE`.

The time zone list for Clocks comes from [vvo/tzdb](https://github.com/vvo/tzdb) (MIT,
Copyright CodeAgain SASU), trimmed into `VibeFlowCore/Sources/VibeFlowCore/Clock/Resources/`.
Refresh it with `python3 scripts/update-time-zones.py`.
