# Selector-mode plumbing for `fill` — first sub-PR of "expand `browser-do --verb` whitelist beyond `[click]`"

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans.

**Goal:** Add `--selector CSS` path to `browser-fill.sh`. Required for Phase 11's memory cache to dispatch fill (cache stores selectors, not refs). Mirrors the precedent already shipped for click. Also adds `fill` to `browser-do --verb` whitelist. First of 4 selector-mode plumbing sub-PRs (fill → hover → press → select).

**Branch:** `selector-mode-fill`
**Tag:** `v0.52.0-selector-mode-fill`

---

## Locked decisions

- **S1 — Mirror click's selector-mode precedent.** `browser-fill.sh` accepts `--selector CSS` mutually-exclusive with `--ref eN`; one of the two required. Adapter sees `--selector "$value"` in argv. Same shape as `browser-click.sh` (already shipped in earlier phase).
- **S2 — Adapter coverage scope = playwright-cli + chrome-devtools-mcp only for v1.** These adapters' `tool_fill` already has a structured arg-parsing block; adding `--selector` is a one-line alias-to-`--ref`-target (mirrors what they already do for `tool_click`). **Defer playwright-lib driver `--selector` plumbing** — it would require IPC schema changes (`runFill` + `case 'fill':` in IPC handler) AND parallel changes to `runClick` for symmetry; clearly its own PR. **playwright-lib doesn't currently support --selector for click either** — this PR doesn't make it worse.
- **S3 — `browser-do --verb` whitelist gains `fill`.** Was `[click]`; becomes `[click fill]`. The whitelist is the gating control for cache dispatch — adding `fill` is the final step that makes form-filling cache hits work.
- **S4 — `--text` and `--secret-stdin` semantics unchanged.** Selector-mode fill still requires either `--text VALUE` or `--secret-stdin`. Privacy invariants from AP-7 (secret-not-on-argv via `--secret-stdin`) are unchanged.
- **S5 — Routing unchanged.** `browser-fill.sh` calls `pick_tool fill` which honors existing routing rules. If routing picks playwright-lib for fill (e.g. due to `BROWSER_SKILL_STORAGE_STATE` set), the `--selector` flag falls into `verb_argv` and ends up in playwright-lib's `tool_fill` → `_drive fill "$@"` → driver. Driver currently doesn't parse `--selector` → returns exit 2 ("--ref required"). Test will document this as expected behavior; user-visible workaround is to pass `--tool=playwright-cli` explicitly.

## Surface

```
bash scripts/browser-fill.sh \
  [--site NAME] [--tool NAME] [--dry-run] [--raw] \
  (--ref eN | --selector CSS) \
  (--text VALUE | --secret-stdin)
```

- `--ref eN` — existing snapshot-relative ref (Phase 11-uncacheable).
- `--selector CSS` — NEW. CSS selector string. Cacheable; what `browser-do --verb fill` will dispatch.
- `--text` / `--secret-stdin` — unchanged.

## Implementation strategy

### `scripts/browser-fill.sh`

Mirror `scripts/browser-click.sh`'s `--ref` / `--selector` parsing block. Validation:
- `--ref` AND `--selector` both given → `EXIT_USAGE_ERROR` "mutually exclusive".
- Neither given → `EXIT_USAGE_ERROR` "fill requires --ref eN or --selector CSS".

### `scripts/lib/tool/playwright-cli.sh::tool_fill`

Change `--ref) target="$2"; shift 2 ;;` to `--ref|--selector) target="$2"; shift 2 ;;`. Mirrors `tool_click` line 103.

### `scripts/lib/tool/chrome-devtools-mcp.sh::tool_fill`

Same: `--ref) target="$2"; shift 2 ;;` → `--ref|--selector) target="$2"; shift 2 ;;`. Mirrors `tool_click` line 142.

### `scripts/browser-do.sh`

Whitelist update:
```bash
readonly DO_VERB_WHITELIST=(click fill)
```

## Test cases (RED → GREEN)

`tests/browser-fill.bats` (gains 3 cases):

1. `--selector 'input.email' --text alice@x.com` → adapter receives `input.email` as target.
2. `--selector X --ref e1` → mutually-exclusive `EXIT_USAGE_ERROR`.
3. Neither `--selector` nor `--ref` → `EXIT_USAGE_ERROR` "requires --ref eN or --selector CSS".

`tests/browser-do.bats` (gains 1 case): `--verb fill --intent "type email"` cache hit dispatches stub-fill with `--selector $cached --text VALUE`. Existing `tests/browser-do.bats::4` (whitelist enforcement) still passes — `fill` no longer rejected.

**Fixture:** new `tests/fixtures/playwright-cli/<hash>.json` for `["fill","input.email","alice@example.com"]` if argv-hash differs from existing fill fixtures. (Verify during implementation.)

## Sub-scope (what this PR does NOT do)

- **No playwright-lib `--selector` plumbing** (S2; deferred to its own PR — IPC schema + driver changes).
- **No hover/press/select selector-mode plumbing** — separate sub-PRs of the same parent task. This PR is just `fill`.
- **No new privacy canary** — fill's existing AP-7 canary covers `--secret-stdin`; `--selector` is structural (CSS string), not a credential channel.
- **No route-rule changes** — routing picks adapter same as before; flag parsing happens after pick.
- **No cache-write contract changes** — `cache-write-security.md`'s 5 rules unchanged; this PR widens the `--verb` whitelist (Rule 1's allowed list grows) but doesn't change Rule 1 itself.

## Acceptance

- `tests/browser-fill.bats` + 3 new cases all green.
- `tests/browser-do.bats` 32 → 33 cases all green.
- Full bats green; lint exit 0.
- `bash scripts/browser-do.sh --verb fill --intent "type email" --pattern '/login' --site app -- --text alice@example.com` works end-to-end against stub-fill (with seeded cache).
- CHANGELOG `[Unreleased]` `[feat]` block + plan-doc reference.

## Notes for follow-ups

- **Selector-mode plumbing for hover/press/select** — same shape as this PR; one per verb. Each unlocks one more verb in the cache.
- **playwright-lib driver `--selector` plumbing** — needs `runFill`/`runClick` flag handling + `case 'fill'`/`case 'click'` IPC handler updates (use `page.locator(selector)` instead of refMap lookup). Independent PR; coordinate fill + click together to keep IPC schema bumps coherent.
- **Adapter ABI doc update** — `references/recipes/anti-patterns-tool-extension.md` could note "verbs that take element targets should accept `--ref` AND `--selector`" as a positive pattern.
