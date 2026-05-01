# Phase 3 Part 2 — Real verb scripts wired through router → adapter

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Land the first user-facing verb scripts that exercise the full Phase 3 framework end-to-end. Concretely: a `verb_helpers.sh` boilerplate module + `scripts/browser-open.sh` that validates router → adapter → output helper end-to-end through the existing playwright-cli stub. Once `browser-open` proves the pattern, the four sibling verbs (`snapshot`, `click`, `fill`, `inspect`) become mechanical follow-ups; this plan defers them to a follow-up plan to keep the surface area small.

**Architecture:** Each `scripts/browser-<verb>.sh` is a thin orchestrator: parse global flags (`--site`, `--tool`), call `pick_tool VERB`, source the picked adapter in the current shell, dispatch to `tool_<verb>`, emit a single-line JSON summary via `emit_summary`. Verb scripts never source another adapter. Streaming JSON (per token-efficient-output spec §3.3) is the adapter's responsibility; the verb script prints whatever the adapter prints, then appends its summary line.

**Spec references:**
- `docs/superpowers/specs/2026-04-27-browser-automation-skill-design.md` §3.2 (verb scripts), §5.1 (exit codes), §5.4 (summary contract).
- `docs/superpowers/specs/2026-04-30-tool-adapter-extension-model-design.md` §2.2 (verb-dispatch contract).
- `docs/superpowers/specs/2026-05-01-token-efficient-adapter-output-design.md` §3 (output schema), §4 (`--raw`/`--json`/`--depth` flags), §5 (`eN` ref scheme).

**Branch (recommended):** `feature/phase-03-part-2-real-verbs` — sibling to Phase 3 framework branch; created at start, merged when all in-scope tasks land.

---

## File Structure

### New files (creates)

| Path | Purpose | Size budget |
|---|---|---|
| `scripts/lib/verb_helpers.sh` | Shared verb-script boilerplate: `parse_verb_globals`, `source_picked_adapter`, `dispatch_verb` | ≤ 200 LOC |
| `scripts/browser-open.sh` | First real verb: navigate to a URL via picked adapter | ≤ 150 LOC |
| `tests/verb_helpers.bats` | Unit tests for the helper functions | ≤ 200 LOC |
| `tests/browser-open.bats` | Behavior tests for the open verb (via stub) | ≤ 200 LOC |

### Modified files

| Path | Change | Estimated diff |
|---|---|---|
| `SKILL.md` | Add `open` row to the Verbs table | +1 LOC |
| `CHANGELOG.md` | New entries under Phase-3 section | +6 LOC |

### Untouched core files

These DO NOT change in this plan:
- `scripts/lib/common.sh`
- `scripts/lib/router.sh`
- `scripts/lib/output.sh`
- `scripts/lib/tool/playwright-cli.sh`
- `scripts/browser-doctor.sh`
- `tests/lint.sh`

---

## Pre-Plan: Branch and starting state

- [x] **Step 0.1: Branch from main**

```bash
cd /Users/xicao/Projects/browser-automation-skill
git checkout main
git pull --ff-only origin main
git checkout -b feature/phase-03-part-2-real-verbs
git status
```

Expected: clean tree on `feature/phase-03-part-2-real-verbs`. The plan file (this doc) is the only untracked addition.

- [ ] **Step 0.2: Commit the plan**

```bash
git add docs/superpowers/plans/2026-05-01-phase-03-part-2-real-verbs.md
git commit -m "docs: phase-3 part 2 plan — real verb scripts wired through router/adapter"
```

---

## Task 1: scripts/lib/verb_helpers.sh

**Files:**
- Create: `scripts/lib/verb_helpers.sh`
- Create: `tests/verb_helpers.bats`

The helper module factors out boilerplate every verb script will need:
- `parse_verb_globals` — peel off `--site`, `--tool`, `--dry-run`, `--raw` from argv; export `ARG_SITE`, `ARG_TOOL`, `ARG_DRY_RUN`, `ARG_RAW`. Remaining args are kept for the verb's own parser.
- `source_picked_adapter TOOL_NAME` — sources `$LIB_TOOL_DIR/<name>.sh` once in the current shell, after `pick_tool` decided.
- `dispatch_verb VERB FN ARGS...` — wraps the adapter dispatch + summary emit pattern: starts the timer, pipes through to `tool_<verb>`, captures status, emits `emit_summary verb=$verb tool=$tool why=$why status=$status duration_ms=...`. The verb script supplies any extra summary keys via env vars or a post-emit hook.

- [ ] **Step 1.1: Write the failing tests**

Create `tests/verb_helpers.bats`:

```bash
load helpers

setup() {
  setup_temp_home
}
teardown() {
  teardown_temp_home
}

@test "verb_helpers: parse_verb_globals strips --site, --tool, --dry-run, --raw from argv" {
  run bash -c "
    source '${LIB_DIR}/common.sh'
    source '${LIB_DIR}/verb_helpers.sh'
    parse_verb_globals --site prod --tool playwright-cli --foo --bar --dry-run --raw
    printf 'site=%s|tool=%s|dry=%s|raw=%s|rest=%s\n' \"\${ARG_SITE}\" \"\${ARG_TOOL}\" \"\${ARG_DRY_RUN}\" \"\${ARG_RAW}\" \"\${REMAINING_ARGV[*]}\"
  "
  assert_status 0
  assert_output_contains "site=prod"
  assert_output_contains "tool=playwright-cli"
  assert_output_contains "dry=1"
  assert_output_contains "raw=1"
  assert_output_contains "rest=--foo --bar"
}

@test "verb_helpers: parse_verb_globals leaves ARG_* unset when flags absent" {
  run bash -c "
    source '${LIB_DIR}/common.sh'
    source '${LIB_DIR}/verb_helpers.sh'
    parse_verb_globals --foo --bar
    printf 'site=[%s]|tool=[%s]|dry=[%s]|raw=[%s]|rest=%s\n' \"\${ARG_SITE:-}\" \"\${ARG_TOOL:-}\" \"\${ARG_DRY_RUN:-}\" \"\${ARG_RAW:-}\" \"\${REMAINING_ARGV[*]}\"
  "
  assert_status 0
  assert_output_contains "site=[]"
  assert_output_contains "tool=[]"
  assert_output_contains "dry=[]"
  assert_output_contains "raw=[]"
  assert_output_contains "rest=--foo --bar"
}

@test "verb_helpers: parse_verb_globals errors on --site without value" {
  run bash -c "
    source '${LIB_DIR}/common.sh'
    source '${LIB_DIR}/verb_helpers.sh'
    parse_verb_globals --site
  "
  assert_status "$EXIT_USAGE_ERROR"
  assert_output_contains "site"
}

@test "verb_helpers: source_picked_adapter exits EXIT_TOOL_MISSING when adapter file missing" {
  run bash -c "
    source '${LIB_DIR}/common.sh'; init_paths
    source '${LIB_DIR}/verb_helpers.sh'
    source_picked_adapter ghost-tool
  "
  assert_status "$EXIT_TOOL_MISSING"
  assert_output_contains "ghost-tool"
}

@test "verb_helpers: source_picked_adapter loads the adapter and exposes tool_metadata" {
  run bash -c "
    source '${LIB_DIR}/common.sh'; init_paths
    source '${LIB_DIR}/verb_helpers.sh'
    source_picked_adapter playwright-cli
    tool_metadata
  "
  assert_status 0
  printf '%s' "${output}" | jq -e '.name == "playwright-cli"' >/dev/null
}
```

- [ ] **Step 1.2: Run — expect fail**

```bash
bats tests/verb_helpers.bats
```

Expected: 5 fail (no `verb_helpers.sh`).

- [ ] **Step 1.3: Create `scripts/lib/verb_helpers.sh`**

```bash
# scripts/lib/verb_helpers.sh — shared verb-script boilerplate.
# Every scripts/browser-<verb>.sh sources this AFTER common.sh + router.sh.
# See: docs/superpowers/plans/2026-05-01-phase-03-part-2-real-verbs.md Task 1.

[ -n "${BROWSER_SKILL_VERB_HELPERS_LOADED:-}" ] && return 0
readonly BROWSER_SKILL_VERB_HELPERS_LOADED=1

# parse_verb_globals "$@" — peels off the global flags every verb supports:
#   --site NAME           — site profile name (overrides 'current')
#   --tool NAME           — force a specific adapter (sets ARG_TOOL → router)
#   --dry-run             — print planned action, write nothing
#   --raw                 — strip streaming + summary; emit only the value (spec §4)
# Exports ARG_SITE / ARG_TOOL / ARG_DRY_RUN / ARG_RAW (unset if not present).
# Remaining argv (non-global flags) goes into REMAINING_ARGV[].
parse_verb_globals() {
  REMAINING_ARGV=()
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --site)
        [ -n "${2:-}" ] || die "${EXIT_USAGE_ERROR}" "--site requires a value"
        ARG_SITE="$2"; export ARG_SITE
        shift 2
        ;;
      --tool)
        [ -n "${2:-}" ] || die "${EXIT_USAGE_ERROR}" "--tool requires a value"
        ARG_TOOL="$2"; export ARG_TOOL
        shift 2
        ;;
      --dry-run)
        ARG_DRY_RUN=1; export ARG_DRY_RUN
        shift
        ;;
      --raw)
        ARG_RAW=1; export ARG_RAW
        shift
        ;;
      *)
        REMAINING_ARGV+=("$1")
        shift
        ;;
    esac
  done
}

# source_picked_adapter TOOL_NAME — source $LIB_TOOL_DIR/<name>.sh in the
# current shell. Dies with EXIT_TOOL_MISSING if the file is absent.
# Caller MUST have called init_paths first (sets LIB_TOOL_DIR).
source_picked_adapter() {
  local tool="$1"
  local file="${LIB_TOOL_DIR}/${tool}.sh"
  if [ ! -f "${file}" ]; then
    die "${EXIT_TOOL_MISSING}" "adapter file not found: ${tool} (no ${file})"
  fi
  # shellcheck source=/dev/null
  source "${file}"
}
```

- [ ] **Step 1.4: Run — expect pass**

```bash
bats tests/verb_helpers.bats
```

Expected: 5 pass.

- [ ] **Step 1.5: Commit**

```bash
git add scripts/lib/verb_helpers.sh tests/verb_helpers.bats
git commit -m "feat(verb-helpers): parse_verb_globals + source_picked_adapter (shared verb boilerplate)"
```

---

## Task 2: scripts/browser-open.sh

**Files:**
- Create: `scripts/browser-open.sh`
- Create: `tests/browser-open.bats`

The first real verb. Wires:
1. `parse_verb_globals` peels off `--site`, `--tool`, `--dry-run`, `--raw`.
2. Remaining argv must include `--url <URL>` (verb-specific required flag).
3. `pick_tool open "${REMAINING_ARGV[@]}"` returns `<tool>\t<why>`.
4. `source_picked_adapter "${tool}"` brings `tool_open` into scope.
5. `tool_open --url <URL>` runs (passes through to adapter; `playwright-cli` shells to the binary).
6. `emit_summary verb=open tool=<tool> why=<why> status=ok url=<URL> duration_ms=...`

- [ ] **Step 2.1: Write the failing tests**

Create `tests/browser-open.bats`:

```bash
load helpers

setup() {
  setup_temp_home
  mkdir -p "${BROWSER_SKILL_HOME}"
  chmod 700 "${BROWSER_SKILL_HOME}"
}
teardown() {
  teardown_temp_home
}

@test "browser-open: --url passes through to picked adapter via stub" {
  STUB_LOG_FILE="$(mktemp)"
  PLAYWRIGHT_CLI_BIN="${STUBS_DIR}/playwright-cli" \
  PLAYWRIGHT_CLI_FIXTURES_DIR="${FIXTURES_DIR}/playwright-cli" \
  STUB_LOG_FILE="${STUB_LOG_FILE}" \
    run bash "${SCRIPTS_DIR}/browser-open.sh" --url https://example.com
  assert_status 0
  grep -q '^open$' "${STUB_LOG_FILE}"
  grep -q '^--url$' "${STUB_LOG_FILE}"
  grep -q '^https://example.com$' "${STUB_LOG_FILE}"
  rm -f "${STUB_LOG_FILE}"
}

@test "browser-open: emits a single-line JSON summary as the last line of stdout" {
  PLAYWRIGHT_CLI_BIN="${STUBS_DIR}/playwright-cli" \
  PLAYWRIGHT_CLI_FIXTURES_DIR="${FIXTURES_DIR}/playwright-cli" \
    run bash "${SCRIPTS_DIR}/browser-open.sh" --url https://example.com
  assert_status 0
  local last_line
  last_line="$(printf '%s\n' "${lines[@]}" | tail -1)"
  printf '%s' "${last_line}" | jq -e '.verb == "open" and .tool == "playwright-cli" and .status == "ok"' >/dev/null
  printf '%s' "${last_line}" | jq -e '.duration_ms | type == "number"' >/dev/null
}

@test "browser-open: --tool override propagates as ARG_TOOL into router" {
  PLAYWRIGHT_CLI_BIN="${STUBS_DIR}/playwright-cli" \
  PLAYWRIGHT_CLI_FIXTURES_DIR="${FIXTURES_DIR}/playwright-cli" \
    run bash "${SCRIPTS_DIR}/browser-open.sh" --tool playwright-cli --url https://example.com
  assert_status 0
  local last_line
  last_line="$(printf '%s\n' "${lines[@]}" | tail -1)"
  printf '%s' "${last_line}" | jq -e '.why == "user-specified"' >/dev/null
}

@test "browser-open: --tool=ghost-tool fails EXIT_USAGE_ERROR" {
  run bash "${SCRIPTS_DIR}/browser-open.sh" --tool ghost-tool --url https://example.com
  assert_status "$EXIT_USAGE_ERROR"
  assert_output_contains "no such adapter"
}

@test "browser-open: missing --url fails EXIT_USAGE_ERROR" {
  run bash "${SCRIPTS_DIR}/browser-open.sh"
  assert_status "$EXIT_USAGE_ERROR"
  assert_output_contains "--url"
}

@test "browser-open: --dry-run prints planned action and writes nothing" {
  run bash "${SCRIPTS_DIR}/browser-open.sh" --dry-run --url https://example.com
  assert_status 0
  assert_output_contains "dry-run"
  local last_line
  last_line="$(printf '%s\n' "${lines[@]}" | tail -1)"
  printf '%s' "${last_line}" | jq -e '.status == "ok" and .dry_run == true' >/dev/null
}
```

- [ ] **Step 2.2: Run — expect fail**

```bash
bats tests/browser-open.bats
```

Expected: 6 fail (no `browser-open.sh`).

- [ ] **Step 2.3: Create `scripts/browser-open.sh`**

```bash
#!/usr/bin/env bash
# scripts/browser-open.sh — open a URL via the routed adapter.
# Usage: bash scripts/browser-open.sh [--site NAME] [--tool NAME] [--dry-run]
#                                     [--raw] --url <URL>
# Emits one streaming JSON line per adapter event (if any), then a single
# JSON summary line. See docs/superpowers/specs/2026-04-27-browser-automation-skill-design.md §5.4
# and docs/superpowers/specs/2026-05-01-token-efficient-adapter-output-design.md §3.

set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/common.sh"
# shellcheck source=lib/output.sh
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/output.sh"
# shellcheck source=lib/router.sh
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/router.sh"
# shellcheck source=lib/verb_helpers.sh
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/verb_helpers.sh"

init_paths

SUMMARY_T0="$(now_ms)"; export SUMMARY_T0

parse_verb_globals "$@"

# Verb-specific argv parse: pull --url out of REMAINING_ARGV.
url=""
verb_argv=()
i=0
while [ "${i}" -lt "${#REMAINING_ARGV[@]}" ]; do
  case "${REMAINING_ARGV[i]}" in
    --url)
      url="${REMAINING_ARGV[i+1]:-}"
      [ -n "${url}" ] || die "${EXIT_USAGE_ERROR}" "--url requires a value"
      verb_argv+=(--url "${url}")
      i=$((i + 2))
      ;;
    *)
      verb_argv+=("${REMAINING_ARGV[i]}")
      i=$((i + 1))
      ;;
  esac
done

[ -n "${url}" ] || die "${EXIT_USAGE_ERROR}" "--url <URL> is required"

# Dry-run: don't pick a tool or invoke an adapter; emit a planning summary.
if [ "${ARG_DRY_RUN:-0}" = "1" ]; then
  ok "dry-run: would open ${url}"
  emit_summary verb=open tool=none why=dry-run status=ok url="${url}" dry_run=true
  exit 0
fi

# Router pick.
picked="$(pick_tool open "${verb_argv[@]}")"
tool_name="${picked%%$'\t'*}"
why="${picked#*$'\t'}"

# Source the picked adapter so tool_open is in scope.
source_picked_adapter "${tool_name}"

# Dispatch to adapter; capture its stdout (typically streaming JSON lines).
adapter_out="$(tool_open "${verb_argv[@]}")"
adapter_rc=$?

# Forward adapter's stdout (streaming events) verbatim.
[ -n "${adapter_out}" ] && printf '%s\n' "${adapter_out}"

# Compose summary.
if [ "${adapter_rc}" -eq 0 ]; then
  emit_summary verb=open tool="${tool_name}" why="${why}" status=ok url="${url}"
  exit 0
fi
emit_summary verb=open tool="${tool_name}" why="${why}" status=error url="${url}"
exit "${adapter_rc}"
```

```bash
chmod +x scripts/browser-open.sh
```

- [ ] **Step 2.4: Run — expect pass**

```bash
bats tests/browser-open.bats
```

Expected: 6 pass.

- [ ] **Step 2.5: Manual sanity check**

```bash
PLAYWRIGHT_CLI_BIN=tests/stubs/playwright-cli bash scripts/browser-open.sh --url https://example.com | tail -3
```

Expected: streaming line `{"event":"navigate","url":"https://example.com","status":200}` + summary line with `verb=open`, `tool=playwright-cli`, `why="default for open"`, `status=ok`, `url=...`, `duration_ms=N`.

- [ ] **Step 2.6: Update SKILL.md verb table**

Append to the verbs table in `SKILL.md`:

```markdown
| `open`          | Open a URL in the picked browser adapter | `… open --url https://app.example.com` |
```

- [ ] **Step 2.7: Run full suite + lint**

```bash
tests/run.sh 2>&1 | tail -3
bash tests/lint.sh
echo "lint: $?"
```

Expected: all bats tests pass; lint exits 0.

- [ ] **Step 2.8: Commit**

```bash
git add scripts/browser-open.sh tests/browser-open.bats SKILL.md
git commit -m "feat(verb): browser-open.sh — first real verb wired through router → adapter"
```

---

## Task 3: CHANGELOG + tag

- [ ] **Step 3.1: Append entries to CHANGELOG.md** (under `[Unreleased]` or a new `Phase 3 part 2` subsection):

```markdown
### Phase 3 part 2 — Real verb scripts

- [feat] `scripts/lib/verb_helpers.sh` — `parse_verb_globals` + `source_picked_adapter` shared boilerplate for all verb scripts.
- [feat] `scripts/browser-open.sh` — first real verb script: `--site`/`--tool`/`--dry-run`/`--raw` global flags, `--url` required arg, full router → adapter → emit_summary pipeline.
- [docs] `SKILL.md` verbs table gains `open` row.
- [internal] `tests/verb_helpers.bats` (5) + `tests/browser-open.bats` (6) — full pipeline coverage via the playwright-cli stub.
```

- [ ] **Step 3.2: Commit + tag**

```bash
git add CHANGELOG.md
git commit -m "docs(changelog): Phase-3 part 2 — first real verb (browser-open) end-to-end"
git tag -a v0.3.1-phase-03-part-2-browser-open -m "Phase 3 part 2: browser-open verb end-to-end through stub"
git log --oneline -8
```

---

## Out of scope (explicitly deferred)

| Item | Where it lives next |
|---|---|
| `scripts/browser-snapshot.sh` (snapshot to YAML file with `eN` refs) | Phase 3 part 3 |
| `scripts/browser-click.sh` (click by `eN` ref) | Phase 3 part 3 |
| `scripts/browser-fill.sh` (fill, `--secret-stdin`) | Phase 3 part 3 |
| `scripts/browser-inspect.sh` (console + selector text) | Phase 3 part 3 |
| Session loading: wiring `--site`/`--as` to apply storageState before adapter dispatch | Phase 4 |
| Real Playwright binary integration (no stub) | Phase 4 (when `playwright-lib.sh` adapter lands as the node-bridge variant) |

The four sibling verbs (`snapshot`, `click`, `fill`, `inspect`) follow the **same template** as `browser-open.sh` — only the verb name and verb-specific argv differ. Once `browser-open` is proven against the stub, each follow-up verb is a copy + sed + edit. A successor plan (Phase 3 part 3) batches those four under one PR.

---

## Acceptance criteria

- [ ] `tests/verb_helpers.bats` passes (5 tests).
- [ ] `tests/browser-open.bats` passes (6 tests).
- [ ] Full `tests/run.sh` is green; new totals = previous + 11.
- [ ] `bash tests/lint.sh` exits 0 (no static, dynamic, or drift regressions).
- [ ] Manual run of `bash scripts/browser-open.sh --url https://example.com` (with `PLAYWRIGHT_CLI_BIN=tests/stubs/playwright-cli`) prints one streaming line + one summary line; summary has `verb`, `tool`, `why`, `status`, `url`, `duration_ms`.
- [ ] CI (GitHub Actions test workflow) green on macos-latest + ubuntu-latest.
