# Browser-Automation-Skill — Phase 2: Site + Session Core Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship the site-profile + session schema layer that every later phase depends on: site CRUD verbs (`add-site` / `list-sites` / `show-site` / `remove-site` / `use`), `lib/site.sh` and `lib/session.sh` libraries, a Playwright-storageState round-tripping `login` verb (stub-adapter only — no real browser yet), origin-binding on session load, and `current`-file management.

**Architecture:** Two new libraries source `lib/common.sh` and own the JSON read/write for sites and sessions, both with atomic temp-file + `mv` writes, mode 0600 files in mode 0700 directories. Verbs are thin orchestrators that call into the libraries and emit one streaming-JSON line + the standard summary. Login's "stub adapter" is in-process bash logic that consumes a hand-edited Playwright storageState file, validates it, origin-binds it to the site URL, and writes it under `sessions/`. Phase 3 will replace the stub with a real Playwright launch behind the same CLI surface.

**Tech Stack:** bash ≥ 4, jq, python3, bats-core. **No** npm / Playwright runtime in this phase — that arrives in Phase 3.

**Spec reference:** `docs/superpowers/specs/2026-04-27-browser-automation-skill-design.md` — sections **§1** (locked-in decisions), **§2.3** (repo layout), **§3.4** (on-disk format), **§3.5** (site profile schema), **§3.6** (credential schema, deferred but informs structure), **§4.4** (authentication lifecycle), **§5.5** (what we don't catch — origin mismatch), **§5.1** (exit-code table).

**User-instruction reminders:**
- TDD discipline mandatory: failing test → run-to-fail → minimal impl → run-to-pass → commit, every task. Mirrors Phase 1.
- Frequent commits, one logical change per commit; conventional-commits style (`feat(lib): ...`, `feat(site): ...`).
- **Don't commit formatting-only changes.** Lint only files we modify or create. The repo's lint job is not yet wired up (Phase 10) — for now, manual `shellcheck` on each new `.sh` is enough.
- Verb-script files are budgeted ≤ 250 LOC; lib files ≤ 250 LOC; `.bats` files ≤ 300 LOC. Split if you exceed.
- Output contract per spec §2.2: zero-or-more streaming JSON lines on stdout, then a final single-line JSON summary via `summary_json`. **All logging via `ok` / `warn` / `die` goes to stderr.**

---

## File structure (Phase 2 deliverables)

| Path | Responsibility | Created in task |
|---|---|---|
| `tests/helpers.bash` (modify) | Source `lib/common.sh`; drop `${EXIT_*:-N}` fallbacks across `.bats` files | T1 |
| `scripts/lib/site.sh` | Site profile read/write/list/delete; `current` file helpers | T2–T7 |
| `scripts/browser-add-site.sh` | Verb: register a site profile (`--dry-run` aware) | T8 |
| `scripts/browser-list-sites.sh` | Verb: list registered sites + metadata | T9 |
| `scripts/browser-show-site.sh` | Verb: show one site's profile JSON | T10 |
| `scripts/browser-remove-site.sh` | Verb: typed-name confirmed delete | T11 |
| `scripts/browser-use.sh` | Verb: get / set / clear `current` site | T12 |
| `scripts/lib/session.sh` | Playwright storageState read/write + meta sidecar + origin check + expiry summary | T13–T17 |
| `scripts/browser-login.sh` | Verb: stub-adapter login (consumes hand-edited storageState file) | T18–T20 |
| `tests/site.bats` | Tests for `lib/site.sh` and the four site verbs + `use` | T2–T12 |
| `tests/session.bats` | Tests for `lib/session.sh` | T13–T17 |
| `tests/login.bats` | Tests for `browser-login.sh` (stub adapter, origin-binding) | T18–T20 |
| `tests/fixtures/storage-state-good.json` | Hand-edited Playwright storageState — origins match site URL | T18 |
| `tests/fixtures/storage-state-bad-origin.json` | Hand-edited storageState — origin **does not** match | T19 |
| `SKILL.md` (modify) | Add new verbs to the verb table; fix carry-forwards (mode wording, `CLAUDE_SKILL_DIR` explainer) | T21 |
| `CHANGELOG.md` (modify) | Append Phase 2 entries under `[Unreleased]` | T21 |
| `uninstall.sh` (modify) | Fix usage string carry-forward (lies about prompt) | T21 |
| `install.sh` (modify) | Fix dry-run hardcoded path carry-forward | T21 |

Files **deferred** to later phases (do NOT create in Phase 2): credential libs, secret backends, `lib/router.sh`, real `lib/tool/<tool>.sh` adapters, capture/sanitize/clean libs, Node helpers, recipes, examples beyond what tests need.

---

## Schema reference (used across many tasks; one place to look)

### Site profile (`sites/<name>.json`, mode 0600)

```json
{
  "name": "prod-app",
  "url": "https://app.example.com",
  "viewport": {"width": 1280, "height": 800},
  "user_agent": null,
  "stealth": false,
  "default_session": null,
  "default_tool": null,
  "label": "",
  "schema_version": 1
}
```

### Site meta (`sites/<name>.meta.json`, mode 0600, shareable per spec §3.4)

```json
{
  "name": "prod-app",
  "created_at": "2026-04-29T15:42:00Z",
  "last_used_at": "2026-04-29T15:42:00Z"
}
```

### Session storageState (`sessions/<name>.json`, mode 0600) — Playwright-native shape

```json
{
  "cookies": [
    {"name": "sid", "value": "...", "domain": "app.example.com", "path": "/",
     "expires": -1, "httpOnly": true, "secure": true, "sameSite": "Lax"}
  ],
  "origins": [
    {"origin": "https://app.example.com",
     "localStorage": [{"name": "k", "value": "v"}]}
  ]
}
```

### Session meta sidecar (`sessions/<name>.meta.json`, mode 0600)

```json
{
  "name": "prod-app--admin",
  "site": "prod-app",
  "origin": "https://app.example.com",
  "captured_at": "2026-04-29T15:42:00Z",
  "source_user_agent": "browser-skill phase-2 stub adapter",
  "expires_in_hours": 168,
  "schema_version": 1
}
```

`origin` is `scheme://host[:port]` — used by `session_origin_check` to refuse loading the session into a mismatched site (spec §5.5).

---

## Task 1 — Carry-forward: `tests/helpers.bash` sources `lib/common.sh`; drop `${EXIT_*:-N}` fallbacks

**Files:**
- Modify: `tests/helpers.bash`
- Modify: `tests/common.bats`
- Modify: `tests/install.bats`
- Modify: `tests/doctor.bats`

This is a pure refactor. Once `tests/helpers.bash` sources `scripts/lib/common.sh`, every `.bats` file that does `load helpers` automatically has `EXIT_OK`, `EXIT_PREFLIGHT_FAILED`, etc. as plain readonly variables. The `${EXIT_PREFLIGHT_FAILED:-20}` fallback pattern was a Phase-1 workaround for the missing source.

- [ ] **Step 1: Run the full suite to record the baseline (must be 44/44 green)**

```bash
bash tests/run.sh 2>&1 | tail -5
```
Expected: `44 tests, 0 failures` (or equivalent bats output).

- [ ] **Step 2: Modify `tests/helpers.bash` to source common.sh**

Replace the existing top-of-file region (lines 1-9 — the `set -euo pipefail` through the `SCRIPTS_DIR=` line) with:

```bash
# tests/helpers.bash
# Common bats helpers. `load helpers` from any *.bats picks this up.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB_DIR="${REPO_ROOT}/scripts/lib"
SCRIPTS_DIR="${REPO_ROOT}/scripts"

# Make EXIT_* and other constants from common.sh available to every test.
# This means tests can reference $EXIT_PREFLIGHT_FAILED directly without the
# `${EXIT_*:-N}` fallback pattern.
# shellcheck source=../scripts/lib/common.sh
# shellcheck disable=SC1091
source "${LIB_DIR}/common.sh"
```

(Leave the rest of the file — `setup_temp_home`, `teardown_temp_home`, `assert_*` helpers, `fail` polyfill — untouched.)

- [ ] **Step 3: Drop `${EXIT_*:-N}` fallbacks across `.bats` files**

Run a global scan and edit each occurrence by hand (the list is small):

```bash
grep -nE '\$\{EXIT_[A-Z_]+:-[0-9]+\}' tests/*.bats
```
Expected output (today, on `main`):
```
tests/common.bats:    assert_status "${EXIT_USAGE_ERROR:-2}"
tests/common.bats:    assert_status "${EXIT_TOOL_TIMEOUT:-43}"
tests/doctor.bats:    assert_status "${EXIT_PREFLIGHT_FAILED:-20}"
tests/doctor.bats:    assert_status "${EXIT_PREFLIGHT_FAILED:-20}"
tests/install.bats:   assert_status "${EXIT_PREFLIGHT_FAILED:-20}"
tests/install.bats:   assert_status "${EXIT_PREFLIGHT_FAILED:-20}"
```

For each match, replace the `${EXIT_FOO:-N}` form with the bare `$EXIT_FOO`:

```bash
# tests/common.bats: replace `assert_status "${EXIT_USAGE_ERROR:-2}"`
#                    with     `assert_status "$EXIT_USAGE_ERROR"`
# (and similarly for EXIT_TOOL_TIMEOUT)
# tests/doctor.bats / tests/install.bats: same pattern, EXIT_PREFLIGHT_FAILED.
```

- [ ] **Step 4: Run test to verify still 44/44 green**

```bash
bash tests/run.sh 2>&1 | tail -5
```
Expected: `44 tests, 0 failures`.

If anything fails, the most likely cause is `set -u` in a test file tripping on an undefined `$EXIT_FOO` — that means `helpers.bash` isn't being loaded in time. Add `load helpers` to the top of any `.bats` file that's missing it.

- [ ] **Step 5: Commit**

```bash
git add tests/helpers.bash tests/common.bats tests/doctor.bats tests/install.bats
git commit -m "refactor(tests): source lib/common.sh in helpers; drop EXIT_*:-N fallbacks"
```

---

## Task 2 — `lib/site.sh`: path helpers + `site_exists`

**Files:**
- Create: `scripts/lib/site.sh`
- Create: `tests/site.bats`

- [ ] **Step 1: Write the failing test**

```bash
# tests/site.bats
load helpers

setup() {
  setup_temp_home
  mkdir -p "${BROWSER_SKILL_HOME}/sites"
  chmod 700 "${BROWSER_SKILL_HOME}" "${BROWSER_SKILL_HOME}/sites"
}

teardown() { teardown_temp_home; }

@test "site.sh: source guard prevents double-source" {
  run bash -c "source '${LIB_DIR}/site.sh'; source '${LIB_DIR}/site.sh'; printf '%s\n' \"\${BROWSER_SKILL_SITE_LOADED:-unset}\""
  assert_status 0
  [ "${output}" = "1" ]
}

@test "site.sh: _site_path echoes <SITES_DIR>/<name>.json" {
  run bash -c "source '${LIB_DIR}/common.sh'; init_paths; source '${LIB_DIR}/site.sh'; _site_path prod-app"
  assert_status 0
  [ "${output}" = "${BROWSER_SKILL_HOME}/sites/prod-app.json" ]
}

@test "site.sh: _site_meta_path echoes <SITES_DIR>/<name>.meta.json" {
  run bash -c "source '${LIB_DIR}/common.sh'; init_paths; source '${LIB_DIR}/site.sh'; _site_meta_path prod-app"
  assert_status 0
  [ "${output}" = "${BROWSER_SKILL_HOME}/sites/prod-app.meta.json" ]
}

@test "site.sh: site_exists returns 1 when no profile written" {
  run bash -c "source '${LIB_DIR}/common.sh'; init_paths; source '${LIB_DIR}/site.sh'; site_exists prod-app"
  assert_status 1
}

@test "site.sh: site_exists returns 0 when profile file present" {
  printf '{}\n' > "${BROWSER_SKILL_HOME}/sites/prod-app.json"
  run bash -c "source '${LIB_DIR}/common.sh'; init_paths; source '${LIB_DIR}/site.sh'; site_exists prod-app"
  assert_status 0
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bats tests/site.bats`
Expected: FAIL — `scripts/lib/site.sh: No such file or directory`.

- [ ] **Step 3: Write minimal implementation**

```bash
# scripts/lib/site.sh
# Site profile read/write/list/delete + `current` file helpers.
# Source from any verb that needs to read or write a site profile.
# Requires lib/common.sh to be sourced first (init_paths must have run).

[ -n "${BROWSER_SKILL_SITE_LOADED:-}" ] && return 0
readonly BROWSER_SKILL_SITE_LOADED=1

# Internal: path of <name>'s profile JSON inside SITES_DIR.
_site_path() {
  printf '%s/%s.json' "${SITES_DIR}" "$1"
}

# Internal: path of <name>'s meta sidecar.
_site_meta_path() {
  printf '%s/%s.meta.json' "${SITES_DIR}" "$1"
}

# True iff a site profile JSON file exists for the given name.
site_exists() {
  [ -f "$(_site_path "$1")" ]
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bats tests/site.bats`
Expected: 5 tests green.

- [ ] **Step 5: Commit**

```bash
git add scripts/lib/site.sh tests/site.bats
git commit -m "feat(lib): add site.sh path helpers + site_exists"
```

---

## Task 3 — `lib/site.sh`: `site_save` (atomic write, schema_version=1, mode 0600)

**Files:**
- Modify: `scripts/lib/site.sh`
- Modify: `tests/site.bats`

- [ ] **Step 1: Write the failing test**

Append to `tests/site.bats`:

```bash
@test "site.sh: site_save writes valid JSON with schema_version=1 and mode 0600" {
  local profile_json='{"name":"prod-app","url":"https://app.example.com","viewport":{"width":1280,"height":800},"user_agent":null,"stealth":false,"default_session":null,"default_tool":null,"label":"","schema_version":1}'
  local meta_json='{"name":"prod-app","created_at":"2026-04-29T15:42:00Z","last_used_at":"2026-04-29T15:42:00Z"}'
  run bash -c "source '${LIB_DIR}/common.sh'; init_paths; source '${LIB_DIR}/site.sh'; site_save prod-app '${profile_json}' '${meta_json}'"
  assert_status 0
  # Profile file exists, valid JSON, mode 0600.
  [ -f "${BROWSER_SKILL_HOME}/sites/prod-app.json" ]
  jq -e . "${BROWSER_SKILL_HOME}/sites/prod-app.json" >/dev/null
  local mode
  mode="$(stat -f '%Lp' "${BROWSER_SKILL_HOME}/sites/prod-app.json" 2>/dev/null \
       || stat -c '%a' "${BROWSER_SKILL_HOME}/sites/prod-app.json" 2>/dev/null)"
  [ "${mode}" = "600" ]
  # Meta file likewise.
  [ -f "${BROWSER_SKILL_HOME}/sites/prod-app.meta.json" ]
  jq -e . "${BROWSER_SKILL_HOME}/sites/prod-app.meta.json" >/dev/null
}

@test "site.sh: site_save rejects malformed profile JSON" {
  run bash -c "source '${LIB_DIR}/common.sh'; init_paths; source '${LIB_DIR}/site.sh'; site_save bad 'not json' '{}'"
  assert_status "$EXIT_USAGE_ERROR"
  assert_output_contains "profile JSON"
}

@test "site.sh: site_save rejects malformed meta JSON" {
  run bash -c "source '${LIB_DIR}/common.sh'; init_paths; source '${LIB_DIR}/site.sh'; site_save bad '{}' 'nope'"
  assert_status "$EXIT_USAGE_ERROR"
  assert_output_contains "meta JSON"
}

@test "site.sh: site_save is atomic — partial failure leaves no half-written file" {
  # Simulate failure by making sites dir read-only AFTER its parent exists.
  chmod 500 "${BROWSER_SKILL_HOME}/sites"
  run bash -c "source '${LIB_DIR}/common.sh'; init_paths; source '${LIB_DIR}/site.sh'; site_save x '{}' '{}'"
  chmod 700 "${BROWSER_SKILL_HOME}/sites"
  # Either the save succeeded entirely (some test runners) or no file exists —
  # but never a half-written .tmp.* sitting around.
  ! ls "${BROWSER_SKILL_HOME}/sites/"*.tmp.* 2>/dev/null
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bats tests/site.bats`
Expected: FAIL — `site_save: command not found`.

- [ ] **Step 3: Write minimal implementation**

Append to `scripts/lib/site.sh`:

```bash
# site_save NAME PROFILE_JSON META_JSON
# Validates both JSON blobs, writes atomically (tmp + mv), mode 0600.
# Caller is responsible for shape — site.sh only validates "is it JSON".
site_save() {
  local name="$1" profile_json="$2" meta_json="$3"

  if ! printf '%s' "${profile_json}" | jq -e . >/dev/null 2>&1; then
    die "${EXIT_USAGE_ERROR}" "site_save: profile JSON is not valid"
  fi
  if ! printf '%s' "${meta_json}" | jq -e . >/dev/null 2>&1; then
    die "${EXIT_USAGE_ERROR}" "site_save: meta JSON is not valid"
  fi

  mkdir -p "${SITES_DIR}"
  chmod 700 "${SITES_DIR}"

  local profile_path meta_path profile_tmp meta_tmp
  profile_path="$(_site_path "${name}")"
  meta_path="$(_site_meta_path "${name}")"
  profile_tmp="${profile_path}.tmp.$$"
  meta_tmp="${meta_path}.tmp.$$"

  (
    umask 077
    printf '%s\n' "${profile_json}" | jq . > "${profile_tmp}"
    printf '%s\n' "${meta_json}"    | jq . > "${meta_tmp}"
  )
  chmod 600 "${profile_tmp}" "${meta_tmp}"
  mv "${profile_tmp}" "${profile_path}"
  mv "${meta_tmp}" "${meta_path}"
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bats tests/site.bats`
Expected: 9 tests green.

- [ ] **Step 5: Commit**

```bash
git add scripts/lib/site.sh tests/site.bats
git commit -m "feat(lib): site_save with atomic write + JSON validation + mode 0600"
```

---

## Task 4 — `lib/site.sh`: `site_load` + `site_meta_load`

**Files:**
- Modify: `scripts/lib/site.sh`
- Modify: `tests/site.bats`

- [ ] **Step 1: Write the failing test**

Append to `tests/site.bats`:

```bash
@test "site.sh: site_load echoes the profile JSON as written" {
  local profile_json='{"name":"prod-app","url":"https://app.example.com","schema_version":1}'
  bash -c "source '${LIB_DIR}/common.sh'; init_paths; source '${LIB_DIR}/site.sh'; site_save prod-app '${profile_json}' '{\"name\":\"prod-app\"}'"
  run bash -c "source '${LIB_DIR}/common.sh'; init_paths; source '${LIB_DIR}/site.sh'; site_load prod-app | jq -r .name"
  assert_status 0
  [ "${output}" = "prod-app" ]
}

@test "site.sh: site_load fails (exit 23) when site missing" {
  run bash -c "source '${LIB_DIR}/common.sh'; init_paths; source '${LIB_DIR}/site.sh'; site_load nope"
  assert_status "$EXIT_SITE_NOT_FOUND"
  assert_output_contains "site not found"
}

@test "site.sh: site_meta_load echoes the meta JSON" {
  bash -c "source '${LIB_DIR}/common.sh'; init_paths; source '${LIB_DIR}/site.sh'; site_save prod-app '{\"name\":\"prod-app\"}' '{\"name\":\"prod-app\",\"created_at\":\"2026-04-29T15:42:00Z\"}'"
  run bash -c "source '${LIB_DIR}/common.sh'; init_paths; source '${LIB_DIR}/site.sh'; site_meta_load prod-app | jq -r .created_at"
  assert_status 0
  [ "${output}" = "2026-04-29T15:42:00Z" ]
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bats tests/site.bats`
Expected: FAIL — `site_load: command not found`.

- [ ] **Step 3: Write minimal implementation**

Append to `scripts/lib/site.sh`:

```bash
# site_load NAME → echoes the profile JSON (un-jq'd, exactly as on disk).
site_load() {
  local name="$1"
  local path
  path="$(_site_path "${name}")"
  if [ ! -f "${path}" ]; then
    die "${EXIT_SITE_NOT_FOUND}" "site not found: ${name}"
  fi
  cat "${path}"
}

# site_meta_load NAME → echoes the meta JSON.
site_meta_load() {
  local name="$1"
  local path
  path="$(_site_meta_path "${name}")"
  if [ ! -f "${path}" ]; then
    die "${EXIT_SITE_NOT_FOUND}" "site meta not found: ${name}"
  fi
  cat "${path}"
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bats tests/site.bats`
Expected: 12 tests green.

- [ ] **Step 5: Commit**

```bash
git add scripts/lib/site.sh tests/site.bats
git commit -m "feat(lib): site_load + site_meta_load (exit 23 on missing)"
```

---

## Task 5 — `lib/site.sh`: `site_list_names`

**Files:**
- Modify: `scripts/lib/site.sh`
- Modify: `tests/site.bats`

- [ ] **Step 1: Write the failing test**

Append to `tests/site.bats`:

```bash
@test "site.sh: site_list_names lists profiles only (excludes .meta.json) sorted" {
  for n in zeta alpha mid; do
    bash -c "source '${LIB_DIR}/common.sh'; init_paths; source '${LIB_DIR}/site.sh'; site_save '${n}' '{\"name\":\"${n}\"}' '{\"name\":\"${n}\"}'"
  done
  run bash -c "source '${LIB_DIR}/common.sh'; init_paths; source '${LIB_DIR}/site.sh'; site_list_names"
  assert_status 0
  [ "${lines[0]}" = "alpha" ]
  [ "${lines[1]}" = "mid" ]
  [ "${lines[2]}" = "zeta" ]
  [ "${#lines[@]}" -eq 3 ]
}

@test "site.sh: site_list_names returns empty when no sites registered" {
  run bash -c "source '${LIB_DIR}/common.sh'; init_paths; source '${LIB_DIR}/site.sh'; site_list_names"
  assert_status 0
  [ -z "${output}" ]
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bats tests/site.bats`
Expected: FAIL — `site_list_names: command not found`.

- [ ] **Step 3: Write minimal implementation**

Append to `scripts/lib/site.sh`:

```bash
# site_list_names → echoes each registered site name on its own line, sorted.
# Excludes *.meta.json files; an empty SITES_DIR (or missing) prints nothing.
site_list_names() {
  if [ ! -d "${SITES_DIR}" ]; then
    return 0
  fi
  find "${SITES_DIR}" -maxdepth 1 -type f -name '*.json' ! -name '*.meta.json' \
    -exec basename {} .json \; 2>/dev/null | sort
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bats tests/site.bats`
Expected: 14 tests green.

- [ ] **Step 5: Commit**

```bash
git add scripts/lib/site.sh tests/site.bats
git commit -m "feat(lib): site_list_names (sorted, excludes .meta.json)"
```

---

## Task 6 — `lib/site.sh`: `site_delete` + `current` cascade

**Files:**
- Modify: `scripts/lib/site.sh`
- Modify: `tests/site.bats`

- [ ] **Step 1: Write the failing test**

Append to `tests/site.bats`:

```bash
@test "site.sh: site_delete removes profile and meta" {
  bash -c "source '${LIB_DIR}/common.sh'; init_paths; source '${LIB_DIR}/site.sh'; site_save prod '{\"name\":\"prod\"}' '{\"name\":\"prod\"}'"
  [ -f "${BROWSER_SKILL_HOME}/sites/prod.json" ]
  run bash -c "source '${LIB_DIR}/common.sh'; init_paths; source '${LIB_DIR}/site.sh'; site_delete prod"
  assert_status 0
  [ ! -f "${BROWSER_SKILL_HOME}/sites/prod.json" ]
  [ ! -f "${BROWSER_SKILL_HOME}/sites/prod.meta.json" ]
}

@test "site.sh: site_delete clears CURRENT_FILE if it pointed at the deleted site" {
  bash -c "source '${LIB_DIR}/common.sh'; init_paths; source '${LIB_DIR}/site.sh'; site_save prod '{\"name\":\"prod\"}' '{\"name\":\"prod\"}'"
  printf 'prod\n' > "${BROWSER_SKILL_HOME}/current"
  bash -c "source '${LIB_DIR}/common.sh'; init_paths; source '${LIB_DIR}/site.sh'; site_delete prod"
  [ ! -f "${BROWSER_SKILL_HOME}/current" ]
}

@test "site.sh: site_delete leaves CURRENT_FILE alone when it points elsewhere" {
  bash -c "source '${LIB_DIR}/common.sh'; init_paths; source '${LIB_DIR}/site.sh'; site_save a '{\"name\":\"a\"}' '{\"name\":\"a\"}'"
  bash -c "source '${LIB_DIR}/common.sh'; init_paths; source '${LIB_DIR}/site.sh'; site_save b '{\"name\":\"b\"}' '{\"name\":\"b\"}'"
  printf 'b\n' > "${BROWSER_SKILL_HOME}/current"
  bash -c "source '${LIB_DIR}/common.sh'; init_paths; source '${LIB_DIR}/site.sh'; site_delete a"
  [ -f "${BROWSER_SKILL_HOME}/current" ]
  [ "$(cat "${BROWSER_SKILL_HOME}/current")" = "b" ]
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bats tests/site.bats`
Expected: FAIL — `site_delete: command not found`.

- [ ] **Step 3: Write minimal implementation**

Append to `scripts/lib/site.sh`:

```bash
# site_delete NAME → rm -f the profile + meta. Idempotent.
# If CURRENT_FILE points at this site, clear it (orphan reference fix).
site_delete() {
  local name="$1"
  rm -f "$(_site_path "${name}")" "$(_site_meta_path "${name}")"

  if [ -f "${CURRENT_FILE}" ]; then
    local current
    current="$(tr -d '[:space:]' < "${CURRENT_FILE}" 2>/dev/null || true)"
    if [ "${current}" = "${name}" ]; then
      rm -f "${CURRENT_FILE}"
    fi
  fi
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bats tests/site.bats`
Expected: 17 tests green.

- [ ] **Step 5: Commit**

```bash
git add scripts/lib/site.sh tests/site.bats
git commit -m "feat(lib): site_delete cascades to CURRENT_FILE"
```

---

## Task 7 — `lib/site.sh`: `current_get` / `current_set` / `current_clear` + `now_iso` in common.sh

**Files:**
- Modify: `scripts/lib/common.sh` (add `now_iso`)
- Modify: `scripts/lib/site.sh`
- Modify: `tests/common.bats`
- Modify: `tests/site.bats`

The verbs need an ISO-8601 timestamp helper for `created_at` / `last_used_at`. Adding it now keeps Task 8 (`browser-add-site.sh`) self-contained.

- [ ] **Step 1: Write the failing tests**

Append to `tests/common.bats`:

```bash
@test "common.sh: now_iso emits a UTC timestamp matching YYYY-MM-DDTHH:MM:SSZ" {
  run bash -c "source '${LIB_DIR}/common.sh'; now_iso"
  assert_status 0
  printf '%s' "${output}" | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$'
}
```

Append to `tests/site.bats`:

```bash
@test "site.sh: current_get echoes empty when CURRENT_FILE missing" {
  run bash -c "source '${LIB_DIR}/common.sh'; init_paths; source '${LIB_DIR}/site.sh'; current_get"
  assert_status 0
  [ -z "${output}" ]
}

@test "site.sh: current_set writes name to CURRENT_FILE at mode 0600" {
  bash -c "source '${LIB_DIR}/common.sh'; init_paths; source '${LIB_DIR}/site.sh'; site_save prod '{\"name\":\"prod\"}' '{\"name\":\"prod\"}'"
  run bash -c "source '${LIB_DIR}/common.sh'; init_paths; source '${LIB_DIR}/site.sh'; current_set prod"
  assert_status 0
  [ "$(cat "${BROWSER_SKILL_HOME}/current")" = "prod" ]
  local mode
  mode="$(stat -f '%Lp' "${BROWSER_SKILL_HOME}/current" 2>/dev/null \
       || stat -c '%a' "${BROWSER_SKILL_HOME}/current" 2>/dev/null)"
  [ "${mode}" = "600" ]
}

@test "site.sh: current_set refuses an unknown site (exit 23)" {
  run bash -c "source '${LIB_DIR}/common.sh'; init_paths; source '${LIB_DIR}/site.sh'; current_set ghost"
  assert_status "$EXIT_SITE_NOT_FOUND"
}

@test "site.sh: current_clear removes CURRENT_FILE" {
  printf 'x\n' > "${BROWSER_SKILL_HOME}/current"
  run bash -c "source '${LIB_DIR}/common.sh'; init_paths; source '${LIB_DIR}/site.sh'; current_clear"
  assert_status 0
  [ ! -f "${BROWSER_SKILL_HOME}/current" ]
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bats tests/common.bats tests/site.bats`
Expected: FAIL — `now_iso: command not found`; `current_get: command not found`.

- [ ] **Step 3: Write minimal implementation**

Append to `scripts/lib/common.sh` (just below `now_ms`):

```bash
# now_iso echoes the current UTC time as RFC-3339 / ISO-8601, second precision,
# trailing Z. Portable across GNU date (-u +%FT%TZ) and BSD date.
now_iso() {
  date -u +%Y-%m-%dT%H:%M:%SZ
}
```

Append to `scripts/lib/site.sh`:

```bash
# current_get → echo current site name (empty string if unset).
current_get() {
  if [ -f "${CURRENT_FILE}" ]; then
    tr -d '[:space:]' < "${CURRENT_FILE}"
  fi
}

# current_set NAME → set CURRENT_FILE to NAME (must be a registered site).
current_set() {
  local name="$1"
  if ! site_exists "${name}"; then
    die "${EXIT_SITE_NOT_FOUND}" "cannot set current: site not found: ${name}"
  fi
  mkdir -p "${BROWSER_SKILL_HOME}"
  ( umask 077; printf '%s\n' "${name}" > "${CURRENT_FILE}" )
  chmod 600 "${CURRENT_FILE}"
}

# current_clear → rm -f CURRENT_FILE (idempotent).
current_clear() {
  rm -f "${CURRENT_FILE}"
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bats tests/common.bats tests/site.bats`
Expected: all green (4 new tests, 21 site tests total counting all earlier ones).

- [ ] **Step 5: Commit**

```bash
git add scripts/lib/common.sh scripts/lib/site.sh tests/common.bats tests/site.bats
git commit -m "feat(lib): now_iso + current_{get,set,clear} site helpers"
```

---

## Task 8 — `browser-add-site.sh`: site CRUD verb (write side)

**Files:**
- Create: `scripts/browser-add-site.sh`
- Modify: `tests/site.bats`

- [ ] **Step 1: Write the failing test**

Append to `tests/site.bats`:

```bash
@test "add-site: minimal --name + --url succeeds and writes default profile" {
  run bash "${SCRIPTS_DIR}/browser-add-site.sh" --name prod-app --url https://app.example.com
  assert_status 0
  local profile="${BROWSER_SKILL_HOME}/sites/prod-app.json"
  [ -f "${profile}" ]
  [ "$(jq -r .name "${profile}")" = "prod-app" ]
  [ "$(jq -r .url "${profile}")" = "https://app.example.com" ]
  [ "$(jq -r .viewport.width "${profile}")" = "1280" ]
  [ "$(jq -r .viewport.height "${profile}")" = "800" ]
  [ "$(jq -r .schema_version "${profile}")" = "1" ]
  # Final line is the JSON summary.
  local last_json
  last_json="$(printf '%s\n' "${lines[@]}" | tail -n 1)"
  printf '%s' "${last_json}" | jq -e '.verb == "add-site" and .status == "ok"' >/dev/null
}

@test "add-site: --viewport WxH overrides default" {
  run bash "${SCRIPTS_DIR}/browser-add-site.sh" --name x --url https://x.test --viewport 1920x1080
  assert_status 0
  [ "$(jq -r .viewport.width  "${BROWSER_SKILL_HOME}/sites/x.json")" = "1920" ]
  [ "$(jq -r .viewport.height "${BROWSER_SKILL_HOME}/sites/x.json")" = "1080" ]
}

@test "add-site: --label, --default-session, --default-tool stored verbatim" {
  run bash "${SCRIPTS_DIR}/browser-add-site.sh" \
    --name prod-app --url https://app.example.com \
    --label "Production app" --default-session prod-app--admin --default-tool playwright-cli
  assert_status 0
  local profile="${BROWSER_SKILL_HOME}/sites/prod-app.json"
  [ "$(jq -r .label             "${profile}")" = "Production app" ]
  [ "$(jq -r .default_session   "${profile}")" = "prod-app--admin" ]
  [ "$(jq -r .default_tool      "${profile}")" = "playwright-cli" ]
}

@test "add-site: rejects an existing site without --force (exit 2)" {
  bash "${SCRIPTS_DIR}/browser-add-site.sh" --name prod --url https://x.test >/dev/null
  run bash "${SCRIPTS_DIR}/browser-add-site.sh" --name prod --url https://other.test
  assert_status "$EXIT_USAGE_ERROR"
  assert_output_contains "already exists"
}

@test "add-site: --force overwrites" {
  bash "${SCRIPTS_DIR}/browser-add-site.sh" --name prod --url https://x.test >/dev/null
  run bash "${SCRIPTS_DIR}/browser-add-site.sh" --name prod --url https://other.test --force
  assert_status 0
  [ "$(jq -r .url "${BROWSER_SKILL_HOME}/sites/prod.json")" = "https://other.test" ]
}

@test "add-site: --dry-run writes nothing and reports planned action" {
  run bash "${SCRIPTS_DIR}/browser-add-site.sh" --name prod --url https://x.test --dry-run
  assert_status 0
  [ ! -f "${BROWSER_SKILL_HOME}/sites/prod.json" ]
  local last_json
  last_json="$(printf '%s\n' "${lines[@]}" | tail -n 1)"
  printf '%s' "${last_json}" | jq -e '.would_run == true' >/dev/null
}

@test "add-site: rejects URL without scheme:// (exit 2)" {
  run bash "${SCRIPTS_DIR}/browser-add-site.sh" --name x --url example.com
  assert_status "$EXIT_USAGE_ERROR"
  assert_output_contains "url must start with"
}

@test "add-site: rejects bad --viewport format (exit 2)" {
  run bash "${SCRIPTS_DIR}/browser-add-site.sh" --name x --url https://x.test --viewport 1280
  assert_status "$EXIT_USAGE_ERROR"
  assert_output_contains "viewport"
}

@test "add-site: missing --name or --url is a usage error" {
  run bash "${SCRIPTS_DIR}/browser-add-site.sh" --url https://x.test
  assert_status "$EXIT_USAGE_ERROR"
  run bash "${SCRIPTS_DIR}/browser-add-site.sh" --name x
  assert_status "$EXIT_USAGE_ERROR"
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bats tests/site.bats`
Expected: FAIL — `scripts/browser-add-site.sh: No such file or directory`.

- [ ] **Step 3: Write minimal implementation**

```bash
# scripts/browser-add-site.sh
#!/usr/bin/env bash
# add-site — register a site profile under sites/<name>.json.
set -euo pipefail
IFS=$'\n\t'
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/common.sh"
# shellcheck source=lib/site.sh
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/site.sh"
init_paths

name=""; url=""; viewport="1280x800"; user_agent=""; stealth="false"
default_session=""; default_tool=""; label=""
force=0; dry_run=0

usage() {
  cat <<'USAGE'
Usage: add-site --name NAME --url URL [options]

  --name NAME              site name (required, used as filename)
  --url  URL               site URL (must start with http:// or https://)
  --viewport WxH           viewport (default 1280x800)
  --user-agent UA          override user agent
  --stealth                set stealth flag (default false)
  --default-session NAME   default session for verbs that omit --session
  --default-tool NAME      default tool for verbs that omit --tool
  --label TEXT             human-readable description
  --force                  overwrite an existing site
  --dry-run                print planned action; write nothing
  -h, --help               this message
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --name)             name="$2";              shift 2 ;;
    --url)              url="$2";               shift 2 ;;
    --viewport)         viewport="$2";          shift 2 ;;
    --user-agent)       user_agent="$2";        shift 2 ;;
    --stealth)          stealth="true";         shift ;;
    --default-session)  default_session="$2";   shift 2 ;;
    --default-tool)     default_tool="$2";      shift 2 ;;
    --label)            label="$2";             shift 2 ;;
    --force)            force=1;                shift ;;
    --dry-run)          dry_run=1;              shift ;;
    -h|--help)          usage; exit 0 ;;
    *)                  die "${EXIT_USAGE_ERROR}" "unknown flag: $1" ;;
  esac
done

[ -n "${name}" ] || { usage; die "${EXIT_USAGE_ERROR}" "--name is required"; }
[ -n "${url}" ]  || { usage; die "${EXIT_USAGE_ERROR}" "--url is required"; }
case "${url}" in
  http://*|https://*) ;;
  *) die "${EXIT_USAGE_ERROR}" "url must start with http:// or https:// (got: ${url})" ;;
esac
[[ "${viewport}" =~ ^[0-9]+x[0-9]+$ ]] \
  || die "${EXIT_USAGE_ERROR}" "viewport must be WIDTHxHEIGHT (got: ${viewport})"
vw="${viewport%x*}"; vh="${viewport#*x}"

started_at_ms="$(now_ms)"

if site_exists "${name}" && [ "${force}" -ne 1 ]; then
  die "${EXIT_USAGE_ERROR}" "site already exists: ${name} (use --force to overwrite)"
fi

profile_json="$(jq -nc \
  --arg n "${name}" \
  --arg u "${url}" \
  --argjson vw "${vw}" --argjson vh "${vh}" \
  --arg ua "${user_agent}" \
  --argjson stealth "${stealth}" \
  --arg ds "${default_session}" \
  --arg dt "${default_tool}" \
  --arg lbl "${label}" \
  '{
    name: $n, url: $u,
    viewport: {width: $vw, height: $vh},
    user_agent: (if $ua == "" then null else $ua end),
    stealth: $stealth,
    default_session: (if $ds == "" then null else $ds end),
    default_tool:    (if $dt == "" then null else $dt end),
    label: $lbl,
    schema_version: 1
  }')"

now_ts="$(now_iso)"
meta_json="$(jq -nc \
  --arg n "${name}" \
  --arg now "${now_ts}" \
  '{name: $n, created_at: $now, last_used_at: $now}')"

if [ "${dry_run}" -eq 1 ]; then
  ok "dry-run: would write ${SITES_DIR}/${name}.json"
  duration_ms=$(( $(now_ms) - started_at_ms ))
  summary_json verb=add-site tool=none why=dry-run status=ok would_run=true \
               site="${name}" duration_ms="${duration_ms}"
  exit "${EXIT_OK}"
fi

site_save "${name}" "${profile_json}" "${meta_json}"
ok "site added: ${name}"

duration_ms=$(( $(now_ms) - started_at_ms ))
summary_json verb=add-site tool=none why=write-profile status=ok \
             site="${name}" duration_ms="${duration_ms}"
```

- [ ] **Step 4: Run test to verify it passes**

```bash
chmod +x scripts/browser-add-site.sh
bats tests/site.bats
```
Expected: all 26 site tests green.

- [ ] **Step 5: Commit**

```bash
git add scripts/browser-add-site.sh tests/site.bats
git commit -m "feat(site): add-site verb with --dry-run and --force"
```

---

## Task 9 — `browser-list-sites.sh`

**Files:**
- Create: `scripts/browser-list-sites.sh`
- Modify: `tests/site.bats`

- [ ] **Step 1: Write the failing test**

Append to `tests/site.bats`:

```bash
@test "list-sites: empty directory → status=ok and zero rows" {
  run bash "${SCRIPTS_DIR}/browser-list-sites.sh"
  assert_status 0
  local last_json
  last_json="$(printf '%s\n' "${lines[@]}" | tail -n 1)"
  printf '%s' "${last_json}" | jq -e '.verb == "list-sites" and .status == "ok" and .count == 0' >/dev/null
}

@test "list-sites: lists registered sites with name + label + url" {
  bash "${SCRIPTS_DIR}/browser-add-site.sh" --name a --url https://a.test --label "App A" >/dev/null
  bash "${SCRIPTS_DIR}/browser-add-site.sh" --name b --url https://b.test --label "App B" >/dev/null
  run bash "${SCRIPTS_DIR}/browser-list-sites.sh"
  assert_status 0
  local last_json
  last_json="$(printf '%s\n' "${lines[@]}" | tail -n 1)"
  [ "$(printf '%s' "${last_json}" | jq -r '.count')" = "2" ]
  [ "$(printf '%s' "${last_json}" | jq -r '.sites[0].name')"  = "a" ]
  [ "$(printf '%s' "${last_json}" | jq -r '.sites[0].url')"   = "https://a.test" ]
  [ "$(printf '%s' "${last_json}" | jq -r '.sites[0].label')" = "App A" ]
  [ "$(printf '%s' "${last_json}" | jq -r '.sites[1].name')"  = "b" ]
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bats tests/site.bats`
Expected: FAIL — `scripts/browser-list-sites.sh: No such file or directory`.

- [ ] **Step 3: Write minimal implementation**

```bash
# scripts/browser-list-sites.sh
#!/usr/bin/env bash
# list-sites — list registered site profiles (no creds; sites are non-secret).
set -euo pipefail
IFS=$'\n\t'
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/common.sh"
# shellcheck source=lib/site.sh
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/site.sh"
init_paths

started_at_ms="$(now_ms)"

names="$(site_list_names)"
rows='[]'
count=0
if [ -n "${names}" ]; then
  while IFS= read -r n; do
    [ -z "${n}" ] && continue
    profile="$(site_load "${n}")"
    meta="$(site_meta_load "${n}")"
    rows="$(jq --argjson p "${profile}" --argjson m "${meta}" '
      . + [{
        name:           $p.name,
        url:            $p.url,
        label:          ($p.label // ""),
        default_session:$p.default_session,
        default_tool:   $p.default_tool,
        last_used_at:   ($m.last_used_at // null)
      }]' <<< "${rows}")"
    count=$((count + 1))
  done <<< "${names}"
fi

duration_ms=$(( $(now_ms) - started_at_ms ))
jq -cn --argjson r "${rows}" --argjson c "${count}" --argjson d "${duration_ms}" \
  '{verb: "list-sites", tool: "none", why: "list", status: "ok",
    count: $c, sites: $r, duration_ms: $d}'
```

- [ ] **Step 4: Run test to verify it passes**

```bash
chmod +x scripts/browser-list-sites.sh
bats tests/site.bats
```
Expected: all green.

- [ ] **Step 5: Commit**

```bash
git add scripts/browser-list-sites.sh tests/site.bats
git commit -m "feat(site): list-sites verb"
```

---

## Task 10 — `browser-show-site.sh`

**Files:**
- Create: `scripts/browser-show-site.sh`
- Modify: `tests/site.bats`

- [ ] **Step 1: Write the failing test**

Append to `tests/site.bats`:

```bash
@test "show-site: prints profile JSON and a JSON summary" {
  bash "${SCRIPTS_DIR}/browser-add-site.sh" --name prod --url https://x.test --label "Prod" >/dev/null
  run bash "${SCRIPTS_DIR}/browser-show-site.sh" --name prod
  assert_status 0
  local last_json
  last_json="$(printf '%s\n' "${lines[@]}" | tail -n 1)"
  printf '%s' "${last_json}" | jq -e '.verb == "show-site" and .status == "ok" and .site == "prod"' >/dev/null
  [ "$(printf '%s' "${last_json}" | jq -r '.profile.url')" = "https://x.test" ]
}

@test "show-site: missing site exits 23 (SITE_NOT_FOUND)" {
  run bash "${SCRIPTS_DIR}/browser-show-site.sh" --name nope
  assert_status "$EXIT_SITE_NOT_FOUND"
}

@test "show-site: requires --name (exit 2)" {
  run bash "${SCRIPTS_DIR}/browser-show-site.sh"
  assert_status "$EXIT_USAGE_ERROR"
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bats tests/site.bats`
Expected: FAIL — `scripts/browser-show-site.sh: No such file or directory`.

- [ ] **Step 3: Write minimal implementation**

```bash
# scripts/browser-show-site.sh
#!/usr/bin/env bash
# show-site — emit one site's full profile JSON.
# (Phase 5 will mask credential-shaped fields if any are added; today the
#  profile contains nothing secret, so this verb has no --reveal flag.)
set -euo pipefail
IFS=$'\n\t'
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/common.sh"
# shellcheck source=lib/site.sh
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/site.sh"
init_paths

name=""
usage() { printf 'Usage: show-site --name NAME\n'; }
while [ $# -gt 0 ]; do
  case "$1" in
    --name) name="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "${EXIT_USAGE_ERROR}" "unknown flag: $1" ;;
  esac
done
[ -n "${name}" ] || { usage; die "${EXIT_USAGE_ERROR}" "--name is required"; }

started_at_ms="$(now_ms)"
profile="$(site_load "${name}")"
meta="$(site_meta_load "${name}")"
duration_ms=$(( $(now_ms) - started_at_ms ))

jq -cn --arg n "${name}" --argjson p "${profile}" --argjson m "${meta}" \
       --argjson d "${duration_ms}" \
  '{verb: "show-site", tool: "none", why: "show", status: "ok",
    site: $n, profile: $p, meta: $m, duration_ms: $d}'
```

- [ ] **Step 4: Run test to verify it passes**

```bash
chmod +x scripts/browser-show-site.sh
bats tests/site.bats
```
Expected: all green.

- [ ] **Step 5: Commit**

```bash
git add scripts/browser-show-site.sh tests/site.bats
git commit -m "feat(site): show-site verb"
```

---

## Task 11 — `browser-remove-site.sh` (typed-name confirmation)

**Files:**
- Create: `scripts/browser-remove-site.sh`
- Modify: `tests/site.bats`

- [ ] **Step 1: Write the failing test**

Append to `tests/site.bats`:

```bash
@test "remove-site: removes a registered site (typed-name confirmation via stdin)" {
  bash "${SCRIPTS_DIR}/browser-add-site.sh" --name prod --url https://x.test >/dev/null
  run bash -c "printf 'prod\n' | '${SCRIPTS_DIR}/browser-remove-site.sh' --name prod"
  assert_status 0
  [ ! -f "${BROWSER_SKILL_HOME}/sites/prod.json" ]
}

@test "remove-site: refuses on confirmation mismatch" {
  bash "${SCRIPTS_DIR}/browser-add-site.sh" --name prod --url https://x.test >/dev/null
  run bash -c "printf 'wrong\n' | '${SCRIPTS_DIR}/browser-remove-site.sh' --name prod"
  assert_status "$EXIT_USAGE_ERROR"
  [ -f "${BROWSER_SKILL_HOME}/sites/prod.json" ]
}

@test "remove-site: --yes-i-know skips the prompt" {
  bash "${SCRIPTS_DIR}/browser-add-site.sh" --name prod --url https://x.test >/dev/null
  run bash "${SCRIPTS_DIR}/browser-remove-site.sh" --name prod --yes-i-know
  assert_status 0
  [ ! -f "${BROWSER_SKILL_HOME}/sites/prod.json" ]
}

@test "remove-site: missing site exits 23" {
  run bash "${SCRIPTS_DIR}/browser-remove-site.sh" --name ghost --yes-i-know
  assert_status "$EXIT_SITE_NOT_FOUND"
}

@test "remove-site: --dry-run prints planned action and writes nothing" {
  bash "${SCRIPTS_DIR}/browser-add-site.sh" --name prod --url https://x.test >/dev/null
  run bash "${SCRIPTS_DIR}/browser-remove-site.sh" --name prod --dry-run
  assert_status 0
  [ -f "${BROWSER_SKILL_HOME}/sites/prod.json" ]
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bats tests/site.bats`
Expected: FAIL — `scripts/browser-remove-site.sh: No such file or directory`.

- [ ] **Step 3: Write minimal implementation**

```bash
# scripts/browser-remove-site.sh
#!/usr/bin/env bash
# remove-site — typed-name confirmation, then delete profile + meta.
# Cascade: if CURRENT_FILE points at this site, lib/site.sh::site_delete
# clears it. (Sessions / credentials linked to this site are NOT removed in
# Phase 2 — that lands with the credential lifecycle in Phase 5.)
set -euo pipefail
IFS=$'\n\t'
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/common.sh"
# shellcheck source=lib/site.sh
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/site.sh"
init_paths

name=""; yes=0; dry_run=0
usage() {
  cat <<'USAGE'
Usage: remove-site --name NAME [--yes-i-know] [--dry-run]

  --name NAME      site to remove (required)
  --yes-i-know     skip the typed-name confirmation
  --dry-run        print planned action; remove nothing
USAGE
}
while [ $# -gt 0 ]; do
  case "$1" in
    --name)        name="$2"; shift 2 ;;
    --yes-i-know)  yes=1; shift ;;
    --dry-run)     dry_run=1; shift ;;
    -h|--help)     usage; exit 0 ;;
    *)             die "${EXIT_USAGE_ERROR}" "unknown flag: $1" ;;
  esac
done
[ -n "${name}" ] || { usage; die "${EXIT_USAGE_ERROR}" "--name is required"; }

started_at_ms="$(now_ms)"

if ! site_exists "${name}"; then
  die "${EXIT_SITE_NOT_FOUND}" "site not found: ${name}"
fi

if [ "${dry_run}" -eq 1 ]; then
  ok "dry-run: would remove site ${name}"
  duration_ms=$(( $(now_ms) - started_at_ms ))
  summary_json verb=remove-site tool=none why=dry-run status=ok would_run=true \
               site="${name}" duration_ms="${duration_ms}"
  exit "${EXIT_OK}"
fi

if [ "${yes}" -ne 1 ]; then
  printf 'Type the site name (%s) to confirm removal: ' "${name}" >&2
  answer=""
  IFS= read -r answer || true
  if [ "${answer}" != "${name}" ]; then
    die "${EXIT_USAGE_ERROR}" "removal aborted (confirmation mismatch)"
  fi
fi

site_delete "${name}"
ok "site removed: ${name}"

duration_ms=$(( $(now_ms) - started_at_ms ))
summary_json verb=remove-site tool=none why=delete status=ok \
             site="${name}" duration_ms="${duration_ms}"
```

- [ ] **Step 4: Run test to verify it passes**

```bash
chmod +x scripts/browser-remove-site.sh
bats tests/site.bats
```
Expected: all green.

- [ ] **Step 5: Commit**

```bash
git add scripts/browser-remove-site.sh tests/site.bats
git commit -m "feat(site): remove-site verb with typed-name confirmation"
```

---

## Task 12 — `browser-use.sh` (set / show / clear current site)

**Files:**
- Create: `scripts/browser-use.sh`
- Modify: `tests/site.bats`

- [ ] **Step 1: Write the failing test**

Append to `tests/site.bats`:

```bash
@test "use: --show prints empty when no current site set" {
  run bash "${SCRIPTS_DIR}/browser-use.sh" --show
  assert_status 0
  local last_json
  last_json="$(printf '%s\n' "${lines[@]}" | tail -n 1)"
  printf '%s' "${last_json}" | jq -e '.verb == "use" and .status == "ok" and .current == null' >/dev/null
}

@test "use: --set NAME persists, --show then reports it" {
  bash "${SCRIPTS_DIR}/browser-add-site.sh" --name prod --url https://x.test >/dev/null
  run bash "${SCRIPTS_DIR}/browser-use.sh" --set prod
  assert_status 0
  [ "$(cat "${BROWSER_SKILL_HOME}/current")" = "prod" ]
  run bash "${SCRIPTS_DIR}/browser-use.sh" --show
  local last_json
  last_json="$(printf '%s\n' "${lines[@]}" | tail -n 1)"
  [ "$(printf '%s' "${last_json}" | jq -r '.current')" = "prod" ]
}

@test "use: --set rejects an unknown site (exit 23)" {
  run bash "${SCRIPTS_DIR}/browser-use.sh" --set ghost
  assert_status "$EXIT_SITE_NOT_FOUND"
}

@test "use: --clear removes CURRENT_FILE" {
  bash "${SCRIPTS_DIR}/browser-add-site.sh" --name prod --url https://x.test >/dev/null
  bash "${SCRIPTS_DIR}/browser-use.sh" --set prod >/dev/null
  run bash "${SCRIPTS_DIR}/browser-use.sh" --clear
  assert_status 0
  [ ! -f "${BROWSER_SKILL_HOME}/current" ]
}

@test "use: requires exactly one of --set/--show/--clear (exit 2)" {
  run bash "${SCRIPTS_DIR}/browser-use.sh"
  assert_status "$EXIT_USAGE_ERROR"
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bats tests/site.bats`
Expected: FAIL — `scripts/browser-use.sh: No such file or directory`.

- [ ] **Step 3: Write minimal implementation**

```bash
# scripts/browser-use.sh
#!/usr/bin/env bash
# use — get / set / clear the current site (CURRENT_FILE).
set -euo pipefail
IFS=$'\n\t'
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/common.sh"
# shellcheck source=lib/site.sh
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/site.sh"
init_paths

mode=""; arg=""
usage() {
  cat <<'USAGE'
Usage: use --set NAME | --show | --clear
USAGE
}
while [ $# -gt 0 ]; do
  case "$1" in
    --set)    mode=set;   arg="$2"; shift 2 ;;
    --show)   mode=show;  shift ;;
    --clear)  mode=clear; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "${EXIT_USAGE_ERROR}" "unknown flag: $1" ;;
  esac
done
[ -n "${mode}" ] || { usage; die "${EXIT_USAGE_ERROR}" "specify --set NAME, --show, or --clear"; }

started_at_ms="$(now_ms)"

case "${mode}" in
  set)
    [ -n "${arg}" ] || die "${EXIT_USAGE_ERROR}" "--set requires NAME"
    current_set "${arg}"
    ok "current site: ${arg}"
    why="set"
    ;;
  show)
    why="show"
    ;;
  clear)
    current_clear
    ok "current site cleared"
    why="clear"
    ;;
esac

current="$(current_get)"
duration_ms=$(( $(now_ms) - started_at_ms ))
if [ -z "${current}" ]; then
  jq -cn --arg w "${why}" --argjson d "${duration_ms}" \
    '{verb: "use", tool: "none", why: $w, status: "ok", current: null, duration_ms: $d}'
else
  jq -cn --arg w "${why}" --arg c "${current}" --argjson d "${duration_ms}" \
    '{verb: "use", tool: "none", why: $w, status: "ok", current: $c, duration_ms: $d}'
fi
```

- [ ] **Step 4: Run test to verify it passes**

```bash
chmod +x scripts/browser-use.sh
bats tests/site.bats
```
Expected: all green.

- [ ] **Step 5: Commit**

```bash
git add scripts/browser-use.sh tests/site.bats
git commit -m "feat(site): use verb (set/show/clear current site)"
```

---

## Task 13 — `lib/session.sh`: paths + `session_exists`

**Files:**
- Create: `scripts/lib/session.sh`
- Create: `tests/session.bats`

- [ ] **Step 1: Write the failing test**

```bash
# tests/session.bats
load helpers

setup() {
  setup_temp_home
  mkdir -p "${BROWSER_SKILL_HOME}/sessions"
  chmod 700 "${BROWSER_SKILL_HOME}" "${BROWSER_SKILL_HOME}/sessions"
}

teardown() { teardown_temp_home; }

@test "session.sh: source guard prevents double-source" {
  run bash -c "source '${LIB_DIR}/session.sh'; source '${LIB_DIR}/session.sh'; printf '%s\n' \"\${BROWSER_SKILL_SESSION_LOADED:-unset}\""
  assert_status 0
  [ "${output}" = "1" ]
}

@test "session.sh: _session_path echoes <SESSIONS_DIR>/<name>.json" {
  run bash -c "source '${LIB_DIR}/common.sh'; init_paths; source '${LIB_DIR}/session.sh'; _session_path prod-app--admin"
  assert_status 0
  [ "${output}" = "${BROWSER_SKILL_HOME}/sessions/prod-app--admin.json" ]
}

@test "session.sh: _session_meta_path echoes <SESSIONS_DIR>/<name>.meta.json" {
  run bash -c "source '${LIB_DIR}/common.sh'; init_paths; source '${LIB_DIR}/session.sh'; _session_meta_path prod-app--admin"
  assert_status 0
  [ "${output}" = "${BROWSER_SKILL_HOME}/sessions/prod-app--admin.meta.json" ]
}

@test "session.sh: session_exists is false for missing, true for present" {
  run bash -c "source '${LIB_DIR}/common.sh'; init_paths; source '${LIB_DIR}/session.sh'; session_exists nope"
  assert_status 1
  printf '{}' > "${BROWSER_SKILL_HOME}/sessions/here.json"
  run bash -c "source '${LIB_DIR}/common.sh'; init_paths; source '${LIB_DIR}/session.sh'; session_exists here"
  assert_status 0
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bats tests/session.bats`
Expected: FAIL — `scripts/lib/session.sh: No such file or directory`.

- [ ] **Step 3: Write minimal implementation**

```bash
# scripts/lib/session.sh
# Read/write helpers for Playwright storageState files plus their meta sidecar.
# Source from any verb that needs to load or save a session.
# Requires lib/common.sh sourced first (init_paths must have run).

[ -n "${BROWSER_SKILL_SESSION_LOADED:-}" ] && return 0
readonly BROWSER_SKILL_SESSION_LOADED=1

_session_path()      { printf '%s/%s.json'      "${SESSIONS_DIR}" "$1"; }
_session_meta_path() { printf '%s/%s.meta.json' "${SESSIONS_DIR}" "$1"; }

session_exists() {
  [ -f "$(_session_path "$1")" ]
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bats tests/session.bats`
Expected: 4 tests green.

- [ ] **Step 5: Commit**

```bash
git add scripts/lib/session.sh tests/session.bats
git commit -m "feat(lib): session.sh path helpers + session_exists"
```

---

## Task 14 — `lib/session.sh`: `session_save` (atomic write + sidecar)

**Files:**
- Modify: `scripts/lib/session.sh`
- Modify: `tests/session.bats`

- [ ] **Step 1: Write the failing test**

Append to `tests/session.bats`:

```bash
@test "session.sh: session_save writes storageState + meta atomically at mode 0600" {
  local ss='{"cookies":[{"name":"sid","value":"abc","domain":"app.example.com","path":"/","expires":-1,"httpOnly":true,"secure":true,"sameSite":"Lax"}],"origins":[{"origin":"https://app.example.com","localStorage":[]}]}'
  local meta='{"name":"prod-app--admin","site":"prod-app","origin":"https://app.example.com","captured_at":"2026-04-29T15:42:00Z","source_user_agent":"phase-2 stub","expires_in_hours":168,"schema_version":1}'
  run bash -c "source '${LIB_DIR}/common.sh'; init_paths; source '${LIB_DIR}/session.sh'; session_save prod-app--admin '${ss}' '${meta}'"
  assert_status 0
  jq -e '.cookies[0].name == "sid"' "${BROWSER_SKILL_HOME}/sessions/prod-app--admin.json" >/dev/null
  jq -e '.schema_version == 1' "${BROWSER_SKILL_HOME}/sessions/prod-app--admin.meta.json" >/dev/null
  for f in prod-app--admin.json prod-app--admin.meta.json; do
    local mode
    mode="$(stat -f '%Lp' "${BROWSER_SKILL_HOME}/sessions/${f}" 2>/dev/null \
         || stat -c '%a' "${BROWSER_SKILL_HOME}/sessions/${f}" 2>/dev/null)"
    [ "${mode}" = "600" ] || fail "expected mode 600 on ${f}, got ${mode}"
  done
}

@test "session.sh: session_save rejects malformed storageState JSON (exit 2)" {
  run bash -c "source '${LIB_DIR}/common.sh'; init_paths; source '${LIB_DIR}/session.sh'; session_save x 'not json' '{}'"
  assert_status "$EXIT_USAGE_ERROR"
}

@test "session.sh: session_save rejects storageState missing cookies/origins arrays (exit 2)" {
  run bash -c "source '${LIB_DIR}/common.sh'; init_paths; source '${LIB_DIR}/session.sh'; session_save x '{\"cookies\":[]}' '{}'"
  assert_status "$EXIT_USAGE_ERROR"
  assert_output_contains "origins"
  run bash -c "source '${LIB_DIR}/common.sh'; init_paths; source '${LIB_DIR}/session.sh'; session_save x '{\"origins\":[]}' '{}'"
  assert_status "$EXIT_USAGE_ERROR"
  assert_output_contains "cookies"
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bats tests/session.bats`
Expected: FAIL — `session_save: command not found`.

- [ ] **Step 3: Write minimal implementation**

Append to `scripts/lib/session.sh`:

```bash
# session_save NAME STORAGE_STATE_JSON META_JSON
# Validates that storageState has top-level `cookies` and `origins` arrays
# (Playwright shape), then writes both files atomically at mode 0600.
session_save() {
  local name="$1" ss_json="$2" meta_json="$3"

  if ! printf '%s' "${ss_json}" | jq -e . >/dev/null 2>&1; then
    die "${EXIT_USAGE_ERROR}" "session_save: storageState JSON is not valid"
  fi
  if ! printf '%s' "${ss_json}" | jq -e '.cookies | type == "array"' >/dev/null 2>&1; then
    die "${EXIT_USAGE_ERROR}" "session_save: storageState missing cookies array"
  fi
  if ! printf '%s' "${ss_json}" | jq -e '.origins | type == "array"' >/dev/null 2>&1; then
    die "${EXIT_USAGE_ERROR}" "session_save: storageState missing origins array"
  fi
  if ! printf '%s' "${meta_json}" | jq -e . >/dev/null 2>&1; then
    die "${EXIT_USAGE_ERROR}" "session_save: meta JSON is not valid"
  fi

  mkdir -p "${SESSIONS_DIR}"
  chmod 700 "${SESSIONS_DIR}"

  local ss_path meta_path ss_tmp meta_tmp
  ss_path="$(_session_path "${name}")"
  meta_path="$(_session_meta_path "${name}")"
  ss_tmp="${ss_path}.tmp.$$"
  meta_tmp="${meta_path}.tmp.$$"

  (
    umask 077
    printf '%s\n' "${ss_json}"   | jq . > "${ss_tmp}"
    printf '%s\n' "${meta_json}" | jq . > "${meta_tmp}"
  )
  chmod 600 "${ss_tmp}" "${meta_tmp}"
  mv "${ss_tmp}" "${ss_path}"
  mv "${meta_tmp}" "${meta_path}"
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bats tests/session.bats`
Expected: 7 tests green.

- [ ] **Step 5: Commit**

```bash
git add scripts/lib/session.sh tests/session.bats
git commit -m "feat(lib): session_save with storageState validation"
```

---

## Task 15 — `lib/session.sh`: `session_load` + `session_meta_load`

**Files:**
- Modify: `scripts/lib/session.sh`
- Modify: `tests/session.bats`

- [ ] **Step 1: Write the failing test**

Append to `tests/session.bats`:

```bash
@test "session.sh: session_load echoes the storageState JSON" {
  local ss='{"cookies":[],"origins":[{"origin":"https://app.example.com","localStorage":[]}]}'
  bash -c "source '${LIB_DIR}/common.sh'; init_paths; source '${LIB_DIR}/session.sh'; session_save x '${ss}' '{\"name\":\"x\",\"site\":\"y\",\"origin\":\"https://app.example.com\",\"schema_version\":1}'"
  run bash -c "source '${LIB_DIR}/common.sh'; init_paths; source '${LIB_DIR}/session.sh'; session_load x | jq -r '.origins[0].origin'"
  assert_status 0
  [ "${output}" = "https://app.example.com" ]
}

@test "session.sh: session_load fails (exit 22) when missing" {
  run bash -c "source '${LIB_DIR}/common.sh'; init_paths; source '${LIB_DIR}/session.sh'; session_load nope"
  assert_status "$EXIT_SESSION_EXPIRED"
  assert_output_contains "session not found"
}

@test "session.sh: session_meta_load echoes the meta JSON" {
  local ss='{"cookies":[],"origins":[]}'
  bash -c "source '${LIB_DIR}/common.sh'; init_paths; source '${LIB_DIR}/session.sh'; session_save x '${ss}' '{\"name\":\"x\",\"origin\":\"https://x.test\",\"schema_version\":1}'"
  run bash -c "source '${LIB_DIR}/common.sh'; init_paths; source '${LIB_DIR}/session.sh'; session_meta_load x | jq -r .origin"
  assert_status 0
  [ "${output}" = "https://x.test" ]
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bats tests/session.bats`
Expected: FAIL — `session_load: command not found`.

- [ ] **Step 3: Write minimal implementation**

Append to `scripts/lib/session.sh`:

```bash
# session_load NAME → echoes the storageState JSON (Playwright shape).
# Missing session → exit 22 (SESSION_EXPIRED) per spec §5.5; the caller
# can decide whether to relogin (Phase 5) or surface to the user.
session_load() {
  local name="$1"
  local path
  path="$(_session_path "${name}")"
  if [ ! -f "${path}" ]; then
    die "${EXIT_SESSION_EXPIRED}" "session not found: ${name}"
  fi
  cat "${path}"
}

session_meta_load() {
  local name="$1"
  local path
  path="$(_session_meta_path "${name}")"
  if [ ! -f "${path}" ]; then
    die "${EXIT_SESSION_EXPIRED}" "session meta not found: ${name}"
  fi
  cat "${path}"
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bats tests/session.bats`
Expected: 10 tests green.

- [ ] **Step 5: Commit**

```bash
git add scripts/lib/session.sh tests/session.bats
git commit -m "feat(lib): session_load + session_meta_load"
```

---

## Task 16 — `lib/session.sh`: `session_origin_check`

**Files:**
- Modify: `scripts/lib/session.sh`
- Modify: `tests/session.bats`

This is the security-critical helper from spec §5.5 ("Origin mismatch on session load — exit 22; we never load cookies into the wrong origin to be helpful"). It compares the session's recorded `origin` (from the meta sidecar) against a target URL's `scheme://host[:port]`.

- [ ] **Step 1: Write the failing test**

Append to `tests/session.bats`:

```bash
@test "session.sh: session_origin_check passes when origins match exactly" {
  bash -c "source '${LIB_DIR}/common.sh'; init_paths; source '${LIB_DIR}/session.sh'; session_save x '{\"cookies\":[],\"origins\":[]}' '{\"name\":\"x\",\"origin\":\"https://app.example.com\",\"schema_version\":1}'"
  run bash -c "source '${LIB_DIR}/common.sh'; init_paths; source '${LIB_DIR}/session.sh'; session_origin_check x https://app.example.com/dashboard"
  assert_status 0
}

@test "session.sh: session_origin_check fails (exit 22) on host mismatch" {
  bash -c "source '${LIB_DIR}/common.sh'; init_paths; source '${LIB_DIR}/session.sh'; session_save x '{\"cookies\":[],\"origins\":[]}' '{\"name\":\"x\",\"origin\":\"https://app.example.com\",\"schema_version\":1}'"
  run bash -c "source '${LIB_DIR}/common.sh'; init_paths; source '${LIB_DIR}/session.sh'; session_origin_check x https://evil.example.com/"
  assert_status "$EXIT_SESSION_EXPIRED"
  assert_output_contains "origin mismatch"
}

@test "session.sh: session_origin_check fails on scheme mismatch" {
  bash -c "source '${LIB_DIR}/common.sh'; init_paths; source '${LIB_DIR}/session.sh'; session_save x '{\"cookies\":[],\"origins\":[]}' '{\"name\":\"x\",\"origin\":\"https://app.example.com\",\"schema_version\":1}'"
  run bash -c "source '${LIB_DIR}/common.sh'; init_paths; source '${LIB_DIR}/session.sh'; session_origin_check x http://app.example.com/"
  assert_status "$EXIT_SESSION_EXPIRED"
}

@test "session.sh: session_origin_check fails on port mismatch when port is part of origin" {
  bash -c "source '${LIB_DIR}/common.sh'; init_paths; source '${LIB_DIR}/session.sh'; session_save x '{\"cookies\":[],\"origins\":[]}' '{\"name\":\"x\",\"origin\":\"https://app.example.com:8443\",\"schema_version\":1}'"
  run bash -c "source '${LIB_DIR}/common.sh'; init_paths; source '${LIB_DIR}/session.sh'; session_origin_check x https://app.example.com/"
  assert_status "$EXIT_SESSION_EXPIRED"
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bats tests/session.bats`
Expected: FAIL — `session_origin_check: command not found`.

- [ ] **Step 3: Write minimal implementation**

Append to `scripts/lib/session.sh`:

```bash
# url_origin URL → echoes scheme://host[:port] from a URL string.
# Bash-only, no python3 dep. Examples:
#   https://app.example.com/x      -> https://app.example.com
#   https://app.example.com:8443/  -> https://app.example.com:8443
#   http://localhost               -> http://localhost
url_origin() {
  local url="$1"
  case "${url}" in
    http://*)  ;;
    https://*) ;;
    *) die "${EXIT_USAGE_ERROR}" "url must start with http:// or https:// (got: ${url})" ;;
  esac
  # Strip the path/query/fragment after the host[:port].
  printf '%s' "${url}" | awk '
    {
      n = index($0, "://")
      scheme = substr($0, 1, n + 2)
      rest   = substr($0, n + 3)
      slash  = index(rest, "/")
      if (slash > 0) rest = substr(rest, 1, slash - 1)
      q = index(rest, "?")
      if (q > 0) rest = substr(rest, 1, q - 1)
      h = index(rest, "#")
      if (h > 0) rest = substr(rest, 1, h - 1)
      printf "%s%s", scheme, rest
    }'
}

# session_origin_check NAME TARGET_URL
# Compares the session's stored origin (from meta sidecar) against the URL's
# origin. Exits EXIT_SESSION_EXPIRED on mismatch (spec §5.5).
session_origin_check() {
  local name="$1" target_url="$2"
  local meta_origin target_origin
  meta_origin="$(session_meta_load "${name}" | jq -r .origin)"
  target_origin="$(url_origin "${target_url}")"
  if [ "${meta_origin}" != "${target_origin}" ]; then
    die "${EXIT_SESSION_EXPIRED}" \
      "origin mismatch: session origin=${meta_origin}, target origin=${target_origin}"
  fi
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bats tests/session.bats`
Expected: 14 tests green.

- [ ] **Step 5: Commit**

```bash
git add scripts/lib/session.sh tests/session.bats
git commit -m "feat(lib): session_origin_check (spec §5.5 enforcement)"
```

---

## Task 17 — `lib/session.sh`: `session_expiry_summary`

**Files:**
- Modify: `scripts/lib/session.sh`
- Modify: `tests/session.bats`

- [ ] **Step 1: Write the failing test**

Append to `tests/session.bats`:

```bash
@test "session.sh: session_expiry_summary emits expires_in_hours from meta" {
  bash -c "source '${LIB_DIR}/common.sh'; init_paths; source '${LIB_DIR}/session.sh'; session_save x '{\"cookies\":[],\"origins\":[]}' '{\"name\":\"x\",\"origin\":\"https://x.test\",\"captured_at\":\"2026-04-29T15:42:00Z\",\"expires_in_hours\":168,\"schema_version\":1}'"
  run bash -c "source '${LIB_DIR}/common.sh'; init_paths; source '${LIB_DIR}/session.sh'; session_expiry_summary x"
  assert_status 0
  printf '%s' "${output}" | jq -e '.session == "x" and .expires_in_hours == 168 and .captured_at == "2026-04-29T15:42:00Z"' >/dev/null
}

@test "session.sh: session_expiry_summary defaults expires_in_hours to null when meta omits it" {
  bash -c "source '${LIB_DIR}/common.sh'; init_paths; source '${LIB_DIR}/session.sh'; session_save x '{\"cookies\":[],\"origins\":[]}' '{\"name\":\"x\",\"origin\":\"https://x.test\",\"schema_version\":1}'"
  run bash -c "source '${LIB_DIR}/common.sh'; init_paths; source '${LIB_DIR}/session.sh'; session_expiry_summary x"
  assert_status 0
  printf '%s' "${output}" | jq -e '.expires_in_hours == null' >/dev/null
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bats tests/session.bats`
Expected: FAIL — `session_expiry_summary: command not found`.

- [ ] **Step 3: Write minimal implementation**

Append to `scripts/lib/session.sh`:

```bash
# session_expiry_summary NAME → emits a single-line JSON object:
#   {"session": NAME, "captured_at": ..., "expires_in_hours": ..., "origin": ...}
# Used by login + later phases' relogin / doctor to surface session staleness.
session_expiry_summary() {
  local name="$1"
  local meta
  meta="$(session_meta_load "${name}")"
  jq -c --arg n "${name}" '{
    session:          $n,
    origin:           (.origin // null),
    captured_at:      (.captured_at // null),
    expires_in_hours: (.expires_in_hours // null)
  }' <<< "${meta}"
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bats tests/session.bats`
Expected: 16 tests green.

- [ ] **Step 5: Commit**

```bash
git add scripts/lib/session.sh tests/session.bats
git commit -m "feat(lib): session_expiry_summary"
```

---

## Task 18 — `browser-login.sh`: arg parsing + stub-adapter file ingestion

**Files:**
- Create: `scripts/browser-login.sh`
- Create: `tests/login.bats`
- Create: `tests/fixtures/storage-state-good.json`

This is the Phase-2 stub-adapter login. It accepts a hand-edited Playwright storageState file via `--storage-state-file PATH`, validates the shape, copies it into `sessions/<name>.json` with a meta sidecar bound to the site's origin. **No browser launch in Phase 2** — Phase 3 will replace the file-read with a real Playwright headed launch behind the same CLI surface.

`--auto` is reserved for Phase 5 (auto-relogin); Phase 2 accepts the flag only to give a clear error.

- [ ] **Step 1: Create the fixture and write the failing test**

Create `tests/fixtures/storage-state-good.json`:

```json
{
  "cookies": [
    {"name": "sid", "value": "phase-2-stub-fixture", "domain": "app.example.com",
     "path": "/", "expires": -1, "httpOnly": true, "secure": true, "sameSite": "Lax"}
  ],
  "origins": [
    {"origin": "https://app.example.com",
     "localStorage": [{"name": "demo", "value": "1"}]}
  ]
}
```

Create `tests/login.bats`:

```bash
load helpers

setup() {
  setup_temp_home
  bash "${REPO_ROOT}/install.sh" --user >/dev/null 2>&1
  bash "${SCRIPTS_DIR}/browser-add-site.sh" \
    --name prod-app --url https://app.example.com >/dev/null
}

teardown() { teardown_temp_home; }

@test "login: writes session JSON + meta from a hand-edited storageState fixture" {
  run bash "${SCRIPTS_DIR}/browser-login.sh" \
    --site prod-app --as prod-app--admin \
    --storage-state-file "${REPO_ROOT}/tests/fixtures/storage-state-good.json"
  assert_status 0
  local ss="${BROWSER_SKILL_HOME}/sessions/prod-app--admin.json"
  local meta="${BROWSER_SKILL_HOME}/sessions/prod-app--admin.meta.json"
  jq -e '.cookies[0].name == "sid"' "${ss}" >/dev/null
  jq -e '.origin == "https://app.example.com"' "${meta}" >/dev/null
  jq -e '.site == "prod-app"'                  "${meta}" >/dev/null
  jq -e '.schema_version == 1'                 "${meta}" >/dev/null
  # Final line is summary.
  local last_json
  last_json="$(printf '%s\n' "${lines[@]}" | tail -n 1)"
  printf '%s' "${last_json}" | jq -e '.verb == "login" and .status == "ok" and .session == "prod-app--admin"' >/dev/null
}

@test "login: requires --site, --as, and --storage-state-file (exit 2)" {
  run bash "${SCRIPTS_DIR}/browser-login.sh" --site prod-app --as x
  assert_status "$EXIT_USAGE_ERROR"
  run bash "${SCRIPTS_DIR}/browser-login.sh" --as x --storage-state-file /tmp/x
  assert_status "$EXIT_USAGE_ERROR"
  run bash "${SCRIPTS_DIR}/browser-login.sh" --site prod-app --storage-state-file /tmp/x
  assert_status "$EXIT_USAGE_ERROR"
}

@test "login: --auto refused in Phase 2 (clear error message)" {
  run bash "${SCRIPTS_DIR}/browser-login.sh" \
    --site prod-app --as x --auto
  assert_status "$EXIT_USAGE_ERROR"
  assert_output_contains "Phase 5"
}

@test "login: missing storage-state-file path exits 2" {
  run bash "${SCRIPTS_DIR}/browser-login.sh" \
    --site prod-app --as x --storage-state-file /no/such/path.json
  assert_status "$EXIT_USAGE_ERROR"
  assert_output_contains "not found"
}

@test "login: unknown site exits 23" {
  run bash "${SCRIPTS_DIR}/browser-login.sh" \
    --site ghost --as x \
    --storage-state-file "${REPO_ROOT}/tests/fixtures/storage-state-good.json"
  assert_status "$EXIT_SITE_NOT_FOUND"
}

@test "login: --dry-run does not write a session" {
  run bash "${SCRIPTS_DIR}/browser-login.sh" \
    --site prod-app --as prod-app--admin \
    --storage-state-file "${REPO_ROOT}/tests/fixtures/storage-state-good.json" \
    --dry-run
  assert_status 0
  [ ! -f "${BROWSER_SKILL_HOME}/sessions/prod-app--admin.json" ]
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bats tests/login.bats`
Expected: FAIL — `scripts/browser-login.sh: No such file or directory`.

- [ ] **Step 3: Write minimal implementation**

```bash
# scripts/browser-login.sh
#!/usr/bin/env bash
# login — capture a Playwright storageState into sessions/<name>.json.
#
# Phase 2: STUB ADAPTER. Reads a hand-edited storageState file from disk,
# validates it, origin-binds it to the site, writes the session + meta.
# No browser launch yet — Phase 3 will replace this file-read with a real
# `playwright open --save-storage` call behind the same CLI.
#
# Headed-only; --auto is reserved for Phase 5 (auto-relogin).
set -euo pipefail
IFS=$'\n\t'
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/common.sh"
# shellcheck source=lib/site.sh
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/site.sh"
# shellcheck source=lib/session.sh
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/session.sh"
init_paths

site=""; as=""; ss_file=""; dry_run=0; auto=0; headed=1

usage() {
  cat <<'USAGE'
Usage: login --site NAME --as SESSION --storage-state-file PATH [--dry-run]

Phase 2 stub adapter — reads a hand-edited Playwright storageState from
PATH and writes it as sessions/<SESSION>.json. (Phase 3 will replace
--storage-state-file with a real headed browser launch.)

  --site NAME                 site profile to bind the session to (required)
  --as SESSION                session name (required, used as filename)
  --storage-state-file PATH   path to a Playwright storageState JSON (required)
  --dry-run                   validate inputs; write nothing
  --headed                    accepted (default; Phase 2 is headed-only)
  --auto                      reserved; refused in Phase 2
  -h, --help
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --site)                 site="$2"; shift 2 ;;
    --as)                   as="$2"; shift 2 ;;
    --storage-state-file)   ss_file="$2"; shift 2 ;;
    --dry-run)              dry_run=1; shift ;;
    --headed)               headed=1; shift ;;
    --auto)                 auto=1; shift ;;
    -h|--help)              usage; exit 0 ;;
    *)                      die "${EXIT_USAGE_ERROR}" "unknown flag: $1" ;;
  esac
done

[ -n "${site}" ]    || { usage; die "${EXIT_USAGE_ERROR}" "--site is required"; }
[ -n "${as}" ]      || { usage; die "${EXIT_USAGE_ERROR}" "--as is required"; }
[ -n "${ss_file}" ] || { usage; die "${EXIT_USAGE_ERROR}" "--storage-state-file is required (Phase 2 is stub-only)"; }
if [ "${auto}" -eq 1 ]; then
  die "${EXIT_USAGE_ERROR}" "--auto is reserved for Phase 5 auto-relogin; refused in Phase 2"
fi
[ -f "${ss_file}" ] || die "${EXIT_USAGE_ERROR}" "storage-state-file not found: ${ss_file}"

started_at_ms="$(now_ms)"

# Site must exist; load its URL → derive origin for binding.
profile_json="$(site_load "${site}")"   # exits 23 if missing
site_url="$(printf '%s' "${profile_json}" | jq -r .url)"
site_origin="$(url_origin "${site_url}")"

# Read & validate the storageState file.
if ! ss_json="$(jq -c . "${ss_file}" 2>/dev/null)"; then
  die "${EXIT_USAGE_ERROR}" "storage-state-file is not valid JSON: ${ss_file}"
fi

ok "site=${site} session=${as} origin=${site_origin}"

if [ "${dry_run}" -eq 1 ]; then
  ok "dry-run: would write ${SESSIONS_DIR}/${as}.json"
  duration_ms=$(( $(now_ms) - started_at_ms ))
  summary_json verb=login tool=playwright-lib-stub why=dry-run status=ok would_run=true \
               site="${site}" session="${as}" duration_ms="${duration_ms}"
  exit "${EXIT_OK}"
fi

# Origin binding gate (Task 20 will tighten this with full origin-list checks).
# Build meta sidecar.
captured_at="$(now_iso)"
meta_json="$(jq -nc \
  --arg n "${as}" \
  --arg s "${site}" \
  --arg o "${site_origin}" \
  --arg c "${captured_at}" \
  --arg ua "browser-skill phase-2 stub adapter" \
  '{
    name: $n, site: $s, origin: $o, captured_at: $c,
    source_user_agent: $ua, expires_in_hours: 168, schema_version: 1
  }')"

session_save "${as}" "${ss_json}" "${meta_json}"
ok "session captured: ${as}"

duration_ms=$(( $(now_ms) - started_at_ms ))
summary_json verb=login tool=playwright-lib-stub why=stub-storageState status=ok \
             site="${site}" session="${as}" origin="${site_origin}" \
             expires_in_hours=168 duration_ms="${duration_ms}"
```

- [ ] **Step 4: Run test to verify it passes**

```bash
chmod +x scripts/browser-login.sh
bats tests/login.bats
```
Expected: 6 tests green.

- [ ] **Step 5: Commit**

```bash
git add scripts/browser-login.sh tests/login.bats tests/fixtures/storage-state-good.json
git commit -m "feat(login): Phase-2 stub adapter (storageState file → session)"
```

---

## Task 19 — `browser-login.sh`: enforce origin-binding on storageState `origins[]`

**Files:**
- Modify: `scripts/browser-login.sh`
- Modify: `tests/login.bats`
- Create: `tests/fixtures/storage-state-bad-origin.json`

The `cookies[]` are domain-scoped (which can be a parent domain), so the strongest cross-check is: every entry in `storageState.origins[]` must match the site's origin. If `origins[]` is empty, that's allowed (storageState may carry only cookies). If any entry mismatches, refuse with exit 22 (per spec §5.5).

- [ ] **Step 1: Create fixture and write the failing test**

Create `tests/fixtures/storage-state-bad-origin.json`:

```json
{
  "cookies": [],
  "origins": [
    {"origin": "https://evil.example.com", "localStorage": []}
  ]
}
```

Append to `tests/login.bats`:

```bash
@test "login: refuses storageState whose origins do not match the site (exit 22)" {
  run bash "${SCRIPTS_DIR}/browser-login.sh" \
    --site prod-app --as prod-app--admin \
    --storage-state-file "${REPO_ROOT}/tests/fixtures/storage-state-bad-origin.json"
  assert_status "$EXIT_SESSION_EXPIRED"
  assert_output_contains "origin mismatch"
  [ ! -f "${BROWSER_SKILL_HOME}/sessions/prod-app--admin.json" ]
}

@test "login: empty origins[] is allowed (cookie-only storageState)" {
  local fixture="${TEST_HOME}/empty-origins.json"
  printf '{"cookies":[{"name":"x","value":"y","domain":"app.example.com","path":"/","expires":-1,"httpOnly":true,"secure":true,"sameSite":"Lax"}],"origins":[]}' > "${fixture}"
  run bash "${SCRIPTS_DIR}/browser-login.sh" \
    --site prod-app --as p \
    --storage-state-file "${fixture}"
  assert_status 0
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bats tests/login.bats`
Expected: FAIL — current login accepts mismatched origins (no enforcement yet).

- [ ] **Step 3: Modify `browser-login.sh` to enforce the check**

In `scripts/browser-login.sh`, find the line:

```bash
ok "site=${site} session=${as} origin=${site_origin}"
```

Insert immediately ABOVE that line:

```bash
# Origin-binding (spec §5.5): every storageState.origins[] must match site_origin.
# Empty origins[] is allowed (storageState may carry only cookies).
mismatched="$(printf '%s' "${ss_json}" | jq -r --arg target "${site_origin}" '
  [.origins[]? | select(.origin != $target) | .origin] | join(",")')"
if [ -n "${mismatched}" ]; then
  die "${EXIT_SESSION_EXPIRED}" \
    "origin mismatch: storage-state-file origins=[${mismatched}], site origin=${site_origin}"
fi
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bats tests/login.bats`
Expected: 8 tests green.

- [ ] **Step 5: Commit**

```bash
git add scripts/browser-login.sh tests/login.bats tests/fixtures/storage-state-bad-origin.json
git commit -m "feat(login): refuse storageState whose origins mismatch site (spec §5.5)"
```

---

## Task 20 — Default-session linkage: site profile feeds `--as` default

**Files:**
- Modify: `scripts/browser-login.sh`
- Modify: `tests/login.bats`

Per spec §3.5, a site profile may carry `default_session`. When `login` is called without `--as`, fall back to `default_session`. This is also the wiring later phases (verbs that omit `--session`) will mirror.

- [ ] **Step 1: Write the failing test**

Append to `tests/login.bats`:

```bash
@test "login: --as falls back to site.default_session when omitted" {
  bash "${SCRIPTS_DIR}/browser-add-site.sh" \
    --name prod-app --url https://app.example.com \
    --default-session prod-app--admin --force >/dev/null
  run bash "${SCRIPTS_DIR}/browser-login.sh" \
    --site prod-app \
    --storage-state-file "${REPO_ROOT}/tests/fixtures/storage-state-good.json"
  assert_status 0
  [ -f "${BROWSER_SKILL_HOME}/sessions/prod-app--admin.json" ]
}

@test "login: missing --as AND missing site.default_session is a usage error" {
  bash "${SCRIPTS_DIR}/browser-add-site.sh" \
    --name no-default --url https://x.test --force >/dev/null
  run bash "${SCRIPTS_DIR}/browser-login.sh" \
    --site no-default \
    --storage-state-file "${REPO_ROOT}/tests/fixtures/storage-state-good.json"
  assert_status "$EXIT_USAGE_ERROR"
  assert_output_contains "default_session"
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bats tests/login.bats`
Expected: FAIL — login currently demands `--as` always.

- [ ] **Step 3: Modify `browser-login.sh`**

Find the validation block:

```bash
[ -n "${site}" ]    || { usage; die "${EXIT_USAGE_ERROR}" "--site is required"; }
[ -n "${as}" ]      || { usage; die "${EXIT_USAGE_ERROR}" "--as is required"; }
[ -n "${ss_file}" ] || { usage; die "${EXIT_USAGE_ERROR}" "--storage-state-file is required (Phase 2 is stub-only)"; }
```

Replace it with:

```bash
[ -n "${site}" ]    || { usage; die "${EXIT_USAGE_ERROR}" "--site is required"; }
[ -n "${ss_file}" ] || { usage; die "${EXIT_USAGE_ERROR}" "--storage-state-file is required (Phase 2 is stub-only)"; }
# --as defaults to site.default_session if the site sets one.
if [ -z "${as}" ]; then
  default_session_from_site="$(site_load "${site}" | jq -r '.default_session // ""')"
  if [ -n "${default_session_from_site}" ]; then
    as="${default_session_from_site}"
  else
    die "${EXIT_USAGE_ERROR}" "--as is required (site ${site} has no default_session set)"
  fi
fi
```

(Re-running `site_load` later in the script is fine — it's a `cat`, not expensive.)

- [ ] **Step 4: Run test to verify it passes**

Run: `bats tests/login.bats`
Expected: 10 tests green.

- [ ] **Step 5: Commit**

```bash
git add scripts/browser-login.sh tests/login.bats
git commit -m "feat(login): --as falls back to site.default_session"
```

---

## Task 21 — Docs + carry-forward fixes (`SKILL.md`, `CHANGELOG.md`, `uninstall.sh`, `install.sh`)

**Files:**
- Modify: `SKILL.md`
- Modify: `CHANGELOG.md`
- Modify: `uninstall.sh`
- Modify: `install.sh`

This is a docs / housekeeping task — no failing test up front, but we re-run the entire bats suite at the end to confirm nothing regressed.

- [ ] **Step 1: Update `SKILL.md`**

Replace the entire file with:

```markdown
---
name: browser-automation-skill
description: Drive a real browser from Claude Code via four routed tools (chrome-devtools-mcp, playwright-cli, playwright-lib, obscura). Credentials and sessions stay strictly local in $HOME/.browser-skill/ (mode 0700 dir, 0600 files) and never appear on argv, in git, or in the Claude transcript.
when_to_use: The user mentions a browser task — register a site, capture a session, verify a page, fill a form, capture console errors, run a lighthouse audit, scrape multiple URLs, debug a UI bug iteratively, or run a recorded flow.
argument-hint: [verb] [--site NAME] [--session NAME] [--tool NAME] [--dry-run]
allowed-tools: Bash(bash *) Bash(jq *) Bash(chmod *) Bash(mkdir *) Bash(stat *) Bash(rm *) Bash(mv *) Bash(cat *)
---

# browser-automation-skill (Phase 2 — site & session core)

Phase 2 ships site CRUD + the session schema + a stub-adapter `login`.
Real browser launches arrive in Phase 3.

## Verbs

| Verb | What it does | Example |
|---|---|---|
| `doctor`        | Health check: deps, state dir mode, disk encryption, no network | `bash "${CLAUDE_SKILL_DIR}/scripts/browser-doctor.sh"` |
| `add-site`      | Register a site profile | `… add-site --name prod --url https://app.example.com` |
| `list-sites`    | List registered sites | `… list-sites` |
| `show-site`     | Show one site's profile JSON | `… show-site --name prod` |
| `remove-site`   | Typed-name confirmed delete | `… remove-site --name prod --yes-i-know` |
| `use`           | Get / set / clear current site | `… use --set prod` |
| `login`         | Capture a Playwright storageState into a session | `… login --site prod --as prod--admin --storage-state-file PATH` |

`${CLAUDE_SKILL_DIR}` is the absolute path that Claude Code injects when it
invokes the skill — it points at the symlink under `~/.claude/skills/`. Use it
in command examples so they work whether the user installed at `--user` or
`--project` scope.

## Before running anything

If `doctor` reports `~/.browser-skill` missing, run `./install.sh` (or
`./install.sh --with-hooks` for the credential-leak blocker).

## Output contract

Every verb prints zero or more streaming JSON lines, then ends with a
single-line JSON summary. Parse with jq; route on `.status` (`ok`,
`partial`, `error`, `empty`, `aborted`).

```
$ bash scripts/browser-doctor.sh | tail -1 | jq .
{"verb":"doctor","tool":"none","why":"health-check","status":"ok","problems":0,"duration_ms":42}
```

## Storage layout

```
~/.browser-skill/                       # mode 0700
├── version                              # schema marker
├── current                              # current site name (mode 0600, [personal])
├── sites/    <name>.json + .meta.json   # mode 0600 ([shareable])
├── sessions/ <name>.json + .meta.json   # mode 0600 ([PERSONAL — gitignored])
├── credentials/                         # Phase 5
└── captures/                            # Phase 7
```

## Roadmap

See `docs/superpowers/specs/2026-04-27-browser-automation-skill-design.md` for
the full design and `docs/superpowers/plans/` for phase plans.
```

- [ ] **Step 2: Update `CHANGELOG.md`**

In `CHANGELOG.md` find the line containing `### Phase 1 — Foundation` and the trailing entries below it; append a new section above it (i.e., right under `## [Unreleased]`):

```markdown
### Phase 2 — Site & session core

- [feat] `add-site` / `list-sites` / `show-site` / `remove-site` verbs ship (typed-name confirm on remove)
- [feat] `use` verb: get / set / clear current site
- [feat] `login` verb (Phase 2 stub): consumes a hand-edited Playwright storageState file, validates origins against the site URL, writes session + meta sidecar
- [feat] `lib/site.sh`: site profile CRUD with atomic write, mode 0600, schema_version=1
- [feat] `lib/session.sh`: storageState read/write, `session_origin_check` (spec §5.5), `session_expiry_summary`
- [feat] `common.sh`: `now_iso` helper added (UTC, second precision)
- [security] sessions inherit the same gitignored / 0600-files invariant as Phase 1
- [internal] `tests/helpers.bash` now sources `lib/common.sh`; `${EXIT_*:-N}` fallback pattern dropped from all `.bats` files
- [docs] SKILL.md verb table reflects new verbs; mode wording corrected to "0700 dir, 0600 files"; `CLAUDE_SKILL_DIR` explainer added
```

- [ ] **Step 3: Fix `uninstall.sh` carry-forward (line 18 — usage string lies about prompt)**

In `uninstall.sh` find the `usage()` block:

```bash
usage() {
  cat <<'USAGE'
Usage: ./uninstall.sh [options]

  --keep-state     don't ask about deleting ~/.browser-skill/ (the default is to ask)
  --dry-run        print what would happen, change nothing
  -h, --help
USAGE
}
```

Replace with:

```bash
usage() {
  cat <<'USAGE'
Usage: ./uninstall.sh [options]

  --keep-state     do not delete ~/.browser-skill/ (default; today the script
                   never deletes state — a future release may add an opt-in
                   --delete-state flag)
  --dry-run        print what would happen, change nothing
  -h, --help
USAGE
}
```

- [ ] **Step 4: Fix `install.sh` carry-forward (line 50 — dry-run hardcodes path)**

In `install.sh` find the line:

```bash
  ok "dry-run: would create ~/.browser-skill/ and symlink to ~/.claude/skills/browser-automation-skill"
```

Replace with:

```bash
  init_paths
  ok "dry-run: would create ${BROWSER_SKILL_HOME} and symlink to ${HOME}/.claude/skills/browser-automation-skill"
```

(Calling `init_paths` here means the message reflects whatever `BROWSER_SKILL_HOME` resolves to — env var, walk-up, or `~/.browser-skill/` fallback — instead of a hardcoded literal.)

- [ ] **Step 5: Run the full suite to confirm nothing regressed**

```bash
bash tests/run.sh 2>&1 | tail -5
```
Expected: every test green; total ≥ ~80 tests counting Phase 1's 44 + Phase 2's new ones.

- [ ] **Step 6: Commit**

```bash
git add SKILL.md CHANGELOG.md uninstall.sh install.sh
git commit -m "docs: SKILL.md Phase-2 verbs + carry-forward fixes (uninstall/install copy)"
```

---

## Task 22 — Phase 2 acceptance gate (manual smoke + tag)

**Files:** none new — manual + scripted verification.

- [ ] **Step 1: Wipe state and re-install fresh**

```bash
rm -rf ~/.browser-skill
rm -f  ~/.claude/skills/browser-automation-skill
cd ~/Projects/browser-automation-skill
./install.sh --with-hooks
```
Expected: exit 0, doctor green, state dir at `~/.browser-skill/` mode 0700, symlink in place.

- [ ] **Step 2: Drive the full Phase-2 happy path against the real fs**

```bash
bash scripts/browser-add-site.sh \
  --name prod-app --url https://app.example.com \
  --label "Production app" --default-session prod-app--admin \
| tail -1 | jq .

bash scripts/browser-list-sites.sh | tail -1 | jq .

bash scripts/browser-show-site.sh --name prod-app | tail -1 | jq '.profile.url'

bash scripts/browser-use.sh --set prod-app | tail -1 | jq .

bash scripts/browser-login.sh \
  --site prod-app \
  --storage-state-file tests/fixtures/storage-state-good.json \
| tail -1 | jq .

ls -la ~/.browser-skill/sessions/
stat -f '%Lp' ~/.browser-skill/sessions/prod-app--admin.json 2>/dev/null \
  || stat -c '%a' ~/.browser-skill/sessions/prod-app--admin.json
```
Expected: every JSON summary `.status == "ok"`; session file present at mode 600; meta sidecar present.

- [ ] **Step 3: Drive the negative paths**

```bash
# Origin mismatch refused (exit 22)
bash scripts/browser-login.sh \
  --site prod-app --as bad \
  --storage-state-file tests/fixtures/storage-state-bad-origin.json \
; echo "exit=$?"

# Unknown site refused (exit 23)
bash scripts/browser-show-site.sh --name ghost ; echo "exit=$?"

# remove-site without confirmation refused (exit 2)
printf 'wrong\n' | bash scripts/browser-remove-site.sh --name prod-app ; echo "exit=$?"
```
Expected: exits `22`, `23`, `2` respectively; no on-disk state mutated.

- [ ] **Step 4: Run the full bats suite**

```bash
bash tests/run.sh
```
Expected: every test green; total time <30 s on a modern dev box.

- [ ] **Step 5: Doctor still green after Phase 2 work**

```bash
bash scripts/browser-doctor.sh | tail -1 | jq -e '.status == "ok"'
```
Expected: prints `true`.

- [ ] **Step 6: Tag the milestone**

```bash
git tag -a v0.2.0-phase-02-site-session-core -m "Phase 2 — site/session core complete"
# Push if desired:
#   git push origin v0.2.0-phase-02-site-session-core
```

- [ ] **Step 7: Clean up the smoke artefacts**

```bash
bash scripts/browser-remove-site.sh --name prod-app --yes-i-know
rm -f ~/.browser-skill/sessions/prod-app--admin.json \
      ~/.browser-skill/sessions/prod-app--admin.meta.json
```

---

## Acceptance criteria for Phase 2 (must all be true)

- [ ] `bash tests/run.sh` reports every test green; total runtime <30 s on a modern dev box.
- [ ] Phase 1's 44 tests still pass (the Task-1 refactor must not regress them).
- [ ] `add-site` / `list-sites` / `show-site` / `remove-site` / `use` / `login` all emit a single-line JSON summary on stdout via `summary_json` (or `jq -cn` for verbs whose summary needs an array).
- [ ] `lib/site.sh` and `lib/session.sh` write atomically (tmp + mv), files at mode 0600, dirs at mode 0700.
- [ ] Site profiles + sessions carry `schema_version: 1`.
- [ ] `login` refuses a storageState whose `origins[]` mismatch the site origin (exit 22, spec §5.5).
- [ ] `login --auto` refused with a clear "Phase 5" message (exit 2).
- [ ] `login` falls back to `site.default_session` when `--as` is omitted; errors clearly when neither is set.
- [ ] `remove-site` enforces typed-name confirmation (or `--yes-i-know`); cascades to clear `current` if it pointed at the deleted site.
- [ ] No script exceeds 250 LOC; no `.bats` exceeds 300 LOC. (Manual check now; lint will enforce in Phase 10.)
- [ ] `SKILL.md`, `CHANGELOG.md` reflect the new verbs.
- [ ] Carry-forward fixes from Phase-1 review applied: `tests/helpers.bash` sources `common.sh`; `${EXIT_*:-N}` fallbacks gone; `uninstall.sh` usage no longer lies; `install.sh` dry-run reports the resolved path; `SKILL.md` mode wording fixed and `CLAUDE_SKILL_DIR` explained.
- [ ] `git tag` shows `v0.2.0-phase-02-site-session-core`.
- [ ] `bash scripts/browser-doctor.sh` exits 0.

---

## What ships in subsequent phases (preview, unchanged from Phase 1 plan §"What ships next")

| Phase | Plan filename (when written) | Key deliverable |
|---|---|---|
| 3 | `phase-03-first-adapter-playwright-cli.md` | `lib/tool/playwright-cli.sh` + real `lib/tool/playwright-lib.sh` (replaces Phase-2 stub); `open` / `snapshot` / `click` / `fill` / `inspect` end-to-end |
| 4 | `phase-04-router-and-cdt-mcp.md` | `lib/router.sh` + chrome-devtools-mcp adapter; `inspect --capture-console`; `audit` |
| 5 | `phase-05-credentials-and-relogin.md` | credential vault (3 backends), `login_detect`, single auto-retry, blocklist, typed-phrase, `login --auto` actually wired |
| 6+  | (see Phase 1 plan tail) | … |

Each subsequent plan is written **after** the previous phase merges, so it can read the actual code state, not speculate about it.

---

## Self-review checklist (run after writing this plan)

- [x] **Spec coverage:** §2.3 repo layout — site verbs + lib live exactly where Appendix-style tree says (`scripts/browser-<verb>.sh`, `scripts/lib/site.sh`, `scripts/lib/session.sh`). §3.5 site schema fully implemented. §3.6 credential schema deliberately deferred to Phase 5; this plan does not touch it. §4.4 login lifecycle row 1 ("ONE-TIME OR ON-EXPIRY: login") implemented as a stub adapter; rows 2 and 3 (auto-relogin, transparent re-login) are explicitly Phase 5. §5.5 origin-mismatch refusal implemented at write-time AND a `session_origin_check` helper exists for read-time use. §1 invariants honored: storageState only (no credential vault); `login` headed-only; never on argv.
- [x] **No placeholders:** every step has full code or full commands. No "implement validation appropriately" hand-waves.
- [x] **Type/symbol consistency:** function names — `site_save`, `site_load`, `site_meta_load`, `site_list_names`, `site_delete`, `site_exists`, `current_get`/`set`/`clear`, `session_save`, `session_load`, `session_meta_load`, `session_exists`, `session_origin_check`, `session_expiry_summary`, `url_origin`, `now_iso` — used consistently across tasks. Exit codes (`EXIT_SITE_NOT_FOUND`, `EXIT_SESSION_EXPIRED`, `EXIT_USAGE_ERROR`) match spec §5.1 and the `common.sh` constants.
- [x] **TDD discipline:** every code task — T1 through T20 — has a failing test → run-to-fail → minimal impl → run-to-pass → commit. T21 is doc/cleanup with a full-suite green gate; T22 is the manual acceptance gate (mirrors Phase 1's T20).
- [x] **Frequent commits:** 22 tasks → 21 commits + 1 tag.
- [x] **Bite-sized:** every step is 2–5 minutes for a competent shell engineer.
- [x] **Carry-forward fixes**: T1 handles helpers.bash + .bats files; T21 handles `SKILL.md`, `uninstall.sh`, `install.sh`. The whole user-supplied carry-forward list is covered.

---

## Reading order for an engineer who's never seen this codebase

1. `docs/superpowers/specs/2026-04-27-browser-automation-skill-design.md` — read §1, §2.3, §3.4, §3.5, §4.4, §5.1, §5.5.
2. `docs/superpowers/plans/2026-04-27-browser-automation-skill-phase-01-foundation.md` — Phase 1 ships the `lib/common.sh` and bats harness this plan stands on.
3. `https://github.com/xicv/mqtt-skill/blob/main/scripts/lib/profile.sh` — proven reference for atomic JSON write + meta sidecar pattern; this plan mirrors its shape.
4. This plan, top to bottom.
