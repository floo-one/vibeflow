# Prompt evals

A local harness for tuning the smart read prompts. It sends real selections through the brief
exactly as the app does (same prompt, model, language detection and max tokens) and prints how
long each answer is and how it starts, so a prompt change can be judged on the same set.

```bash
cd MaagicalCore && swift run vf-eval --label baseline
```

The key comes from `ANTHROPIC_API_KEY`, else from VibeFlow's Keychain item (macOS asks once).

Options: `--label name` names the run, `--only text` runs the fixtures whose name contains it,
`--repeat n` runs each fixture n times (the model is not deterministic), `--model id` tries
another model, `--fixtures dir` reads fixtures from elsewhere, `--prompts dev` or `--prompts prod`
uses the prompt edits saved in VibeFlow Dev or the release (Settings > Prompts)
instead of the built-in defaults. The harness covers the brief only.

## Fixtures

`evals/local/` is gitignored: fixtures are real selections (emails, names, client work) and
never leave this Mac. One `.txt` per fixture, a small header, `---`, then the selected text:

```text
situation: ai-reply
ai-reply: true
must: retry | 3 attempts
---
The selected text…
```

- `situation`: a label for the table (message, ai-reply, error, decide, article, other).
- `ai-reply`: true when the text was copied from an AI assistant app, as the app would detect.
- `must`: phrases the answer has to contain, separated by `|`, matched case-insensitively.
  Missing ones show in the table.

## Runs

Each run writes `evals/local/runs/<date>-<label>.json` and `.md` (the full answers). The table
compares word counts with the previous run, so the loop is: edit `SmartReadPrompts.swift`, run
with a new label, compare, read the `.md` for the answers that changed.
