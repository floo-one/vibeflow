# VibeFlow

**Hear anything. Say anything.**

[![CI](https://github.com/floo-one/vibeflow/actions/workflows/ci.yml/badge.svg)](https://github.com/floo-one/vibeflow/actions/workflows/ci.yml)

A tiny Mac menu bar app for both directions of voice. Select text anywhere and press a
shortcut to hear it in a natural voice. Hold another shortcut, talk, and your words are typed
where your cursor is.

Native Swift and SwiftUI, macOS 15 or later. No VibeFlow account, no server, no telemetry.
You bring your own API keys.

## Install

1. Download [VibeFlow.dmg](https://github.com/floo-one/vibeflow/releases/latest/download/VibeFlow.dmg)
   (signed and notarized by Apple), open it and drag VibeFlow to Applications.
2. Grant Accessibility when asked, and Microphone on your first dictation.
3. Add your keys in Settings > Keys (see [Keys](#keys); all optional).

To update, download the new DMG and replace the app.

## What it does

| Shortcut | Action |
|---|---|
| Option + . | **Read** the selection aloud, usually in well under a second |
| Option + , | **Smart read**: Claude explains the selection in a few spoken sentences |
| Hold Option + , | **Ask back**: ask a question about what you just heard, let go to hear the answer |
| Hold Option + - | **Dictate**: talk, release, and the text is pasted where you were typing |
| Shift + Option + - | **Dictate hands-free**: press once to start, again to stop |
| Add Shift to a read | Read or smart read the **clipboard** instead of the selection |
| Control + Option + V | **Paste last dictation** again |
| Shift + Control + Option + V | **Paste last smart read** |

Press a read shortcut again to stop. Every shortcut can be changed in Settings, and the menu
bar menu lists every action with its current shortcut.

- **Read** rewrites tables, links and Markdown for listening: a table row becomes "Campaign:
  X, Budget: Y", a link its text, a bare URL its domain.
- **Smart read** talks like a sharp friend explaining to a curious 15-year-old, longer for
  longer selections. In the ChatGPT, Codex, Claude and Gemini apps it speaks a reply as that
  assistant, in first person, ending on any question it asked you.
- **Ask back** answers in one to three sentences grounded in the text; the voice starts after
  the first sentence. The text, the brief and your last ten questions stay in context. Holding
  while it speaks interrupts it.
- **Dictation** is transcribed by Groq Whisper, cleaned up (punctuation, casing, misheard
  words) and pasted in about 0.8 s.
- **History** keeps every read and every question with its answer, on this Mac only.
- **Clocks** show other time zones in the menu bar with their flags (🇩🇪 14:05 🇺🇸 08:05).
- **Meetings** shows your next Google Calendar meeting in the menu bar 10 minutes before it
  starts (📅 Standup in 8m), with a Join button for Meet, Zoom, Teams and Webex links. Sign in
  with Google in Settings > Meetings; pick the calendars to watch and the lead time (5, 10 or
  15 minutes). Focus time, out of office, all-day, declined and solo events are skipped.

## Keys

Each key is optional. Add them in Settings > Keys; they are stored in your login Keychain.

| Key | Enables | Without it |
|---|---|---|
| [ElevenLabs](https://elevenlabs.io/app/settings/api-keys) (free allowance) | The natural reading voice | The best installed Apple voice |
| [Anthropic](https://console.anthropic.com/settings/keys) (pay as you go) | Smart read and ask back | No smart read |
| [Groq](https://console.groq.com/keys) (free tier) | Dictation with cleanup, ask back | macOS 26: Apple's on-device recognizer, no cleanup. macOS 15: no dictation |

With no keys at all you still get reading with an Apple voice, plus dictation on macOS 26.

## Privacy: what leaves your Mac

- **Read**: the selected text goes to ElevenLabs. With an Apple voice, nothing is sent.
- **Smart read**: the selected text also goes to Anthropic.
- **Ask back**: your recording goes to Groq (or stays on device, as for dictation); the text,
  brief and recent questions go to Anthropic; the answer goes to ElevenLabs.
- **Dictation**: your recording goes to Groq, then the transcript goes to Groq for cleanup.
  Without Groq (no key, offline, rate limited) Apple's on-device recognizer is used on macOS
  26 and nothing is sent.
- **Meetings**: VibeFlow reads your calendars from Google with read-only access. Events stay
  in memory on this Mac; the Google sign-in is kept in your Keychain. Sign Out in Settings >
  Meetings forgets the sign-in on this Mac only; to remove VibeFlow's access entirely, remove
  it at myaccount.google.com/permissions.
- **Stays local**: History (`~/Library/Application Support/VibeFlow/history.json`, cleared in
  Settings > General), recordings (in memory only; the last failed one is kept until the next
  dictation so you can retry it) and API keys (Keychain).

## Good to know

- **Clipboard.** When an app does not expose its selection, VibeFlow presses Edit > Copy for
  you and restores your previous clipboard text afterwards. Dictation pastes through the
  clipboard too (marked transient, so clipboard managers skip it) and restores it 750 ms
  later. Before pasting it checks that the same text field still has focus and that no
  password field is active; otherwise the text stays on the clipboard with a note in the menu.
  Only plain text is restored.
- **Microphone.** Automatic uses the built-in microphone while you listen on Bluetooth
  headphones (a headset microphone drops them to call quality) or when the system input is a
  virtual device. Pick a specific microphone in Settings > Dictation.
- **Speaker.** Settings > Reading > Speaker sends the ElevenLabs voice to a specific output.
- **Google sign-in.** Google has not verified VibeFlow yet, so the consent screen warns that
  the app is unverified (Advanced > Go to VibeFlow), and while the app is in Google's testing
  phase only invited accounts can sign in. A Google Workspace admin can block third-party apps;
  the Meetings tab then says "Blocked by your Google Workspace admin". If you untick calendar
  access on the consent screen, sign-in stops with "Allow calendar access"; sign in again and
  keep "See your calendars" ticked.

## Build it yourself

```bash
brew install xcodegen
xcodegen generate
xcodebuild -project VibeFlow.xcodeproj -scheme VibeFlow -configuration Debug -derivedDataPath build/DerivedData build
open "build/DerivedData/Build/Products/Debug/VibeFlow Dev.app"
```

Set your own `DEVELOPMENT_TEAM` and bundle id in `project.yml` first. Signing, tests,
releases and the design docs are in [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md). Changes are
listed in [CHANGELOG.md](CHANGELOG.md).

## License

MIT, see [LICENSE](LICENSE). The time zone list for Clocks comes from
[vvo/tzdb](https://github.com/vvo/tzdb) (MIT, Copyright CodeAgain SASU).
