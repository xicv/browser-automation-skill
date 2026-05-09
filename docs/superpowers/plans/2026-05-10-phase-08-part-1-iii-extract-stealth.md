# Phase 8 part 1-iii — `tool_extract --stealth` real-mode (single-URL via `obscura fetch`)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans.

**Goal:** Second real verb backend on the obscura adapter (after `--scrape` in 8-1-ii). Wraps `obscura fetch <url> --stealth --eval EXPR`. Single-URL, anti-detect mode (per-session fingerprint randomization + 3520-tracker block). Path A still — `--stealth` requires `--tool obscura`; router promotion is 8-2-i.

**Branch:** `phase-08-part-1-iii-extract-stealth`
**Tag:** `v0.40.0-phase-08-part-1-iii-extract-stealth`

---

## Upstream behavior (researched, source: `crates/obscura-cli/src/main.rs::run_fetch`)

```rust
if let Some(ref expr) = eval {
    let result = page.evaluate(expr);
    match result {
        serde_json::Value::String(s) => println!("{}", s),     // unquoted
        serde_json::Value::Null      => println!("null"),
        other                         => println!("{}", other), // JSON-encoded
    }
    return Ok(());
}
```

Critical divergence from `obscura scrape`:
- Single URL (positional, no Vec).
- No aggregate JSON wrapper. Just the raw evaluated result on stdout.
- String → unquoted (cannot distinguish from raw bytes).
- Null/Number/Array/Object → JSON-encoded.
- No `time_ms` reported. Adapter must time the call itself.
- No `title` reported (would require a separate eval-call; out of scope here).

## Adapter contract

`--stealth` mode requires `--eval EXPR`. Without `--eval`, `obscura fetch` defaults to dumping HTML to stdout — too large for the streaming-event contract. Reject at the verb script if `--stealth` lands without `--eval`.

`eval` field in the event is **always emitted as a string** in 8-1-iii. Reasoning: obscura's stdout is already-stringified (string case unquotes). Disambiguating "this was a string upstream" from "this was a JSON-encoded other" requires heuristic parsing; deferred. Callers needing typed results should `JSON.stringify` inside their `--eval` expression and parse downstream.

## Surface

```bash
# Stealth-fetch a single URL, eval document.title, return as string:
bash scripts/browser-extract.sh --tool obscura --stealth \
  --eval "document.title" \
  https://example.com

# JSON-stringified for typed result:
bash scripts/browser-extract.sh --tool obscura --stealth \
  --eval "JSON.stringify({title: document.title, h1: document.querySelector('h1').textContent})" \
  https://example.com
```

## Skill output contract

Single streaming event:

```json
{"event":"extract_stealth","url":"https://example.com","eval":"Example Domain","time_ms":420}
```

Summary line (emitted by `browser-extract.sh`):

```json
{"verb":"extract","tool":"obscura","why":"user-specified","status":"ok","mode":"stealth","url":"https://example.com","duration_ms":425}
```

Status semantics:
- obscura exit 0 + non-empty stdout → `ok`
- obscura exit 0 + empty stdout → `empty`
- obscura exit ≠ 0 → `error`

## API additions

### `scripts/lib/tool/obscura.sh::tool_extract` (extend, don't rewrite)

```bash
# New mode branch alongside the existing --scrape mode:
#   --stealth  → single URL + --eval EXPR; build:
#                obscura fetch <url> --stealth --eval EXPR
#                Time the call. Emit one extract_stealth event.
# Mode mutual exclusion:
#   --scrape + --stealth → return 41 (USAGE — modes are mutually exclusive).
# Empty URL list with --stealth → return 2 (USAGE_ERROR).
# Missing --eval with --stealth → return 2 (USAGE_ERROR).
```

### `scripts/browser-extract.sh`

```bash
# New flag: --stealth (boolean). When set:
#   - Skips the require-selector-or-eval check (similar to --scrape).
#   - Requires --eval EXPR (rejected if missing).
#   - Requires exactly 1 positional URL (rejected on 0 or ≥2).
#   - Mutually exclusive with --scrape.
#   - Routes to obscura via existing pick_tool path (Path A — user MUST pass
#     --tool obscura; rule promotion is 8-2-i).
#   - Summary line emits mode=stealth + url=<URL>.
```

## Test cases (RED → GREEN)

`tests/obscura_adapter.bats` (extend the 24-case file):

25. `tool_extract --stealth --eval EXPR https://example.com` → emits 1 `extract_stealth` event with `url`, `eval`, `time_ms`.
26. `tool_extract --stealth` without URL → returns 2 (USAGE_ERROR).
27. `tool_extract --stealth` without `--eval` → returns 2 (USAGE_ERROR).
28. `tool_extract --scrape --stealth ...` → returns 41 (mutually-exclusive modes).
29. `tool_extract --stealth` argv shape (via STUB_LOG_FILE grep): `fetch <url> --stealth --eval EXPR` (in canonical order).

`tests/browser-extract.bats` (extend the 10-case file):

30. `--tool obscura --stealth --eval EXPR https://example.com` → 1 event + ok summary with `mode:stealth / url`.
31. `--stealth` without URL → EXIT_USAGE_ERROR with "--stealth requires exactly one URL".
32. `--stealth` without `--eval` → EXIT_USAGE_ERROR with "--stealth requires --eval".
33. `--stealth --dry-run` → plan with `mode:stealth / url:... / dry_run:true`; skips adapter.

## Sub-scope (what 8-1-iii does NOT do)

- **No router promotion.** `--stealth` doesn't auto-route to obscura yet; user must pass `--tool obscura`. Promotion is 8-2-i (Path B).
- **No typed-eval parsing.** `eval` field always a string in this PR. Heuristic JSON-parse deferred.
- **No `--site` support for `--stealth`.** Same constraint as `--scrape`: stealth fetches don't apply per-URL session storageState.
- **No `obscura fetch --dump html|text|links` modes.** Only `--eval`-based extraction supported. Dump modes deferred.
- **No multi-URL stealth.** Stealth via `obscura scrape` (multi-URL stealth) NOT exposed in this PR — `obscura scrape` doesn't accept `--stealth` upstream (scrape uses worker subprocesses; stealth is a serve/fetch flag). Document the limitation.

## Acceptance

- `tests/obscura_adapter.bats` extended with 5 new cases (24 → 29); all green.
- `tests/browser-extract.bats` extended with 4 new cases (10 → 14); all green.
- `bash tests/lint.sh` exit 0 (all three tiers).
- `bash scripts/browser-doctor.sh` enumerates 4 adapters (unchanged).
- `bash scripts/browser-extract.sh --tool obscura --stealth --eval "1+1" https://example.com` reaches the obscura adapter (with stub) and emits one `extract_stealth` event + ok summary.
- CHANGELOG `[Unreleased]` `[adapter]` + `[feat]` tags.
- Cheatsheet (`references/obscura-cheatsheet.md`) updated to reflect `--stealth` is now real-mode.

## Notes for follow-ups

- **8-2-i: router promotion** — adds `rule_scrape_flag` + `rule_stealth_flag` to `ROUTING_RULES`. Drops the `--tool obscura` friction. Tiny PR.
- **Typed-eval heuristic** — try jq-parse the obscura stdout; if it succeeds use the parsed value; else wrap as string. Deferred until users surface a need.
- **Multi-URL stealth** — would require either upstream support in `obscura scrape --stealth` OR adapter-side fan-out via N parallel `obscura fetch --stealth` calls. Both are non-trivial; deferred.
