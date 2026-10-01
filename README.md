# Outflow

Select text anywhere on your Mac, press a shortcut, hear it read aloud in a voice you
actually want to listen to. Outflow is the counterpart to speech-to-text tools like
Wispr Flow: speech out instead of speech in.

- **Read** (Control-Option-R by default): the selection, spoken with an ElevenLabs voice,
  first audio in well under a second. Apple's built-in voices are the free, offline fallback.
- **Smart read** (Control-Option-S): the selection goes through Claude first, as a short
  spoken brief or a cleanup that reads well aloud, then is spoken.
- **Per-app presets**: a calm narrator for PDFs, a fast voice for Slack, or "Apple only, no
  smart read" for apps whose text must never leave the Mac.
- Press the shortcut again to stop. Everything lives in the menu bar.

Native Swift 6 / SwiftUI, macOS 15 or later. No accounts, no server, no telemetry. Bring your
own API keys.

## What leaves your Mac

- A **read** with the ElevenLabs provider sends the selected text to ElevenLabs.
- A **smart read** also sends it to Anthropic.
- A read with the **Apple** provider sends nothing anywhere.
- API keys are stored in your login Keychain and never written to a file.

Set a per-app preset to the Apple provider with smart read off for anything sensitive.

## Clipboard note

When an app does not expose its selection through Accessibility, Outflow falls back to
pressing that app's Edit > Copy for you and then puts your previous clipboard text back.
This is best-effort: the copy itself shows up in clipboard managers, only plain text is
restored, and if another app writes the clipboard in the same instant the read is refused
rather than guessed.

## Setup

1. Install [Xcode](https://apps.apple.com/app/xcode/id497799835) and XcodeGen:
   `brew install xcodegen`.
2. Sign in to Xcode with an Apple ID (Settings > Accounts). A free personal team is enough;
   it gives the app a stable signature so the Accessibility permission survives rebuilds.
   Put your team id into `DEVELOPMENT_TEAM` in `project.yml`.
3. Generate and build:

   ```bash
   xcodegen generate
   xcodebuild -project Outflow.xcodeproj -scheme Outflow -configuration Debug -derivedDataPath build/DerivedData build
   open build/DerivedData/Build/Products/Debug/Outflow.app
   ```

4. Grant Accessibility when asked. Add your keys under Settings > Keys.

## Development

The logic lives in the `OutflowCore` Swift package behind seven small protocols
(pasteboard, accessibility, speech provider, audio player, clock, smart read client, secrets),
so everything from the state machine to the Copy fallback is tested with in-memory fakes:

```bash
cd OutflowCore && swift test
```

Live goldens that call the real Anthropic API (injection resistance, brief keeps
qualifications, cleanup keeps numbers and names) run only on request:

```bash
OUTFLOW_RUN_EVALS=1 ANTHROPIC_API_KEY=... swift test --filter LiveEvalTests
```

`Spike/elevenlabs-spike.swift` measures ElevenLabs first-audio and stop latency on your
machine; run it with `swift Spike/elevenlabs-spike.swift` and a key in a local `.env`.

The design, every review decision and the task list are in `docs/designs/outflow-v1.md`.

## License

MIT, see `LICENSE`.
