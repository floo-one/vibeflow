# Build plan: the VibeFlow website (Astro)

Status: ready to execute, written 2026-10-30. Read this whole file before starting.
Companion docs: `docs/designs/website.md` (positioning, copy rules, feature table) and
`docs/designs/website-canvas/*.dc.html` (the approved design, one file per page; the live
canvas is https://claude.ai/artifact/EU3V6FCDJ3CzYy8Pp2hcmC).

## Goal

A static marketing site for VibeFlow (by floo.one LLC), built with Astro in `website/` in this
repo and deployed to GitHub Pages by a GitHub Action. Three pages (`/`, `/meetings/`,
`/clocks/`) plus a 404, matching the canvas. Done means: it builds from a frozen lockfile, the
checks in "Verification" pass, and the deploy workflow publishes it.

## Fixed decisions (do not revisit)

| Topic | Decision |
|---|---|
| Location | `website/` in `floo-one/vibeflow`, its own `package.json` and lockfile. Nothing outside `website/` imports from it. |
| Framework | Astro, current stable major at execution time, static output (`output: 'static'`). No UI framework (no React/Vue/Svelte), no Tailwind. |
| Language | TypeScript, `astro/tsconfigs/strict`. |
| Styling | Plain CSS: one `src/styles/global.css` with design tokens as CSS variables, plus scoped `<style>` in components. |
| JavaScript shipped | None. The German/US keyboard switch is CSS only (radio inputs + `:checked`); the FAQ uses `<details>`. |
| Fonts | System stack (`-apple-system, BlinkMacSystemFont, "SF Pro Text", "Inter", system-ui, sans-serif`). Inter is self-hosted via `@fontsource-variable/inter` for non-Apple visitors. No Google Fonts request (the site promises no tracking). |
| Package manager | pnpm, pinned with `"packageManager": "pnpm@<exact>"` in `website/package.json`. Exact versions for every dependency (no `^` or `~`). |
| Node | 24 LTS: `website/.nvmrc` = `24`, `"engines": {"node": ">=24 <25"}`, CI uses `actions/setup-node` with `node-version-file: website/.nvmrc`. Locally use `/opt/homebrew/opt/node@24/bin` (the default `node` on this Mac is 26). |
| Integrations | `@astrojs/sitemap` only. |
| Hosting | GitHub Pages, source "GitHub Actions". Until a domain exists the site lives at `https://floo-one.github.io/vibeflow/`, so `base` is `/vibeflow`. |
| Analytics | None. |
| Downloads | Every Download button links to `https://github.com/floo-one/vibeflow/releases/latest/download/VibeFlow.dmg`. Never a versioned URL. |

## Before you start

1. Work on a new branch from `origin/main` (for example `website`). `main` already has the
   dictation-on-the-key-right-of-"." change (PR 19), which the copy below assumes.
2. Make sure `docs/designs/website.md`, this file and `docs/designs/website-canvas/` are on your
   branch. They were written on branch `website-planning-marketing-f7d085`; if they are not on
   `main` yet, check them out from that branch.
3. Ask the user these four questions in one message. Use the answers in the copy; for anything
   unanswered, **leave that sentence or FAQ entry out** (never ship a `[PLACEHOLDER]`):
   - Typical monthly cost for a heavy daily user (Pricing section footnote).
   - Meetings: are calendars other than Google planned? (Meetings FAQ "Outlook or iCloud".)
   - Is the Google app verified for everyone? If not, keep a Meetings FAQ entry explaining the
     "unverified app" warning; if yes, drop that entry.
   - Is there a domain yet? (If yes, see "Custom domain".)
4. Find out the supported Macs yourself: download the latest DMG
   (`gh release download --repo floo-one/vibeflow --pattern VibeFlow.dmg --dir <scratch>`),
   mount it, and run `lipo -archs` on `VibeFlow.app/Contents/MacOS/VibeFlow`. `arm64 x86_64`
   means "Apple silicon and Intel Macs with macOS 15 or later"; `arm64` alone means "Apple
   silicon". Put that in the FAQ "Which Macs does it run on?".

## File layout

```
website/
  .nvmrc                      24
  package.json                scripts: dev, build, preview, check, verify
  pnpm-lock.yaml
  astro.config.mjs
  tsconfig.json
  public/
    favicon.png               from VibeFlow/Assets.xcassets/AppIcon.appiconset/icon_32x32@2x.png
    apple-touch-icon.png      from icon_256x256@2x.png (resize to 180x180 with `sips -z 180 180`)
    og.png                    1200x630, see task 8
    robots.txt
  src/
    data/site.ts              constants + version read from ../project.yml
    styles/global.css         tokens, reset, base typography, utilities (.k keycap, .row)
    layouts/Base.astro        <html>, <head> (title, description, canonical, OG/Twitter, icons), Nav, Footer
    components/
      Nav.astro               logo + links; current page bold with aria-current
      Footer.astro            "VibeFlow by floo.one LLC · MIT licensed" + links
      AppIcon.astro           the inline SVG app icon (gradient #6B70FF → #4030C7, four white bars)
      DownloadButton.astro    pill button, size prop
      Keycaps.astro           renders ["⌥", ","] as .k spans
      Keyboard.astro          the hero keyboard, German and US, CSS-only switch
      FeatureCard.astro       Voice card: icon tile, title, subtitle, text, shortcut rows (slot)
      ShortcutRow.astro       label, optional hint, keycaps
      ToolCard.astro          Tools card: mockup slot, icon tile, title, text, link
      Faq.astro               list of { q, a } as <details>
      MenuBarMock.astro       shared menu bar strip used by Meetings and Clocks mockups
      Flag.astro              tiny SVG flags (IE, DE, JP) used in the clock mockups
    pages/
      index.astro
      meetings.astro
      clocks.astro
      404.astro
      og.astro                1200x630 social card, `noindex`, excluded from the sitemap
  scripts/
    check-links.mjs           verifies every internal href/src in dist/ resolves
```

## Design tokens (global.css)

Copy exactly; they come from the app's Foundations.

```css
:root {
  --text: #1D1D1F; --text-2: #424245; --text-3: #6E6E73;
  --ground: #FFFFFF; --ground-2: #F5F5F7; --line: #ECECF0; --line-2: #D2D2D7;
  --dark: #1D1D1F; --dark-2: #2C2C30; --dark-text: #F5F5F7; --dark-text-2: #C7C7CC;
  --read: #0064D2; --smart: #5B4FE0; --dictation: #D93025; --tools: #0F7B5F;
  --icon-top: #6B70FF; --icon-bottom: #4030C7;
  --radius-card: 18px; --radius-pill: 999px;
  --max: 1200px; --gutter: 24px;
}
```

Colour is an accent only (icon tiles, dots, keys, Tools links); body text uses `--text*`.
Light theme only for now (the canvas has no dark design); do not add a dark mode.

## Tasks

Do them in order; each ends with `pnpm check && pnpm build` passing.

### 1. Scaffold

- `pnpm create astro@latest website -- --template minimal --typescript strict --no-git --install`
  (or the equivalent flags of the current CLI), then delete the template's sample content.
- Pin every version exactly in `package.json`, add `packageManager`, `engines`, `.nvmrc`.
- Add `@astrojs/sitemap` and `@fontsource-variable/inter`.
- `astro.config.mjs`:
  ```js
  import { defineConfig } from 'astro/config';
  import sitemap from '@astrojs/sitemap';
  export default defineConfig({
    site: process.env.SITE_URL ?? 'https://floo-one.github.io',
    base: process.env.BASE_PATH ?? '/vibeflow',
    trailingSlash: 'always',
    integrations: [sitemap({ filter: (page) => !page.includes('/og/') })],
  });
  ```
- Scripts: `"check": "astro check"`, `"build": "astro build"`, `"verify": "pnpm check && pnpm build && node scripts/check-links.mjs"`.
- Root `.gitignore`: add `website/node_modules/`, `website/dist/`, `website/.astro/`.
  This matters: `scripts/release.sh --publish` refuses a dirty working tree.

### 2. Data and layout

- `src/data/site.ts` exports `DMG_URL`, `REPO_URL = 'https://github.com/floo-one/vibeflow'`,
  `CHANGELOG_URL = REPO_URL + '/blob/main/CHANGELOG.md'`, `PUBLISHER = 'floo.one LLC'`, and
  `VERSION`, read at build time from `../project.yml` with
  `/MARKETING_VERSION:\s*"([^"]+)"/`, using `node:fs` and
  `path.resolve(process.cwd(), '../project.yml')` (Astro runs from `website/`; do not use
  `import.meta.url`, which points into the bundle after a build).
  Throw if the file or key is missing, so a moved key fails the build instead of shipping "undefined".
- Every internal link goes through a helper `url(path)` that prefixes `import.meta.env.BASE_URL`.
  Never hard-code `/meetings/`.
- `Base.astro` takes `title`, `description`, `path`; sets `<html lang="en">`, canonical,
  `og:title/description/image/url`, `twitter:card=summary_large_image`, favicon and touch icon.
  Titles: "VibeFlow: hear anything, say anything", "Meetings in your Mac menu bar · VibeFlow",
  "World clocks in your Mac menu bar · VibeFlow".

### 3. Shared components

Build Nav, Footer, AppIcon, DownloadButton, Keycaps, ShortcutRow, FeatureCard, ToolCard, Faq,
MenuBarMock, Flag from the canvas markup. Rules:
- Real `<a href>` and `<button>`; touch targets at least 44px; visible focus ring
  (`:focus-visible { outline: 2px solid var(--read); outline-offset: 2px; }`).
- Decorative SVG gets `aria-hidden="true"`; mockups are `aria-hidden` as a whole.
- Layout uses flex-wrap and `grid-template-columns: repeat(auto-fit, minmax(…, 1fr))` like the
  canvas, so every section stacks at 375px without media-query gymnastics. No horizontal page
  scroll at 375px (the keyboard and the pricing table scroll inside their own box).

### 4. The keyboard (Keyboard.astro)

Port `docs/designs/website-canvas/landing.dc.html` (the `.kb`, `.kbr`, `.kk*`, `.arr` rules and
the two `kbr` blocks), with the switch rebuilt CSS-only:

```html
<fieldset class="layout-switch">
  <legend class="visually-hidden">Keyboard layout</legend>
  <input type="radio" name="kb" id="kb-de" checked><label for="kb-de">German</label>
  <input type="radio" name="kb" id="kb-us"><label for="kb-us">US</label>
</fieldset>
<div class="kb-de">…German panel + caption…</div>
<div class="kb-us">…US panel + caption…</div>
```
Show `.kb-us` and hide `.kb-de` with `#kb-us:checked ~ …` (keep the inputs as earlier
siblings of both panels), style the labels as the segmented control, and keep the radios
keyboard-focusable (visually hidden, not `display:none`).

Geometry (MacBook Air, M-series), unit 54px keys with 6px gaps, rows right-aligned in a 429px box:
- Row 1, German: N M `,`(Smart read, `--smart`) `.`(Read, `--read`) `-`(Dictation, `--dictation`)
  ⇧ (129px, "shift · clipboard"). US: the same with `/` as Dictation.
- Row 2: end of the space bar (114px, left corners square, faded), ⌘ (69px; "cmd" on German,
  "command" on US), ⌥ "option" (white, highlighted), ◀ full height, ▲/▼ stacked half keys, ▶ full height.
- Captions: German "German keyboard: comma, period and minus sit side by side, right above
  Option." US "US keyboard: comma, period and slash. Same three keys, same place, on every layout."
- Each panel has `role="img"` and the `aria-label` from the canvas.

### 5. Landing page (index.astro)

Sections in this order, copy taken verbatim from `landing.dc.html` unless "Copy fixes" below says
otherwise: Nav · Hero (eyebrow, h1 "Hear anything. Say anything.", intro, Download + "Source on
GitHub", trust line, Keyboard) · grammar strip (⌥ key / ⇧ ⌥ key / hold) · Voice (three
FeatureCards with their ShortcutRows) · dark "Smart read, made for AI chat" band · Tools (Meetings
and Clocks ToolCards linking to their pages) · "Also in the box" (six items) · Pricing (key table)
· Privacy (table) · FAQ · final CTA with the app icon and "Version {VERSION} · macOS 15 or later
· What's new" · Footer.

### 6. Meetings and Clocks pages

Port `meetings.dc.html` and `clocks.dc.html` with the same components. Nav on these pages:
Voice (`/#voice`), Meetings, Clocks, GitHub, Download. Both end with "Comes with a voice, too."
and link back to `/#voice`.

### 7. 404, robots, sitemap

- `404.astro`: short message, links to Home and Download. GitHub Pages serves `404.html`
  automatically.
- `public/robots.txt`: allow all, `Sitemap: <site><base>/sitemap-index.xml`.

### 8. Social card

- `og.astro` renders the canvas `og-card.dc.html` at exactly 1200×630 (`<meta name="robots"
  content="noindex">`).
- Produce `public/og.png` once: `pnpm build && pnpm preview`, then with Node 24 on PATH run
  `pnpm dlx playwright@<exact current version> screenshot --viewport-size=1200,630
  http://localhost:4321/vibeflow/og/ public/og.png` (install Chromium first with
  `pnpm dlx playwright@<same version> install chromium`). Commit the PNG. Re-run only when the
  card changes. If Playwright cannot run, ask the user to export the canvas's "Social card"
  artboard as a PNG instead.

### 9. Link check

`scripts/check-links.mjs` (plain Node, no dependency): walk `dist/**/*.html`, collect every
`href`/`src` that starts with the base path, strip `#…`, and fail if the target file does not
exist in `dist` (`/x/` → `x/index.html`). External links are not fetched.

### 10. Deploy workflow (.github/workflows/website.yml)

```yaml
name: Website
on:
  push:
    branches: [main]
    paths: ['website/**', 'project.yml', '.github/workflows/website.yml']
  pull_request:
    paths: ['website/**', 'project.yml', '.github/workflows/website.yml']
  workflow_dispatch:
permissions:
  contents: read
concurrency:
  group: pages
  cancel-in-progress: false
jobs:
  build:
    runs-on: ubuntu-latest
    defaults: { run: { working-directory: website } }
    steps:
      - uses: actions/checkout@v4
      - uses: pnpm/action-setup@v4          # reads packageManager from website/package.json
        with: { package_json_file: website/package.json }
      - uses: actions/setup-node@v4
        with: { node-version-file: website/.nvmrc, cache: pnpm, cache-dependency-path: website/pnpm-lock.yaml }
      - run: pnpm install --frozen-lockfile
      - run: pnpm verify
      - if: github.event_name != 'pull_request'
        uses: actions/upload-pages-artifact@v3
        with: { path: website/dist }
  deploy:
    if: github.event_name != 'pull_request'
    needs: build
    runs-on: ubuntu-latest
    permissions: { pages: write, id-token: write }
    environment: { name: github-pages, url: '${{ steps.deployment.outputs.page_url }}' }
    steps:
      - id: deployment
        uses: actions/deploy-pages@v4
```
Use the newest major of each action that exists at execution time.

Leave `.github/workflows/ci.yml` unchanged (the macOS build stays on every push; it is free on
a public repo and nothing requires it to be skipped).

### 11. Keep website commits out of the nightly channel

`scripts/nightly.sh` builds and publishes a nightly for every new `origin/main` that passed CI,
so a copy fix on the website would ship an identical app to everyone on the Nightly channel.
In `run()`, right after the `PUBLISHED` check and before the CI check, add:

```zsh
  # Website-only commits change nothing in the app: mark them done without a build.
  local last="$(cat "$PUBLISHED" 2>/dev/null || true)"
  if [[ -n $last ]] && git -C "$SRC" cat-file -e "$last" 2>/dev/null; then
    local app_changes="$(git -C "$SRC" diff --name-only "$last" "$sha" -- . \
      ':(exclude)website' ':(exclude).github/workflows/website.yml')"
    if [[ -z $app_changes ]]; then
      print "$sha" > "$PUBLISHED"
      say "${sha:0:7}: website only, no nightly needed"
      exit 0
    fi
  fi
```
Then tell the user to run `scripts/nightly.sh --install` once from their checkout, because the
LaunchAgent runs an installed copy. Mention it in `docs/DEVELOPMENT.md` "Nightly: follow main".

### 12. Docs

- `docs/DEVELOPMENT.md`: a short "Website" section (Node 24, `cd website && pnpm install && pnpm dev`,
  `pnpm verify`, deploys on push to main via the Website workflow, `og.png` regeneration).
- `README.md`: no change until the site is live; then add the URL under the title.
- `CLAUDE.md`: one line under "Build and verify": website lives in `website/`, verify with
  `cd website && pnpm verify`.

## Copy fixes (apply while porting)

- Footer on every page: "VibeFlow by floo.one LLC · MIT licensed" (Clocks adds "· Time zone data
  from vvo/tzdb").
- The canvas files link pages as `Main.dc.html`, `Meetings.dc.html`, `Clocks.dc.html`; map them to
  `/`, `/meetings/`, `/clocks/` via `url()`.
- Clock mockups say "Thu 30 Oct"; use a neutral "Thu 09:05" style or keep it, but no year.
- Remove the canvas-only note under the Clocks mockup ("flags are drawn here for the mockup")
  only if you render real flag emoji instead; otherwise keep it.
- Apply the answers from "Before you start"; drop anything still unanswered.
- Shortcut keycaps for Dictation show `-` (the German key). The Dictation card text already
  explains "- on German keyboards, / on US"; keep it.

## Things that must stay true (from docs/designs/website.md)

- Voice first, Tools second, on every page.
- Show key positions, never fingers. Never claim one character is in the same place on every
  layout; say "the three keys right above Option".
- Same words as the app: Read, Smart read, Dictation, Read clipboard, Ask a follow-up,
  Paste again.
- Nothing that has not shipped (no Activity window, onboarding, keyboard HUD, meeting
  heads-up in the notch).
- No tracking, no third-party requests at runtime (no Google Fonts, no analytics, no
  embedded videos from other hosts).

## Verification (all required before calling it done)

1. `cd website && pnpm install --frozen-lockfile && pnpm verify`: astro check clean, build
   succeeds, link check passes.
2. `pnpm preview`, then look at `/`, `/meetings/`, `/clocks/`, a missing path (404) and `/og/`
   in a browser (built-in browser pane or gstack `/browse`) at 375px, 768px and 1440px wide:
   - no horizontal page scroll at 375px;
   - the German/US switch works with the keyboard (Tab, Space, arrow keys) and with JS disabled;
   - every Download button points at the latest-release DMG URL;
   - the version line shows the `MARKETING_VERSION` from `project.yml`.
3. `grep -rnE '\[(YOUR|CONFIRM|DECIDE|MEASURE)' website/src website/dist` finds no leftover
   placeholder text from the canvas.
4. `dist/` contains no request to another host except links the user clicks
   (`grep -rhoE 'src="https?://[^"]+"' website/dist` is empty).
5. Lighthouse (Chrome DevTools, mobile) on `/`: Accessibility 100, Best Practices ≥ 95,
   Performance ≥ 95. Report the numbers.
6. `git status` from the repo root is clean after a build (gitignore works).
7. Push the branch, open a PR, confirm the Website workflow's build job passes on the PR.

## Going live (needs the user)

- **Enable Pages** (repo setting, ask first): Settings › Pages › Source "GitHub Actions", or
  `gh api -X POST repos/floo-one/vibeflow/pages -f build_type=workflow`.
- After the PR merges, the Website workflow deploys; confirm
  `https://floo-one.github.io/vibeflow/` returns 200 and shows the current version.
  Merged is not live until that URL answers.
- **Custom domain** (when there is one): add `website/public/CNAME` with the domain, set
  the workflow env `SITE_URL=https://<domain>` and `BASE_PATH=/`, add the domain in
  Settings › Pages, and create the DNS record GitHub shows. Then add the URL to the README and
  the repo's "website" field (`gh repo edit --homepage`), with the user's OK.

## Out of scope for this build

Demo video (needs recording by the user; leave a clear spot in the hero to add it later),
changelog page, blog/SEO pages, dark mode, translations, Homebrew cask.
