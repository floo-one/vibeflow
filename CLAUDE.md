# VibeFlow

Native macOS menu bar app: select text anywhere, press a global shortcut, hear it read
aloud in a natural voice. v1 (shipped locally) is speech out; VibeFlow 2 adds FreeFlow-style
dictation and a conversation mode (docs/designs/vibeflow-2-dictation-conversation.md).
Default shortcuts: Option + . read, Option + , smart read (hold to ask a follow-up), Shift adds clipboard, Option + - push-to-talk
dictation, Shift + Option + - toggle dictation, Control + Option + V paste last dictation,
Shift + Control + Option + V paste last smart read.

## Stack and decisions

- Swift 6 / SwiftUI, `MenuBarExtra` for the menu bar UI, a Settings window for voice,
  speed and shortcuts. No Electron, no Tauri, no server, no database.
- Xcode project generated from `project.yml` via XcodeGen so it stays text-reviewable.
- Selection capture: Accessibility API first, simulated Cmd+C + pasteboard as fallback.
  Needs the Accessibility permission; sign with a stable identity so TCC keeps the grant
  across rebuilds (ad-hoc signing revokes it on every build).
- Voice providers behind one protocol. V1: ElevenLabs (Flash v2.5 for latency) as the
  premium voice, Apple `AVSpeechSynthesizer` as the free offline fallback. OpenAI TTS and
  local Kokoro are later additions.
- Playback: one ElevenLabs streaming request per selection (stream/with-timestamps,
  pcm_24000) into AVAudioPlayerNode. No chunking in v1; size cap fixed at 40,000 chars.
  Same hotkey stops. v1 design and review decisions: docs/designs/vibeflow-v1.md
  (Decision ledger D1 to D16, Implementation Tasks T1 to T12, all done).
- Performance rule: never call AVSpeechSynthesisVoice.speechVoices() or other system
  enumerations in a SwiftUI body; SystemVoiceCatalog caches them once per launch.

## Skills to use

- `swiftui-pro` (Paul Hudson) when writing or reviewing SwiftUI.
- `text-to-speech` (ElevenLabs official) for API shapes, voices and streaming details.
- gstack skills below for planning, review, QA and shipping.

## Build and verify

Xcode 26.6 installed and selected (2026-10-01). The .xcodeproj is generated and gitignored; project.yml is the source of truth.

- Regenerate the project after editing project.yml: `xcodegen generate`
- Build: `xcodebuild -project VibeFlow.xcodeproj -scheme VibeFlow -configuration Debug -derivedDataPath build/DerivedData build`
  (until a signing identity exists, append `CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM=` for an ad-hoc build)
- Core tests: `cd VibeFlowCore && swift test` (Swift Testing)
- Two apps side by side: the installed release (Release config, "VibeFlow", one.floo.vibeflow, from the GitHub DMG in /Applications) is prod; the Debug build is "VibeFlow Dev" (one.floo.vibeflow.dev): own UserDefaults and TCC grants, DEV tag in the menu bar, Control added to default shortcuts via `#if DEBUG` in Shortcuts.swift. Keychain service "one.floo.vibeflow" is shared by both.
- Built dev app: "build/DerivedData/Build/Products/Debug/VibeFlow Dev.app"
- Signing: team X7UXDLS9F7 (paid Apple Developer Program, company Apple Account in Xcode) for every configuration. Debug: automatic, Apple Development certificate. Release: manual, "Developer ID Application", hardened runtime, timestamped. Accessibility grant verified to survive rebuilds.
- Version: MARKETING_VERSION and CURRENT_PROJECT_VERSION in project.yml (Info.plist reads them).
- Release: `scripts/release.sh` archives, exports with Developer ID (`scripts/ExportOptions.plist`), notarizes and staples app and DMG, then checks with `spctl`; result in build/release/VibeFlow-<version>.dmg. `--publish` (only on a clean main equal to origin/main, tag must be new, CHANGELOG needs "## <version>") also tags v<version> and creates the GitHub release with VibeFlow.dmg. Needs the `VibeFlowNotary` notarytool keychain profile (docs/DEVELOPMENT.md "Release"). `--no-notarize` stops after the signed export. VibeFlow cannot go in the Mac App Store (Accessibility, simulated Cmd+C and global hotkeys do not work in the App Sandbox).
- If xcodebuild fails at CodeSign with errSecInternalComponent, the login keychain is locked: run `security unlock-keychain ~/Library/Keychains/login.keychain-db` in a terminal (asks for the login password).
- Read app logs with `/usr/bin/log show --last 5m --predicate 'subsystem == "one.floo.vibeflow"'` (plain `log` is a zsh builtin and silently does nothing). Use `.notice`, not `.info`, for lines that must persist.
- Swift 6 gotcha: `kAXTrustedCheckOptionPrompt` is a non-Sendable global; use the literal key "AXTrustedCheckOptionPrompt".

## gstack (optional)

The author builds VibeFlow with [gstack](https://github.com/garrytan/gstack) skills
(/office-hours, /plan-eng-review, /review, /qa, /ship, /investigate). If they are installed,
use them as routed below; if not, work normally. Nothing in this repo requires them.

## Skill routing

When gstack is installed and the user's request matches one of its skills, invoke it via the Skill tool.

Key routing rules:
- Product ideas/brainstorming → invoke /office-hours
- Strategy/scope → invoke /plan-ceo-review
- Architecture → invoke /plan-eng-review
- Design system/plan review → invoke /design-consultation or /plan-design-review
- Full review pipeline → invoke /autoplan
- Bugs/errors → invoke /investigate
- QA/testing site behavior → invoke /qa or /qa-only
- Code review/diff check → invoke /review
- Visual polish → invoke /design-review
- Ship/deploy/PR → invoke /ship or /land-and-deploy
- Save progress → invoke /context-save
- Resume context → invoke /context-restore
- Author a backlog-ready spec/issue → invoke /spec
