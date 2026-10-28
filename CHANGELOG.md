# Changelog

## 1.1.0 (2026-10-28)

### Smart read
- Ask back: hold Option + , (the smart read shortcut), say a question about what you just
  heard, let go. Claude answers in a few spoken sentences, grounded in the text, and says in a
  few words when it goes beyond it. The text, the brief and the last ten questions stay in
  context; selecting something new starts over, and a hold while VibeFlow speaks interrupts it.
  Answers stream: each sentence goes to the voice as soon as it is complete, so the answer
  starts after the first sentence instead of after the whole reply. An answer cut off at the
  length cap stops at its last full sentence and says "Answer cut short". A tap of the shortcut
  still smart reads, and the microphone opens only after the shortcut is held for 0.3 s.
- The menu shows the last question and answer with a Copy answer button, and Paste last smart
  read pastes the last answer as well as the last brief.
- Settings > Smart Read holds the model, a speed of its own (briefs and answers are listened to
  more slowly than a text you skim) and the prompts, separate from Reading.
- Claude Haiku 5.5 is the default smart read model, with thinking switched off so it answers
  at once.
- Smart read now explains like a sharp friend talking to a curious 15-year-old: it leads with
  what matters, keeps real terms and says what they mean, and sounds spoken rather than written.
  The length follows the selection (up to 40, 80 or 140 words), and the focus follows the kind
  of text: what an email wants and by when, a contract's money, deadlines and ways out, an
  article's claim, an error's likely fix. Numbers and dates are kept exactly as written.
- In the ChatGPT, Codex, Claude and Gemini Mac apps, smart read speaks a reply as that assistant,
  in first person and more sharply, and ends on what it needs from you: its question, or the
  step it announced. Selecting the reply or copying it and pressing Shift + Option + , both
  work; copied text gets the assistant voice only when it was copied in that app. Warnings about data, security or money are kept, and links or payment requests the reply
  quotes are attributed instead of voiced as advice. Settings > Prompts shows the added rule.

### Dictation
- Dictate is now pure push-to-talk: releasing the shortcut always transcribes and pastes,
  however short the press. A separate toggle shortcut (Shift + Option + - by default) starts a
  hands-free recording with one press and stops it with the next.

### Menu
- The menu bar menu lists every action with the shortcut it is set to right now: read and smart
  read the selection or the clipboard, start or stop dictation, and where push-to-talk lives.
- Paste last dictation (Control + Option + V) pastes your most recent dictation again, and Paste
  last smart read (Shift + Control + Option + V) pastes the last smart read result. Both are in the
  menu and in Settings, kept in memory only, and restore your clipboard afterwards. When there is
  nowhere to paste, nothing is pasted and your clipboard is left alone.

### History
- Every read and every question with its answer is kept on this Mac, in one JSON file readable
  only by your account. The menu's History submenu reads an entry aloud again or opens the
  History window, where an entry can be read again, copied or deleted. Settings > General
  chooses how much to keep (7, 30 or 90 days, or the last 100 or 500 entries) and clears it.
  Nothing from history is sent anywhere beyond the reads and questions you trigger.

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
