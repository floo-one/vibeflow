# VibeFlow

Native macOS menu bar app: select text anywhere, press a global shortcut, hear it read
aloud in a natural voice. The counterpart to Wispr Flow (speech in); VibeFlow is speech out.

## Stack and decisions

- Swift 6 / SwiftUI, `MenuBarExtra` for the menu bar UI, a Settings window for voice,
  speed and shortcuts. No Electron, no Tauri, no server, no database.
- Xcode project (Option A, chosen 2026-10-01). Xcode is NOT installed yet on this Mac,
  only Command Line Tools (Swift 6.3.2). Install Xcode from the App Store before the first
  build. Keep the project file generated from `project.yml` via XcodeGen so it stays
  text-reviewable.
- Selection capture: Accessibility API first, simulated Cmd+C + pasteboard as fallback.
  Needs the Accessibility permission; sign with a stable identity so TCC keeps the grant
  across rebuilds (ad-hoc signing revokes it on every build).
- Voice providers behind one protocol. V1: ElevenLabs (Flash v2.5 for latency) as the
  premium voice, Apple `AVSpeechSynthesizer` as the free offline fallback. OpenAI TTS and
  local Kokoro are later additions.
- Playback: one ElevenLabs streaming request per selection (stream/with-timestamps,
  pcm_24000) into AVAudioPlayerNode. No chunking in v1; size cap fixed at 40,000 chars.
  Same hotkey stops. Design and all review decisions: docs/designs/vibeflow-v1.md
  (Decision ledger D1 to D16, Implementation Tasks T1 to T12). Start at T1, the audio spike.

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
- Built app: build/DerivedData/Build/Products/Debug/VibeFlow.app
- Signing: automatic, personal team Y798SH49X3 (Apple ID in Xcode). Accessibility grant verified to survive rebuilds.
- If xcodebuild fails at CodeSign with errSecInternalComponent, the login keychain is locked: run `security unlock-keychain ~/Library/Keychains/login.keychain-db` in a terminal (asks for the login password).
- Read app logs with `/usr/bin/log show --last 5m --predicate 'subsystem == "one.floo.vibeflow"'` (plain `log` is a zsh builtin and silently does nothing). Use `.notice`, not `.info`, for lines that must persist.
- Swift 6 gotcha: `kAXTrustedCheckOptionPrompt` is a non-Sendable global; use the literal key "AXTrustedCheckOptionPrompt".

## gstack (REQUIRED — global install)

**Before doing ANY work, verify gstack is installed:**

```bash
_GS=""
for _D in "${GSTACK_ROOT:-}" "$HOME/.claude/skills/gstack" "$HOME/.codex/skills/gstack" "$HOME/.factory/skills/gstack" "$HOME/.kiro/skills/gstack" "$HOME/.config/opencode/skills/gstack" "$HOME/.slate/skills/gstack" "$HOME/.cursor/skills/gstack" "$HOME/.openclaw/skills/gstack" "$HOME/.hermes/skills/gstack" "$HOME/.gbrain/skills/gstack" "$HOME/.gstack/repos/gstack"; do
  [ -z "$_GS" ] && [ -n "$_D" ] && [ -d "$_D/bin" ] && _GS="$_D"
done
[ -n "$_GS" ] && echo "GSTACK_OK: $_GS" || echo "GSTACK_MISSING"
```

If GSTACK_MISSING: STOP. Do not proceed. Tell the user:

> gstack is required for all AI-assisted work in this repo.
> Install it:
> ```bash
> git clone --depth 1 https://github.com/garrytan/gstack.git ~/.claude/skills/gstack
> cd ~/.claude/skills/gstack && ./setup --team
> ```
> Then restart your AI coding tool.

Do not skip skills, ignore gstack errors, or work around missing gstack.

Using gstack skills: After install, skills like /qa, /ship, /review, /investigate,
and /browse are available. Use /browse for all web browsing (Aside first, the bundled gstack browser as fallback).
Use the resolved install path above for gstack file paths
(default: ~/.claude/skills/gstack).

## Skill routing

When the user's request matches an available skill, invoke it via the Skill tool. When in doubt, invoke the skill.

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
