# Selector-mode plumbing for `select` — third sub-PR of "expand `browser-do --verb` whitelist beyond `[click]`"

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans.

**Goal:** Add `--selector CSS` path to `browser-select.sh`. Mirrors selector-mode-fill (PR #99) and selector-mode-hover (PR #101). **PIVOT FROM PRESS:** survey discovered press has no target arg (chrome-devtools-mcp bridge designed stateless: "acts on focused element"); cache-dispatch model requires bridge IPC schema bump for press, deferring it as its own decision (could ship `--focus-selector` flag separately or skip press from cache scope entirely).

**Branch:** `selector-mode-select`
**Tag:** `v0.54.0-selector-mode-select`

---

## Locked decisions

- **SS1 — Mirror selector-mode-fill (PR #99) + selector-mode-hover (PR #101) decisions exactly.** Mutually-exclusive `--ref|--selector`; whitelist append; routing unchanged. Mechanical pattern-match.
- **SS2 — Adapter coverage = chrome-devtools-mcp only.** Other adapters (playwright-cli, playwright-lib, obscura) don't define `tool_select`. `lib/router.sh::rule_select_default` routes select exclusively to chrome-devtools-mcp.
- **SS3 — Bridge unchanged.** chrome-devtools-mcp's `_drive select "${target}" ${mode_flag} ${mode_val}` shells the target string to the bridge; same handling expected as click/fill/hover.
- **SS4 — Mode flags (`--value`/`--label`/`--index`) unchanged.** Selector-mode select still requires exactly one of the three mode flags (mutual-exclusion + at-least-one preserved). Same option-picking semantics; only the target axis gains a new flag.
- **SS5 — Press deferred (PIVOT documentation).** Survey found `tool_press` accepts only `--key`; bridge's `case 'press':` (chrome-devtools-bridge.mjs:488) takes only `key`, no target. Comment at line 1098: "Stateless w.r.t. refMap — acts on the focused element or page." Adding selector-targeting requires a new "focus then press" semantic at the bridge level — bigger surface than the per-verb mechanical pattern. **Defer press to a separate decision** (`--focus-selector` flag or bridge IPC schema bump or skip from cache scope entirely). HANDOFF documents the deferral.

## Surface

```
bash scripts/browser-select.sh \
  [--site NAME] [--tool NAME] [--dry-run] [--raw] \
  (--ref eN | --selector CSS) \
  (--value V | --label L | --index N)
```

- `--ref eN` — existing snapshot-relative ref (Phase 11-uncacheable).
- `--selector CSS` — NEW. CSS selector string. Cacheable; what `browser-do --verb select` will dispatch.
- `--value` / `--label` / `--index` — option-picking modes, unchanged. Exactly one required.

## Implementation strategy

### `scripts/browser-select.sh`

Mirror `scripts/browser-fill.sh`'s `--ref` / `--selector` parsing block. Validation:
- `--ref` AND `--selector` both given → `EXIT_USAGE_ERROR` "mutually exclusive".
- Neither given → `EXIT_USAGE_ERROR` "select requires --ref eN or --selector CSS".
- Mode-flag rules unchanged: exactly one of `--value`/`--label`/`--index`.

### `scripts/lib/tool/chrome-devtools-mcp.sh::tool_select`

Change `--ref) ref="$2"; shift 2 ;;` to `--ref|--selector) ref="$2"; shift 2 ;;`. Mirrors `tool_click` + `tool_fill` + `tool_hover` patterns.

### `scripts/browser-do.sh`

Whitelist update:
```bash
readonly DO_VERB_WHITELIST=(click fill hover select)
```

Note: `press` skipped (SS5).

## Test cases (RED → GREEN)

`tests/browser-select.bats` (gains 3 cases):

1. `--dry-run --selector 'select.country' --value US` → summary carries selector + value.
2. `--selector X --ref e1 --value y` → mutually-exclusive `EXIT_USAGE_ERROR`.
3. Neither `--selector` nor `--ref` (with `--value foo`) → `EXIT_USAGE_ERROR` "requires --ref eN or --selector CSS".

`tests/browser-do.bats` (gains 1 case): `--verb select --intent "pick country"` cache hit dispatches stub-select with `--selector $cached -- --value US`.

## Sub-scope (what this PR does NOT do)

- **No additional adapter coverage** (SS2; only chrome-devtools-mcp defines `tool_select`).
- **No press selector-mode plumbing** (SS5; deferred — needs bridge schema bump).
- **No mode-flag changes** (SS4; `--value`/`--label`/`--index` semantics unchanged).
- **No new privacy canary** — select doesn't ingest secrets; no AP-7 surface.
- **No route-rule changes**.

## Acceptance

- `tests/browser-select.bats` + 3 new cases all green.
- `tests/browser-do.bats` 34 → 35 cases all green.
- Full bats green; lint exit 0.
- `bash scripts/browser-do.sh --verb select --intent "pick country" --pattern '/checkout' --site app -- --value US` works end-to-end via dispatcher mock (with seeded cache).
- CHANGELOG `[Unreleased]` `[feat]` block + plan-doc reference.

## Notes for follow-ups

- **Press selector-mode (deferred per SS5):** decide between (a) new `--focus-selector` flag on press that focuses an element before pressing the key (bridge schema bump), (b) keep press out of cache scope entirely (document in cache-write-security recipe), or (c) compose: agent calls `browser-do --verb click --intent "focus input"` followed by `browser-press --key Enter` (no cache for press itself; relies on existing focus state). Option (c) is closest to "no-op for cache" — recommend.
- **playwright-lib driver `--selector` plumbing** — independent PR; coordinate fill + click together.
- **3/4 selector-mode-plumbing per-verb sub-PRs** done after this lands. fill (PR #99), hover (PR #101), select (this PR). Press = formally skipped per SS5.
