# Phase 8 part 2-i — router promotion (Path B → CLOSES Phase 8)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans.

**Goal:** Promote obscura to default for `--scrape` / `--stealth` per adapter-extension-model spec §4.4 (Path B). Drops the `--tool obscura` friction that 8-1-i / 8-1-ii / 8-1-iii required. **Closes Phase 8.**

**Branch:** `phase-08-part-2-i-router-promotion`
**Tag:** `v0.41.0-phase-08-part-2-i-router-promotion`

---

## Surface change

Before this PR:
```bash
bash scripts/browser-extract.sh --tool obscura --scrape --eval EXPR url1 url2
bash scripts/browser-extract.sh --tool obscura --stealth --eval EXPR url
```

After this PR:
```bash
bash scripts/browser-extract.sh --scrape --eval EXPR url1 url2     # auto-routes to obscura
bash scripts/browser-extract.sh --stealth --eval EXPR url          # auto-routes to obscura
```

`--tool obscura` still works as an explicit override. `--tool chrome-devtools-mcp --scrape` would fail the capability filter (cdt-mcp doesn't declare `--scrape`) and the router falls through to next rule.

## API additions

### `scripts/lib/router.sh`

Two new precedence rules placed BEFORE `rule_extract_default`:

```bash
ROUTING_RULES=(
  rule_session_required
  rule_capture_flags
  rule_audit_or_perf
  rule_inspect_default
  rule_scrape_flag         # NEW (8-2-i)
  rule_stealth_flag        # NEW (8-2-i)
  rule_extract_default
  ...
)

rule_scrape_flag() {
  local verb="$1"
  shift
  if _has_flag --scrape "$@"; then
    printf 'obscura\t%s\n' "--scrape requested (only obscura declares scrape backend)"
  fi
}

rule_stealth_flag() {
  local verb="$1"
  shift
  if _has_flag --stealth "$@"; then
    printf 'obscura\t%s\n' "--stealth requested (only obscura declares stealth backend)"
  fi
}
```

Order matters: `rule_scrape_flag` and `rule_stealth_flag` MUST come BEFORE `rule_extract_default` so that `extract --scrape` and `extract --stealth` route to obscura instead of falling into `rule_extract_default → chrome-devtools-mcp`.

Stale comment cleanup in `rule_extract_default`:
```diff
-# multi-URL inspection. NOTE: `--scrape <urls...>` should route to obscura
-# when it lands (Phase 8); prepend a higher-precedence obscura rule above
-# this one then — no edits needed here.
+# multi-URL inspection. `--scrape` / `--stealth` route to obscura via the
+# higher-precedence rule_scrape_flag / rule_stealth_flag rules (Phase 8-2-i).
```

Same cleanup in `scripts/browser-extract.sh` header.

## Test cases (RED → GREEN)

`tests/router.bats` — new cases:

1. `pick_tool extract --scrape https://a https://b` → routes to obscura (`why: --scrape requested`).
2. `pick_tool extract --stealth https://a` → routes to obscura (`why: --stealth requested`).
3. `pick_tool extract` (no flags) → still routes to chrome-devtools-mcp (existing default unchanged).
4. `pick_tool extract --selector .title` → still routes to chrome-devtools-mcp (`--scrape`/`--stealth` not in argv; falls to `rule_extract_default`).
5. `pick_tool open --scrape` → falls through. `rule_scrape_flag` would pick obscura but obscura doesn't declare `open` in capabilities → capability filter rejects → router walks to next rule. Eventually `rule_default_navigation` picks playwright-cli. (Documents the capability-filter safety.)

`tests/routing-capability-sync.bats` — extend the verb loop to include `--scrape` / `--stealth` on extract:

6. `pick_tool extract --scrape https://a` → status 0 (drift check; new rule + cap-declared verb).
7. `pick_tool extract --stealth https://a` → status 0.

`tests/browser-extract.bats` — drop `--tool obscura` from a smoke test to confirm auto-routing works end-to-end:

8. `--scrape --eval EXPR url1 url2` (no `--tool` flag) → reaches obscura adapter; ok summary with `tool:obscura`.
9. `--stealth --eval EXPR url` (no `--tool` flag) → reaches obscura adapter; ok summary with `tool:obscura`.

## Sub-scope (what 8-2-i does NOT do)

- **No new verb-dispatch backend.** Only routing-rule changes; obscura's `tool_extract` already handles both modes (8-1-ii / 8-1-iii).
- **No `--site` support for `--scrape` / `--stealth`.** Same deferral as before (obscura doesn't apply per-URL session).
- **No multi-URL stealth.** Still requires upstream support or adapter-side fan-out; deferred indefinitely.
- **No daemon-mode wiring** (`obscura serve --port 9222`). Still routed via future `playwright-lib --cdp-endpoint` flag, NOT this adapter.

## Acceptance

- `tests/router.bats` extended with 5 new cases (~20 → ~25); all green.
- `tests/routing-capability-sync.bats` extended (~2 → ~4 cases); all green.
- `tests/browser-extract.bats` extended with 2 auto-routing smoke cases (~15 → ~17); all green.
- `bash tests/lint.sh` exit 0 (all three tiers).
- Stale routing-comments updated in `router.sh` + `browser-extract.sh`.
- `references/obscura-cheatsheet.md` "When the router picks this adapter" table flips both rows from "planned 8-2-i" to "yes (default)".
- CHANGELOG `[Unreleased]` `[feat]` + `[adapter]` tags.

**Phase 8 closure note:** with 8-2-i merged, all 4 sub-parts of Phase 8 are shipped. Adapter inventory: 4 of 4 real-mode adapter shells + obscura partial (1 verb-dispatch fn now real-mode for 2 modes; remaining 7 are 41-stubs by design). The roster is complete; routing precedence locked in for the 4-adapter model.
