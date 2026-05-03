# Phase 5 part 2d — `creds add` verb + smart backend select

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans.

**Goal:** First user-visible win on the auth track. Lands `scripts/browser-creds-add.sh` — the verb that turns the part-2a/2b/2c substrate into a CLI surface. Plus `scripts/lib/secret_backend_select.sh` — smart per-OS backend auto-detection (keychain on Darwin, libsecret on Linux when `secret-tool` is on PATH, plaintext fallback otherwise) per parent spec §1.

**Why focused (creds add only, not all 4 verbs):** Concentrating on one verb keeps the PR reviewable and lets the patterns it establishes (smart backend select, stdin-only password, doctor surface, summary JSON) drive the design. The other verbs (`creds list`, `creds show`, `creds remove`) follow these patterns and land in part 2d-ii. `mask.sh` + `--reveal` typed-phrase flow + `migrate-credential` cross-backend moves stay deferred (2d-iii / 2e).

**Tech stack:** Bash 5+, jq, bats-core. No new runtime deps.

**Spec references:**
- Parent spec §1 (per-OS-default backend; never argv; AP-7), §3.1 (lib responsibility split — `credential.sh` for record I/O, backends for storage, verb scripts for CLI surface), §3.2 (verb roster — `add-credential` is row 7 in Appendix A).
- Token-efficient-output spec §3 (single-line JSON summary).
- Phase 5 part 2a/2b/2c plans — the substrate this verb consumes.
- AP-7 (no secrets in argv) — verb script's `--password-stdin` is the ONLY input path; no `--password VALUE` flag exists.

**Branch:** `feature/phase-05-part-2d-creds-add`.

---

## File Structure

### New (creates)

| Path | Purpose | Size budget |
|---|---|---|
| `scripts/browser-creds-add.sh` | Verb — register a credential | ≤ 250 LOC |
| `scripts/lib/secret_backend_select.sh` | Smart per-OS backend auto-detect | ≤ 80 LOC |
| `tests/creds-add.bats` | Verb-script integration tests | ≤ 250 LOC |
| `tests/secret_backend_select.bats` | Detection lib unit tests | ≤ 100 LOC |
| `docs/superpowers/plans/2026-05-03-phase-05-part-2d-creds-add.md` | This plan | — |

### Modified

| Path | Change | Estimated diff |
|---|---|---|
| `scripts/browser-doctor.sh` | New advisory check after adapter aggregation: walk `${CREDENTIALS_DIR}/*.json` and emit credentials count line + per-backend breakdown. Does NOT increment `problems`. | +~25 LOC |
| `tests/doctor.bats` | Add a case asserting the credentials count line is present (zero-state and one-credential-state) | +~30 LOC |
| `SKILL.md` | Add `creds add` row to the verbs table | +~3 LOC |
| `CHANGELOG.md` | New `### Phase 5 part 2d` subsection | +~15 LOC |

### Untouched

- `scripts/lib/router.sh`, `scripts/lib/common.sh`, `scripts/lib/output.sh`
- `scripts/lib/site.sh`, `scripts/lib/session.sh`, `scripts/lib/verb_helpers.sh`
- `scripts/lib/credential.sh`, `scripts/lib/secret/*.sh` (backends — Phase 5 part 2a/2b/2c)
- `scripts/lib/tool/*.sh` (no adapter changes)
- `tests/lint.sh`

---

## Pre-Plan: branch + plan commit

- [x] **Step 0.1** Branch `feature/phase-05-part-2d-creds-add`.
- [ ] **Step 0.2** Commit plan: `docs: phase-5 part-2d plan — creds add verb + smart backend select`.

---

## Task 1: Smart backend select — RED + GREEN

**Files:** Create `scripts/lib/secret_backend_select.sh` + `tests/secret_backend_select.bats`.

API:
```bash
detect_backend  # echoes 'keychain' | 'libsecret' | 'plaintext'
```

Logic:
1. If `${BROWSER_SKILL_FORCE_BACKEND}` is set and ∈ `{keychain, libsecret, plaintext}`, echo it. (Test override; also user override knob.)
2. Per `uname -s`:
   - **Darwin**: if `command -v "${KEYCHAIN_SECURITY_BIN:-security}"` succeeds → `keychain`; else → `plaintext`.
   - **Linux**: if `command -v "${LIBSECRET_TOOL_BIN:-secret-tool}"` succeeds → `libsecret`; else → `plaintext`. (Don't probe D-Bus reachability; too brittle. Assume `secret-tool` on PATH means usable. User can override with `BROWSER_SKILL_FORCE_BACKEND=plaintext`.)
   - **Other**: → `plaintext`.

Tests (~5 cases):
- BROWSER_SKILL_FORCE_BACKEND override honored
- Darwin + KEYCHAIN_SECURITY_BIN reachable → keychain (use stub bin)
- Darwin + KEYCHAIN_SECURITY_BIN missing → plaintext (point env at /nonexistent)
- Linux + LIBSECRET_TOOL_BIN reachable → libsecret (use stub bin)
- Linux + LIBSECRET_TOOL_BIN missing → plaintext

Steps:
- [ ] **1.1** Write bats; run RED.
- [ ] **1.2** Write `secret_backend_select.sh`; run GREEN.

---

## Task 2: `scripts/browser-creds-add.sh` — RED + GREEN

**Files:** Create the verb script + `tests/creds-add.bats`.

CLI surface:
```
Usage: creds-add --site SITE --as CRED_NAME [options]
  --site SITE              site profile name (must exist)
  --as CRED_NAME           credential name (filename, must be safe; can match site name)
  --account ACCOUNT        account/email value (default: "<site>@example.com" placeholder)
  --backend BACKEND        keychain|libsecret|plaintext (default: smart auto-detect)
  --auto-relogin BOOL      true|false (default: true; honest for now — no flow detection)
  --password-stdin         REQUIRED — password from stdin (one line, NUL-terminated OK)
  --dry-run                print planned action; write nothing
```

`--password-stdin` is mandatory in this PR. Interactive `read -s` prompting deferred to a follow-up (because terminals + bats don't compose well; keeps test surface clean).

AP-7 enforcement: NO `--password VALUE` flag. Lint test greps the script for the pattern.

Validation:
1. `--site` and `--as` required (exit 2 USAGE_ERROR)
2. `--password-stdin` required (exit 2)
3. `assert_safe_name` on `--as`
4. `site_exists` on `--site` → else exit 23 SITE_NOT_FOUND
5. `credential_exists` on `--as` → else exit 2 with hint "use creds-remove first"
6. Resolve backend: `--backend` if set, else `detect_backend`

Plaintext first-use flow (deferred to part 2d-ii or 2d-iii):
- The typed-phrase confirmation prompt happens in part 2d-iii (it requires TTY interaction which bats can't fake easily). For 2d, plaintext just works without confirmation BUT a stderr warn line surfaces (so users see it). The full typed-phrase flow lands when we add a verb that can prompt without breaking bats.

Action:
1. Read password from stdin (single line OK; `cat` consumes everything to handle multi-line edge cases — but typically one line)
2. Build metadata JSON via `jq -nc`
3. `credential_save NAME META_JSON`
4. `printf '%s' "${password}" | credential_set_secret NAME` — pipe via stdin (AP-7)
5. Emit summary

Summary JSON:
```json
{"verb":"creds-add","tool":"none","why":"register-credential","status":"ok","credential":"prod--admin","site":"prod","backend":"keychain","duration_ms":42}
```

Tests (~14 cases):
- happy path with `--password-stdin` + `--backend plaintext` (roundtrip get_secret = stdin)
- happy path with `--backend keychain` via stub
- happy path with `--backend libsecret` via stub
- backend auto-detect via `BROWSER_SKILL_FORCE_BACKEND=plaintext`
- rejects existing cred name (must remove first; exit 2)
- rejects unknown site (exit 23)
- `--as` rejected when unsafe (exit 2)
- AP-7 grep guard: script source contains NO `--password VALUE` flag handler
- `--password-stdin` missing → exit 2
- `--site` missing → exit 2
- `--as` missing → exit 2
- `--dry-run` skips writes (verify file doesn't exist after)
- `--account` override appears in metadata
- summary JSON has verb/tool/why/status/duration_ms + credential + site + backend keys

Steps:
- [ ] **2.1** Write `tests/creds-add.bats`. Run RED.
- [ ] **2.2** Write `scripts/browser-creds-add.sh`. Run GREEN.

---

## Task 3: Doctor surface + SKILL.md row

**Files:** Modify `scripts/browser-doctor.sh` + `tests/doctor.bats` + `SKILL.md`.

Doctor change:
- After adapter aggregation, walk `${CREDENTIALS_DIR}/*.json` (skip `.secret` files — those are payload, not metadata)
- For each, `jq -r .backend` to count per-backend
- Print one line: `credentials: N total (keychain: A, libsecret: B, plaintext: C)`
- Advisory only — does NOT touch `problems` count
- When zero credentials: `credentials: 0 total`

SKILL.md verbs table — add row between `remove-session` and `open` (alphabetical-ish — auth verbs cluster):
```
| `creds add` | Register credential (smart per-OS backend) | `… creds-add --site prod --as prod--admin --password-stdin` |
```

Steps:
- [ ] **3.1** Add the credentials walk to `scripts/browser-doctor.sh` (placed after the adapter walk, before the summary).
- [ ] **3.2** Add 2 cases to `tests/doctor.bats`: zero-credential state + one-credential state.
- [ ] **3.3** Add row to `SKILL.md` verbs table.

---

## Task 4: Lint + full bats run

Steps:
- [ ] **4.1** `bash tests/lint.sh` exit 0.
- [ ] **4.2** `bash tests/run.sh` — expect 357 + ~5 backend-select + ~14 creds-add + ~2 doctor = ~378 pass / 0 fail.

---

## Task 5: CHANGELOG + commit + tag + PR

Steps:
- [ ] **5.1** Add `### Phase 5 part 2d` subsection to `CHANGELOG.md`.
- [ ] **5.2** Commit: `feat(phase-5-part-2d): creds add verb + smart backend select`.
- [ ] **5.3** Tag: `v0.8.0-phase-05-part-2d-creds-add` (minor — first user-visible auth surface).
- [ ] **5.4** Push branch + tag; `gh pr create`.
- [ ] **5.5** Wait CI green on macos-latest + ubuntu-latest.
- [ ] **5.6** Squash-merge + delete branch + reset main.

---

## Acceptance criteria

- [ ] `scripts/lib/secret_backend_select.sh` exists; `detect_backend` honors `BROWSER_SKILL_FORCE_BACKEND` override + per-OS detection.
- [ ] `scripts/browser-creds-add.sh` exists; `--password-stdin` is the ONLY password-input path; AP-7 grep guard passes.
- [ ] `tests/secret_backend_select.bats` (~5 cases) green.
- [ ] `tests/creds-add.bats` (~14 cases) green; covers happy path × 3 backends + validation + AP-7 grep.
- [ ] `scripts/browser-doctor.sh` emits credentials count line; advisory only (no `problems` increment).
- [ ] `SKILL.md` verbs table has a `creds add` row.
- [ ] `bash tests/lint.sh` exit 0 across 3 tiers.
- [ ] `bash tests/run.sh` ≥378 pass / 0 fail.
- [ ] `scripts/lib/router.sh` UNTOUCHED.
- [ ] CI green on macos-latest + ubuntu-latest.

---

## Out of scope (explicit — defer with named follow-ups)

| Item | Goes to |
|---|---|
| `creds list` / `creds show` (read-only verbs) | **part 2d-ii** |
| `creds remove` (typed-name confirmation; mirrors `remove-site` shape) | **part 2d-ii** |
| `mask.sh` + `creds show --reveal` (typed-phrase confirmation flow) | **part 2d-iii** |
| `migrate-credential` cross-backend moves | **part 2e** |
| Interactive `read -s` password prompt (TTY-aware, no `--password-stdin`) | follow-up (TTY mocking in bats is complex; deferred) |
| First-use plaintext typed-phrase confirmation prompt | **part 2d-iii** (where `mask.sh` lands and TTY-prompt patterns get factored) |
| Auth flow detection on `creds add` (single-step / multi-step / interactive-required) — observed at first login per parent spec §3 | Phase 5 part 3 (auto-relogin) |
| Auto-relogin (single-retry on `EXIT_SESSION_EXPIRED`) | Phase 5 part 3 |
| TOTP (`--enable-totp`, RFC 6238 codes via `oathtool`) | Phase 5 part 4 |

---

## Risk register

| Risk | Mitigation |
|---|---|
| Smart backend auto-detect picks `libsecret` on Linux but D-Bus session not running → real `secret-tool` fails on first set | User can override with `--backend plaintext` or `BROWSER_SKILL_FORCE_BACKEND=plaintext`; doctor's credentials count line surfaces failures over time |
| Plaintext credential created without typed-phrase confirmation → security regression vs spec | Acknowledged: typed-phrase flow lands in 2d-iii. Until then, a stderr warn line ("plaintext backend stores secret on disk; ensure FileVault/LUKS enabled") surfaces the risk |
| `--password-stdin` requirement blocks interactive use | Acceptable for 2d; interactive read-s prompt is a follow-up. Documented in usage |
| AP-7 regression — future contributor adds `--password VALUE` flag | Lint-style grep test in `tests/creds-add.bats` catches it before merge |
| Doctor walk of credentials adds noise on machines with no credentials | "credentials: 0 total" stays one short line — lower noise than the per-adapter check lines we already emit |
