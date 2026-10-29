# Developing VibeFlow

## Build

1. Install [Xcode 26](https://apps.apple.com/app/xcode/id497799835) and XcodeGen:
   `brew install xcodegen`.
2. Sign in to Xcode with an Apple ID (Settings > Accounts). A free personal team is enough
   for Debug builds. It gives the app a stable signature, so the Accessibility and Microphone
   permissions survive rebuilds. In `project.yml`, set `DEVELOPMENT_TEAM` to your team id and
   change `PRODUCT_BUNDLE_IDENTIFIER` (for example to `com.yourname.vibeflow`), since
   `one.floo.vibeflow` belongs to the author's team.
3. Generate and build:

   ```bash
   xcodegen generate
   xcodebuild -project VibeFlow.xcodeproj -scheme VibeFlow -configuration Debug -derivedDataPath build/DerivedData build
   open "build/DerivedData/Build/Products/Debug/VibeFlow Dev.app"
   ```

4. Grant Accessibility when asked, and Microphone on the first dictation, then add your keys
   in Settings > Keys.

The Debug build is **VibeFlow Dev**, a separate app from the release, so both can run at once:
its own bundle id, settings and permissions, a DEV tag in the menu bar, and Control added to
every default shortcut (Control + Option + . reads, and so on). API keys are shared with the
release; the Google sign-in for Meetings is not, so each app signs in on its own.

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

To build a release locally:

```bash
scripts/release.sh
```

It archives the Release configuration (bundle id `one.floo.vibeflow`), exports it with
Developer ID (`scripts/ExportOptions.plist`), notarizes and staples the app, packs it into a
DMG with an Applications shortcut, notarizes and staples the DMG as well, and finishes with a
Gatekeeper check (`spctl`). The result is `build/release/VibeFlow-<version>.dmg`.
`--no-notarize` stops after the signed export, which needs no credentials.

To publish:

1. Bump `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in `project.yml`.
2. Add a `## <version>` section to `CHANGELOG.md`.
3. Merge to main, then on a clean, pushed main run `scripts/release.sh --publish`.

It refuses to run anywhere else, tags `v<version>` and creates the GitHub release with the
changelog section as notes and the DMG as `VibeFlow.dmg`, so the README download link always
points at the newest version. Forks: change `teamID` in `scripts/ExportOptions.plist` and the
team id in the commands above to yours.

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
- `upcoming-meetings.md`: meetings in the menu bar (Google Calendar)
