# Phase 5 part 2c — Linux libsecret backend (secret-tool)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans.

**Goal:** Land the third (and final Tier-1) credentials backend — `scripts/lib/secret/libsecret.sh` — wired into the dispatcher in `lib/credential.sh`. Mirrors `secret/keychain.sh` shape: 4-fn API (`secret_set/get/delete/exists`), sentinel guard, sources `common.sh` for `assert_safe_name` + `EXIT_*`. Uses Linux `secret-tool` CLI (libsecret-tools package on Debian/Ubuntu, freedesktop Secret Service API).

**Why now:** Completes the per-OS backend roster (plaintext + keychain + libsecret). After this PR, part 2d's `creds add` verb has all three backends available for smart auto-detection (keychain on macOS, libsecret on Linux when `secret-tool` is present, plaintext-with-typed-phrase fallback otherwise).

**AP-7 — clean (no documented exception).** Unlike macOS `security`, Linux `secret-tool` reads the password from stdin natively (newline-terminated). The skill's invariant holds end-to-end: `secret_set` reads stdin and pipes directly into `secret-tool store`; password never appears in argv. The asymmetry vs keychain is documented in part 2d's cheatsheet.

**Tech stack:** Bash 5+, jq, bats-core. Linux `secret-tool` (libsecret-tools package). Test stub at `tests/stubs/secret-tool` lets bats run identically on macos-latest CI (which doesn't have libsecret) and ubuntu-latest CI (which doesn't have a running D-Bus session by default).

**Spec references:**
- Parent spec §1 (per-OS-default backend model — libsecret is Tier 1 on Linux).
- Token-efficient-output spec §3 — backend ops silent.
- AP-6 (namespace-prefix file-scope globals), AP-7 (no secrets in argv — *this backend honors it cleanly*).
- Phase 5 part 2b plan (`docs/superpowers/plans/2026-05-02-phase-05-part-2b-keychain.md`) — the analog this PR mirrors.

**Branch:** `feature/phase-05-part-2c-libsecret`.

---

## File Structure

### New (creates)

| Path | Purpose | Size budget |
|---|---|---|
| `scripts/lib/secret/libsecret.sh` | Linux libsecret backend — 4-fn API; shells to `${LIBSECRET_TOOL_BIN:-secret-tool}` | ≤ 130 LOC |
| `tests/stubs/secret-tool` | Mock of `secret-tool` CLI — supports `store`/`lookup`/`clear` with attr=val pairs (`service`, `account`); state in `${LIBSECRET_STUB_STORE}`; reads PW via stdin | ≤ 90 LOC |
| `tests/secret_libsecret.bats` | Backend unit tests via stub | ≤ 200 LOC |
| `docs/superpowers/plans/2026-05-02-phase-05-part-2c-libsecret.md` | This plan | — |

### Modified

| Path | Change | Estimated diff |
|---|---|---|
| `scripts/lib/credential.sh` | libsecret dispatcher branch shifts from `die EXIT_TOOL_MISSING` placeholder to `source secret/libsecret.sh; secret_${op}` | +~5 LOC, -~3 LOC |
| `tests/credential.bats` | Replace "credential_set_secret returns EXIT_TOOL_MISSING for libsecret" with positive-roundtrip-via-stub test | +~10 LOC, -~10 LOC |
| `CHANGELOG.md` | New `### Phase 5 part 2c` subsection | +~10 LOC |

### Untouched

- `scripts/lib/router.sh`, `scripts/lib/common.sh`, `scripts/lib/output.sh`
- `scripts/lib/secret/plaintext.sh`, `scripts/lib/secret/keychain.sh`
- `scripts/browser-doctor.sh`, every `scripts/browser-<verb>.sh`
- every adapter file
- `SKILL.md`
- `tests/lint.sh`

---

## Pre-Plan: branch + plan commit

- [x] **Step 0.1** Branch `feature/phase-05-part-2c-libsecret`.
- [ ] **Step 0.2** Commit plan: `docs: phase-5 part-2c plan — Linux libsecret backend`.

---

## Task 1: secret-tool stub + state-file model

`tests/stubs/secret-tool` is the bash mock of the upstream `secret-tool` CLI. State lives in a JSON file (`${LIBSECRET_STUB_STORE}` per test) — `{ACCOUNT: PW, ...}` keyed by account.

Subcommands handled:
- `store --label LABEL service SERVICE account NAME` → reads PW from stdin (newline-terminated), `{NAME: PW}` merge into store
- `lookup service SERVICE account NAME` → echo PW or exit 1 (not found)
- `clear service SERVICE account NAME` → remove from store; exit 1 if not found (so the backend's idempotent contract uses `|| true`)

Steps:
- [ ] **1.1** Write `tests/stubs/secret-tool`; chmod +x.

---

## Task 2: RED — `tests/secret_libsecret.bats`

~13 cases mirror of `secret_keychain.bats`:
- file exists + readable
- AP-7 STDIN-CLEAN assertion: backend file MUST NOT contain "AP-7 documented exception" (libsecret has no exception — opposite invariant from keychain)
- `secret_set` reads stdin, persists (verify via stub store)
- `secret_get` echoes payload verbatim
- `secret_delete` removes (idempotent — wraps `clear` non-zero exit)
- `secret_exists` 0/1
- multiple secrets coexist
- last-write-wins on overwrite (clear-then-store pattern)
- `assert_safe_name` rejects `../escape`
- `secret_get` on missing exits non-zero
- Default service prefix is "browser-skill" (verify in stub log)
- `BROWSER_SKILL_LIBSECRET_SERVICE` override honored
- secret_set strips trailing newline added by stub's `read` (or doesn't introduce one — verify byte-exact roundtrip)

Steps:
- [ ] **2.1** Write the bats file.
- [ ] **2.2** Run RED.

---

## Task 3: GREEN — `scripts/lib/secret/libsecret.sh`

```bash
[ -n "${BROWSER_SKILL_SECRET_LIBSECRET_LOADED:-}" ] && return 0
readonly BROWSER_SKILL_SECRET_LIBSECRET_LOADED=1

readonly _LIBSECRET_SERVICE="${BROWSER_SKILL_LIBSECRET_SERVICE:-browser-skill}"
readonly _LIBSECRET_TOOL_BIN="${LIBSECRET_TOOL_BIN:-secret-tool}"

# secret_set NAME — stdin → libsecret via `secret-tool store`. Stdin-clean:
# secret-tool reads the password from stdin (newline-terminated). NO argv
# leak; AP-7 holds end-to-end (no documented exception).
# Idempotency: clear-then-store guarantees last-write-wins; clear's non-zero
# exit on missing item is swallowed.
secret_set() {
  local name="$1"
  assert_safe_name "${name}" "credential-name"
  "${_LIBSECRET_TOOL_BIN}" clear service "${_LIBSECRET_SERVICE}" account "${name}" >/dev/null 2>&1 || true
  "${_LIBSECRET_TOOL_BIN}" store --label "browser-skill: ${name}" \
    service "${_LIBSECRET_SERVICE}" account "${name}"
}

secret_get() {
  local name="$1"
  assert_safe_name "${name}" "credential-name"
  "${_LIBSECRET_TOOL_BIN}" lookup service "${_LIBSECRET_SERVICE}" account "${name}"
}

secret_delete() {
  local name="$1"
  assert_safe_name "${name}" "credential-name"
  "${_LIBSECRET_TOOL_BIN}" clear service "${_LIBSECRET_SERVICE}" account "${name}" >/dev/null 2>&1 || true
}

secret_exists() {
  local name="$1"
  assert_safe_name "${name}" "credential-name"
  "${_LIBSECRET_TOOL_BIN}" lookup service "${_LIBSECRET_SERVICE}" account "${name}" >/dev/null 2>&1
}
```

Steps:
- [ ] **3.1** Write the file with full header documenting the AP-7-clean property (contrast to keychain).
- [ ] **3.2** Run GREEN.

---

## Task 4: Wire libsecret into credential dispatcher

Modify `scripts/lib/credential.sh::_credential_dispatch_backend`:
- `libsecret` branch: replace `die EXIT_TOOL_MISSING ...` with `source "${lib_dir}/libsecret.sh"; "secret_${op}" "${name}" "$@"`.
- `keychain` and `plaintext` branches unchanged.

After this PR, ALL three backend branches dispatch to real implementations. The unknown-backend default arm stays.

Steps:
- [ ] **4.1** Apply the diff.

---

## Task 5: Update `tests/credential.bats` for libsecret

Replace the existing "credential_set_secret returns EXIT_TOOL_MISSING for libsecret backend (deferred to part 2c)" test with:
- "credential_set_secret + credential_get_secret roundtrip via libsecret backend (stub-validated)"

Use the inline-env-prefix style (matching the existing keychain test pattern in this file).

Steps:
- [ ] **5.1** Edit the bats file.

---

## Task 6: Lint + full bats run

Steps:
- [ ] **6.1** `bash tests/lint.sh` exit 0.
- [ ] **6.2** `bash tests/run.sh` — expect 345 + ~13 = ~358 pass / 0 fail.

---

## Task 7: CHANGELOG + commit + tag + PR

Steps:
- [ ] **7.1** Add `### Phase 5 part 2c` subsection to `CHANGELOG.md`.
- [ ] **7.2** Commit: `feat(phase-5-part-2c): Linux libsecret backend (secret-tool)`.
- [ ] **7.3** Tag: `v0.7.2-phase-05-part-2c-libsecret`.
- [ ] **7.4** Push branch + tag; `gh pr create`.
- [ ] **7.5** Wait CI green on macos-latest + ubuntu-latest.
- [ ] **7.6** Squash-merge + delete branch + reset main.

---

## Acceptance criteria

- [ ] `scripts/lib/secret/libsecret.sh` exists; 4-fn API; AP-7 clean (no documented exception present in header).
- [ ] `tests/stubs/secret-tool` exists and is executable.
- [ ] `tests/secret_libsecret.bats` (~13 cases) green via stub.
- [ ] `tests/credential.bats` libsecret roundtrip test passes.
- [ ] `bash tests/lint.sh` exit 0 across 3 tiers.
- [ ] `bash tests/run.sh` ≥358 pass / 0 fail.
- [ ] No verb script files added/modified.
- [ ] `scripts/lib/router.sh` UNTOUCHED.
- [ ] After this PR, `lib/credential.sh::_credential_dispatch_backend` has zero `die EXIT_TOOL_MISSING` placeholder branches — all three backends real.
- [ ] CI green on macos-latest + ubuntu-latest (stub makes both pass identically).

---

## Out of scope (explicit — defer with named follow-ups)

| Item | Goes to |
|---|---|
| Verb scripts (`creds add/list/show/remove`); per-OS-default backend selection (smart auto-detect: keychain on Darwin, libsecret on Linux with `command -v secret-tool`, plaintext fallback); first-use typed-phrase confirmation; `mask.sh` for `creds show` | **part 2d** |
| `migrate-credential` cross-backend moves | **part 2e** |
| Auto-relogin (single-retry on `EXIT_SESSION_EXPIRED` with stored credentials) | Phase 5 part 3 |
| TOTP (`--enable-totp`, RFC 6238 codes) | Phase 5 part 4 |
| Real libsecret integration test (no stub; requires Linux runner with running D-Bus session + libsecret installed) | optional follow-up gated on CI matrix expansion |
| `kwallet` backend (KDE) | not in current spec; revisit if user demand surfaces |

---

## Risk register

| Risk | Mitigation |
|---|---|
| Stub diverges from real `secret-tool` behavior | Stub covers store/lookup/clear with the exact attr=val pair pattern (`service` + `account`) the backend uses; real-libsecret integration test (deferred) closes the loop on Linux-only follow-up |
| `secret-tool store` writes a trailing newline as part of the password (some users hit this) | Stub mimics this exactly; backend documents the byte-exact roundtrip behavior in its header; tests assert verbatim roundtrip |
| Test runs on macOS CI without `secret-tool` installed | Stub override at `${LIBSECRET_TOOL_BIN}` makes tests OS-agnostic |
| D-Bus session not running on a Linux box (server / sandbox without dbus-daemon) → real `secret-tool` fails | This affects real-mode use only; doctor (in part 2d's surface integration) will check `command -v secret-tool` AND probe whether the agent is reachable; smart auto-detect falls through to plaintext on failure |
