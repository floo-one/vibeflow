# Dev and prod side by side

Status: 2026-10-29. P2 built (scripts/dev.sh, one copy per app, cleanup), P3 built (app
icons, Dev build stamp, Quit names the app) and P1 built (Sparkle, ships with 1.2.0); P4 open.

## Goal

- **VibeFlow** (prod) is always installed in /Applications, always the newest GitHub
  release, updates itself, keeps its Accessibility and Microphone grants forever.
- **VibeFlow Dev** can be launched from any branch or worktree to try a feature, has its own
  grants, and never gets confused with prod.
- At a glance (menu bar, Dock-less app switcher, Spotlight, Activity Monitor, System
  Settings > Privacy) it is obvious which one is which, and which branch a Dev build is.

## What is true today

The split already exists: Release is `one.floo.vibeflow` "VibeFlow", Debug is
`one.floo.vibeflow.dev` "VibeFlow Dev" with a DEV tag and Control-added shortcuts, both
signed by team X7UXDLS9F7 so grants survive rebuilds. What makes it unreliable:

1. **Prod is not installed.** /Applications has no VibeFlow. Nothing keeps it current; the
   only way up is downloading the DMG by hand.
2. **Stray copies with the prod bundle id.** Old Debug builds from before the split still
   sit at `build/DerivedData/.../Debug/VibeFlow.app` (main checkout and the
   prompt-editing-ui worktree), plus `build/release/export/VibeFlow.app` and the xcarchive.
   They are all `one.floo.vibeflow`, so Spotlight and Launch Services may open one of them
   when you mean prod, and System Settings shows one "VibeFlow" row for all of them.
3. **One Dev app per worktree.** Seven worktrees, each with its own
   `build/DerivedData/.../VibeFlow Dev.app`. Same bundle id, same grants, but nothing stops
   two of them running at once (two DEV icons, the same hotkeys registered twice) and nothing
   tells you which branch the running one came from.
4. **Same icon.** Dev and prod look identical in Spotlight, Finder and Settings; only the
   menu bar label differs.

## Plan

### P1. Sparkle auto-updater in prod

[Sparkle 2](https://sparkle-project.org) is the standard updater for notarized Developer ID
apps outside the App Store; it verifies an EdDSA signature on every update and swaps the app
in place, so the bundle id and signature stay the same and the grants survive.

- Add the `Sparkle` SPM package. One `SPUStandardUpdaterController`, created only in
  Release (`#if !DEBUG`); Dev never checks for updates.
- Info.plist (Release only): `SUFeedURL =
  https://github.com/floo-one/vibeflow/releases/latest/download/appcast.xml`,
  `SUPublicEDKey`, `SUEnableAutomaticChecks = YES`, `SUAutomaticallyUpdate = YES`
  (download in the background, install on quit or next launch, no prompt),
  `SUScheduledCheckInterval = 21600` (6 h).
- Menu: "Check for Updates…" plus the version in the menu footer.
- One-time: `generate_keys` puts the EdDSA private key in the login keychain (nothing in the
  repo); the public key goes in project.yml.
- `scripts/release.sh --publish`: after the DMG is notarized, run Sparkle's `sign_update` on
  it, write a one-item `appcast.xml` (version, build number, DMG URL of this tag, signature,
  length, CHANGELOG section as release notes) and upload it as a second release asset. The
  `latest/download` URL then always points at the newest appcast. No new hosting, no server.
- Guard: release.sh already refuses a reused tag; also refuse when CURRENT_PROJECT_VERSION is
  not greater than the last release's, because Sparkle compares build numbers.

Why not a hand-rolled GitHub API check: replacing a running, notarized app safely
(quarantine, signature check, relaunch) is exactly what Sparkle already does well.

As built (2026-10-29):

- **Package:** Sparkle 2.10 via SPM, linked in both configurations. `Updater`
  (`VibeFlow/Updater.swift`) is created only in Release (`AppContainer`, `#if !DEBUG`).
- **When it installs** (decided with the user: silently, when idle): Sparkle downloads in the
  background (`SUAutomaticallyUpdate`), and `Updater` takes over `willInstallUpdateOnQuit`.
  It checks every minute and installs (relaunching VibeFlow) once nothing is reading or
  dictating and the Mac has had no keyboard or mouse input for 5 minutes. That way a relaunch
  never cuts off work or loses "paste last dictation" mid-task. A quit installs it too.
- **Key:** created 2026-10-29 in the login keychain under the Sparkle account `vibeflow`, not
  the default account, so another Sparkle app never shares it. Back it up with
  `generate_keys --account vibeflow -x`.
- **Feed:** `scripts/write-appcast.sh` writes a one-item feed (the CHANGELOG section as simple
  HTML, the enclosure signed by `sign_update`). It was tested with a throwaway key: `xmllint`
  passes and `sign_update --verify` accepts the signature.
- **`release.sh` checks:** before building, that the keychain key matches `SUPublicEDKey`; on
  `--publish`, that the build number beats the last tag's. It uploads `appcast.xml` next to
  the DMG.
- **Not verified yet:** a real update from one release to the next. The first chance is 1.2.0
  to the release after it.

### P2. One fixed home for each app

- **Prod**: `/Applications/VibeFlow.app`, installed once from the 1.2.0 DMG (the first with
  Sparkle), then never touched by hand. Launch at login stays on for prod only.
- **Dev**: `~/Applications/VibeFlow Dev.app`, always the build you are testing right now.
  New `scripts/dev.sh` (run from any worktree):
  1. `xcodegen generate` + Debug build into that worktree's `build/DerivedData`.
  2. Quit the running VibeFlow Dev (by bundle id), whichever worktree it came from.
  3. Replace `~/Applications/VibeFlow Dev.app` with the fresh build and open it.
  Same path, same bundle id, same signature every time: one entry in Spotlight, one row in
  System Settings, grants kept.
- **Single instance in Dev**: on launch, a Dev build terminates any other running
  `one.floo.vibeflow.dev` (belt and braces when launched from Xcode instead of dev.sh).
  Prod does the same for `one.floo.vibeflow`.
- **Cleanup once**: delete the stray prod-id copies listed above and unregister them from
  Launch Services (`lsregister -u`). `scripts/dev.sh --doctor` lists every VibeFlow*.app on
  disk with bundle id, version and path, and flags anything outside the two homes.

As built (2026-10-29):

- The newest-copy-wins check runs in `VibeFlowApp.init`, before `AppContainer`: the Keychain
  read there can block launch on an access dialog (P4), and a check in the app delegate never
  ran in that state. Until a copy has finished launching, SIGTERM ends it on the spot; after
  that it quits like the Quit menu item. The rule itself is `SingleInstance` in Core, tested.
- `--clean` deletes leftovers instead of moving them to the Trash: Launch Services follows a
  bundle into the Trash and keeps it registered. It only deletes copies with the release
  bundle id in checkouts that now build VibeFlow Dev, so nothing rebuilds them.
- Worktrees on a branch from before the Dev split (prompt-editing-ui, upcoming-meetings-menubar
  on 2026-10-29) still build a Debug app with the release bundle id. `--clean` leaves them and
  the doctor names them; merging main fixes them.
- Spotlight keeps an app that still exists registered with Launch Services, so `lsregister -u`
  only sticks for deleted apps and fresh build outputs.
- `release.sh` deletes the exported app after the DMG and runs `dev.sh --clean`, so a release
  leaves no second launchable VibeFlow in build/.

### P3. Tell them apart at a glance

- **Icon**: Dev gets its own app icon (same glyph, orange with a DEV band) via
  `ASSETCATALOG_COMPILER_APPICON_NAME: AppIconDev` in the Debug config. Shows in Spotlight,
  Finder, System Settings > Privacy and notification banners.
- **Menu bar**: prod keeps the plain icon; Dev keeps "DEV" and tints the icon orange.
- **Build stamp in Dev**: a build phase writes branch, short commit and build time into
  Info.plist (`VFGitBranch`, `VFGitCommit`, `VFBuildDate`). The Dev menu shows a header row
  "Dev · prompt-editing-ui · 916f8dd · 14:02", so you always know which feature is running.
- **Prod footer**: "VibeFlow 1.2.0 · up to date" (from Sparkle), so you can see prod is
  current.
- **Quit item** names the app: "Quit VibeFlow Dev" / "Quit VibeFlow".

As built (2026-10-29):

- There was no app icon at all, so `scripts/make-icons.swift` draws both: AppIcon (blue-violet,
  white waveform bars) and AppIconDev (orange, same bars, dark DEV band). The bars are drawn,
  not SF Symbols, which Apple's license keeps out of app icons. A Release build compiles only
  AppIcon; Debug sets `ASSETCATALOG_COMPILER_APPICON_NAME: AppIconDev`.
- The stamp uses build settings instead of a build phase: `dev.sh` passes `VF_GIT_BRANCH`,
  `VF_GIT_COMMIT` (with `*` for uncommitted changes) and `VF_BUILD_DATE` on the xcodebuild
  command line, and Info.plist substitutes them. `BuildStamp` in Core reads and formats them; a
  build from an earlier day shows its date. A build from Xcode says "not built by
  scripts/dev.sh". The changing date does not force a rebuild (incremental `dev.sh` about 5 s).
- The menu bar tint is skipped: the label stays a template image, and DEV next to it is enough.
- The prod footer waits for Sparkle (P1).

### P4. Permissions you can see

Both apps need Accessibility and Microphone, granted once each (separate bundle ids by
design). Add a small "Permissions" row to both menus that shows ✓ or a "Grant…" button per
permission, opening the right System Settings pane. With the fixed homes from P2 the grants
stay put; the row just makes a missing one obvious instead of a silent failed capture.

Found while building P2: `AppContainer` reads the API keys from the shared Keychain item in
`App.init`, on the main thread. An app whose signature is not on the item's access list yet
(the first VibeFlow Dev, or prod after Dev saved the keys) gets a Keychain dialog, and until it
is answered the app has no menu bar icon, no logs and no delegate callbacks. Load the keys
after launch, off the main thread (the in-memory cache is already there), and say in the
menu that the keys are waiting for Keychain access.

### What stays the same

- Settings and history: separate per app (own UserDefaults), as today.
- API keys: shared Keychain item, as today.
- Shortcuts: Dev keeps Control added, so both can run at once without clashing.

## Daily use after this

| I want to…                     | Do                                                        |
|--------------------------------|-----------------------------------------------------------|
| Use VibeFlow                   | Nothing. Prod runs at login and updates itself.           |
| Try a branch                   | `scripts/dev.sh` in that worktree. Old Dev quits first.   |
| See which Dev branch is live   | Open the DEV menu: branch and commit in the header.       |
| Stop testing                   | "Quit VibeFlow Dev". Prod keeps running.                  |
| Ship                           | Merge, bump version, `scripts/release.sh --publish`. Prod picks it up within 6 h, or now via "Check for Updates…". |

## Order of work

1. P2 cleanup + `scripts/dev.sh` + single instance (fixes the confusion today, no release
   needed). Done 2026-10-29.
2. P3 Dev icon + build stamp. Done 2026-10-29.
3. P1 Sparkle + release.sh appcast, shipped as 1.2.0; install that DMG in /Applications once.
   Built 2026-10-29; ships when 1.2.0 is published.
4. P4 permissions row.

## Open questions

- Prod auto-installs silently (`SUAutomaticallyUpdate`) or asks first? Plan assumes silent.
- Should prod also offer a "beta" channel (pre-release tags) later? Not in this plan.
