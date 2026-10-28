# TODOS

## Speech

### Chunking for selections over 40,000 characters

**What:** Reintroduce a TextChunker with previous_text/next_text continuity so selections above the Flash v2.5 limit can be read, including chunk-aware resume and prefetch failure rules.

**Why:** v1 refuses anything over 40,000 characters (about 25 minutes of audio). Long PDFs and transcripts exceed it.

**Context:** Cut in the 2026-10-01 eng review (D1) because the default 10,000 cap never reaches the chunker. The drafted design lives in the git history of docs/designs/vibeflow-v1.md (Chunking section) and in reviewer concerns R3-1 and R3-2 at the end of that doc. Needs the (sessionID, attempt) guard from D11 so a failed prefetch cannot leak audio. Start by counting "Selection too long" refusals above 40k to see if anyone hits it.

**Effort:** M
**Priority:** P3
**Depends on:** v1 shipped and in daily use; evidence of >40k selections being attempted.

## Interaction

### Conversational mode: talk with an AI through VibeFlow and Flow

**Status:** designed 2026-10-01 in docs/designs/vibeflow-2-dictation-conversation.md (dictation plus conversation in one app). Milestone 1 (dictation) passed eng review 2026-10-02; milestone 2 (conversation) still needs its own eng review after a week of dictation use.

**What:** A flowing back-and-forth where VibeFlow speaks an AI reply, you answer by voice (Wispr Flow) or by selecting text, and the conversation keeps context across turns: follow-up questions about what was just read, "more detail", "read the original", "what should I reply".

**Why:** Florian after the first working build (2026-10-01): "a more communicative and flowy way of interacting with an AI using this software". Smart read is one-shot; this makes VibeFlow the voice of an assistant rather than a reader.

**Context:** Builds on the smart read pipeline (AnthropicClient, guarded prompts) and the Codex "depth dial" idea in docs/designs/vibeflow-v1.md. Open questions to settle in /office-hours: where the conversation state lives, how a turn starts (hotkey, hold-to-talk, auto after Flow dictation), how to interrupt mid-answer, and whether Flow can be detected or the mic is read directly. Start with a design session, not code.

**Effort:** L
**Priority:** P2
**Depends on:** v1 shipped; one week of daily use of smart read.

### Reply drafting loop

**What:** Hear an email, say what you want to answer, hear the draft read back, say "change X" or "use it", and the draft is pasted into the reply.

**Why:** Florian, 2026-10-01: wanted later, low priority. Builds on dictation and conversation.

**Context:** See docs/designs/vibeflow-2-dictation-conversation.md premise 6. Needs TextInserter from VibeFlow 2 milestone 1 and the conversation turn list from milestone 2.

**Effort:** M
**Priority:** P3
**Depends on:** VibeFlow 2 milestones 1 and 2.

## Clipboard

### One clipboard owner across reads, dictation and paste again

**What:** A single clipboard owner that every clipboard transaction (a read's Copy capture, a dictation paste, paste again, Copy dictated text) must hold for its whole life, including writes that land late, so no two can overlap.

**Why:** Each session guards only its own steps today. Known edges left from the menu/paste-again PR (#10): a read stopped mid-capture goes idle while its Copy can still land (~300 ms) and paste again passes its guard; Copy dictated text checks idle once but does not hold the clipboard while its write is in flight, so a paste again started then can collide. Both need a slow or hanging clipboard or a sub-second double action.

**Context:** Same family as the inherited TextInsertion issues found in that review: a clipboard write that times out keeps running and can land after the paste gave up; ClipboardSnapshot keeps plain text only, so image, file and rich-text clipboards are replaced by any paste; focus is not re-checked after the async snapshot and write right before Cmd-V; and the restore writes the user's text back as transient, so ClipboardSourceTracker loses the AI-app source and the next clipboard smart read uses the narrator voice. Start from DictationSession.pasteAgain, TextInsertion.insert, PasteboardCapture and AppContainer's readIsCapturing / dictationCancelledByRead.

**Effort:** M
**Priority:** P2
**Depends on:** None

## Completed

### Only give clipboard text the assistant voice when it was copied in the AI app

**What:** Remember NSPasteboard.changeCount while ChatGPT, Codex, Claude or Gemini is frontmost, and set aiReply for Shift + smart read only when the clipboard last changed there.

**Why:** Today Shift + smart read with an AI app in front treats any clipboard text as that assistant's reply. A phishing email copied in Mail and read with ChatGPT in front is voiced as "I'd reset your password at...". Both review models flagged it while shipping the assistant voice (2026-10-27).

**Context:** ReadSession.startClipboardRead sets session.aiReply from the frontmost app. Same pass noted: clipboard reads use the default preset, not the AI app's, and the attribution guard in SmartReadPrompts.aiReplyRule only covers links and payments a reply visibly quotes.

**Effort:** S
**Priority:** P2
**Depends on:** nothing.

**Completed:** 2026-10-28. ClipboardSourceTracker attributes each clipboard change to the app that was frontmost while NSPasteboard.changeCount moved (fed by NSWorkspace activations), and ReadSession gives Shift + smart read the assistant voice only when that app is the AI app in front. Transient pasteboard contents (VibeFlow's own restores) count as unknown.

## Distribution

### Guided onboarding for keys

**What:** A first-run window that explains the three keys, links to where to get each, and shows what already works without them (Apple voice, on-device dictation on macOS 26).

**Why:** The first users are non-technical friends who set up their own keys (office hours 2026-10-06). Today they must find Settings > Keys on their own.

**Effort:** S
**Priority:** P2

### Downloadable build: notarized DMG and Homebrew cask

**What:** Sign with a Developer ID, notarize, attach a DMG to GitHub Releases, then publish a Homebrew cask.

**Why:** Without it, only people who can build from source can run VibeFlow, and Homebrew casks now require notarized apps.

**Context:** Needs the paid Apple Developer Program ($99/year). Deferred until people beyond friends want to run it (docs/designs/vibeflow-github-v1.md).

**Effort:** M
**Priority:** P3

## Settings

### Bring back vocabulary and per-app settings

**What:** UI for the dictation vocabulary and per-app presets (voice, speed, "Keep this app on this Mac", smart read instructions). Storage and logic still exist (Preferences.vocabulary, AppPreset, AppPresetStore).

**Why:** Removed from Settings on 2026-10-06 to keep it minimal; wanted long term.

**Effort:** S
**Priority:** P3

