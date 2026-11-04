# Changelog

## 1.5.0

Transcribe any audio or video file, a Pomodoro timer and Keep Awake built in, Send Feedback,
and a calmer menu bar.

### New
- **Transcribe File.** Voice > Transcribe File… turns an audio or video file into a
  transcript. Calls and meetings get speaker labels (ElevenLabs Scribe); memos and talks get
  timestamped text (Groq Whisper, or Apple on-device when offline). Optionally, Claude writes
  a summary with action items, each linked to the moment it was said.
- **Transcript window.** Click a turn to play it, rename or merge speakers, search, Copy or
  Save as Text. It opens by itself when a file is done. Transcripts have their own filter in
  History and stay until you delete them. The Mac stays awake while a file runs.
- **Pomodoro.** Focus and break rounds in four rhythms: Classic 25/5, Long 50/10, Deep 90/20
  or Custom. Start it from Focus & Time in the menu or Settings > Pomodoro. VibeFlow chimes
  between phases and waits for you, unless "Start the next phase on its own" is on. Stats for
  today, this week, your streak and the last 30 days, and a history of rounds.
- **Keep Awake**, in place of Amphetamine. Keep the Mac awake indefinitely or for 15 minutes
  to 8 hours, with or without the display. From Utilities in the menu or Settings > Keep
  Awake; while it runs, the menu bar shows a cup and the time left.
- **Send Feedback.** From the menu or the bottom of the Settings sidebar: Bug, Idea or Love
  it, with a note. You see exactly what gets sent before you send it. Crashes and hangs are
  reported too. Nothing you read, dictate or transcribe is ever included.

### Changed
- **Grouped by job.** The menu and Settings now have three parts: Voice, Focus & Time
  (Clocks, Meetings, Pomodoro) and Utilities (Keep Awake). The menu bar keeps the VibeFlow
  icon and the clock; Pomodoro, Meetings and Keep Awake show up there only while active.
- **Settings panes** open with a card that says what the feature does, its state and its main
  action. Google sign-in moved to Accounts, where each key says which feature uses it. The
  dictation sound moved to Dictation; the version and Check for Updates… sit at the top of
  General.
- **Nightly builds** carry their own version, like 1.5.0-nightly.80, so the update window no
  longer says "1.5.0" on a build that isn't the release.

### Fixed
- VibeFlow could hang at launch while macOS loaded its audio components; the audio engine now
  starts in the background.
- The Settings sidebar could still be dragged closed and then stayed closed.
- Nightly updates failed with "An error occurred in retrieving update information" from
  November 2: the nightly feed was gone. It is back, and built in a way that cannot vanish
  like that again.

### Behind the scenes
- Releases and nightlies are built, signed, notarized and published by GitHub Actions instead
  of on the author's Mac, so nightlies arrive even while that Mac sleeps.
- Each build's debug symbols go to Sentry, so crash reports point at the right line.

## 1.4.0

The new Settings, a one-click way back from a nightly, and the dictation key in the same row
as the other voice keys on every keyboard.

### New
- **Settings, redesigned.** A sidebar replaces the eight toolbar tabs: General and Accounts,
  then Voice (Read, Smart Read, Dictation), then Tools (Clocks, Meetings). Each voice pane
  starts with its own shortcuts, and Smart Read shows "Ask a follow-up" (hold the smart read
  key) as its own row.
- **Appearance.** General > Look & Feel: System, Light or Dark for VibeFlow's windows.
- **Back to Stable.** On a nightly, Settings > General and the menu (under Check for
  Updates…) install the latest release in one click: VibeFlow downloads it, checks that it is
  VibeFlow, signed by us and notarized, swaps it in and reopens. If anything fails, the
  installed app stays as it was.
- **Channel picker.** General > Updates: Stable or Nightly, in place of the "Update to the
  newest main" toggle. Your earlier choice carries over.

### Changed
- **Dictation key.** Dictate (Option) and Dictate hands-free (Shift + Option) default to the
  key right of ".": "-" on German, "/" on US. All three voice keys now sit in one row right
  above Option, on every layout. Shortcuts still on the old default move over once; shortcuts
  you recorded stay as they are.
- **Settings layout.** General holds Look & Feel, History and Updates. Accounts replaces
  Advanced and says what each API key unlocks. "Change shortcuts…" is no longer in the menu;
  each feature's shortcuts are in its own pane.

### Fixed
- Switching to Nightly now checks right away in the update window, instead of downloading
  silently and installing only after 5 minutes away from the Mac. While a downloaded update
  waited for that idle time, Check for Updates… did nothing; it now installs that update.
- Switching back to Stable from a nightly no longer keeps the nightly until the next release
  (Back to Stable, above).
- On German keyboards the dictation default was the "ß" key, not the key next to ".".
- The Settings sidebar cannot be dragged away or hidden any more; before, dragging its edge
  all the way left made it disappear with no way back to the other panes.

### Behind the scenes
- New website at vibeflow.floo.one, with download, features, Meetings and Clocks pages.
- The nightly job builds from its own clone outside ~/Documents (macOS blocks background jobs
  there), skips commits that only change the website, and `nightly.sh --install` copies the
  right file.

## 1.3.0

### Updates
- Settings > Advanced > "Update to the newest main": VibeFlow updates to a build of every new
  main that passed CI, not only to releases. The menu then shows the commit next to the
  version. Turning it off keeps that build until a release is newer; if a build of main
  breaks, Go Back to the Release turns it off and downloads the release to drag over it.

### Settings
- Keys is now Advanced: the API keys, and an Updates section with the version, "Update to the
  newest main", when VibeFlow last checked and Check for Updates…. Error messages that sent you
  to Settings > Keys now say Settings > Advanced.

### Meetings
- Your next Google Calendar meeting shows in the menu bar from 10 minutes before it starts
  (📅 Standup in 8m, then "now") until 5 minutes after. Click it to Join the Meet, Zoom, Teams
  or Webex call, see the rest of today's meetings, or open Google Calendar. When two meetings
  overlap, the next one to start is shown.
- Only real meetings count: focus time, out of office, working location, birthdays, all-day,
  cancelled, "free", declined and solo events are skipped, judged by your own email even on a
  colleague's calendar. Invites with a hidden guest list still count. A meeting on two
  calendars you watch shows once, and a watched calendar that stops sharing is skipped
  instead of stopping the sync.
- Settings > Meetings: sign in with Google (read-only), a status line (signed in, offline,
  signed out, blocked by your Workspace admin), on/off, lead time 5, 10 or 15 minutes, and the
  calendars to watch. It syncs every 5 minutes, after wake and when the network comes back.
  Sign out forgets the sign-in on this Mac only; VibeFlow Dev keeps its own sign-in.
- Builds without a Google client (forks, CI) work as before; the tab says "Not configured in
  this build".

## 1.2.0

### Updates
- VibeFlow keeps itself up to date. It checks for a new version every 6 hours, downloads it
  in the background and installs it once VibeFlow is not reading or dictating and the Mac has
  been left alone for 5 minutes; it restarts in a second or two. Quitting VibeFlow installs a
  downloaded update too. The menu shows the version and has Check for Updates…. This starts
  with 1.2.0, so install it by hand once.

### Look
- An app icon: white waveform bars on blue-violet. VibeFlow Dev gets an orange one with a DEV
  band.

### Menu
- A missing permission shows in the menu with a button to System Settings: Accessibility, and
  Microphone once it was turned off. The menu checks again each time it opens, and every two
  seconds while something is missing, so the entry and the warning icon go away as soon as you
  grant it, without pressing a shortcut first.

### Distribution
- `scripts/dev.sh` runs VibeFlow Dev from `~/Applications/VibeFlow Dev.app`, whichever
  worktree built it, and only one copy of each app runs: a newly started copy quits the older
  one. The Dev menu starts with the branch, commit and build time, and Quit names the app.
  `--doctor` lists every VibeFlow on the Mac, `--clean` removes leftover builds with the
  release bundle id.
- Releases carry a signed Sparkle update feed (`appcast.xml`) next to the DMG, and
  `scripts/release.sh` refuses to publish with a signing key or build number that installed
  copies would reject.

## 1.1.0 (2026-10-29)

### Smart read
- Ask back: hold Option + , (the smart read shortcut), say a question about what you just
  heard, let go. Claude answers in a few spoken sentences, grounded in the text, and says in a
  few words when it goes beyond it. The text, the brief and the last ten questions stay in
  context; selecting something new starts over, and a hold while VibeFlow speaks interrupts it.
  Answers stream: each sentence goes to the voice as soon as it is complete, so the answer
  starts after the first sentence instead of after the whole reply. An answer cut off at the
  length cap stops at its last full sentence and says "Answer cut short". A tap of the shortcut
  still smart reads, and the microphone opens only after the shortcut is held for 0.3 s.
  With nothing selected, a hold asks about the last text, also in Chrome and other apps where
  VibeFlow has to use Edit > Copy to read the selection.
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

### Distribution
- VibeFlow is now a download: a notarized DMG on GitHub Releases that opens on any Mac
  without the "unidentified developer" detour. `scripts/release.sh --publish` builds, notarizes
  and uploads it from main.
- Debug builds are a separate app, VibeFlow Dev, that runs next to the installed release: its
  own settings and permissions, a DEV tag in the menu bar, and Control added to every default
  shortcut (Control + Option + . and so on, Command added to the paste shortcuts). It uses the same API keys as the release.

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
