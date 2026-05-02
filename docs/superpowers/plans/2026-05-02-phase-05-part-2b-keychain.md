# Phase 5 part 2b — macOS Keychain backend (security CLI)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans.

**Goal:** Land the second credentials backend — `scripts/lib/secret/keychain.sh` — wired into the dispatcher in `lib/credential.sh`. Mirrors `secret/plaintext.sh` exactly: 4-fn API (`secret_set/get/delete/exists`), sentinel guard, sources `common.sh` for `assert_safe_name` + `EXIT_*`. Uses macOS's built-in `security` CLI under the hood.

**Why first (vs libsecret):** Per parent spec §1, macOS Keychain is the smart per-OS default on macOS — the most common dev box for browser-automation work. Until 2b lands, macOS users default to plaintext-with-warning, which is paper security without disk encryption. Shipping 2b first reduces the worst-case install posture immediately.

**AP-7 caveat — documented exception.** macOS's `security` CLI takes the password on argv (`-w PASSWORD`). There is no clean stdin path in the upstream tool (verified: `security add-generic-password`'s `-w` flag is argv-only; the only stdin-input path is interactive TTY prompt, which doesn't compose with a non-TTY pipeline). The skill's own code never puts secrets on argv (`secret_set` reads stdin, then invokes `security`); the leak surface is the brief `security` subprocess invocation (~50ms). Mitigations:
1. Subprocess is short-lived — `ps` polling at any practical rate misses it
2. The `-U` flag makes the call idempotent (no second invocation needed)
3. Cheatsheet (when 2d ships) documents the trade-off vs alternatives
4. Linux libsecret (part 2c) uses `secret-tool` which IS stdin-clean — so the AP-7 exception is macOS-specific

This is the pragmatic-honest pattern: AP-7 holds for our code; the upstream tool's argv design is an unavoidable constraint we acknowledge in the file header + cheatsheet rather than work around with extra runtime deps (python+keyring, swift helper, etc).

**Tech stack:** Bash 5+, jq, bats-core. macOS `security` CLI (built-in, always present). Test stub at `tests/stubs/security` lets the bats run on Ubuntu CI too — same pattern as `tests/stubs/playwright-cli`.

**Spec references:**
- Parent spec §1 (per-OS-default backend model — macOS Keychain is Tier 1 on macOS).
- Token-efficient-output spec §3 — backend operations are silent (no streaming JSON; secrets flow via stdin/stdout, not streaming events).
- AP-6 (namespace-prefix file-scope globals), AP-7 (no secrets in argv — *with documented upstream-tool exception*).

**Branch:** `feature/phase-05-part-2b-keychain`.

---

## File Structure

### New (creates)

| Path | Purpose | Size budget |
|---|---|---|
| `scripts/lib/secret/keychain.sh` | macOS Keychain backend — 4-fn API; shells to `${KEYCHAIN_SECURITY_BIN:-security}` | ≤ 150 LOC |
| `tests/stubs/security` | Mock of macOS `security` CLI — supports `add/find/delete-generic-password` with `-s/-a/-w` flags; state in `${KEYCHAIN_STUB_STORE:-/tmp/keychain-stub.json}` | ≤ 80 LOC |
| `tests/secret_keychain.bats` | Backend unit tests via stub | ≤ 200 LOC |
| `docs/superpowers/plans/2026-05-02-phase-05-part-2b-keychain.md` | This plan | — |

### Modified

| Path | Change | Estimated diff |
|---|---|---|
| `scripts/lib/credential.sh` | Keychain dispatcher branch shifts from `die EXIT_TOOL_MISSING` placeholder to `source secret/keychain.sh; secret_${op}` | +~5 LOC, -~3 LOC |
| `tests/credential.bats` | Replace "credential_set_secret returns EXIT_TOOL_MISSING for keychain" with positive-roundtrip-via-stub test | +~12 LOC, -~10 LOC |
| `CHANGELOG.md` | New `### Phase 5 part 2b` subsection | +~10 LOC |

### Untouched

- `scripts/lib/router.sh`, `scripts/lib/common.sh`, `scripts/lib/output.sh`, `scripts/lib/site.sh`, `scripts/lib/session.sh`, `scripts/lib/secret/plaintext.sh`
- `scripts/browser-doctor.sh`, every `scripts/browser-<verb>.sh`
- every adapter file
- `SKILL.md` (no new verbs)
- `tests/lint.sh`

---

## Pre-Plan: branch + plan commit

- [x] **Step 0.1** Branch `feature/phase-05-part-2b-keychain`.
- [ ] **Step 0.2** Commit plan: `docs: phase-5 part-2b plan — macOS Keychain backend`.

---

## Task 1: security CLI stub + state-file model

`tests/stubs/security` is the bash mock of the upstream `security` CLI. State lives in a JSON file (`${KEYCHAIN_STUB_STORE}` per test) — `{"NAME": "PW", ...}` keyed by account.

Subcommands handled:
- `add-generic-password -s SERVICE -a NAME -w PW [-U]` → `{NAME: PW}` merge into store
- `find-generic-password -s SERVICE -a NAME -w` → echo PW or exit 44 (security's "item not found" code)
- `find-generic-password -s SERVICE -a NAME` (no `-w`) → exit 0/44 (existence probe)
- `delete-generic-password -s SERVICE -a NAME` → remove from store

Steps:
- [ ] **1.1** Write `tests/stubs/security`; chmod +x.

---

## Task 2: RED — `tests/secret_keychain.bats`

~12 cases, mirror of `secret_plaintext.bats`:
- file exists + readable
- `secret_set` reads stdin, persists to stub store (verify via `find-generic-password`)
- `secret_get` echoes payload verbatim
- `secret_delete` removes (idempotent)
- `secret_exists` 0/1
- multiple secrets coexist
- last-write-wins on overwrite
- `assert_safe_name` rejects `../escape`
- `secret_get` on missing exits non-zero
- AP-7 doc-acceptance comment present in keychain.sh header (grep for "AP-7" + "documented exception")
- Stub log captures argv (sanity: confirms stub was actually called)
- Service prefix is "browser-skill" by default (verify in stub log)

Steps:
- [ ] **2.1** Write the bats file.
- [ ] **2.2** Run RED.

---

## Task 3: GREEN — `scripts/lib/secret/keychain.sh`

```bash
[ -n "${BROWSER_SKILL_SECRET_KEYCHAIN_LOADED:-}" ] && return 0
readonly BROWSER_SKILL_SECRET_KEYCHAIN_LOADED=1

readonly _KEYCHAIN_SERVICE="${BROWSER_SKILL_KEYCHAIN_SERVICE:-browser-skill}"
readonly _KEYCHAIN_SECURITY_BIN="${KEYCHAIN_SECURITY_BIN:-security}"

# secret_set NAME — stdin → keychain via `security add-generic-password -w`.
# AP-7 documented exception: macOS security CLI takes -w PASSWORD on argv.
# Mitigation: short-lived subprocess (~50ms); -U makes idempotent.
secret_set() {
  local name="$1"
  assert_safe_name "${name}" "credential-name"
  local secret
  secret="$(cat)"
  "${_KEYCHAIN_SECURITY_BIN}" add-generic-password \
    -s "${_KEYCHAIN_SERVICE}" -a "${name}" -w "${secret}" -U \
    >/dev/null
}

secret_get() {
  local name="$1"
  assert_safe_name "${name}" "credential-name"
  "${_KEYCHAIN_SECURITY_BIN}" find-generic-password \
    -s "${_KEYCHAIN_SERVICE}" -a "${name}" -w 2>/dev/null
}

secret_delete() {
  local name="$1"
  assert_safe_name "${name}" "credential-name"
  "${_KEYCHAIN_SECURITY_BIN}" delete-generic-password \
    -s "${_KEYCHAIN_SERVICE}" -a "${name}" >/dev/null 2>&1 || true
}

secret_exists() {
  local name="$1"
  assert_safe_name "${name}" "credential-name"
  "${_KEYCHAIN_SECURITY_BIN}" find-generic-password \
    -s "${_KEYCHAIN_SERVICE}" -a "${name}" >/dev/null 2>&1
}
```

Steps:
- [ ] **3.1** Write the file with full header documenting the AP-7 exception.
- [ ] **3.2** Run GREEN.

---

## Task 4: Wire keychain into credential dispatcher

Modify `scripts/lib/credential.sh::_credential_dispatch_backend`:
- `keychain` branch: replace `die EXIT_TOOL_MISSING ...` with `source "${lib_dir}/keychain.sh"; "secret_${op}" "${name}" "$@"`
- `libsecret` branch: unchanged (still placeholder until 2c)

Steps:
- [ ] **4.1** Apply the diff.

---

## Task 5: Update `tests/credential.bats` for keychain

Replace the existing "credential_set_secret returns EXIT_TOOL_MISSING for keychain backend" test with:
- "credential_set_secret + credential_get_secret roundtrip via keychain backend (stub-validated)"

The libsecret-21 test stays (still deferred to 2c).

Steps:
- [ ] **5.1** Edit the bats file.
- [ ] **5.2** Run full `bash tests/run.sh tests/credential.bats` — expect all green.

---

## Task 6: Lint + full bats run

Steps:
- [ ] **6.1** `bash tests/lint.sh` exit 0.
- [ ] **6.2** `bash tests/run.sh` — expect 331 + ~12 keychain + 0 net change in credential = ~343 pass / 0 fail.

---

## Task 7: CHANGELOG + commit + tag + PR

Steps:
- [ ] **7.1** Add `### Phase 5 part 2b` subsection to `CHANGELOG.md`.
- [ ] **7.2** Commit: `feat(phase-5-part-2b): macOS Keychain backend (security CLI)`.
- [ ] **7.3** Tag: `v0.7.1-phase-05-part-2b-keychain`.
- [ ] **7.4** Push branch + tag; `gh pr create`.
- [ ] **7.5** Wait CI green on macos-latest + ubuntu-latest.
- [ ] **7.6** Squash-merge + delete branch + reset main.

---

## Acceptance criteria

- [ ] `scripts/lib/secret/keychain.sh` exists; 4-fn API; AP-7 exception documented in header.
- [ ] `tests/stubs/security` exists and is executable.
- [ ] `tests/secret_keychain.bats` (~12 cases) green via stub.
- [ ] `tests/credential.bats` keychain roundtrip test passes.
- [ ] `bash tests/lint.sh` exit 0 across 3 tiers.
- [ ] `bash tests/run.sh` ≥343 pass / 0 fail.
- [ ] No verb script files added/modified.
- [ ] `scripts/lib/router.sh` UNTOUCHED.
- [ ] CI green on macos-latest + ubuntu-latest (stub makes Ubuntu pass too).

---

## Out of scope (explicit — defer with named follow-ups)

| Item | Goes to |
|---|---|
| Linux libsecret backend (`scripts/lib/secret/libsecret.sh`) — uses `secret-tool` (stdin-clean) | **part 2c** |
| Verb scripts (`creds add/list/show/remove`); per-OS-default backend selection (smart auto-detect: keychain on macOS, libsecret on Linux, plaintext fallback) | **part 2d** |
| `migrate-credential` cross-backend moves | **part 2e** |
| Real macOS keychain integration test (no stub; requires macOS CI runner with Keychain access) | optional follow-up gated by `command -v security` on Darwin only |
| Touch-ID / biometric prompts | not in current spec |

---

## Risk register

| Risk | Mitigation |
|---|---|
| AP-7 exception expands quietly to other backends | libsecret uses `secret-tool` which IS stdin-clean — exception stays macOS-only; cheatsheet (part 2d) documents the asymmetry explicitly |
| Stub diverges from real `security` CLI behavior | Stub covers the 3 subcommands + 4 flags this backend uses; real-keychain integration test (deferred) closes the loop on macOS-only follow-up |
| Service prefix collision with other apps using "browser-skill" service | Override knob `BROWSER_SKILL_KEYCHAIN_SERVICE` lets users pick a unique prefix; default is unique enough for this skill's audience |
| `security delete-generic-password` exits non-zero on missing item; idempotent contract requires success | Wrapped with `\|\| true` |
| Test runs on Ubuntu CI without `security` binary | Stub override at `${KEYCHAIN_SECURITY_BIN}` makes tests OS-agnostic |
