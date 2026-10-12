# Changelog

## Unreleased

### Dictation
- Dictate is now pure push-to-talk: releasing the shortcut always transcribes and pastes,
  however short the press. A separate toggle shortcut (Shift + Option + - by default) starts a
  hands-free recording with one press and stops it with the next.

### Clocks
- A second menu bar item shows the time in other time zones, each with its flag. It starts
  with Berlin. Settings > Clocks adds clocks by city, country, abbreviation or IANA name
  (time zone data from vvo/tzdb), and removes or reorders them.

## 1.0.0 (2026-10-06)

First public version.

### Reading
- Select text anywhere and press Option + . to hear it in an ElevenLabs voice; first audio
  usually arrives in well under a second. The best installed Apple voice takes over without a
  key, offline, or if ElevenLabs fails mid-read, resuming from the sentence it reached.
- Smart read (Option + ,): Claude explains the selection like you are 10 in a few short
  sentences, then it is spoken.
- Add Shift to read or smart read the clipboard. Press the shortcut again to stop.
- Tables, links and Markdown are rewritten for listening: a table row is read as
  "Header: value" pairs, a link as its text, a bare URL as its domain.

### Dictation
- Hold Option + - to talk and release to paste; tap it to dictate hands-free until the next
  press (2-minute cap). Groq Whisper transcribes and a quick cleanup fixes punctuation,
  casing and misheard words.
- Pastes into the exact field you were typing in, then restores your clipboard. If focus
  moved or a password field is active, the text is left on the clipboard instead.
- Falls back to Apple's on-device recognizer when Groq is unreachable or no key is set
  (macOS 26). A failed dictation can be retried, copied or discarded from the menu.
- Automatic microphone choice keeps Bluetooth headphones in high-quality mode and skips
  virtual or aggregate input devices.

### Settings
- Four small tabs: shortcuts, voice and models, dictation models and microphone, keys.
  Keys live in your Keychain; there is no server and no telemetry.
