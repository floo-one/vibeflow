# VibeFlow website and launch plan

Status: draft, rebuilt 2026-10-30 on the UI consolidation model (Voice and Tools, Option plus
three keys, four feature colours) and on 1.3.0 as shipped. Design draft:
https://claude.ai/artifact/EU3V6FCDJ3CzYy8Pp2hcmC (landing page, Meetings and Clocks pages,
1200×630 social card). Source of the model: the "VibeFlow UI Consolidation" canvas
(https://claude.ai/artifact/2ZrfvQoVUPWvroXegTqfgr).

Publisher: VibeFlow is software by floo.one LLC (footer on every page).

## Positioning

**One line:** Hear anything. Say anything. A free, open-source Mac menu bar app: Option with
the three keys right above it (comma, period and the key after it) read, explain and dictate. A few quiet tools come with it.

**Two kinds of things, one app.** The site follows the app's own model:
- **Voice** (the product, always first): Read on `.`, Smart read on `,`, Dictation on `-`,
  all with Option. One grammar: ⌥ + key = the selection (or dictate), ⇧ ⌥ + key = the
  clipboard, hold = and talk. ⇧ ⌥ - is the one exception (hands-free dictation).
- **Tools** (the "and it also does" layer): small menu bar utilities, each one menu bar
  item, one switch, no extra options. Today Clocks and Meetings.

**The wedge:** reading aloud and dictation are usually two separate paid apps with their
own accounts. VibeFlow does both from one key position, has no account and no server, and
works with no keys at all (Apple voice, on-device dictation on macOS 26). Keys only make it
better, and the user pays the provider directly.

**Sharpest hook:** "Stop reading walls of AI text. Listen to them." Smart read in the
ChatGPT, Claude, Codex and Gemini apps speaks the reply as the assistant and ends on its
question; hold the key to answer by voice.

**Who it is for, in order:** developers and heavy AI chat users on a Mac; knowledge workers
who read a lot of email, contracts and reports; people who prefer listening. Clocks and
Meetings add a fourth: anyone working across time zones and calendars.

**Proof points:** under a second to the first word; about 0.8 s from release to pasted
text; works in every app; the same three key positions on every layout; no account; signed, notarized,
updates itself; MIT; the privacy table.

**Rules for copy** (from the UI work):
- Show the key position, never which finger to use.
- One word per thing, the same words as the app: Read, Smart read, Dictation, Paste again,
  Read clipboard, Ask a follow-up. Behaviour goes in a hint line, never in parentheses.
- Every shortcut is shown under the feature it serves, never in a separate shortcut list.
- No planned features presented as shipped (Activity, onboarding, the keyboard HUD, the
  meeting heads-up in the notch stay off the site until they ship).

## Look

Native macOS, matching the app's foundations:
- System font (SF Pro on Macs, Inter as the web fallback), text `#1D1D1F`, secondary
  `#6E6E73`, grounds white and `#F5F5F7`, dark band `#1D1D1F`. Pill buttons.
- Feature colours as accents only (icon tiles, dots, the keyboard keys), never for body
  text: Read `#0064D2`, Smart read `#5B4FE0`, Dictation `#D93025`, Tools `#0F7B5F`.
- The logo is the real app icon: white waveform bars on blue-violet (`#6B70FF` → `#4030C7`).
- Signature visual: the right half of a MacBook keyboard with `,` `.` `-` in their colours,
  Shift labelled "clipboard" and Option highlighted, drawn to the MacBook Air (M-series)
  geometry: two rows only, right-aligned, the end of the space bar on the left, ⌥ option and
  ⌘ under `,` `.` `-`, full-height ◀ ▶. The hero shows the German (QWERTZ) layout by default, where the three keys sit side by side above Option, with a German/US
  switch; on US the third key is `/`. The site always describes the position (the three keys right above Option, next to M), naming the characters per layout: `,` `.` `-` on German, `,` `.` `/` on US. Copy never names one character as if it were the same on every layout
  by side on every layout. The social card uses the German arrangement.

## What's included (1.3.0)

| Group | Feature | What the user gets | Needs |
|---|---|---|---|
| Voice | Read | ⌥ . selection, ⇧ ⌥ . clipboard; < 1 s; tables, links, Markdown rewritten for listening | ElevenLabs key, else Apple voice |
| Voice | Smart read | ⌥ , spoken brief; hold ⌥ , to ask a follow-up (10 turns of context); ⇧ ⌥ , clipboard; ⇧ ⌃ ⌥ V paste again; assistant voice in AI chat apps | Anthropic key (+ Groq or on-device for questions) |
| Voice | Dictation | hold ⌥ - to talk; ⇧ ⌥ - hands-free; ⌃ ⌥ V paste again; cleanup, ~0.8 s; the key right of the period (- on German, / on US) | Groq key, else Apple on macOS 26 |
| Tools | Clocks | Time zones with flags in the menu bar, 24 h, added by city, country, abbreviation or IANA name | none |
| Tools | Meetings | Next Google Calendar meeting from 5/10/15 min before, one-click Join, only real meetings | Google sign-in (read-only) |
| Shared | Notch indicator | Wings at the notch while listening, thinking or speaking | none |
| Shared | History | Every read and answer, kept locally | none |
| Shared | Updates | Sparkle, installs while idle; Check for Updates… | none |
| Shared | Permissions | Missing permission shown in the menu with a button to System Settings | none |

## Site structure

**Landing page (`/`):**
1. Nav: Voice, Tools, Pricing, Privacy, FAQ, GitHub, Download.
2. Hero: "Hear anything. Say anything.", the keyboard cluster, Download + GitHub.
3. Grammar strip: ⌥ key / ⇧ ⌥ key / hold.
4. Voice: three cards (Read, Smart read, Dictation), each with its icon tile and its own
   shortcuts underneath.
5. Dark band: Smart read made for AI chat.
6. Tools: Meetings and Clocks cards with menu bar mockups, linking to their pages.
7. Also in the box: notch indicator, History, updates, clipboard care, AirPods, permissions.
8. Pricing: "Free. Works without any keys. Better with them." One table: key, unlocks,
   without it, cost (ElevenLabs, Anthropic, Groq, Google sign-in).
9. Privacy table, including Meetings.
10. FAQ: keys, keyboard layouts, supported Macs, Accessibility, updates, App Store.
11. Final CTA (version 1.3.0) and footer.

**Tool pages (`/meetings`, `/clocks`):** same nav (Voice, Meetings, Clocks), green Tools
eyebrow, hero with a menu bar mockup, the details, own FAQ, and a closing "Comes with a
voice, too" that sends people back to the voice features. A new tool gets a card in the Tools
section first, and a page once it has enough to say.

**Biggest gap: no sound.** The product is audio. Before launch the hero needs a 20–30 s
screen recording with sound (read, smart read on an AI reply, dictation), click to play,
plus a muted captioned loop.

## Build and hosting

- Astro with plain CSS (tokens above as CSS variables), in `website/` in this repo. Shared
  nav, footer, keycap and feature-card components; Markdown for later SEO pages; the version
  read from `project.yml` and the changelog from `CHANGELOG.md` at build time.
- GitHub Pages via one Action (or a static site on Coolify). No server, no database, no
  analytics (fits "no telemetry").
- Download buttons point at
  `https://github.com/floo-one/vibeflow/releases/latest/download/VibeFlow.dmg`.
- The Sparkle `appcast.xml` already ships as a release asset, so the site does not need to
  host it.
- Needs: a domain, the og:image exported from the canvas, the demo video.

## Launch plan

| When | Channel | What |
|---|---|---|
| Before | Google app in production | Meetings sign-in must work for strangers before the site promotes it |
| Before | Homebrew cask | `brew install --cask vibeflow` |
| Before | Demo video | 30 s with sound; three vertical clips (read, AI reply, dictate) |
| Day 1 | Show HN | "Show HN: VibeFlow, an open-source Mac app to hear any text and dictate anywhere". Lead with one key position, no account, works without keys, the privacy table |
| Day 1–2 | r/macapps, r/MacOS | The demo video, "I built this for myself" |
| Week 1 | X / Bluesky / LinkedIn | The AI-chat clip first |
| Week 1 | Product Hunt | Only with the video and site done |
| Ongoing | Directories | AlternativeTo, MacUpdate, Mac newsletters |
| Ongoing | SEO pages | "read selected text aloud on Mac", "dictation Mac Whisper", "listen to ChatGPT answers on Mac", "menu bar world clock", "next meeting in menu bar" |

**Measure without telemetry:** release download counts, stars, GitHub traffic referrers.

## Open decisions

0. The app must match the site: dictation defaults on the physical key right of the period
   (`kVK_ANSI_Slash`: `-` on German, `/` on US), not on the printed "-" key. The UI
   consolidation branch currently follows the printed "-" (HyphenKey), which on US is in the
   number row.

1. Domain name.
2. Apple silicon only, or Intel too (FAQ placeholder).
3. Typical monthly cost for a heavy user (measure a week of own use).
4. Meetings: other calendars planned? And is the Google app verified for everyone before
   launch (Meetings FAQ placeholder)?
5. Launch the site before or after the UI consolidation slices ship? Screenshots of
   Settings and the menu should show the new sidebar and menu panel, so after slice 4 is
   the natural point.
