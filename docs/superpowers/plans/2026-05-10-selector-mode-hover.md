# Selector-mode plumbing for `hover` — second sub-PR of "expand `browser-do --verb` whitelist beyond `[click]`"

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans.

**Goal:** Add `--selector CSS` path to `browser-hover.sh`. Mirrors selector-mode-fill (PR #99) precisely. Smaller scope than fill — only one adapter (`chrome-devtools-mcp`) defines `tool_hover` (per `lib/router.sh::rule_hover_default`: "only cdt-mcp declares hover today").

**Branch:** `selector-mode-hover`
**Tag:** `v0.53.0-selector-mode-hover`

---

## Locked decisions

- **H1 — Mirror selector-mode-fill (PR #99) decisions exactly.** S1 → mutually-exclusive `--ref|--selector`; S3 → whitelist append; S5 → routing unchanged. Mechanical pattern-match on the existing precedent.
- **H2 — Adapter coverage = chrome-devtools-mcp only.** Other adapters don't define `tool_hover` (verified: playwright-cli, playwright-lib, obscura all lack it). `lib/router.sh::rule_hover_default` routes hover exclusively to chrome-devtools-mcp. So this PR touches one adapter, not two like selector-mode-fill.
- **H3 — Bridge unchanged.** chrome-devtools-mcp's `_drive hover "${target}"` shells the target string to the bridge node script. Bridge already accepts target strings for click (PR #99 didn't require bridge changes); same handling expected for hover. If bridge interpretation differs (e.g. requires a uid not a CSS selector), that surfaces in testing — handle then.

## Surface

```
bash scripts/browser-hover.sh \
  [--site NAME] [--tool NAME] [--dry-run] [--raw] \
  (--ref eN | --selector CSS)
```

- `--ref eN` — existing snapshot-relative ref (Phase 11-uncacheable).
- `--selector CSS` — NEW. CSS selector string. Cacheable; what `browser-do --verb hover` will dispatch.

## Implementation strategy

### `scripts/browser-hover.sh`

Mirror `scripts/browser-fill.sh`'s `--ref` / `--selector` parsing block (which itself mirrored `browser-click.sh`). Validation:
- `--ref` AND `--selector` both given → `EXIT_USAGE_ERROR` "mutually exclusive".
- Neither given → `EXIT_USAGE_ERROR` "hover requires --ref eN or --selector CSS".

Header doc-comment line 8 currently says "`--selector` path is a follow-up sub-part if user demand surfaces" — convenient self-prediction; remove that line + replace with the new flag form.

### `scripts/lib/tool/chrome-devtools-mcp.sh::tool_hover`

Change `--ref) ref="$2"; shift 2 ;;` to `--ref|--selector) ref="$2"; shift 2 ;;`. Mirrors `tool_click` line 142 and `tool_fill` (just shipped in PR #99).

### `scripts/browser-do.sh`

Whitelist update:
```bash
readonly DO_VERB_WHITELIST=(click fill hover)
```

## Test cases (RED → GREEN)

`tests/browser-hover.bats` (gains 3 cases):

1. `--selector 'button.action'` → adapter receives `button.action` as target.
2. `--selector X --ref e1` → mutually-exclusive `EXIT_USAGE_ERROR`.
3. Neither `--selector` nor `--ref` → `EXIT_USAGE_ERROR` "requires --ref eN or --selector CSS".

`tests/browser-do.bats` (gains 1 case): `--verb hover --intent "hover button"` cache hit dispatches stub-hover with `--selector $cached`.

## Sub-scope (what this PR does NOT do)

- **No additional adapter coverage** (H2; only chrome-devtools-mcp defines `tool_hover` — other adapters' addition is a separate follow-up if hover routing ever expands).
- **No press/select selector-mode plumbing** — separate sub-PRs of the same parent task.
- **No new privacy canary** — hover doesn't ingest secrets; no AP-7 surface.
- **No route-rule changes** — routing picks adapter same as before; flag parsing happens after pick.

## Acceptance

- `tests/browser-hover.bats` + 3 new cases all green.
- `tests/browser-do.bats` 33 → 34 cases all green.
- Full bats green; lint exit 0.
- `bash scripts/browser-do.sh --verb hover --intent "hover button" --pattern '/page' --site app` works end-to-end against stub-hover (with seeded cache).
- CHANGELOG `[Unreleased]` `[feat]` block + plan-doc reference.

## Notes for follow-ups

- **selector-mode-press** — same shape as this PR.
- **selector-mode-select** — same shape as this PR.
- **playwright-lib driver `--selector` plumbing** — independent PR; coordinate fill + click together.
- **Adapter `tool_hover` for other adapters** (if hover routing ever expands beyond chrome-devtools-mcp) — touch the per-adapter `tool_hover` and add `--ref|--selector` alias same way.
