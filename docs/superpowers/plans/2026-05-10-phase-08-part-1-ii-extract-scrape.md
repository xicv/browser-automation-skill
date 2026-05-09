# Phase 8 part 1-ii — `tool_extract --scrape` real-mode (obscura backend)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans.

**Goal:** First real verb backend on the obscura adapter. Wraps `obscura scrape u1 u2 ... --eval EXPR --format json`. Per-URL streaming JSON event + summary. Path A still — `--tool obscura` only; router promotion deferred to 8-2-i.

**Branch:** `phase-08-part-1-ii-extract-scrape`
**Tag:** `v0.39.0-phase-08-part-1-ii-extract-scrape`

---

## Upstream JSON shape (researched, source: `crates/obscura-cli/src/main.rs::run_parallel_scrape`)

```json
{
  "total_urls": 3,
  "concurrency": 10,
  "total_time_ms": 1842,
  "avg_time_ms": 614.0,
  "results": [
    {"url": "https://a.com", "title": "A", "eval": "...", "time_ms": 350, "worker": 0},
    {"url": "https://b.com", "title": "B", "eval": null, "time_ms": 400, "worker": 1},
    {"url": "https://c.com", "error": "navigate failed", "time_ms": 100}
  ]
}
```

- `serde_json::to_string_pretty` → multi-line JSON to stdout.
- Progress (`Scraping N URLs with C concurrent workers...`) emitted to stderr.
- Per-result divergence: success has `title`/`eval`/`worker`; error has `error` field, no `title`/`eval`/`worker`.
- `eval` field is `serde_json::Value` — string / number / array / null / object. Adapter parser must not assume string.

## Skill output contract (what `tool_extract --scrape` emits to stdout)

Streaming events (one JSON line per URL):

```json
{"event":"scrape_url","url":"https://a.com","title":"A","time_ms":350,"eval":"..."}
{"event":"scrape_url","url":"https://b.com","title":"B","time_ms":400,"eval":null}
{"event":"scrape_url","url":"https://c.com","error":"navigate failed","time_ms":100}
```

Summary line (emitted by `browser-extract.sh`, not the adapter):

```json
{"verb":"extract","tool":"obscura","why":"user-specified","status":"partial","total_urls":3,"successful":2,"failed":1,"total_time_ms":1842,"duration_ms":1850}
```

Status semantics:
- All URLs OK → `ok`
- Some URLs OK + some failed → `partial`
- All URLs failed → `error`
- Zero URLs → `empty` (caller passes `--scrape` but no URLs → caught earlier as USAGE_ERROR)

## Surface

```bash
# Scrape 3 URLs, eval document title on each, end-to-end via obscura adapter:
bash scripts/browser-extract.sh --tool obscura --scrape \
  --eval "document.title" \
  https://example.com https://example.org https://example.net

# Scrape without --eval (returns title + time only):
bash scripts/browser-extract.sh --tool obscura --scrape \
  https://example.com https://example.org

# Concurrency override (default 10 from obscura):
bash scripts/browser-extract.sh --tool obscura --scrape --concurrency 25 \
  --eval "document.title" url1 url2 ... url25
```

`--scrape` is a boolean flag that switches mode. URLs are positional after `--scrape` (consumed up to next `--flag`). `--eval EXPR` and `--concurrency N` optional.

## API additions

### `scripts/lib/tool/obscura.sh::tool_extract`

```bash
# Parses: --scrape (required for this PR), --eval EXPR (optional),
#         --concurrency N (optional), positional URLs.
# Builds:  obscura scrape u1 u2 ... [--eval EXPR] --concurrency N --format json
# Runs:    captures stdout (the pretty-printed JSON dump).
# Parses:  jq over .results[]; emits one event per URL.
# Returns: 0 if any URL succeeded; 11 (EMPTY_RESULT) if all failed.
#          (Tier-1 status mapping; verb-script normalizes to ok/partial/error.)
# Stub: in 8-1-i shipped --version-only stub at tests/stubs/obscura;
#       this PR upgrades it to fixture-based (sha256 argv → tests/fixtures/obscura/<sha>.json),
#       preserving --version short-circuit for doctor + install tests.
```

### `scripts/browser-extract.sh`

```bash
# New flag: --scrape (boolean). When set:
#   - Skips the "require --selector or --eval" check.
#   - Collects positional URLs from REMAINING_ARGV after flag stripping.
#   - Validates ≥1 URL; otherwise EXIT_USAGE_ERROR.
#   - Routes to obscura via existing pick_tool path (NOT yet via router rule —
#     user MUST pass `--tool obscura` in 8-1-ii; rule promotion is 8-2-i).
#   - Aggregates per-URL events into total_urls / successful / failed counts
#     for the summary line.
```

## Test cases (RED → GREEN)

`tests/obscura_adapter.bats` (extend the existing 18-case file):

19. `tool_extract --scrape` with 3 URLs + `--eval` → emits 3 `scrape_url` events; jq shape OK.
20. `tool_extract --scrape` with mixed results (2 ok + 1 error) → emits 3 events, error event has `.error` field.
21. `tool_extract --scrape` with 0 URLs → returns 2 (USAGE_ERROR).
22. `tool_extract --scrape` shells to `obscura scrape u1 u2 --format json` (argv shape via STUB_LOG_FILE grep).
23. `tool_extract --scrape` without `--scrape` flag (just selector/eval) → returns 41 (other modes deferred to 8-1-iii).
24. **Privacy canary:** URL with sensitive token (`?api_key=CANARY-1-ii`) appears in event AS PROVIDED (URL is user-supplied input, not sanitized — but verify it doesn't leak elsewhere unexpectedly). Per parent spec §8.3, URLs in scrape mode are caller-controlled; sanitization is the user's responsibility for `--scrape` URLs (different from inspect-mode network HAR which we DO sanitize).

`tests/stubs/obscura` upgrade tests — verify backwards compat:

25. Stub still responds to `--version` (existing doctor + install tests stay green).

`tests/browser-extract.bats` — new file or extension:

26. `--tool obscura --scrape u1 u2 --eval EXPR` → reaches obscura adapter; emits 2 events + summary.
27. `--scrape` without URLs → EXIT_USAGE_ERROR.
28. `--scrape` without `--tool obscura` → router falls through to default (chrome-devtools-mcp) which doesn't support `--scrape` → falls back per capability filter; eventually EXIT_TOOL_MISSING. Acceptance: documents the Path A constraint until 8-2-i lands.

Drift / lint: `tool_capabilities.verbs.extract.flags` already lists `--scrape` advisorily — no schema bump.

## Sub-scope (what 8-1-ii does NOT do)

- **No `--stealth` mode.** That's 8-1-iii (wraps `obscura fetch <url> --stealth --eval`).
- **No router promotion.** `--scrape` doesn't auto-route to obscura yet; user must pass `--tool obscura`. Promotion is 8-2-i.
- **No `--selector` support for `--scrape`.** Obscura's scrape command takes `--eval` only. Combining `--selector` + `--scrape` is rejected at the verb-script layer.
- **No `--site` support for `--scrape`.** Scrape mode doesn't apply per-URL session storageState; would need per-URL site mapping (out of scope; deferred indefinitely).
- **No retention/capture-write integration.** Phase 7 capture pipeline composes with `inspect`; combining with `extract --scrape` is a Phase 8+ follow-up.

## Acceptance

- `tests/obscura_adapter.bats` extended with 8-1-ii cases (~7 new); all green.
- `tests/browser-extract.bats` extended (~3 cases); all green.
- `bash tests/lint.sh` exit 0 (all three tiers).
- `bash scripts/browser-doctor.sh` enumerates 4 adapters (unchanged from 8-1-i).
- `bash scripts/browser-extract.sh --tool obscura --scrape --eval "1+1" https://example.com` reaches the obscura adapter (with stub) and emits one `scrape_url` event + summary.
- CHANGELOG `[Unreleased]` `[adapter]` + `[feat]` tags.

## Notes for follow-ups

- **8-1-iii: `tool_extract --stealth` real-mode** — wraps `obscura fetch <url> --stealth --eval EXPR`. Single-URL, anti-detection mode. Adds `--stealth` flag plumbing.
- **8-2-i: router promotion** — adds `rule_scrape_flag` + `rule_stealth_flag` to `ROUTING_RULES`; obscura becomes the default when `--scrape` / `--stealth` is set.
- **`--site` support** — not currently feasible; obscura's scrape mode doesn't support per-URL session apply. Document the limitation.
