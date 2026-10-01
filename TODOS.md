# TODOS

## Speech

### Chunking for selections over 40,000 characters

**What:** Reintroduce a TextChunker with previous_text/next_text continuity so selections above the Flash v2.5 limit can be read, including chunk-aware resume and prefetch failure rules.

**Why:** v1 refuses anything over 40,000 characters (about 25 minutes of audio). Long PDFs and transcripts exceed it.

**Context:** Cut in the 2026-10-01 eng review (D1) because the default 10,000 cap never reaches the chunker. The drafted design lives in the git history of docs/designs/outflow-v1.md (Chunking section) and in reviewer concerns R3-1 and R3-2 at the end of that doc. Needs the (sessionID, attempt) guard from D11 so a failed prefetch cannot leak audio. Start by counting "Selection too long" refusals above 40k to see if anyone hits it.

**Effort:** M
**Priority:** P3
**Depends on:** v1 shipped and in daily use; evidence of >40k selections being attempted.

## Interaction

### Conversational mode: talk with an AI through Outflow and Flow

**Status:** designed 2026-10-01 in docs/designs/outflow-2-dictation-conversation.md (dictation plus conversation in one app).

**What:** A flowing back-and-forth where Outflow speaks an AI reply, you answer by voice (Wispr Flow) or by selecting text, and the conversation keeps context across turns: follow-up questions about what was just read, "more detail", "read the original", "what should I reply".

**Why:** Florian after the first working build (2026-10-01): "a more communicative and flowy way of interacting with an AI using this software". Smart read is one-shot; this makes Outflow the voice of an assistant rather than a reader.

**Context:** Builds on the smart read pipeline (AnthropicClient, guarded prompts) and the Codex "depth dial" idea in docs/designs/outflow-v1.md. Open questions to settle in /office-hours: where the conversation state lives, how a turn starts (hotkey, hold-to-talk, auto after Flow dictation), how to interrupt mid-answer, and whether Flow can be detected or the mic is read directly. Start with a design session, not code.

**Effort:** L
**Priority:** P2
**Depends on:** v1 shipped; one week of daily use of smart read.

### Reply drafting loop

**What:** Hear an email, say what you want to answer, hear the draft read back, say "change X" or "use it", and the draft is pasted into the reply.

**Why:** Florian, 2026-10-01: wanted later, low priority. Builds on dictation and conversation.

**Context:** See docs/designs/outflow-2-dictation-conversation.md premise 6. Needs TextInserter from Outflow 2 milestone 1 and the conversation turn list from milestone 2.

**Effort:** M
**Priority:** P3
**Depends on:** Outflow 2 milestones 1 and 2.

## Completed
