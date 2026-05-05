# Phase 5 part 1d — Router promotion (Path B for cdt-mcp)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans.

**Goal:** Promote `chrome-devtools-mcp` from "opt-in via `--tool=`" (Path A) to a router default for the verbs and flags where it's the only sensible adapter. Per parent spec Appendix B:

| Trigger | Tool |
|---|---|
| `--capture-console` / `--capture-network` | chrome-devtools-mcp |
| `--lighthouse` / `--perf-trace` / verb=`audit` | chrome-devtools-mcp |
| verb=`inspect` | chrome-devtools-mcp |
| verb=`extract` | chrome-devtools-mcp (with `--scrape` exception going to obscura when it lands) |

Adds 4 rules to `scripts/lib/router.sh`. Zero adapter changes (cdt-mcp already declares the verbs in `tool_capabilities`). Phase 5 part 1c-ii made stateful verbs work via daemon, so this promotion is "meaningful" now per HANDOFF sequencing.

**Branch:** `feature/phase-05-part-1d-router-promotion`
**Tag:** `v0.11.0-phase-05-part-1d-router-promotion` (minor — adds routing surface).

---

## File Structure

### New (creates)
- `docs/superpowers/plans/2026-05-05-phase-05-part-1d-router-promotion.md` — this plan.

### Modified
| Path | Change | Diff |
|---|---|---|
| `scripts/lib/router.sh` | +4 rule functions; ROUTING_RULES re-ordered | +~70 LOC |
| `tests/router.bats` | +~10 new cases (capture-flag / audit / inspect / extract); update existing audit-fall-through test | +~80 LOC |
| `references/chrome-devtools-mcp-cheatsheet.md` | "When the router picks this adapter" table reflects new defaults | +~10 LOC |
| `CHANGELOG.md` | Phase 5 part 1d subsection | +~15 LOC |

### Untouched
- `scripts/lib/tool/*.sh` (no adapter capability changes)
- All verb scripts (`scripts/browser-*.sh`) — they already call `pick_tool VERB`; the routing change is transparent.
- `scripts/lib/node/chrome-devtools-bridge.mjs` (no bridge changes)
- `scripts/lib/common.sh`, `scripts/lib/output.sh`, etc.

---

## Rule design

```
ROUTING_RULES=(
  rule_session_required        # storageState set → playwright-lib (existing)
  rule_capture_flags           # --capture-console/network → cdt-mcp (NEW)
  rule_audit_or_perf           # --lighthouse/--perf-trace or verb=audit → cdt-mcp (NEW)
  rule_inspect_default         # verb=inspect → cdt-mcp (NEW)
  rule_extract_default         # verb=extract → cdt-mcp (NEW)
  rule_default_navigation      # open/click/fill/snapshot → playwright-cli (existing)
)
```

### `rule_capture_flags`
- Match: `--capture-console` OR `--capture-network` in argv (any verb).
- Echo: `chrome-devtools-mcp\t--capture-* requested`.

### `rule_audit_or_perf`
- Match: verb=`audit` OR `--lighthouse` OR `--perf-trace` in argv.
- Echo: `chrome-devtools-mcp\tlighthouse/perf only here`.

### `rule_inspect_default`
- Match: verb=`inspect`.
- Echo: `chrome-devtools-mcp\tinspect default per Appendix B`.

### `rule_extract_default`
- Match: verb=`extract`.
- Echo: `chrome-devtools-mcp\textract default per Appendix B`.
- Note: per spec Appendix B, `--scrape <urls...>` should route to `obscura`. Obscura doesn't exist (Phase 8). When it lands, prepend an `obscura` rule above this one — no edits needed here.

### Capability-filter interaction

`pick_tool` already runs `_tool_supports` after each rule. This means:
- A rule that picks a tool the tool doesn't declare → `pick_tool` walks past it. Safe.
- Session-required rule echoes playwright-lib for `open/click/fill/snapshot`; for `inspect/audit/extract` (which playwright-lib doesn't declare), the rule simply doesn't fire — no conflict. Capture-flag rule below it picks cdt-mcp.
- **Known limitation (out of scope):** `--site app --capture-console` on `snapshot` — session_required wins (playwright-lib supports snapshot). User's --capture-console flag is silently ignored because playwright-lib doesn't capture console. This is a documented limitation; resolution is part 1f (Chrome `--user-data-dir` lets cdt-mcp do session loading too) or a future "session-aware capture" rule.

---

## Test approach

`tests/router.bats` already covers existing rules + capability filter. Extend it (no new file):

| # | Case | Expected |
|---|---|---|
| 1 | `pick_tool snapshot --capture-console` | chrome-devtools-mcp |
| 2 | `pick_tool snapshot --capture-network` | chrome-devtools-mcp |
| 3 | `pick_tool snapshot --capture-console --headed` | chrome-devtools-mcp |
| 4 | `pick_tool audit` | chrome-devtools-mcp (was: EXIT_TOOL_MISSING — UPDATE existing test #9) |
| 5 | `pick_tool snapshot --lighthouse` | chrome-devtools-mcp |
| 6 | `pick_tool snapshot --perf-trace` | chrome-devtools-mcp |
| 7 | `pick_tool inspect` | chrome-devtools-mcp |
| 8 | `pick_tool extract` | chrome-devtools-mcp |
| 9 | `pick_tool open --capture-console` | chrome-devtools-mcp (capture wins over default-navigation) |
| 10 | `pick_tool open` (no flags) | playwright-cli (default-navigation still wins when no capture flags) |
| 11 | `BROWSER_SKILL_STORAGE_STATE=/x pick_tool snapshot` | playwright-lib (session_required wins above capture rules) |
| 12 | `ARG_TOOL=playwright-cli pick_tool inspect` | EXIT_USAGE_ERROR (capability filter rejects — preserves existing behavior) |

Plus update `tests/routing-capability-sync.bats`:
- Extend the iterated-verbs loop to include `audit / inspect / extract` so the drift guard covers them.

---

## Risks + mitigations

| Risk | Mitigation |
|---|---|
| Existing snapshot+session combo regresses (silent flag drop) | Documented limitation; no behavior change vs pre-1d |
| Future obscura promotion needs to inject above extract rule | Rule order documented in router.sh comments + plan |
| `audit` verb has no script yet (1e) | `pick_tool audit` is unit-testable in bats today; CLI surface lands in 1e |

---

## Lint + drift

- shellcheck on router.sh — clean (existing pattern).
- bats-tier: full suite still 469+ pass.
- Drift tier: no adapter capability change → no `regenerate-docs.sh` run.

---

## Tag + push

```
git tag v0.11.0-phase-05-part-1d-router-promotion
git push -u origin feature/phase-05-part-1d-router-promotion
git push origin v0.11.0-phase-05-part-1d-router-promotion
gh pr create --title "feat(phase-5-part-1d): router promotion (cdt-mcp Path B)"
```
