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
   in Settings > Keys. If a Keychain dialog asks for the keys the release saved, click Always
   Allow: VibeFlow Dev waits for that answer before its menu bar icon appears.

The Debug build is **VibeFlow Dev**, a separate app from the release, so both can run at once:
its own bundle id, settings and permissions, a DEV tag in the menu bar, and Control added to
every default shortcut (Control + Option + . reads, and so on). API keys are shared with the
release.

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

To build a release locally:

```bash
scripts/release.sh
```

It archives the Release configuration (bundle id `one.floo.vibeflow`), exports it with
Developer ID (`scripts/ExportOptions.plist`), notarizes and staples the app, packs it into a
DMG with an Applications shortcut, notarizes and staples the DMG as well, and finishes with a
Gatekeeper check (`spctl`). The result is `build/release/VibeFlow-<version>.dmg`. The
exported app is deleted at the end, since the DMG is the release and a second copy of
VibeFlow could answer to its bundle id; the archive stays for its dSYMs.
`--no-notarize` stops after the signed export, which needs no credentials.

To publish:

1. Bump `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in `project.yml`.
2. Add a `## <version>` section to `CHANGELOG.md`.
3. Merge to main, then on a clean, pushed main run `scripts/release.sh --publish`.

It refuses to run anywhere else, tags `v<version>` and creates the GitHub release with the
changelog section as notes and the DMG as `VibeFlow.dmg`, so the README download link always
points at the newest version. Forks: change `teamID` in `scripts/ExportOptions.plist` and the
team id in the commands above to yours.

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
