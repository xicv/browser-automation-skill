# Phase 5 part 1e-i — Verb scripts (browser-audit / browser-extract / un-skip browser-inspect)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans.

**Goal:** Surface `audit`, `extract`, and `inspect` as first-class CLI verbs (no `--tool=` needed). Two new shell scripts plus one un-skipped bats file. After 1d's router promotion, `bash scripts/browser-<verb>.sh` for all three routes to chrome-devtools-mcp by default.

**Sub-scope (1e-i, minimal):** verb scripts + stub-mode bats coverage. Audit ships **real-mode end-to-end** (bridge already supports the `audit` verb via lighthouse_audit, part 1c). Inspect/extract still exit 41 in real mode — the bridge's `inspect` / `extract` daemon-side dispatch lands in **part 1e-ii** (next sub-PR).

**Branch:** `feature/phase-05-part-1e-audit-extract-inspect`
**Tag:** `v0.12.0-phase-05-part-1e-i-audit-extract-scripts` (minor — adds CLI surface).

---

## File Structure

### New (creates)
| Path | Purpose | Size budget |
|---|---|---|
| `scripts/browser-audit.sh` | `audit` verb script — flags: `--lighthouse`, `--perf-trace` | ≤ 60 LOC |
| `scripts/browser-extract.sh` | `extract` verb script — flags: `--selector`, `--eval` | ≤ 60 LOC |
| `tests/browser-audit.bats` | stub-mode coverage via cdt-mcp lib-stub fixtures | ≤ 60 LOC |
| `tests/browser-extract.bats` | stub-mode coverage via cdt-mcp lib-stub fixtures | ≤ 60 LOC |
| `docs/superpowers/plans/2026-05-05-phase-05-part-1e-i-audit-extract-scripts.md` | this plan | — |

### Modified
| Path | Change | Diff |
|---|---|---|
| `tests/browser-inspect.bats` | un-skip; rewrite from playwright-cli stub → cdt-mcp lib-stub mode using existing fixture for `inspect --capture-console` | +~10 LOC |
| `SKILL.md` | add `audit` + `extract` rows; clarify `inspect` row (real-mode deferred to 1e-ii) | +~5 LOC |
| `CHANGELOG.md` | Phase 5 part 1e-i subsection | +~15 LOC |

### Untouched
- `scripts/lib/router.sh` (no rule changes — 1d already routes audit/inspect/extract to cdt-mcp)
- `scripts/lib/tool/chrome-devtools-mcp.sh` (capabilities unchanged)
- `scripts/lib/node/chrome-devtools-bridge.mjs` (bridge daemon dispatch for inspect/extract is **part 1e-ii**)
- All other adapters

---

## Verb script shape

Mirror `scripts/browser-snapshot.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"
source "${SCRIPT_DIR}/lib/output.sh"
source "${SCRIPT_DIR}/lib/router.sh"
source "${SCRIPT_DIR}/lib/verb_helpers.sh"

init_paths

SUMMARY_T0="$(now_ms)"; export SUMMARY_T0

parse_verb_globals "$@"

resolve_session_storage_state

# Verb-specific: parse + validate flags into verb_argv.

# Dry-run guard.

picked="$(pick_tool VERB "${verb_argv[@]}")"
tool_name="${picked%%$'\t'*}"
why="${picked#*$'\t'}"

source_picked_adapter "${tool_name}"

set +e
adapter_out="$(tool_VERB "${verb_argv[@]}")"
adapter_rc=$?
set -e

[ -n "${adapter_out}" ] && printf '%s\n' "${adapter_out}"

if [ "${adapter_rc}" -eq 0 ]; then
  emit_summary verb=VERB tool="${tool_name}" why="${why}" status=ok ...
  exit 0
fi
emit_summary verb=VERB tool="${tool_name}" why="${why}" status=error ...
exit "${adapter_rc}"
```

### `browser-audit.sh` flags

- `--lighthouse` (default behavior; adapter runs lighthouse_audit MCP tool)
- `--perf-trace` (adapter runs performance_start_trace + stop)
- Both flags can coexist; adapter returns combined summary.
- No required flags — bare `bash scripts/browser-audit.sh` runs default lighthouse audit.

### `browser-extract.sh` flags

- `--selector CSS` — select elements by CSS selector and return their text.
- `--eval JS` — evaluate arbitrary JS in page context and return the result.
- One required: `--selector OR --eval`. Both is acceptable (eval can use selector via DOM API).

---

## RED bats

### `tests/browser-audit.bats`

```bash
@test "browser-audit: --lighthouse routes to cdt-mcp and emits summary"
@test "browser-audit: --perf-trace routes to cdt-mcp"
@test "browser-audit: bare invocation (default = --lighthouse) routes to cdt-mcp"
@test "browser-audit: --tool=ghost-tool fails EXIT_USAGE_ERROR"
@test "browser-audit: --dry-run skips adapter"
```

### `tests/browser-extract.bats`

```bash
@test "browser-extract: --selector .title routes to cdt-mcp"
@test "browser-extract: --eval 'document.title' routes to cdt-mcp"
@test "browser-extract: missing --selector AND --eval fails USAGE_ERROR"
@test "browser-extract: --tool=ghost-tool fails EXIT_USAGE_ERROR"
@test "browser-extract: --dry-run skips adapter"
```

### `tests/browser-inspect.bats` (un-skip + rewrite)

Existing tests use playwright-cli stub. After 1d, router routes inspect → cdt-mcp. Rewrite to use `BROWSER_SKILL_LIB_STUB=1` + cdt-mcp's lib-stub fixture lookup for `inspect --capture-console`.

```bash
@test "browser-inspect: --capture-console routes to cdt-mcp lib-stub fixture"
@test "browser-inspect: emits summary with verb=inspect, tool=chrome-devtools-mcp"
@test "browser-inspect: missing flags (no capture/screenshot) is a usage error" (?? — see below)
@test "browser-inspect: --tool=ghost-tool fails EXIT_USAGE_ERROR"
```

The "missing flags" test depends on whether `inspect` requires at least one capture flag. Per cdt-mcp capabilities, the flags are optional. Defer that policy decision; tests just exercise the happy paths.

---

## Lint + drift

- shellcheck on new shell scripts — clean.
- Drift tier: no adapter capability change → no `regenerate-docs.sh` run.
- bats-tier: full suite still 479+ pass.

---

## Tag + push

```
git tag v0.12.0-phase-05-part-1e-i-audit-extract-scripts
git push -u origin feature/phase-05-part-1e-audit-extract-inspect
git push origin v0.12.0-phase-05-part-1e-i-audit-extract-scripts
gh pr create --title "feat(phase-5-part-1e-i): browser-audit + browser-extract scripts (un-skip browser-inspect.bats)"
```

---

## Risks + mitigations

| Risk | Mitigation |
|---|---|
| Existing inspect bats was speculative — rewrite may miss edge cases | Mirror snapshot.bats shape; existing fixture for `inspect --capture-console` already covers stub-mode happy path |
| Real-mode inspect/extract still exit 41 — confusing UX for users | Document explicitly in 1e-i CHANGELOG: "real-mode dispatch deferred to 1e-ii"; bridge error message remains pointing at next sub-part |
| extract --selector requires JS to read DOM; --eval as primary path | Spec says both flags supported; `--eval` is the cleanest path for stub-mode. Real-mode (1e-ii) handles both via tools/call evaluate_script |
