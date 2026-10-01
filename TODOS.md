# TODOS

## Speech

### Chunking for selections over 40,000 characters

**What:** Reintroduce a TextChunker with previous_text/next_text continuity so selections above the Flash v2.5 limit can be read, including chunk-aware resume and prefetch failure rules.

**Why:** v1 refuses anything over 40,000 characters (about 25 minutes of audio). Long PDFs and transcripts exceed it.

**Context:** Cut in the 2026-10-01 eng review (D1) because the default 10,000 cap never reaches the chunker. The drafted design lives in the git history of docs/designs/outflow-v1.md (Chunking section) and in reviewer concerns R3-1 and R3-2 at the end of that doc. Needs the (sessionID, attempt) guard from D11 so a failed prefetch cannot leak audio. Start by counting "Selection too long" refusals above 40k to see if anyone hits it.

**Effort:** M
**Priority:** P3
**Depends on:** v1 shipped and in daily use; evidence of >40k selections being attempted.

## Completed
