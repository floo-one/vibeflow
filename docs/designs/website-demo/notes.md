# Website live demo (1.5)

**Direction changed 2026-11-05:** the interactive demo is parked. The site gets a minimal
feature showcase now (`showcase.html`: one menu as the hero, the four 1.5 features beside it),
and a demo video later. The showcase waits for the new pop-up menu bar the author is building:
once it exists, its design replaces the menu mock in `showcase.html`, then it is ported to
Astro. The prototype and voice clips below stay for the video.

Status of the interactive prototype: 2026-11-04. Open `prototype.html` in a browser (desktop width, Chrome or Safari).

## Idea

A section on the landing page, right after the hero: a Mac screen in the browser where the
real shortcuts work. "Don't watch a video. Press the keys." Desktop only; under 900 px it
says "Open this page on your Mac to try it."

## What the prototype does

- **Stage:** a 1120×700 Mac screen (wallpaper in the icon's blue-violet), scaled to fit and
  tilting flat as it scrolls into view. Menu bar with the VibeFlow icon, the German clock and
  the notch. The notch grows VibeFlow's wings like the app: mic + level bars (listening),
  sparkle + spinner (thinking), speaker + waveform (speaking), tinted per feature.
- **Keys:** ⌥ . / ⌥ , / ⌥ + the key right of "." are caught by `event.code` (Period,
  Comma, Slash), so they match the physical position on German and US layouts, exactly like
  the app. Only while the demo is on screen. Shift switches to the demo clipboard (⌘C inside
  the demo fills it). ⌃⌥V pastes the last dictation. Every keycap in the hints and the mini
  keyboard can also be clicked or held.
- **Scenes** (tabs under the Mac):
  1. Read: Mail. Select any words, ⌥ . reads them with word-by-word highlight; again stops.
  2. Smart read: a long AI chat reply. ⌥ , speaks the brief as the assistant; hold ⌥ , to
     ask a follow-up (the demo "asks" a scripted question), let go to hear the answer.
  3. Dictation: a chat thread. Hold ⌥ - and the raw, messy words stream in; let go and the
     cleaned text is pasted into the compose box. ⇧⌥ - is hands-free.
  4. Transcribe (new): drag `Kickoff call.m4a` onto the menu bar icon (or menu > Transcribe
     File…). Progress panel, then the Transcript window: speakers, timestamps, Claude
     summary, action items linked to the moment. Click a turn to hear it in that speaker's voice.
  5. Focus & Time (new): the VibeFlow menu (Voice / Focus & Time / Utilities, as in 1.5).
     Start a Pomodoro or Keep Awake and their menu bar items appear and count down; the
     meeting item appears and opens the Join popover.
- The menu is live in every scene (Read selection, Smart read clipboard, …).

## Decisions to make before porting

1. **Voice: decided 2026-11-05, pre-rendered ElevenLabs.** `website/scripts/render-demo-voice.mjs`
   renders every line in `website/src/data/demo-lines.json` (with-timestamps, mp3 44.1 kHz
   64 kbps, multilingual v2) into `website/public/demo/voice/`: one MP3 per line plus
   `voice.json` with the start of every character in ms (and `voice.js`, the same data for
   the file:// prototype). It only renders lines whose text, voice or speed changed, and
   reads the key from `ELEVENLABS_API_KEY` or the app's Keychain item. 28 clips, 1.6 MB,
   about 3,200 characters per full render. Voices: narrator = the author's reading voice
   (bIHbv24MWmeRgasZH58o), Anna = Sarah, Ben = Brian (ElevenLabs stock voices).
   Any selection works: each readable block is one clip, the words are matched to the
   clip by characters, and playback seeks from the first selected word to the last. The
   browser voice remains only as a fallback for a line without a clip. Before a visitor's
   first click or keypress the browser blocks sound; the demo then plays muted (the
   highlight still runs) and says "Click anywhere in the demo to hear the voice."
   Changing any demo text means editing demo-lines.json and running the script again.
2. **Real microphone for dictation?** Web Speech API works in Chrome and Safari but sends
   audio to Google/Apple, asks for mic permission, and is unreliable. Recommendation: keep
   it scripted.
3. **Smart read briefs** are fixed per scene, whatever part is selected. Fine for a demo; the
   footnote already says what really runs.
4. **Where on the page:** as its own section after the hero (prototype), or replace the
   hero keyboard with it on desktop. Recommendation: own section; the hero stays static and
   fast.

## Porting plan (Astro)

- `website/src/components/demo/Demo.astro` (markup + scoped CSS) and `demo.ts` (client
  script, one `<script>` that Astro bundles). Content (texts, briefs, follow-ups, samples,
  transcript) in `website/src/data/demo.ts`, so copy edits don't touch logic.
- Audio clips in `website/public/demo/` + a `scripts/render-demo-voice.mjs` that calls
  ElevenLabs with the key from the Keychain and writes MP3 + timings (run by hand, results
  committed; no key in CI).
- Lazy: the script and clips load only when the section nears the viewport.
- Accessibility: tabs as a real tablist, the caption is `aria-live`, every action reachable
  by button; reduced motion turns off tilt, drift and waves.
- `pnpm verify` before merge.
