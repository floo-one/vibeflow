# Developing VibeFlow

## Build

1. Install [Xcode 26](https://apps.apple.com/app/xcode/id497799835) and XcodeGen:
   `brew install xcodegen`.
2. Sign in to Xcode with an Apple ID (Settings > Accounts). A free personal team is enough
   for Debug builds. It gives the app a stable signature, so the Accessibility and Microphone
   permissions survive rebuilds. In `project.yml`, set `DEVELOPMENT_TEAM` to your team id and
   change `PRODUCT_BUNDLE_IDENTIFIER` (for example to `com.yourname.vibeflow`), since
   `one.floo.vibeflow` belongs to the author's team.
3. Build and run:

   ```bash
   scripts/dev.sh
   ```

   It generates the project, builds Debug, quits the VibeFlow Dev that is running (from
   whichever worktree), installs the new build to `~/Applications/VibeFlow Dev.app` and opens
   it. One place for every build means one VibeFlow Dev to open, quit and grant permissions
   to. To only check that it compiles:

   ```bash
   xcodegen generate
   xcodebuild -project VibeFlow.xcodeproj -scheme VibeFlow -configuration Debug -derivedDataPath build/DerivedData build
   ```

4. Grant Accessibility when asked, and Microphone on the first dictation, then add your keys
   in Settings > Accounts. If a Keychain dialog asks for the keys the release saved, click Always
   Allow: VibeFlow Dev waits for that answer before its menu bar icon appears.

The Debug build is **VibeFlow Dev**, a separate app from the release, so both can run at once:
its own bundle id, settings and permissions, an orange app icon with a DEV band, a DEV tag in
the menu bar, and Control added to every default shortcut (Control + Option + . reads, and so
on). API keys are shared with the release; the Google sign-in for Meetings is not, so each
app signs in on its own. Its menu starts with the branch, commit and build
time it came from, which `scripts/dev.sh` stamps into Info.plist; a `*` after the commit
means it was built with uncommitted changes. Both app icons are drawn by
`swift scripts/make-icons.swift`.

Each app runs once: a VibeFlow that starts quits any older copy of itself, from any path
(another worktree, Xcode), so two menu bar icons never answer the same shortcut. VibeFlow and
VibeFlow Dev never quit each other.

`scripts/dev.sh --doctor` lists every VibeFlow on the Mac: the two homes
(`/Applications/VibeFlow.app` and `~/Applications/VibeFlow Dev.app`), what is running, other
copies and dead Launch Services entries. A copy with the release bundle id outside
/Applications can take over its Accessibility entry, so `scripts/dev.sh --clean` deletes the
leftover ones in this repo's build folders and makes Launch Services forget dead entries.
Worktrees on a branch from before VibeFlow Dev still build their Debug app with the release
bundle id; `--clean` leaves those alone and the doctor names them (merge main there).

An ad-hoc build (`CODE_SIGN_IDENTITY=-`, as CI does) works too, but macOS forgets its
Accessibility permission on every rebuild; remove the old entry and grant it again each time.

`project.yml` is the source of truth; the `.xcodeproj` is generated and gitignored. Run
`xcodegen generate` after editing it.

## Test

The logic lives in the `VibeFlowCore` Swift package behind small protocols (pasteboard,
accessibility, speech provider, audio player, audio recorder, transcriber, clock, smart read
client, secrets), so everything from both state machines to the paste and Copy fallbacks is
tested with in-memory fakes:

```bash
cd VibeFlowCore && swift test
```

Live goldens that call the real Anthropic API (injection resistance, brief keeps
qualifications, cleanup keeps numbers and names, AI replies spoken as the assistant) run only
on request:

```bash
VIBEFLOW_RUN_EVALS=1 ANTHROPIC_API_KEY=... swift test --filter LiveEvalTests
```

The dictation cleanup golden (a dictated question is cleaned, never answered) runs the same
way with `GROQ_API_KEY` set and `--filter CleanupEvals`.

`Spike/elevenlabs-spike.swift` measures ElevenLabs first-audio and stop latency and
`Spike/dictation-spike.swift` measures Groq transcription and cleanup on your machine; run
them with `swift Spike/<name>.swift` and keys in a local `.env`.
`Spike/google-calendar-spike.swift` signs in to Google Calendar the way the app will and
lists today's meetings with the keep/drop verdict; it reads `Config/Google.xcconfig`.

## Release

Release builds are signed with Developer ID and notarized, so a downloaded copy opens on any
Mac without the "unidentified developer" detour. This needs the paid Apple Developer Program
and a "Developer ID Application" certificate in your login keychain (Xcode > Settings >
Accounts > your team > Manage Certificates > + > Developer ID Application).

One-time setup, so `notarytool` can talk to Apple:

```bash
xcrun notarytool store-credentials VibeFlowNotary --team-id X7UXDLS9F7
```

It asks for the Apple Account email of the team and an app-specific password (create one at
account.apple.com > Sign-In and Security > App-Specific Passwords; the account password does
not work). Both go into the login keychain, nothing into the repo.

Installed copies update themselves with [Sparkle](https://sparkle-project.org): every
release is signed with a private EdDSA key, and the app checks it against its public key,
`SUPublicEDKey` in `project.yml`. The private key lives in the login keychain under the
Sparkle account `vibeflow`. Sparkle's tools appear after the first build (or
`xcodebuild -resolvePackageDependencies -project VibeFlow.xcodeproj -scheme VibeFlow -derivedDataPath build/DerivedData`):

```bash
SPARKLE=build/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin
$SPARKLE/generate_keys --account vibeflow -p                    # print the public key
$SPARKLE/generate_keys --account vibeflow -x vibeflow-sparkle.key  # export a backup
$SPARKLE/generate_keys --account vibeflow -f vibeflow-sparkle.key  # import it on a new Mac
```

Keep the exported backup in a password manager and delete the file. Without the key, no Mac
can sign an update that installed copies accept. The first release asks for Keychain access
for `sign_update`: allow it always.

To build a release locally:

```bash
scripts/release.sh
```

It archives the Release configuration (bundle id `one.floo.vibeflow`), exports it with
Developer ID (`scripts/ExportOptions.plist`), notarizes and staples the app, packs it into a
DMG with an Applications shortcut, notarizes and staples the DMG as well, and finishes with a
Gatekeeper check (`spctl`). It then signs the DMG with the Sparkle key and writes the update
feed, `build/release/appcast.xml` (`scripts/write-appcast.sh`), after checking before the
build that the key in the keychain matches `SUPublicEDKey`. The result is
`build/release/VibeFlow-<version>.dmg`. The exported app is deleted at the end, since the DMG
is the release and a second copy of VibeFlow could answer to its bundle id; the archive stays
for its dSYMs. `--no-notarize` stops after the signed export, which needs no credentials.

To publish:

1. Bump `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in `project.yml`. The build number
   must be higher than the last release's, or installed copies never see the update.
2. Add a `## <version>` section to `CHANGELOG.md`.
3. Merge to main, then on a clean, pushed main run `scripts/release.sh --publish`.

It refuses to run anywhere else or with a build number that is not higher than the last
tag's. It tags `v<version>` and creates the GitHub release with the changelog section as
notes, the DMG as `VibeFlow.dmg` and the feed as `appcast.xml`. So the README download link
always points at the newest version, and installed copies (which read
`.../releases/latest/download/appcast.xml`) find it within 6 hours. Forks: change `teamID` in
`scripts/ExportOptions.plist`, the team id in the commands above, and `SUFeedURL` and
`SUPublicEDKey` in `project.yml` to yours.

### Nightly: follow main

With Settings > General > Updates, Channel "Nightly", the installed VibeFlow updates to
every new main instead of waiting for a release. Those builds come from this Mac:

```bash
scripts/nightly.sh --install
```

That adds a LaunchAgent (`~/Library/LaunchAgents/one.floo.vibeflow.nightly.plist`) that
looks at origin/main every 30 minutes. When main moved and CI passed on it, it checks the
commit out in its own worktree (`~/Library/Caches/one.floo.vibeflow.nightly/src`) and runs
`scripts/release.sh --nightly --publish`: the same signed, notarized DMG, with build number
`<CURRENT_PROJECT_VERSION>.<commits on main>`, uploaded with its feed to the rolling `nightly`
pre-release. The Mac has to be on and logged in; it catches up after sleep. Log:
`~/Library/Logs/VibeFlow Nightly.log`.

```bash
scripts/nightly.sh --status      # LaunchAgent, last published commit, recent log
scripts/nightly.sh               # check once now
scripts/nightly.sh --retry       # again, after a failed build of the same main
scripts/nightly.sh --uninstall
```

If a nightly breaks, Settings > General > Go Back to the Release turns the switch off and
downloads the newest release's DMG; drag it to Applications. Sparkle never installs an older
build by itself.

Re-run `--install` after changing `scripts/nightly.sh`: the LaunchAgent runs an installed copy.
Each run copies the gitignored `Config/Google.xcconfig` from your checkout into its worktree,
since `--publish` refuses to build without the Google client.

## Google Calendar (Meetings)

Upcoming meetings sign in to Google with a "Desktop app" OAuth client. Its ID and secret are
built into the app (Google treats a desktop client's secret as public) but never committed:
they live in the gitignored `Config/Google.xcconfig`, which `Config/VibeFlow.xcconfig`
includes when it exists. Without it the app builds as usual and Settings > Meetings says
"Not configured in this build" (CI builds this way).

To use your own client:

1. In the [Google Cloud console](https://console.cloud.google.com/), create a project and
   enable the Google Calendar API.
2. Google Auth Platform: audience External; add the scope
   `https://www.googleapis.com/auth/calendar.readonly`; under Clients create a "Desktop app"
   client. While the app is in Testing, add each account that should sign in as a test user
   (their sign-in expires after 7 days). "Publish app" needs a homepage and a privacy policy
   link on an authorized domain; after that any account can sign in (with the unverified-app
   warning, up to 100 users until Google verifies the app).
3. `cp Config/Google.xcconfig.example Config/Google.xcconfig` and fill in
   `GOOGLE_CLIENT_ID` and `GOOGLE_CLIENT_SECRET`. Google shows the secret only once.
4. Check it before building: `swift Spike/google-calendar-spike.swift --login you@example.com`
   signs in the same way the app does and lists today's meetings with the keep/drop reason.

The author's client lives in the floo.one project `vibeflow-513107`. Release builds pick up
`Config/Google.xcconfig` from the checkout that runs `scripts/release.sh`, so copy the file
into that checkout; `--publish` refuses to run unless it sets both `GOOGLE_CLIENT_ID` and
`GOOGLE_CLIENT_SECRET` (a local build only warns).

## Clocks data

The time zone list comes from [vvo/tzdb](https://github.com/vvo/tzdb) (MIT, Copyright
CodeAgain SASU), trimmed into `VibeFlowCore/Sources/VibeFlowCore/Clock/Resources/`. Refresh
it with `python3 scripts/update-time-zones.py`.

## Design docs

Every design, review decision and task list is in `docs/designs/`:

- `vibeflow-v1.md`: reading
- `vibeflow-2-dictation-conversation.md`: dictation and conversation mode
- `smart-read-follow-up.md`: ask back
- `vibeflow-github-v1.md`: this repository and its releases
- `dev-prod-channels.md`: VibeFlow and VibeFlow Dev side by side, and updates
- `upcoming-meetings.md`: meetings in the menu bar (Google Calendar)
