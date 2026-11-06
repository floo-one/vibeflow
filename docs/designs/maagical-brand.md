# Maagical: the brand

Decided 2026-11-06. The brand guidelines are a six-page private Design canvas
(https://claude.ai/artifact/2QwVBb4pBsJv6dt6yoXAp5): 01 brand overview, 02 logo variations,
03 colours, 04 typography, 05.1 usage in the app, 05.2 usage on the website hero. This file keeps
the same decisions in text.

## Name

**Maagical**: Maag, the author's surname, plus magical. Said exactly like magical; the second a is
seen, not heard. Always "Maagical" in running text, never all caps, never umlauts. "Maagic" is a
noun the copy may use at most once per page ("a little Maagic"); never "maagically" for a feature.
Features keep their plain names: read, smart read, dictation, meetings, focus, keep awake.

Rejected: Maagic (reads as a typo of magic), Maag alone (says nothing), Maagintosh (funny once).

Domain: maagical.app had no DNS records on 2026-11-06; registration status unconfirmed. The site
stays at vibeflow.floo.one until that is settled.

## In the app

The panel's brand colour (Palette.brand, flat #3A2FBF) marks the Ready dot, the update pill
and the one-time rename card: "VibeFlow is now Maagical", shown by RenameNotice on a Mac that
already had VibeFlow data, until OK. The General pane header shows the app icon instead of the
gear tile. Feature colours (read, smart read, dictation, tools) are unchanged, see
menu-bar-popover.md D9.

## Icon: the ace

A white playing card on a flat indigo tile, an A in the top left and bottom right corners (the
second one turned, like a real card), and the five voice bars as its suit, the middle one gold.
No gradient, no sparkle, no wand: the first draft (gradient tile, waveform, four point star) was
thrown out as the generic AI app look.

Drawn by `scripts/make-icons.swift`, which also writes the website's favicon and apple touch icon;
`website/src/components/AppIcon.astro` is the same shapes as SVG. Dev build: same card on solid
orange with the DEV band.

Menu bar: the idle glyph stays the SF Symbol waveform, with mic, ellipsis and exclamation for the
other states. The card does not reduce to 18 px.

Also considered and kept on the canvas: a mirrored double a monogram, rabbit ears in a top hat,
the plain hat, a floating card, cups and ball.

## Colour

| Role | Hex | Use |
|---|---|---|
| Indigo | #3A2FBF | Icon tile, links, primary button, the wordmark's second a |
| Midnight | #14123A | Headings, dark website bands |
| Gold | #F5B82E | The middle bar, live states. Fills only on light grounds (2.1:1 as text); #8A5B00 is the gold allowed as text on white |
| Mist | #F4F3FF | Tinted section ground |
| Indigo on midnight | #9B8CFF | Small text and links on dark |

The website's four feature colours (read, smart read, dictation, tools) stay as they are.

## Wordmark

The name in the product's own type: SF Pro in the app, Inter on the web. Weight 800, tracking
about -0.04em, one colour (midnight on light, white on midnight), every letter on the baseline.
Lockup: icon at the cap height, gap of a third of the icon, clear space the height of the a.
Rejected on the way: a lifted second a, a mirrored or turned second a, a second typeface.

## Headline

"Your Mac, just better. Quite Maagical." Two sentences, two lines, sentence case. The shorter
"Your Mac, but Maagical." serves one-line places (DMG window, social preview).

## What the rename touched and what it did not

Moved to Maagical: `PRODUCT_NAME` (Maagical, Maagical Dev), the icons, every user visible string,
the DMG (`Maagical.dmg`, `Maagical-<version>.dmg`), the website, README, CHANGELOG, CLAUDE.md.

Stays VibeFlow: the Xcode project, scheme and target, the `VibeFlowCore` module, the bundle ids
`one.floo.vibeflow` and `.dev` (Sparkle refuses an update with another bundle id; TCC and
UserDefaults are keyed to it; `StableInstaller.swift` checks it in its code requirement), the
Keychain service, the log subsystem, `Application Support/VibeFlow`, the Sparkle keys and feed
URLs, the GitHub repo and the domain (both can move later; GitHub redirects old URLs).

Transition: the first Maagical release also uploads the DMG as `VibeFlow.dmg`, because Back to
Stable in the 1.5 nightlies downloads that name (`scripts/release.sh`). `scripts/dev.sh` quits and
removes an old `VibeFlow Dev.app`. Sparkle installs updates in place, so an installed copy likely
keeps the file name `VibeFlow.app` with Maagical inside: verify on a second Mac before the release
and decide whether the first launch offers to rename it.
