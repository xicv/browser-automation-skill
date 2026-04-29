# Browser-Automation-Skill — Phase 1: Foundation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Lay the foundation that every subsequent phase depends on: working `install.sh` (user mode), `~/.browser-skill/` skeleton with strict perms, `lib/common.sh` with paths/exit-codes/logging/summary-writer/home-resolver, a working `doctor` verb that exits green on a fresh box, `.gitignore` + opt-in pre-commit credential-leak hook, basic SKILL.md/README.md/SECURITY.md/CHANGELOG.md.

**Architecture:** Pure Bash following the proven mqtt-skill pattern (see `https://github.com/xicv/mqtt-skill`). All state under `$BROWSER_SKILL_HOME` (default `~/.browser-skill/`, resolved via walk-up). Strict file modes 0700/0600 with `umask 077`. Test-driven with `bats` against stub-binary fixtures. No network calls in any verb in this phase.

**Tech Stack:** bash ≥ 4, jq, python3, bats-core, shellcheck. No npm/cargo. The Node helper and underlying tool adapters arrive in later phases.

**Spec reference:** `docs/superpowers/specs/2026-04-27-browser-automation-skill-design.md` — sections 1, 2, 3.1, 3.4, 4.5, 5.1, 5.6, 6, 7, 8, 13.

**User-instruction reminders:**
- Don't commit code-formatting-only changes; lint only files we modify/create.
- Tests are mandatory at every step (TDD). 80%+ coverage target inherited from the user's `~/.claude/rules/testing.md`.
- Frequent commits — one logical change per commit.

---

## File structure (Phase 1 deliverables)

| Path | Responsibility | Created in task |
|---|---|---|
| `.gitignore` | Block credentials, sessions, captures, keys, env files | T14 |
| `.githooks/pre-commit` | Reject staged credential-shaped files/strings | T15 |
| `install.sh` | Preflight + state dir + symlink + opt-in hook + doctor | T10–T13 |
| `uninstall.sh` | Remove symlink; ask before deleting state | T13 |
| `README.md` | Install + first-5-min walkthrough (Phase-1 stub) | T17 |
| `SKILL.md` | Frontmatter + verb table (Phase-1 stub showing only `doctor`) | T17 |
| `SECURITY.md` | Threat model + disclosure path | T18 |
| `CHANGELOG.md` | Initial entry; tag conventions | T18 |
| `scripts/browser-doctor.sh` | Health check; prints resolved home; exits non-zero on issues | T7–T9 |
| `scripts/install-git-hooks.sh` | Wire `core.hooksPath` to `.githooks/` | T16 |
| `scripts/lib/common.sh` | Exit codes, paths, logging, summary writer, home resolver, with_timeout | T2–T6 |
| `tests/helpers.bash` | bats helpers, temp-home setup, asserts | T1 |
| `tests/run.sh` | Runs unit suite (bats files), reports timing | T1 |
| `tests/common.bats` | lib/common.sh tests | T2–T6 |
| `tests/install.bats` | install.sh tests | T10–T13 |
| `tests/doctor.bats` | doctor tests | T7–T9 |
| `tests/git-leak.bats` | Pre-commit hook security regression | T14–T15 |
| `.github/workflows/test.yml` | Unit job: ubuntu + macos | T19 |

Files **deferred** to later phases (do NOT create in Phase 1): site/session/credential libs, sanitize.sh, router.sh, all `lib/tool/*.sh` adapters, all interactive verbs, capture.sh, schema-migrate.sh, recipes/, examples/.

---

## Task 1 — Repo bootstrap

**Files:**
- Create: `.gitignore` (initial; full version in T14)
- Create: `tests/helpers.bash`
- Create: `tests/run.sh`
- Create: `README.md` (one-line stub; full version in T17)

- [ ] **Step 1: Initialize git and write the smoke test for the test harness**

```bash
cd ~/Projects/browser-automation-skill
git init -b main
```

Create `tests/helpers.bash`:

```bash
# tests/helpers.bash
# Common bats helpers. `load helpers` from any *.bats picks this up.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB_DIR="${REPO_ROOT}/scripts/lib"
SCRIPTS_DIR="${REPO_ROOT}/scripts"

# Per-test isolated home. Set in setup(); torn down in teardown().
setup_temp_home() {
  TEST_HOME="$(mktemp -d "${TMPDIR:-/tmp}/browser-skill-test.XXXXXX")"
  export BROWSER_SKILL_HOME="${TEST_HOME}/.browser-skill"
  export HOME="${TEST_HOME}"
}

teardown_temp_home() {
  if [ -n "${TEST_HOME:-}" ] && [ -d "${TEST_HOME}" ]; then
    rm -rf "${TEST_HOME}"
  fi
}

# Assert that a string is present in $output (bats sets $output on `run`).
assert_output_contains() {
  local needle="$1"
  if ! printf '%s' "${output}" | grep -qF -- "${needle}"; then
    printf 'expected output to contain:\n  %s\n--- actual output ---\n%s\n' "${needle}" "${output}" >&2
    return 1
  fi
}

assert_output_not_contains() {
  local needle="$1"
  if printf '%s' "${output}" | grep -qF -- "${needle}"; then
    printf 'expected output NOT to contain:\n  %s\n--- actual output ---\n%s\n' "${needle}" "${output}" >&2
    return 1
  fi
}

# Assert exit status (mirrors bats-assert's assert_failure but no extra dep).
assert_status() {
  local expected="$1"
  if [ "${status}" -ne "${expected}" ]; then
    printf 'expected status %d, got %d\n--- output ---\n%s\n' "${expected}" "${status}" "${output}" >&2
    return 1
  fi
}

# Portable fail() — bats-core ships one in newer versions, but not all distros.
# Define our own so tests run on Ubuntu's older bats package too.
if ! declare -F fail >/dev/null 2>&1; then
  fail() {
    printf 'fail: %s\n' "$*" >&2
    return 1
  }
fi
```

Create `tests/run.sh`:

```bash
#!/usr/bin/env bash
# tests/run.sh — runs the bats unit suite; nothing more (e2e + lint live elsewhere).
set -euo pipefail
IFS=$'\n\t'

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

if ! command -v bats >/dev/null 2>&1; then
  printf 'bats not installed. Install: brew install bats-core (macOS) or apt install bats (Linux)\n' >&2
  exit 20
fi

bats --tap tests/*.bats
```

Create initial minimal `.gitignore`:

```gitignore
# Editor/OS detritus (full credential rules added in Task 14)
.DS_Store
*.swp
*.swo
*~
.idea/
.vscode/
*.log
node_modules/
```

Create one-line `README.md` (replaced in T17):

```markdown
# browser-automation-skill

(Phase 1 in progress — see `docs/superpowers/plans/2026-04-27-browser-automation-skill-phase-01-foundation.md`.)
```

- [ ] **Step 2: Verify bats is installed and the harness file is well-formed**

Run:
```bash
command -v bats || echo "MISSING — install bats-core before continuing"
chmod +x tests/run.sh
bash -n tests/helpers.bash      # syntax check; exit 0 expected
bash -n tests/run.sh
```
Expected: `bash -n` exits 0 for both; `command -v bats` prints a path.

- [ ] **Step 3: Commit**

```bash
git add .gitignore tests/helpers.bash tests/run.sh README.md
git commit -m "chore: initialize repo with bats harness + helpers"
```

---

## Task 2 — `lib/common.sh`: exit codes (constants)

**Files:**
- Create: `scripts/lib/common.sh`
- Create: `tests/common.bats`

- [ ] **Step 1: Write the failing test**

```bash
# tests/common.bats
load helpers

@test "common.sh: exit codes are exported as readonly constants" {
  run bash -c "source '${LIB_DIR}/common.sh'; printf '%s\n' \"\${EXIT_OK}\" \"\${EXIT_USAGE_ERROR}\" \"\${EXIT_PREFLIGHT_FAILED}\" \"\${EXIT_TOOL_MISSING}\" \"\${EXIT_NETWORK_ERROR}\" \"\${EXIT_CAPTURE_WRITE_FAILED}\""
  assert_status 0
  [ "${lines[0]}" = "0" ]
  [ "${lines[1]}" = "2" ]
  [ "${lines[2]}" = "20" ]
  [ "${lines[3]}" = "21" ]
  [ "${lines[4]}" = "30" ]
  [ "${lines[5]}" = "31" ]
}

@test "common.sh: EXIT_OK is readonly (cannot be reassigned)" {
  run bash -c "source '${LIB_DIR}/common.sh'; EXIT_OK=99"
  assert_status 1
  assert_output_contains "readonly"
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bats tests/common.bats`
Expected: FAIL — `scripts/lib/common.sh: No such file or directory`

- [ ] **Step 3: Write minimal implementation**

```bash
# scripts/lib/common.sh
# Shared helpers for browser-automation-skill. Source this file from every
# verb script and lib module. Mirrors mqtt-skill's lib/common.sh pattern.

# Guard against double-sourcing.
[ -n "${BROWSER_SKILL_COMMON_LOADED:-}" ] && return 0
readonly BROWSER_SKILL_COMMON_LOADED=1

# Restrictive umask for everything we create.
umask 077

# --- Exit code table (matches docs/superpowers/specs §5.1) ---
readonly EXIT_OK=0
readonly EXIT_GENERIC_ERROR=1
readonly EXIT_USAGE_ERROR=2
readonly EXIT_EMPTY_RESULT=11
readonly EXIT_PARTIAL_RESULT=12
readonly EXIT_ASSERTION_FAILED=13
readonly EXIT_PREFLIGHT_FAILED=20
readonly EXIT_TOOL_MISSING=21
readonly EXIT_SESSION_EXPIRED=22
readonly EXIT_SITE_NOT_FOUND=23
readonly EXIT_CREDENTIAL_AMBIGUOUS=24
readonly EXIT_AUTH_INTERACTIVE_REQUIRED=25
readonly EXIT_KEYCHAIN_LOCKED=26
readonly EXIT_TTY_REQUIRED=27
readonly EXIT_BLOCKLIST_REJECTED=28
readonly EXIT_NETWORK_ERROR=30
readonly EXIT_CAPTURE_WRITE_FAILED=31
readonly EXIT_RETENTION_BLOCKED=32
readonly EXIT_SCHEMA_MIGRATION_REQUIRED=33
readonly EXIT_TOOL_UNSUPPORTED_OP=41
readonly EXIT_TOOL_CRASHED=42
readonly EXIT_TOOL_TIMEOUT=43
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bats tests/common.bats`
Expected: PASS, both tests green.

- [ ] **Step 5: Commit**

```bash
git add scripts/lib/common.sh tests/common.bats
git commit -m "feat(lib): add exit-code constants in common.sh"
```

---

## Task 3 — `lib/common.sh`: logging primitives (`ok`, `warn`, `die`)

**Files:**
- Modify: `scripts/lib/common.sh` (append section)
- Modify: `tests/common.bats` (append tests)

- [ ] **Step 1: Write the failing test**

Append to `tests/common.bats`:

```bash
@test "common.sh: ok() prints to stderr with green prefix when TTY" {
  run bash -c "source '${LIB_DIR}/common.sh'; FORCE_COLOR=1 ok 'hello'"
  assert_status 0
  assert_output_contains "hello"
}

@test "common.sh: warn() prints to stderr with yellow prefix" {
  run bash -c "source '${LIB_DIR}/common.sh'; FORCE_COLOR=0 warn 'careful' 2>&1"
  assert_status 0
  assert_output_contains "careful"
  assert_output_contains "warn:"
}

@test "common.sh: die() prints to stderr and exits with given code" {
  run bash -c "source '${LIB_DIR}/common.sh'; die 23 'site not found' || echo \"exit=\$?\""
  assert_output_contains "site not found"
  assert_output_contains "exit=23"
}

@test "common.sh: NO_COLOR=1 suppresses ANSI escapes" {
  run bash -c "source '${LIB_DIR}/common.sh'; NO_COLOR=1 ok 'plain' 2>&1"
  assert_output_not_contains "$(printf '\033')"
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bats tests/common.bats`
Expected: FAIL — `ok: command not found`.

- [ ] **Step 3: Write minimal implementation**

Append to `scripts/lib/common.sh`:

```bash
# --- Logging ---
# All logging goes to stderr. stdout is reserved for streaming JSON + summary.
# Honors NO_COLOR=1 (https://no-color.org) and FORCE_COLOR=1.

_browser_skill_color() {
  if [ "${NO_COLOR:-0}" = "1" ]; then
    printf ''
    return
  fi
  if [ "${FORCE_COLOR:-0}" = "1" ] || [ -t 2 ]; then
    printf '%s' "$1"
    return
  fi
  printf ''
}

ok() {
  local prefix
  prefix="$(_browser_skill_color $'\033[0;32m')ok:$(_browser_skill_color $'\033[0m')"
  printf '%s %s\n' "${prefix}" "$*" >&2
}

warn() {
  local prefix
  prefix="$(_browser_skill_color $'\033[0;33m')warn:$(_browser_skill_color $'\033[0m')"
  printf '%s %s\n' "${prefix}" "$*" >&2
}

# die EXIT_CODE MESSAGE...
# Prints to stderr in red, exits with the given code.
die() {
  local code="$1"
  shift
  local prefix
  prefix="$(_browser_skill_color $'\033[0;31m')error:$(_browser_skill_color $'\033[0m')"
  printf '%s %s\n' "${prefix}" "$*" >&2
  exit "${code}"
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bats tests/common.bats`
Expected: all 6 tests pass (2 from T2 + 4 here).

- [ ] **Step 5: Commit**

```bash
git add scripts/lib/common.sh tests/common.bats
git commit -m "feat(lib): add ok/warn/die logging primitives"
```

---

## Task 4 — `lib/common.sh`: `BROWSER_SKILL_HOME` walk-up resolver

**Files:**
- Modify: `scripts/lib/common.sh`
- Modify: `tests/common.bats`

- [ ] **Step 1: Write the failing test**

Append to `tests/common.bats`:

```bash
@test "common.sh: resolve_browser_skill_home — explicit env var wins" {
  setup_temp_home
  BROWSER_SKILL_HOME="/tmp/explicit-override-xyz" \
    run bash -c "source '${LIB_DIR}/common.sh'; resolve_browser_skill_home"
  teardown_temp_home
  assert_status 0
  [ "${output}" = "/tmp/explicit-override-xyz" ]
}

@test "common.sh: resolve_browser_skill_home — walks up to find .browser-skill/" {
  setup_temp_home
  mkdir -p "${TEST_HOME}/proj/sub/deeper"
  mkdir "${TEST_HOME}/proj/.browser-skill"
  unset BROWSER_SKILL_HOME
  run bash -c "cd '${TEST_HOME}/proj/sub/deeper'; source '${LIB_DIR}/common.sh'; resolve_browser_skill_home"
  teardown_temp_home
  assert_status 0
  assert_output_contains "/proj/.browser-skill"
}

@test "common.sh: resolve_browser_skill_home — falls back to user-level" {
  setup_temp_home
  unset BROWSER_SKILL_HOME
  run bash -c "cd '${TEST_HOME}'; source '${LIB_DIR}/common.sh'; resolve_browser_skill_home"
  teardown_temp_home
  assert_status 0
  [ "${output}" = "${HOME}/.browser-skill" ]
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bats tests/common.bats`
Expected: FAIL — `resolve_browser_skill_home: command not found`.

- [ ] **Step 3: Write minimal implementation**

Append to `scripts/lib/common.sh`:

```bash
# --- Path resolution ---
# resolve_browser_skill_home echoes the canonical state-home path.
# Resolution order:
#   1. $BROWSER_SKILL_HOME (explicit override)
#   2. Walk up from $PWD looking for .browser-skill/ (project-scoped mode)
#   3. ~/.browser-skill/ (user-level fallback)
resolve_browser_skill_home() {
  if [ -n "${BROWSER_SKILL_HOME:-}" ]; then
    printf '%s\n' "${BROWSER_SKILL_HOME}"
    return 0
  fi
  local dir="${PWD}"
  while [ "${dir}" != "/" ]; do
    if [ -d "${dir}/.browser-skill" ]; then
      printf '%s\n' "${dir}/.browser-skill"
      return 0
    fi
    dir="$(dirname "${dir}")"
  done
  printf '%s\n' "${HOME}/.browser-skill"
}

# Convenience: export the resolved home + canonical subdirs once per invocation.
# Verbs source common.sh and call this immediately.
init_paths() {
  BROWSER_SKILL_HOME="$(resolve_browser_skill_home)"
  export BROWSER_SKILL_HOME
  export SITES_DIR="${BROWSER_SKILL_HOME}/sites"
  export SESSIONS_DIR="${BROWSER_SKILL_HOME}/sessions"
  export CREDENTIALS_DIR="${BROWSER_SKILL_HOME}/credentials"
  export CAPTURES_DIR="${BROWSER_SKILL_HOME}/captures"
  export FLOWS_DIR="${BROWSER_SKILL_HOME}/flows"
  export CURRENT_FILE="${BROWSER_SKILL_HOME}/current"
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bats tests/common.bats`
Expected: all 9 tests green.

- [ ] **Step 5: Commit**

```bash
git add scripts/lib/common.sh tests/common.bats
git commit -m "feat(lib): add BROWSER_SKILL_HOME walk-up resolver"
```

---

## Task 5 — `lib/common.sh`: `summary_json` writer

**Files:**
- Modify: `scripts/lib/common.sh`
- Modify: `tests/common.bats`

- [ ] **Step 1: Write the failing test**

Append to `tests/common.bats`:

```bash
@test "common.sh: summary_json emits valid single-line JSON with required keys" {
  run bash -c "source '${LIB_DIR}/common.sh'; summary_json verb=doctor tool=none why=health-check status=ok duration_ms=42"
  assert_status 0
  # Must be a single line.
  [ "${#lines[@]}" -eq 1 ]
  # Must be valid JSON.
  printf '%s' "${output}" | jq -e . >/dev/null
  # Must have all keys.
  [ "$(printf '%s' "${output}" | jq -r .verb)" = "doctor" ]
  [ "$(printf '%s' "${output}" | jq -r .tool)" = "none" ]
  [ "$(printf '%s' "${output}" | jq -r .status)" = "ok" ]
  [ "$(printf '%s' "${output}" | jq -r .duration_ms)" = "42" ]
}

@test "common.sh: summary_json escapes embedded quotes in values" {
  run bash -c "source '${LIB_DIR}/common.sh'; summary_json verb=test why='quote\"inside' status=ok"
  assert_status 0
  printf '%s' "${output}" | jq -e . >/dev/null
  [ "$(printf '%s' "${output}" | jq -r .why)" = 'quote"inside' ]
}

@test "common.sh: summary_json rejects key without =value" {
  run bash -c "source '${LIB_DIR}/common.sh'; summary_json verb=doctor lonely_key status=ok"
  assert_status "${EXIT_USAGE_ERROR:-2}"
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bats tests/common.bats`
Expected: FAIL — `summary_json: command not found`.

- [ ] **Step 3: Write minimal implementation**

Append to `scripts/lib/common.sh`:

```bash
# --- JSON summary writer ---
# Usage: summary_json key=value key=value ...
# Emits one valid JSON object per line on stdout. Uses jq for safe escaping —
# never let bash interpolation construct JSON strings (quote bugs = leaks).
# Numeric values (duration_ms, console_errors, etc.) stay as JSON numbers.
summary_json() {
  if [ "$#" -eq 0 ]; then
    die "${EXIT_USAGE_ERROR}" "summary_json: no key=value pairs supplied"
  fi

  local args=()
  local pair key value
  for pair in "$@"; do
    case "${pair}" in
      *=*)
        key="${pair%%=*}"
        value="${pair#*=}"
        # Numeric? Pass as --argjson; else --arg (string).
        if [[ "${value}" =~ ^-?[0-9]+(\.[0-9]+)?$ ]]; then
          args+=(--argjson "${key}" "${value}")
        elif [ "${value}" = "true" ] || [ "${value}" = "false" ] || [ "${value}" = "null" ]; then
          args+=(--argjson "${key}" "${value}")
        else
          args+=(--arg "${key}" "${value}")
        fi
        ;;
      *)
        die "${EXIT_USAGE_ERROR}" "summary_json: bad pair '${pair}' (expected key=value)"
        ;;
    esac
  done

  # Build the object dynamically: jq -n accepts our --arg/--argjson names.
  local jq_filter='. = {}'
  for pair in "$@"; do
    key="${pair%%=*}"
    jq_filter="${jq_filter} | .${key} = \$${key}"
  done
  jq -nc "${args[@]}" "${jq_filter}"
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bats tests/common.bats`
Expected: all 12 tests green.

- [ ] **Step 5: Commit**

```bash
git add scripts/lib/common.sh tests/common.bats
git commit -m "feat(lib): add summary_json writer (jq-based, escape-safe)"
```

---

## Task 6 — `lib/common.sh`: `with_timeout` wrapper

**Files:**
- Modify: `scripts/lib/common.sh`
- Modify: `tests/common.bats`

- [ ] **Step 1: Write the failing test**

Append to `tests/common.bats`:

```bash
@test "common.sh: with_timeout returns command's exit code on success" {
  run bash -c "source '${LIB_DIR}/common.sh'; with_timeout 5 true"
  assert_status 0
}

@test "common.sh: with_timeout kills slow command and returns 43 (TOOL_TIMEOUT)" {
  run bash -c "source '${LIB_DIR}/common.sh'; with_timeout 1 sleep 10"
  assert_status "${EXIT_TOOL_TIMEOUT:-43}"
}

@test "common.sh: with_timeout passes args through correctly" {
  run bash -c "source '${LIB_DIR}/common.sh'; with_timeout 5 printf '%s|%s|%s\n' a b c"
  assert_status 0
  [ "${output}" = "a|b|c" ]
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bats tests/common.bats`
Expected: FAIL — `with_timeout: command not found`.

- [ ] **Step 3: Write minimal implementation**

Append to `scripts/lib/common.sh`:

```bash
# --- Timeout wrapper ---
# with_timeout SECONDS COMMAND ARGS...
# Wraps `timeout` (GNU) or `gtimeout` (macOS coreutils) or a hand-rolled fallback.
# On timeout: kills the child, returns EXIT_TOOL_TIMEOUT (43).
# On success: returns the child's exit code.
with_timeout() {
  local secs="$1"
  shift
  local rc=0

  if command -v timeout >/dev/null 2>&1; then
    timeout --preserve-status -k 2 "${secs}" "$@" || rc=$?
  elif command -v gtimeout >/dev/null 2>&1; then
    gtimeout --preserve-status -k 2 "${secs}" "$@" || rc=$?
  else
    # Fallback: spawn child + watcher in subshell.
    "$@" &
    local child=$!
    ( sleep "${secs}"; kill -TERM "${child}" 2>/dev/null; sleep 2; kill -KILL "${child}" 2>/dev/null ) &
    local watcher=$!
    wait "${child}" 2>/dev/null || rc=$?
    kill "${watcher}" 2>/dev/null || true
  fi

  # 124 = GNU timeout's "timed out" code; map to our 43.
  if [ "${rc}" = "124" ] || [ "${rc}" = "137" ]; then
    return "${EXIT_TOOL_TIMEOUT}"
  fi
  return "${rc}"
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bats tests/common.bats`
Expected: all 15 tests green. Test runs in <2 s.

- [ ] **Step 5: Commit**

```bash
git add scripts/lib/common.sh tests/common.bats
git commit -m "feat(lib): add with_timeout wrapper (GNU/coreutils/fallback)"
```

---

## Task 7 — `browser-doctor.sh`: command + version checks

**Files:**
- Create: `scripts/browser-doctor.sh`
- Create: `tests/doctor.bats`

- [ ] **Step 1: Write the failing test**

```bash
# tests/doctor.bats
load helpers

@test "doctor: prints resolved BROWSER_SKILL_HOME at top" {
  setup_temp_home
  mkdir -p "${BROWSER_SKILL_HOME}"
  chmod 700 "${BROWSER_SKILL_HOME}"
  run bash "${SCRIPTS_DIR}/browser-doctor.sh"
  teardown_temp_home
  assert_output_contains "${BROWSER_SKILL_HOME}"
}

@test "doctor: passes when bash, jq, python3 are present" {
  setup_temp_home
  mkdir -p "${BROWSER_SKILL_HOME}"
  chmod 700 "${BROWSER_SKILL_HOME}"
  run bash "${SCRIPTS_DIR}/browser-doctor.sh"
  teardown_temp_home
  assert_status 0
  assert_output_contains "all checks passed"
}

@test "doctor: emits a final JSON summary line on stdout" {
  setup_temp_home
  mkdir -p "${BROWSER_SKILL_HOME}"
  chmod 700 "${BROWSER_SKILL_HOME}"
  run bash "${SCRIPTS_DIR}/browser-doctor.sh"
  teardown_temp_home
  assert_status 0
  # Find the final line that's valid JSON
  local last_json
  last_json="$(printf '%s\n' "${lines[@]}" | tail -n 1)"
  printf '%s' "${last_json}" | jq -e '.verb == "doctor"' >/dev/null
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bats tests/doctor.bats`
Expected: FAIL — `scripts/browser-doctor.sh: No such file or directory`.

- [ ] **Step 3: Write minimal implementation**

```bash
# scripts/browser-doctor.sh
#!/usr/bin/env bash
# browser-doctor — health check, exits non-zero on issues. Zero network calls.
set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/common.sh"
init_paths

started_at_ms="$(date +%s%3N 2>/dev/null || python3 -c 'import time; print(int(time.time()*1000))')"
problems=0

check_cmd() {
  local cmd="$1" hint="$2"
  if command -v "${cmd}" >/dev/null 2>&1; then
    ok "${cmd} found: $(command -v "${cmd}")"
  else
    warn "${cmd} NOT FOUND"
    warn "  remediation: ${hint}"
    problems=$((problems + 1))
  fi
}

check_bash_version() {
  local major="${BASH_VERSINFO[0]:-0}"
  if [ "${major}" -ge 4 ]; then
    ok "bash version: ${BASH_VERSION}"
  else
    warn "bash ${BASH_VERSION} is too old (need >= 4)"
    warn "  remediation: brew install bash"
    problems=$((problems + 1))
  fi
}

ok "browser-skill home: ${BROWSER_SKILL_HOME}"
ok "browser-skill doctor"

check_cmd jq "brew install jq (macOS) or apt install jq (Debian)"
check_cmd python3 "brew install python3 (macOS) or apt install python3"
check_bash_version
# Tools below are recommended but not required in Phase 1; later phases will
# elevate these to required and add version-pinning logic.
check_cmd node "(optional in phase 1) brew install node (>=20)"

duration_ms=$(( $(date +%s%3N 2>/dev/null || python3 -c 'import time; print(int(time.time()*1000))') - started_at_ms ))

if [ "${problems}" -eq 0 ]; then
  ok "all checks passed"
  summary_json verb=doctor tool=none why=health-check status=ok problems=0 duration_ms="${duration_ms}"
  exit "${EXIT_OK}"
else
  warn "${problems} problem(s) found"
  summary_json verb=doctor tool=none why=health-check status=error problems="${problems}" duration_ms="${duration_ms}"
  exit "${EXIT_PREFLIGHT_FAILED}"
fi
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bats tests/doctor.bats`
Expected: all 3 tests green.

- [ ] **Step 5: Commit**

```bash
git add scripts/browser-doctor.sh tests/doctor.bats
git commit -m "feat(doctor): add command + bash version checks"
```

---

## Task 8 — `browser-doctor.sh`: home directory mode check

**Files:**
- Modify: `scripts/browser-doctor.sh`
- Modify: `tests/doctor.bats`

- [ ] **Step 1: Write the failing test**

Append to `tests/doctor.bats`:

```bash
@test "doctor: warns when ~/.browser-skill missing" {
  setup_temp_home
  # Don't create BROWSER_SKILL_HOME — should be flagged.
  run bash "${SCRIPTS_DIR}/browser-doctor.sh"
  teardown_temp_home
  assert_status "${EXIT_PREFLIGHT_FAILED:-20}"
  assert_output_contains "does not exist"
}

@test "doctor: warns when ~/.browser-skill mode is not 0700" {
  setup_temp_home
  mkdir -p "${BROWSER_SKILL_HOME}"
  chmod 0755 "${BROWSER_SKILL_HOME}"
  run bash "${SCRIPTS_DIR}/browser-doctor.sh"
  teardown_temp_home
  assert_status "${EXIT_PREFLIGHT_FAILED:-20}"
  assert_output_contains "mode 755"
  assert_output_contains "expected 700"
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bats tests/doctor.bats`
Expected: FAIL — doctor doesn't check the home dir yet.

- [ ] **Step 3: Modify `browser-doctor.sh`**

Replace the section after `check_bash_version` and before `check_cmd node` with:

```bash
check_home() {
  if [ ! -d "${BROWSER_SKILL_HOME}" ]; then
    warn "${BROWSER_SKILL_HOME} does not exist"
    warn "  remediation: run ./install.sh from the repo root"
    problems=$((problems + 1))
    return 0
  fi
  local mode
  mode="$(stat -f '%Lp' "${BROWSER_SKILL_HOME}" 2>/dev/null || stat -c '%a' "${BROWSER_SKILL_HOME}" 2>/dev/null || echo "?")"
  if [ "${mode}" != "700" ]; then
    warn "${BROWSER_SKILL_HOME} has mode ${mode}, expected 700"
    warn "  remediation: chmod 700 ${BROWSER_SKILL_HOME}"
    problems=$((problems + 1))
  else
    ok "${BROWSER_SKILL_HOME} mode 700"
  fi
}

check_bash_version
check_home
check_cmd node "(optional in phase 1) brew install node (>=20)"
```

(Remove the old `check_cmd node` line that was above.)

- [ ] **Step 4: Run test to verify it passes**

Run: `bats tests/doctor.bats`
Expected: 5 tests green.

- [ ] **Step 5: Commit**

```bash
git add scripts/browser-doctor.sh tests/doctor.bats
git commit -m "feat(doctor): check ~/.browser-skill exists with mode 0700"
```

---

## Task 9 — `browser-doctor.sh`: disk encryption advisory check

**Files:**
- Modify: `scripts/browser-doctor.sh`
- Modify: `tests/doctor.bats`

- [ ] **Step 1: Write the failing test**

Append to `tests/doctor.bats`:

```bash
@test "doctor: prints disk-encryption status (advisory, never fails)" {
  setup_temp_home
  mkdir -p "${BROWSER_SKILL_HOME}"
  chmod 700 "${BROWSER_SKILL_HOME}"
  run bash "${SCRIPTS_DIR}/browser-doctor.sh"
  teardown_temp_home
  # disk-encryption status is advisory: doctor MUST mention it but MUST NOT fail on it.
  assert_status 0
  assert_output_contains "disk encryption"
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bats tests/doctor.bats`
Expected: FAIL — output doesn't mention "disk encryption".

- [ ] **Step 3: Modify `browser-doctor.sh`**

Append before the final `if [ "${problems}" ... ]` block:

```bash
check_disk_encryption() {
  case "$(uname -s)" in
    Darwin)
      if command -v fdesetup >/dev/null 2>&1; then
        local status
        status="$(fdesetup status 2>/dev/null || true)"
        case "${status}" in
          *"FileVault is On"*)  ok "disk encryption: FileVault on" ;;
          *"FileVault is Off"*) warn "disk encryption: FileVault OFF (advisory — 0600 modes are paper without disk encryption)" ;;
          *)                    warn "disk encryption: status unknown (fdesetup said: ${status:-empty})" ;;
        esac
      else
        warn "disk encryption: fdesetup not found (cannot verify)"
      fi
      ;;
    Linux)
      if command -v lsblk >/dev/null 2>&1 && lsblk -o NAME,FSTYPE 2>/dev/null | grep -q crypto_LUKS; then
        ok "disk encryption: LUKS-backed volume detected"
      else
        warn "disk encryption: no LUKS volume found (advisory)"
      fi
      ;;
    *)
      warn "disk encryption: unknown OS — please verify manually"
      ;;
  esac
}

check_disk_encryption
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bats tests/doctor.bats`
Expected: 6 tests green.

- [ ] **Step 5: Commit**

```bash
git add scripts/browser-doctor.sh tests/doctor.bats
git commit -m "feat(doctor): add advisory disk-encryption check (FileVault/LUKS)"
```

---

## Task 10 — `install.sh`: arg parsing + preflight

**Files:**
- Create: `install.sh`
- Create: `tests/install.bats`

- [ ] **Step 1: Write the failing test**

```bash
# tests/install.bats
load helpers

@test "install.sh: --help prints usage and exits 0" {
  run bash "${REPO_ROOT}/install.sh" --help
  assert_status 0
  assert_output_contains "Usage:"
  assert_output_contains "--with-hooks"
  assert_output_contains "--dry-run"
}

@test "install.sh: --dry-run does not create state dir" {
  setup_temp_home
  run bash "${REPO_ROOT}/install.sh" --dry-run
  local rc=$?
  local existed=0
  [ -d "${BROWSER_SKILL_HOME}" ] && existed=1
  teardown_temp_home
  [ "${existed}" -eq 0 ] || fail "expected --dry-run to NOT create state dir"
  [ "${rc}" -eq 0 ]
}

@test "install.sh: preflight fails (exit 20) when jq missing" {
  setup_temp_home
  # Stub PATH so jq isn't found; bash + python3 still are.
  local stub_dir="${TEST_HOME}/empty-bin"
  mkdir -p "${stub_dir}"
  PATH="${stub_dir}:/usr/bin:/bin" run bash "${REPO_ROOT}/install.sh" --dry-run
  teardown_temp_home
  assert_status "${EXIT_PREFLIGHT_FAILED:-20}"
  assert_output_contains "jq"
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bats tests/install.bats`
Expected: FAIL — `install.sh: No such file or directory`.

- [ ] **Step 3: Write minimal implementation**

```bash
# install.sh
#!/usr/bin/env bash
# install.sh — preflight + state dir + symlink + (opt) git hooks. Idempotent.
set -euo pipefail
IFS=$'\n\t'

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/common.sh
# shellcheck disable=SC1091
source "${REPO_ROOT}/scripts/lib/common.sh"

WITH_HOOKS=0
DRY_RUN=0
MODE=user   # phase-1 only supports --user; --project arrives in a later phase

usage() {
  cat <<'USAGE'
Usage: ./install.sh [options]

  --user           (default) symlink to ~/.claude/skills/, state at ~/.browser-skill/
  --with-hooks     enable .githooks/pre-commit credential-leak blocker
  --dry-run        print what would happen, change nothing
  -h, --help       this message
USAGE
}

for arg in "$@"; do
  case "${arg}" in
    --user)        MODE=user ;;
    --with-hooks)  WITH_HOOKS=1 ;;
    --dry-run)     DRY_RUN=1 ;;
    -h|--help)     usage; exit 0 ;;
    *)             warn "ignoring unknown arg: ${arg}" ;;
  esac
done

preflight() {
  command -v jq >/dev/null 2>&1 || die "${EXIT_PREFLIGHT_FAILED}" "jq required but not found. Remediation: brew install jq (macOS) or apt install jq (Debian)"
  ok "jq found: $(command -v jq)"
  command -v python3 >/dev/null 2>&1 || die "${EXIT_PREFLIGHT_FAILED}" "python3 required but not found"
  ok "python3 found: $(command -v python3)"
  local major="${BASH_VERSINFO[0]:-0}"
  [ "${major}" -ge 4 ] || die "${EXIT_PREFLIGHT_FAILED}" "bash >= 4 required (have ${BASH_VERSION}). Remediation: brew install bash"
  ok "bash version: ${BASH_VERSION}"
}

ok "browser-automation-skill installer (mode=${MODE} dry-run=${DRY_RUN})"
preflight

if [ "${DRY_RUN}" = "1" ]; then
  ok "dry-run: would create ~/.browser-skill/ and symlink to ~/.claude/skills/browser-automation-skill"
  exit 0
fi

# State dir + symlink + hooks come in tasks 11–13.
ok "preflight passed (state dir/symlink/hooks land in subsequent tasks)"
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bats tests/install.bats`
Expected: 3 tests green. (Note: the dry-run test will pass because no state dir is created yet.)

- [ ] **Step 5: Commit**

```bash
chmod +x install.sh
git add install.sh tests/install.bats
git commit -m "feat(install): preflight + arg parsing + --dry-run"
```

---

## Task 11 — `install.sh`: create state directory tree

**Files:**
- Modify: `install.sh`
- Modify: `tests/install.bats`

- [ ] **Step 1: Write the failing test**

Append to `tests/install.bats`:

```bash
@test "install.sh: creates BROWSER_SKILL_HOME with subdirs at mode 0700" {
  setup_temp_home
  run bash "${REPO_ROOT}/install.sh" --user
  local rc=$?
  if [ "${rc}" -ne 0 ]; then
    teardown_temp_home
    fail "install failed (exit ${rc}): ${output}"
  fi
  for d in "" sites sessions credentials captures flows; do
    [ -d "${BROWSER_SKILL_HOME}/${d}" ] || { teardown_temp_home; fail "expected dir: ${BROWSER_SKILL_HOME}/${d}"; }
  done
  local mode
  mode="$(stat -f '%Lp' "${BROWSER_SKILL_HOME}" 2>/dev/null || stat -c '%a' "${BROWSER_SKILL_HOME}" 2>/dev/null)"
  teardown_temp_home
  [ "${mode}" = "700" ]
}

@test "install.sh: writes version marker file" {
  setup_temp_home
  run bash "${REPO_ROOT}/install.sh" --user
  [ "$(cat "${BROWSER_SKILL_HOME}/version")" = "1" ]
  teardown_temp_home
}

@test "install.sh: writes defense-in-depth .gitignore inside state dir" {
  setup_temp_home
  run bash "${REPO_ROOT}/install.sh" --user
  [ "$(cat "${BROWSER_SKILL_HOME}/.gitignore")" = "*" ]
  teardown_temp_home
}

@test "install.sh: idempotent (second run does not fail or wipe)" {
  setup_temp_home
  bash "${REPO_ROOT}/install.sh" --user >/dev/null
  echo '{"name":"prod"}' > "${BROWSER_SKILL_HOME}/sites/prod.json"
  run bash "${REPO_ROOT}/install.sh" --user
  assert_status 0
  [ -f "${BROWSER_SKILL_HOME}/sites/prod.json" ]
  teardown_temp_home
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bats tests/install.bats`
Expected: FAIL — install.sh doesn't create dirs yet.

- [ ] **Step 3: Modify `install.sh`**

Replace the bottom (after the `--dry-run` early exit) with:

```bash
init_paths

create_state_dir() {
  mkdir -p \
    "${BROWSER_SKILL_HOME}" \
    "${SITES_DIR}" \
    "${SESSIONS_DIR}" \
    "${CREDENTIALS_DIR}" \
    "${CAPTURES_DIR}" \
    "${FLOWS_DIR}"
  chmod 700 \
    "${BROWSER_SKILL_HOME}" \
    "${SITES_DIR}" \
    "${SESSIONS_DIR}" \
    "${CREDENTIALS_DIR}" \
    "${CAPTURES_DIR}" \
    "${FLOWS_DIR}"
  # Defense in depth: if this dir ever ends up inside a git repo, ignore it.
  printf '*\n' > "${BROWSER_SKILL_HOME}/.gitignore"
  # Schema version marker.
  printf '1\n' > "${BROWSER_SKILL_HOME}/version"
  ok "state dir ready: ${BROWSER_SKILL_HOME}"
}

create_state_dir
```

(Remove the placeholder `ok "preflight passed (state dir/symlink/hooks land in subsequent tasks)"` line.)

- [ ] **Step 4: Run test to verify it passes**

Run: `bats tests/install.bats`
Expected: all 7 install tests green.

- [ ] **Step 5: Commit**

```bash
git add install.sh tests/install.bats
git commit -m "feat(install): create state dir tree with mode 0700 + version marker"
```

---

## Task 12 — `install.sh`: symlink + uninstall.sh

**Files:**
- Modify: `install.sh`
- Create: `uninstall.sh`
- Modify: `tests/install.bats`
- Create: `tests/uninstall.bats`

- [ ] **Step 1: Write the failing test**

Append to `tests/install.bats`:

```bash
@test "install.sh: creates symlink ~/.claude/skills/browser-automation-skill -> repo" {
  setup_temp_home
  run bash "${REPO_ROOT}/install.sh" --user
  assert_status 0
  local link="${HOME}/.claude/skills/browser-automation-skill"
  [ -L "${link}" ]
  [ "$(readlink "${link}")" = "${REPO_ROOT}" ]
  teardown_temp_home
}

@test "install.sh: refuses to overwrite a non-symlink at the target path" {
  setup_temp_home
  mkdir -p "${HOME}/.claude/skills"
  echo "hand-written content" > "${HOME}/.claude/skills/browser-automation-skill"
  run bash "${REPO_ROOT}/install.sh" --user
  assert_status "${EXIT_PREFLIGHT_FAILED:-20}"
  assert_output_contains "not a symlink"
  teardown_temp_home
}
```

Create `tests/uninstall.bats`:

```bash
load helpers

@test "uninstall.sh: --help prints usage" {
  run bash "${REPO_ROOT}/uninstall.sh" --help
  assert_status 0
  assert_output_contains "Usage:"
}

@test "uninstall.sh: removes symlink, keeps state by default" {
  setup_temp_home
  bash "${REPO_ROOT}/install.sh" --user >/dev/null
  run bash "${REPO_ROOT}/uninstall.sh" --keep-state
  assert_status 0
  [ ! -L "${HOME}/.claude/skills/browser-automation-skill" ]
  [ -d "${BROWSER_SKILL_HOME}" ]
  teardown_temp_home
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bats tests/install.bats tests/uninstall.bats`
Expected: FAIL — symlink not created; `uninstall.sh: No such file`.

- [ ] **Step 3: Modify `install.sh` and create `uninstall.sh`**

Append to `install.sh` (after `create_state_dir`):

```bash
install_symlink() {
  local skills_dir="${HOME}/.claude/skills"
  local link="${skills_dir}/browser-automation-skill"
  mkdir -p "${skills_dir}"

  if [ -L "${link}" ]; then
    ln -sfn "${REPO_ROOT}" "${link}"
    ok "updated existing symlink: ${link} -> ${REPO_ROOT}"
  elif [ -e "${link}" ]; then
    die "${EXIT_PREFLIGHT_FAILED}" "${link} exists and is not a symlink; refusing to overwrite. Move it aside and re-run."
  else
    ln -s "${REPO_ROOT}" "${link}"
    ok "created symlink: ${link} -> ${REPO_ROOT}"
  fi
}

install_symlink
ok "install complete; next steps:"
ok "  1. /browser doctor       (verify in Claude Code)"
ok "  2. /browser add-site     (register your first site, lands in phase 2)"
```

Create `uninstall.sh`:

```bash
#!/usr/bin/env bash
# uninstall.sh — remove the ~/.claude/skills symlink. Optionally remove state.
set -euo pipefail
IFS=$'\n\t'

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/common.sh
# shellcheck disable=SC1091
source "${REPO_ROOT}/scripts/lib/common.sh"

KEEP_STATE=0
DRY_RUN=0

usage() {
  cat <<'USAGE'
Usage: ./uninstall.sh [options]

  --keep-state     don't ask about deleting ~/.browser-skill/ (the default is to ask)
  --dry-run        print what would happen, change nothing
  -h, --help
USAGE
}

for arg in "$@"; do
  case "${arg}" in
    --keep-state) KEEP_STATE=1 ;;
    --dry-run)    DRY_RUN=1 ;;
    -h|--help)    usage; exit 0 ;;
    *)            warn "ignoring unknown arg: ${arg}" ;;
  esac
done

init_paths

link="${HOME}/.claude/skills/browser-automation-skill"
if [ -L "${link}" ]; then
  if [ "${DRY_RUN}" = "1" ]; then
    ok "dry-run: would remove symlink ${link}"
  else
    rm "${link}"
    ok "removed symlink: ${link}"
  fi
else
  ok "no symlink at ${link} (already gone)"
fi

if [ "${KEEP_STATE}" != "1" ] && [ -d "${BROWSER_SKILL_HOME}" ]; then
  ok "keeping state at ${BROWSER_SKILL_HOME} (use rm -rf manually to delete)"
fi
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bats tests/install.bats tests/uninstall.bats`
Expected: all install + uninstall tests green.

- [ ] **Step 5: Commit**

```bash
chmod +x uninstall.sh
git add install.sh uninstall.sh tests/install.bats tests/uninstall.bats
git commit -m "feat(install): create skill symlink + uninstall.sh"
```

---

## Task 13 — `install.sh`: run doctor as final sanity check

**Files:**
- Modify: `install.sh`
- Modify: `tests/install.bats`

- [ ] **Step 1: Write the failing test**

Append to `tests/install.bats`:

```bash
@test "install.sh: runs doctor at the end and reports its result" {
  setup_temp_home
  run bash "${REPO_ROOT}/install.sh" --user
  assert_status 0
  assert_output_contains "running doctor"
  assert_output_contains "all checks passed"
  teardown_temp_home
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bats tests/install.bats`
Expected: FAIL — install doesn't run doctor yet.

- [ ] **Step 3: Modify `install.sh`**

Replace the final `ok "install complete; next steps:"` block with:

```bash
install_symlink

ok "running doctor..."
doctor_rc=0
bash "${REPO_ROOT}/scripts/browser-doctor.sh" || doctor_rc=$?

ok "install complete; next steps:"
ok "  1. /browser doctor       (verify in Claude Code)"
ok "  2. /browser add-site     (register your first site, lands in phase 2)"
if [ "${doctor_rc}" -ne 0 ]; then
  warn "doctor reported issues (exit ${doctor_rc}); run 'bash scripts/browser-doctor.sh' to review"
fi
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bats tests/install.bats`
Expected: all install tests green.

- [ ] **Step 5: Commit**

```bash
git add install.sh tests/install.bats
git commit -m "feat(install): run doctor as final sanity check"
```

---

## Task 14 — Full `.gitignore` + `tests/git-leak.bats` skeleton

**Files:**
- Modify: `.gitignore`
- Create: `tests/git-leak.bats`

- [ ] **Step 1: Write the failing test**

```bash
# tests/git-leak.bats
load helpers

setup() {
  TEST_REPO="$(mktemp -d "${TMPDIR:-/tmp}/git-leak.XXXXXX")"
  cd "${TEST_REPO}"
  git init -q
  git config user.email "test@example.com"
  git config user.name "Test"
  cp "${REPO_ROOT}/.gitignore" .
}

teardown() {
  cd "${REPO_ROOT}"
  rm -rf "${TEST_REPO}"
}

@test "gitignore: ignores common credential / session / capture patterns" {
  for path in \
      .browser-skill/sessions/x.json \
      .browser-skill/credentials/x.json \
      .browser-skill/captures/001/network.har \
      sessions/x.json \
      credentials/x.json \
      captures/001/screenshot.png \
      sample.creds.json \
      private.pem \
      private.key \
      cert.crt \
      .env \
      .env.local \
      secrets.yaml \
      secrets.json
  do
    mkdir -p "$(dirname "${path}")"
    : > "${path}"
    run git check-ignore "${path}"
    assert_status 0
  done
}

@test "gitignore: does NOT ignore shareable team files" {
  for path in \
      .browser-skill/sites/prod.json \
      .browser-skill/flows/morning.flow.yaml \
      .browser-skill/baselines.json \
      .browser-skill/blocklist.txt \
      .browser-skill/config.json \
      .browser-skill/version
  do
    mkdir -p "$(dirname "${path}")"
    : > "${path}"
    run git check-ignore "${path}"
    assert_status 1   # not ignored
  done
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bats tests/git-leak.bats`
Expected: FAIL — current `.gitignore` is the minimal one.

- [ ] **Step 3: Replace `.gitignore` with the full version**

```gitignore
# browser-automation-skill .gitignore
#
# Security-first: credentials, sessions, captures must NEVER land in git.
# Canonical storage is $HOME/.browser-skill/ — outside this tree — but these
# patterns stop accidents (`git add .` from a parent dir, symlinks, fixtures).
#
# Companion: .githooks/pre-commit enforces the same rules at commit time.
# Run scripts/install-git-hooks.sh (or pass --with-hooks to install.sh).

# --- Credential / session / capture state (any location in tree) ---
.browser-skill/sessions/
.browser-skill/credentials/
.browser-skill/captures/
.browser-skill/current
sessions/
credentials/
captures/
*.creds.json
*.session.json

# --- TLS / key material ---
*.pem
*.key
*.crt
*.cer
*.der
*.p12
*.pfx
*.keystore
*.jks
*.asc
*.gpg
id_rsa
id_ed25519
id_ecdsa

# --- Env files ---
.env
.env.*
!.env.example
secrets.yaml
secrets.yml
secrets.json
credentials.json
credentials.yaml

# --- Browser-specific artifacts ---
*.har
trace.zip
lighthouse.json
*.png.diff

# --- Test temp artifacts ---
tests/tmp/
tests/.bats/
tests/fixtures/tmp/

# --- Editor / OS detritus ---
.DS_Store
Thumbs.db
*.swp
*.swo
*~
.idea/
.vscode/
*.bak
*.orig

# --- Misc leak sources ---
*.log
npm-debug.log*
yarn-debug.log*
core
core.*
*.pid
node_modules/
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bats tests/git-leak.bats`
Expected: both tests green.

- [ ] **Step 5: Commit**

```bash
git add .gitignore tests/git-leak.bats
git commit -m "feat(security): full .gitignore + git-leak.bats baseline"
```

---

## Task 15 — `.githooks/pre-commit`: credential-leak blocker

**Files:**
- Create: `.githooks/pre-commit`
- Modify: `tests/git-leak.bats`

- [ ] **Step 1: Write the failing test**

Append to `tests/git-leak.bats`:

```bash
@test "pre-commit: blocks staged plaintext password JSON" {
  cp -r "${REPO_ROOT}/.githooks" .githooks
  git config core.hooksPath .githooks
  printf '%s\n' '{"password":"hunter2"}' > leak.json   # placeholder fixture
  git add -f leak.json
  run git commit -m "should fail" --no-gpg-sign
  assert_status 1
  assert_output_contains "rejected"
}

@test "pre-commit: blocks staged .pem file" {
  cp -r "${REPO_ROOT}/.githooks" .githooks
  git config core.hooksPath .githooks
  printf -- '-----BEGIN PRIVATE KEY-----\nfake\n' > my.pem
  git add -f my.pem
  run git commit -m "should fail" --no-gpg-sign
  assert_status 1
}

@test "pre-commit: allows clean commits" {
  cp -r "${REPO_ROOT}/.githooks" .githooks
  git config core.hooksPath .githooks
  echo "hello world" > README.md
  git add README.md
  run git commit -m "ok" --no-gpg-sign
  assert_status 0
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bats tests/git-leak.bats`
Expected: FAIL — `.githooks/pre-commit` doesn't exist yet.

- [ ] **Step 3: Write the hook**

```bash
# .githooks/pre-commit
#!/usr/bin/env bash
# Credential-leak blocker. Refuses to commit files matching credential patterns
# OR diffs containing password-shaped strings.
set -euo pipefail

red()    { printf '\033[0;31m%s\033[0m\n' "$*" >&2; }
yellow() { printf '\033[0;33m%s\033[0m\n' "$*" >&2; }

# 1. File-name patterns. Reject if any staged file matches.
banned_patterns=(
  '*.pem' '*.key' '*.crt' '*.p12' '*.pfx' '*.keystore' '*.jks' '*.asc' '*.gpg'
  '*.creds.json' '*.session.json'
  '*.har'
  'id_rsa' 'id_ed25519' 'id_ecdsa'
  '.env' '.env.*'
  'secrets.json' 'secrets.yaml' 'secrets.yml'
  'credentials.json' 'credentials.yaml'
)

declare -a leaked
while IFS= read -r f; do
  [ -z "${f}" ] && continue
  for pat in "${banned_patterns[@]}"; do
    case "${f}" in
      ${pat}|*/${pat})
        leaked+=("${f}")
        ;;
    esac
  done
done < <(git diff --cached --name-only --diff-filter=ACMR)

if [ "${#leaked[@]}" -gt 0 ]; then
  red "rejected: staged files match credential-shaped patterns:"
  for f in "${leaked[@]}"; do red "  - ${f}"; done
  yellow "  remediation: move credentials to ~/.browser-skill/, add patterns to .gitignore,"
  yellow "  or pass --no-verify if you are 100% sure (NOT RECOMMENDED)."
  exit 1
fi

# 2. Diff content scan: password-shaped strings.
suspicious="$(git diff --cached -U0 \
  | grep -E '^\+' \
  | grep -E '"password"[[:space:]]*:[[:space:]]*"[^"]{3,}"' \
  | grep -viE 'mask|example|placeholder|redacted|\*\*\*|hunter2.*test' \
  || true)"

if [ -n "${suspicious}" ]; then
  red "rejected: diff contains password-shaped string:"
  printf '%s\n' "${suspicious}" | sed 's/^/  /' >&2
  yellow "  remediation: remove the literal value before committing."
  exit 1
fi

exit 0
```

- [ ] **Step 4: Run test to verify it passes**

```bash
chmod +x .githooks/pre-commit
bats tests/git-leak.bats
```
Expected: 5 tests green.

- [ ] **Step 5: Commit**

```bash
git add .githooks/pre-commit tests/git-leak.bats
git commit -m "feat(security): pre-commit credential-leak blocker"
```

---

## Task 16 — `scripts/install-git-hooks.sh` + wire `--with-hooks`

**Files:**
- Create: `scripts/install-git-hooks.sh`
- Modify: `install.sh`
- Modify: `tests/install.bats`

- [ ] **Step 1: Write the failing test**

Append to `tests/install.bats`:

```bash
@test "install.sh --with-hooks wires core.hooksPath" {
  setup_temp_home
  # The repo we're testing IS a git repo; just verify hookspath gets set.
  cd "${REPO_ROOT}"
  bash "${REPO_ROOT}/install.sh" --user --with-hooks >/dev/null
  local result
  result="$(git -C "${REPO_ROOT}" config --get core.hooksPath || true)"
  teardown_temp_home
  [ "${result}" = ".githooks" ]
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bats tests/install.bats`
Expected: FAIL — `--with-hooks` doesn't actually wire the hook yet.

- [ ] **Step 3: Create `scripts/install-git-hooks.sh`**

```bash
# scripts/install-git-hooks.sh
#!/usr/bin/env bash
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [ ! -d "${REPO_ROOT}/.git" ] && [ ! -f "${REPO_ROOT}/.git" ]; then
  printf 'not a git checkout: %s\n' "${REPO_ROOT}" >&2
  exit 0
fi
if ! command -v git >/dev/null 2>&1; then
  printf 'git not on PATH; cannot install hooks\n' >&2
  exit 0
fi

git -C "${REPO_ROOT}" config core.hooksPath .githooks
chmod +x "${REPO_ROOT}/.githooks/pre-commit"
printf 'pre-commit hook active (.githooks/pre-commit)\n'
```

- [ ] **Step 4: Modify `install.sh` to call it on `--with-hooks`**

Append (just before the `ok "running doctor..."` line):

```bash
if [ "${WITH_HOOKS}" = "1" ]; then
  bash "${REPO_ROOT}/scripts/install-git-hooks.sh"
fi
```

Run test:

```bash
chmod +x scripts/install-git-hooks.sh
bats tests/install.bats
```
Expected: all install tests green.

- [ ] **Step 5: Commit**

```bash
git add scripts/install-git-hooks.sh install.sh tests/install.bats
git commit -m "feat(install): --with-hooks wires .githooks/pre-commit"
```

---

## Task 17 — `SKILL.md` + `README.md` (Phase-1 stubs)

**Files:**
- Create: `SKILL.md`
- Modify: `README.md`

- [ ] **Step 1: Write the failing test**

Append to `tests/install.bats`:

```bash
@test "SKILL.md: exists and has frontmatter with required fields" {
  [ -f "${REPO_ROOT}/SKILL.md" ]
  head -20 "${REPO_ROOT}/SKILL.md" | grep -q '^name: browser-automation-skill$'
  head -20 "${REPO_ROOT}/SKILL.md" | grep -q '^description:'
  head -20 "${REPO_ROOT}/SKILL.md" | grep -q '^allowed-tools:'
}

@test "README.md: has install + first-flow sections" {
  grep -q '^## Install' "${REPO_ROOT}/README.md"
  grep -q '^### Personal' "${REPO_ROOT}/README.md"
  grep -q '/browser doctor' "${REPO_ROOT}/README.md"
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bats tests/install.bats`
Expected: FAIL — SKILL.md missing.

- [ ] **Step 3: Write the files**

Create `SKILL.md`:

```markdown
---
name: browser-automation-skill
description: Drive a real browser from Claude Code via four routed tools (chrome-devtools-mcp, playwright-cli, playwright-lib, obscura). Credentials and sessions stay strictly local in $HOME/.browser-skill/ (mode 0600) and never appear on argv, in git, or in the Claude transcript.
when_to_use: The user mentions a browser task — verify a page, fill a form, capture console errors, run a lighthouse audit, scrape multiple URLs, debug a UI bug iteratively, or run a recorded flow.
argument-hint: [verb] [--site NAME] [--session NAME] [--tool NAME] [--dry-run]
allowed-tools: Bash(bash *) Bash(jq *) Bash(chmod *) Bash(mkdir *) Bash(stat *) Bash(rm *) Bash(mv *) Bash(cat *)
---

# browser-automation-skill (Phase 1 — foundation)

Phase 1 ships only the foundation: install + doctor + state dir + pre-commit hook.
Verbs that drive a browser arrive in Phase 2 onward.

## Verbs

| Verb | What it does | Example |
|---|---|---|
| `doctor` | Health check: deps, state dir mode, disk encryption, no network | `bash "${CLAUDE_SKILL_DIR}/scripts/browser-doctor.sh"` |

## Before running anything

If `doctor` reports `~/.browser-skill` missing, run `./install.sh` (or `./install.sh --with-hooks` for the credential-leak blocker).

## Output contract

Every verb prints zero or more streaming JSON lines, then ends with a single-line JSON summary. Parse with jq; route on `.status` (`ok`, `partial`, `error`, `empty`, `aborted`).

```
$ bash scripts/browser-doctor.sh | tail -1 | jq .
{"verb":"doctor","tool":"none","why":"health-check","status":"ok","problems":0,"duration_ms":42}
```

## Roadmap

See `docs/superpowers/specs/2026-04-27-browser-automation-skill-design.md` for the full design and `docs/superpowers/plans/` for phase plans.
```

Replace `README.md`:

```markdown
# browser-automation-skill

A [Claude Code](https://claude.com/claude-code) skill for driving real browsers from an LLM. Routes tasks across four tools — Chrome DevTools MCP, Playwright CLI, the Playwright lib, and Obscura — and keeps every credential strictly local under `$HOME/.browser-skill/`.

> **Status:** Phase 1 (foundation). The verb that ships in this phase is `doctor`. Subsequent phases add `add-site`, `login`, `inspect`, `verify`, `audit`, `extract`, `flow run/record`, `replay`, `report`, and the credential vault.

## Security at a glance

- Credentials are on disk only at `$HOME/.browser-skill/` (mode 0700).
- Credentials never appear on argv, in `ps`, in git, or in the Claude transcript.
- `.gitignore` blocks every credential / session / capture pattern from the repo.
- `.githooks/pre-commit` rejects any staged file or diff that looks like a credential.
- See `SECURITY.md` for the full threat model.

## Requirements

- bash ≥ 4 (`brew install bash` on macOS — the system bash 3.2 is too old)
- `jq`
- `python3`
- `bats-core` (for tests; `brew install bats-core`)

## Install

### Personal (one machine, all your projects)

```bash
git clone https://github.com/xicv/browser-automation-skill ~/Projects/browser-automation-skill
cd ~/Projects/browser-automation-skill
./install.sh --with-hooks
```

### Verify (in Claude Code)

```
/browser doctor
```

Expected: exit 0; final line is a JSON summary with `"status":"ok"`.

## Uninstall

```bash
./uninstall.sh
```

Removes the `~/.claude/skills/browser-automation-skill` symlink. State at `~/.browser-skill/` is preserved by default.

## Layout

```
install.sh              # preflight + state dir + symlink + (opt) hooks
uninstall.sh            # remove symlink
SKILL.md                # Claude Code skill manifest (source of truth)
SECURITY.md             # threat model + disclosure
.gitignore              # blocks credential / profile patterns
.githooks/pre-commit    # credential-leak blocker
scripts/
  browser-doctor.sh     # the only verb in Phase 1
  install-git-hooks.sh
  lib/
    common.sh           # paths, exit codes, logging, summary writer, home resolver
tests/                  # bats — runs in <30s
```

## Roadmap

See `docs/superpowers/specs/2026-04-27-browser-automation-skill-design.md` for the design and `docs/superpowers/plans/` for executable plans.
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bats tests/install.bats`
Expected: all install tests green.

- [ ] **Step 5: Commit**

```bash
git add SKILL.md README.md tests/install.bats
git commit -m "docs: ship SKILL.md + README.md (Phase 1 stubs)"
```

---

## Task 18 — `SECURITY.md` + `CHANGELOG.md`

**Files:**
- Create: `SECURITY.md`
- Create: `CHANGELOG.md`

- [ ] **Step 1: Write the files** (no failing test — these are pure docs)

Create `SECURITY.md`:

```markdown
# Security policy

## Threat model

This skill is for single-developer, local-machine use.

### In scope (we defend against)
- Credentials leaking via argv / `ps` / shell history / git / Claude transcript
- Captures (HARs / console / screenshots) leaking auth tokens (Phase 7 sanitization)
- Sessions injected into the wrong origin (Phase 5 origin binding)
- Accidental commits of any credential-shaped file

### Out of scope
- Malware on your machine
- Compromised macOS / Linux kernel
- OS keychain compromise
- Compromised upstream tool (Playwright, chrome-devtools-mcp, Obscura)
- Compromised npm / cargo dependency
- Targeted nation-state attacker

## Reporting vulnerabilities

Use GitHub Security Advisories (private disclosure path) for any vulnerability. Do **not** open a public issue for security bugs.

PGP key: (TBD on first release).

## Defense layers (full set lands across phases)

| Layer | Phase |
|---|---|
| Filesystem perms (0700/0600, umask 077) | 1 |
| Pre-commit credential-leak blocker | 1 |
| Process argv invariants (creds via stdin only) | 5 |
| Origin binding (sessions refuse cross-origin) | 5 |
| OS keychain backend | 5 |
| Typed-phrase confirmations for risky paths | 5 |
| Capture sanitization (HAR + console + DOM) | 7 |

See `docs/superpowers/specs/2026-04-27-browser-automation-skill-design.md` §8 for the full security design.
```

Create `CHANGELOG.md`:

```markdown
# Changelog

Every entry has a tag in `[brackets]`:
- `[feat]` user-visible new behavior
- `[fix]` user-visible bug fix
- `[security]` anything touching credentials, sessions, captures, hooks
- `[adapter]` added/updated tool adapter
- `[schema]` on-disk schema migration
- `[breaking]` requires action from existing users
- `[upstream]` updated pinned upstream tool version
- `[internal]` lint, tests, CI — no user-visible change
- `[docs]` README / SKILL.md / references / examples

## [Unreleased]

### Phase 1 — Foundation

- [feat] `install.sh --user --with-hooks --dry-run` ships
- [feat] `uninstall.sh` ships (symlink-only by default)
- [feat] `doctor` verb: deps + bash version + home dir mode + disk encryption (advisory)
- [feat] `lib/common.sh`: exit codes, logging, summary_json, BROWSER_SKILL_HOME resolver, with_timeout
- [security] `.gitignore` blocks credentials/sessions/captures/keys/.env
- [security] `.githooks/pre-commit` blocks staged credentials and password-shaped diff content
- [docs] SKILL.md, README.md, SECURITY.md scaffolded
- [internal] bats unit suite (~25 tests) runs in <10 s
```

- [ ] **Step 2: Verify the files render correctly**

```bash
head -5 SECURITY.md
head -5 CHANGELOG.md
```
Expected: headers visible, no syntax errors.

- [ ] **Step 3: Commit**

```bash
git add SECURITY.md CHANGELOG.md
git commit -m "docs: SECURITY.md threat model + CHANGELOG.md tag conventions"
```

---

## Task 19 — CI: GitHub Actions unit job

**Files:**
- Create: `.github/workflows/test.yml`

- [ ] **Step 1: Write the workflow** (manual smoke test — no bats test for the YAML itself)

```yaml
# .github/workflows/test.yml
name: test

on:
  push:
    branches: [main]
  pull_request:
    branches: [main]

jobs:
  unit:
    runs-on: ${{ matrix.os }}
    strategy:
      fail-fast: false
      matrix:
        os: [ubuntu-latest, macos-latest]
    steps:
      - uses: actions/checkout@v4

      - name: Install bats (Linux)
        if: runner.os == 'Linux'
        run: sudo apt-get update && sudo apt-get install -y bats jq

      - name: Install bats (macOS)
        if: runner.os == 'macOS'
        run: |
          brew update
          brew install bats-core jq

      - name: Run unit suite
        run: bash tests/run.sh
```

- [ ] **Step 2: Lint the YAML locally**

```bash
python3 -c "import yaml; yaml.safe_load(open('.github/workflows/test.yml'))"
```
Expected: no error.

- [ ] **Step 3: Commit and push to a branch to verify CI green**

```bash
git add .github/workflows/test.yml
git commit -m "ci: unit job on ubuntu + macos"
# Push to your branch and verify the workflow runs green:
#   git push -u origin <your-branch>
# Then check the GitHub Actions tab.
```

(Don't merge until both runners green.)

---

## Task 20 — End-to-end smoke (the acceptance gate for Phase 1)

**Files:**
- (No new files; this is a manual + scripted verification.)

- [ ] **Step 1: Wipe state and re-install from scratch**

```bash
rm -rf ~/.browser-skill
rm -f ~/.claude/skills/browser-automation-skill
cd ~/Projects/browser-automation-skill
./install.sh --with-hooks
```
Expected: exits 0, prints "all checks passed", state dir at `~/.browser-skill/` mode 0700, symlink in place.

- [ ] **Step 2: Run doctor independently**

```bash
bash scripts/browser-doctor.sh | tee /tmp/doctor.log
```
Expected: exit 0; final line is valid JSON; `.status == "ok"`.

```bash
tail -1 /tmp/doctor.log | jq -e '.verb == "doctor" and .status == "ok"'
```
Expected: prints `true`, exits 0.

- [ ] **Step 3: Run the full bats suite**

```bash
bash tests/run.sh
```
Expected: every test green; total time <30 s.

- [ ] **Step 4: Verify pre-commit hook is wired**

```bash
git -C ~/Projects/browser-automation-skill config --get core.hooksPath
```
Expected: prints `.githooks`.

```bash
cd /tmp && rm -rf phase1-leak-test && mkdir phase1-leak-test && cd phase1-leak-test
git init -q
cp ~/Projects/browser-automation-skill/.gitignore .
mkdir -p .githooks
cp ~/Projects/browser-automation-skill/.githooks/pre-commit .githooks/
chmod +x .githooks/pre-commit
git config core.hooksPath .githooks
git config user.email t@t.com && git config user.name t
echo '{"password":"hunter9"}' > leak.json   # placeholder fixture
git add -f leak.json
git commit -m "should fail" --no-gpg-sign 2>&1 | head -5
```
Expected: commit refused with "rejected: staged files match credential-shaped patterns".

```bash
cd ~ && rm -rf /tmp/phase1-leak-test
```

- [ ] **Step 5: Verify uninstall is clean**

```bash
cd ~/Projects/browser-automation-skill
./uninstall.sh --keep-state
```
Expected: symlink removed; `~/.browser-skill/` preserved.

- [ ] **Step 6: Reinstall (idempotent check)**

```bash
./install.sh --with-hooks
ls -la ~/.claude/skills/browser-automation-skill
```
Expected: symlink restored; doctor green.

- [ ] **Step 7: Tag the milestone**

```bash
git tag -a v0.1.0-phase-01-foundation -m "Phase 1 — foundation complete"
# Push if desired:
#   git push origin v0.1.0-phase-01-foundation
```

---

## Acceptance criteria for Phase 1 (must all be true)

- [ ] `./install.sh --with-hooks` works clean on a fresh macOS box and a fresh Ubuntu box.
- [ ] `bash scripts/browser-doctor.sh` exits 0 immediately after a clean install.
- [ ] All bats tests under `tests/` pass; total runtime <30 s.
- [ ] `git config core.hooksPath` reports `.githooks` in this repo.
- [ ] Pre-commit hook blocks a fake credential commit (verified manually in Task 20 Step 4).
- [ ] `./install.sh` is idempotent (running it twice does not error or wipe state).
- [ ] `./uninstall.sh --keep-state` removes the symlink and preserves state.
- [ ] CI workflow `test.yml` is green on both ubuntu-latest and macos-latest.
- [ ] `SKILL.md`, `README.md`, `SECURITY.md`, `CHANGELOG.md` are committed.
- [ ] No file in the working tree exceeds 250 LOC (will be enforced by `tests/lint.sh` in a later phase; manual check now).

---

## What ships in subsequent phases (preview)

| Phase | Plan filename (when written) | Key deliverable |
|---|---|---|
| 2 | `2026-MM-DD-browser-automation-skill-phase-02-site-session-core.md` | `add-site` / `use` / `login` + storageState write/read |
| 3 | `phase-03-first-adapter-playwright-cli.md` | `lib/tool/playwright-cli.sh` + `open` / `snapshot` / `click` / `fill` / `inspect` end-to-end |
| 4 | `phase-04-router-and-cdt-mcp.md` | `lib/router.sh` + chrome-devtools-mcp adapter; `inspect --capture-console`; `audit` |
| 5 | `phase-05-credentials-and-relogin.md` | credential vault (3 backends), login_detect, single auto-retry, blocklist, typed-phrase |
| 6 | `phase-06-remaining-tools.md` | playwright-lib node helper, Obscura adapter; `extract --scrape` |
| 7 | `phase-07-capture-and-sanitization.md` | `lib/capture.sh`, baselines, `lib/sanitize.sh`, `clean` |
| 8 | `phase-08-composition-and-history.md` | `flow run` / `flow record`, `replay`, `history`, `report`, `verify` w/ baselines |
| 9 | `phase-09-project-mode-and-polish.md` | `install.sh --project`, examples/, full references/, fresh-install nightly test |
| 10 | `phase-10-maintainability-scaffolding.md` | `CONTRIBUTING.md`, `references/recipes/*.md`, `tests/lint.sh`, sync-tests, PR template |

Each subsequent plan is written **after** the previous phase merges, so it can read the actual code state, not speculate about it.

---

## Self-review checklist (run after writing this plan)

- [x] **Spec coverage:** every Phase-1 deliverable in §12 of the spec maps to a task here.
- [x] **No placeholders:** every step has full code or a full command. No "implement appropriate validation" hand-waves.
- [x] **Type/symbol consistency:** `EXIT_*` constants used in tests match the names defined in `lib/common.sh`. Function names (`ok`/`warn`/`die`/`init_paths`/`summary_json`/`with_timeout`/`resolve_browser_skill_home`) match across tasks.
- [x] **TDD discipline:** every code task has a failing test → run-to-fail → minimal impl → run-to-pass → commit.
- [x] **Frequent commits:** 20 tasks → 18 commits + 2 doc-only commits + 1 tag. No batch commits.
- [x] **Bite-sized:** every step is 2–5 minutes for a competent shell engineer.

---

## Reading order for an engineer who's never seen this codebase

1. `docs/superpowers/specs/2026-04-27-browser-automation-skill-design.md` — read §0, §1, §2.1, §2.2, §13.1.
2. `https://github.com/xicv/mqtt-skill` — skim `SKILL.md`, `install.sh`, `scripts/lib/common.sh`, `scripts/mqtt-doctor.sh`. This is the proven pattern we mirror.
3. This plan, top to bottom.
4. Begin Task 1.
