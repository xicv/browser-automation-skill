# Phase 5 part 2a — credentials foundation (lib + plaintext backend)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans.

**Goal:** Land the credentials substrate — a `scripts/lib/credential.sh` lib + a `scripts/lib/secret/plaintext.sh` backend — that future verbs (`creds add/list/show/remove` in 2d, `migrate-credential` in 2e), auto-relogin (Phase 5 part 3), and TOTP (Phase 5 part 4) all build on. Mirrors the Phase-4-part-4a precedent: scaffold the abstraction in isolation, defer surface integration.

**Architecture:** Per parent spec §1, credentials use a **per-OS-default backend** model: macOS Keychain (Phase 5 part 2b) → libsecret (Phase 5 part 2c) → plaintext-with-typed-phrase-confirmation fallback (this PR). Each backend exposes the same 4-fn surface (`secret_set`, `secret_get`, `secret_delete`, `secret_exists`) — `lib/credential.sh` dispatches by `metadata.backend`. Secret material moves through stdin pipes only — never argv (AP-7).

**Schema** (mirror session schema from Phase 2):

```json
{
  "schema_version": 1,
  "name": "prod--admin",
  "site": "prod",
  "account": "admin@example.com",
  "backend": "plaintext",
  "auth_flow": "single-step-username-password",
  "auto_relogin": true,
  "totp_enabled": false,
  "created_at": "2026-05-02T…Z"
}
```

Two files per credential:
- `${CREDENTIALS_DIR}/<name>.json` — metadata (mode 0600, no secret values)
- `${CREDENTIALS_DIR}/<name>.secret` — backend-owned secret payload (plaintext backend: same dir, mode 0600; keychain/libsecret: opaque pointer file, secret in OS vault)

**Tech stack:** Bash 5+, jq. No new runtime deps.

**Spec references:**
- Parent spec §1 (credentials invariants — never online, never argv, smart per-OS default), §3.1 (lib responsibility split: `credential.sh` for record I/O, `secret/{plaintext,keychain,libsecret}.sh` for backend implementations).
- Token-efficient-output spec §3 — credential_load output schema matches single-line JSON discipline (no streaming, no inline secret payloads).
- AP-7 (no secrets in argv), AP-6 (namespace-prefix file-scope globals).

**Branch:** `feature/phase-05-part-2a-creds-foundation`.

---

## File Structure

### New (creates)

| Path | Purpose | Size budget |
|---|---|---|
| `scripts/lib/credential.sh` | Lib — `credential_save/load/list/delete/exists/meta_load`; backend dispatcher routes secret operations by `metadata.backend` field | ≤ 250 LOC |
| `scripts/lib/secret/plaintext.sh` | Plaintext backend — `secret_set/get/delete/exists`; reads/writes `<name>.secret` mode 0600; first-use typed-phrase confirmation honored at the **lib** boundary, not here (backends are dumb I/O) | ≤ 100 LOC |
| `tests/credential.bats` | Lib unit tests | ≤ 250 LOC |
| `tests/secret_plaintext.bats` | Backend unit tests + argv-leak guard | ≤ 200 LOC |
| `docs/superpowers/plans/2026-05-02-phase-05-part-2a-creds-foundation.md` | This plan | — |

### Modified

| Path | Change | Estimated diff |
|---|---|---|
| `CHANGELOG.md` | New `### Phase 5 part 2a` subsection | +~12 LOC |

### Untouched

- `scripts/lib/router.sh`, `scripts/lib/common.sh`, `scripts/lib/output.sh`, `scripts/lib/site.sh`, `scripts/lib/session.sh`, `scripts/lib/verb_helpers.sh`
- `scripts/browser-doctor.sh` (no surface yet — credential count comes in 2d when verbs land)
- every existing `scripts/browser-*.sh`
- every existing adapter file
- `tests/lint.sh` (no new lint tier needed — lib files don't enforce adapter ABI)
- `SKILL.md` (no new verbs this PR — verbs in 2d will trigger autogen)

---

## Pre-Plan: branch + plan commit

- [x] **Step 0.1** Branch `feature/phase-05-part-2a-creds-foundation`.
- [ ] **Step 0.2** Commit plan: `docs: phase-5 part-2a plan — creds foundation (lib + plaintext)`.

---

## Task 1: RED — `tests/secret_plaintext.bats`

Backend contract tests; backend file doesn't exist yet so all fail.

Coverage (~10 cases):
- `secret_set NAME` reads stdin, writes `${CREDENTIALS_DIR}/<name>.secret` mode 0600.
- `secret_get NAME` echoes the payload to stdout.
- `secret_delete NAME` removes the file (idempotent — succeeds even if missing).
- `secret_exists NAME` returns 0 if file present, non-zero if not.
- `assert_safe_name` rejects `../escape`, `with space`, empty.
- Roundtrip: `printf 'pw' | secret_set foo; secret_get foo` echoes `pw` exactly (no trailing newline mangling — stdin verbatim).
- Argv-leak guard: `secret_set` MUST NOT accept the secret as an argv arg; passing 2nd arg fails (or is ignored — pick one and assert).
- File mode after `secret_set` is `600` exactly.
- `${CREDENTIALS_DIR}` is created with mode `700` if missing (mirrors `session_save` pattern).
- Multiple secrets coexist (set foo + set bar → both readable).

Steps:
- [ ] **1.1** Write the bats file.
- [ ] **1.2** Run RED: `bash tests/run.sh tests/secret_plaintext.bats` — expect ~10 failures.

---

## Task 2: GREEN — `scripts/lib/secret/plaintext.sh`

Backend implementation. ~80 LOC. Sentinel guard. Sources `common.sh` for `assert_safe_name` + `EXIT_*`. NO secret-flow logic (that's lib/credential.sh's job).

API:
```bash
secret_set NAME       # reads stdin → ${CREDENTIALS_DIR}/<name>.secret mode 0600
secret_get NAME       # cat → stdout
secret_delete NAME    # rm -f, idempotent
secret_exists NAME    # test -f, returns 0/1
```

Path helper:
```bash
_secret_plaintext_path() { printf '%s/%s.secret' "${CREDENTIALS_DIR}" "$1"; }
```

Steps:
- [ ] **2.1** Write the file.
- [ ] **2.2** Run GREEN: bats green.

---

## Task 3: RED — `tests/credential.bats`

Lib contract tests. ~15 cases.

Coverage:
- `credential_save NAME META_JSON` writes metadata file mode 0600 (no secret).
- `credential_save` validates metadata has required fields: `name`, `site`, `account`, `backend`, `created_at`.
- `credential_save` rejects an existing name (caller must `credential_delete` first; no `--force` flag — caller's job to confirm).
- `credential_load NAME` echoes metadata JSON; NEVER includes a secret value.
- `credential_meta_load NAME` is an alias for `credential_load` (clarity for callers).
- `credential_list_names` returns sorted names; excludes `*.secret` files.
- `credential_delete NAME` removes both metadata + secret (via backend dispatch); idempotent.
- `credential_exists NAME` returns 0/1.
- `credential_set_secret NAME` (reads stdin) dispatches to backend per metadata.backend; routes plaintext → `secret_set`; for `keychain` or `libsecret` backends, exits `EXIT_TOOL_MISSING` (21) — placeholder until 2b/2c land.
- `credential_get_secret NAME` — same dispatch, calls `secret_get` to stdout.
- `credential_set_secret` errors clearly if no metadata exists yet (must `credential_save` first).
- `assert_safe_name` guards on all NAME args.
- Schema bumped to 1 (constant for future migrations).
- credential metadata round-trip preserves all fields verbatim (jq normalize via `.`).

Steps:
- [ ] **3.1** Write the bats file.
- [ ] **3.2** Run RED.

---

## Task 4: GREEN — `scripts/lib/credential.sh`

Lib implementation. ~200 LOC. Sentinel guard. Sources `common.sh`. Sources backends on-demand (only `secret/plaintext.sh` exists in this PR; 2b/2c add the others).

API:
```bash
credential_save NAME META_JSON              # metadata only
credential_load NAME                        # echoes metadata JSON
credential_meta_load NAME                   # alias
credential_list_names                       # sorted, excludes .secret
credential_delete NAME                      # both files via backend
credential_exists NAME
credential_set_secret NAME                  # stdin → backend
credential_get_secret NAME                  # backend → stdout
```

Backend dispatcher (internal):
```bash
_credential_dispatch_backend() {
  local name="$1" op="$2"
  shift 2
  local meta backend
  meta="$(credential_load "${name}")" || return $?
  backend="$(printf '%s' "${meta}" | jq -r '.backend')"
  case "${backend}" in
    plaintext)
      source "${BASH_SOURCE%/*}/secret/plaintext.sh"
      "secret_${op}" "${name}" "$@"
      ;;
    keychain|libsecret)
      die "${EXIT_TOOL_MISSING}" "credential ${name}: backend '${backend}' lands in phase-05 part 2${backend:0:1} (keychain=2b, libsecret=2c)"
      ;;
    *)
      die "${EXIT_USAGE_ERROR}" "credential ${name}: unknown backend '${backend}'"
      ;;
  esac
}
```

Steps:
- [ ] **4.1** Write the file.
- [ ] **4.2** Run GREEN.

---

## Task 5: Lint + full bats run

Steps:
- [ ] **5.1** `bash tests/lint.sh` — exit 0 across all 3 tiers.
- [ ] **5.2** `bash tests/run.sh` — expect 298 + ~25 new = ~323 pass / 0 fail.

---

## Task 6: CHANGELOG + commit + tag + PR

Steps:
- [ ] **6.1** Add `### Phase 5 part 2a` subsection summarizing: lib scaffold, plaintext backend, schema v1, deferred backends (2b/2c), deferred verbs (2d), invariants (AP-7 stdin-only, mode 0600, mode 0700 dir).
- [ ] **6.2** Commit: `feat(phase-5-part-2a): credentials foundation (lib + plaintext backend)`.
- [ ] **6.3** Tag: `v0.7.0-phase-05-part-2a-creds-foundation` (minor — new auth substrate).
- [ ] **6.4** Push branch + tag; `gh pr create`.
- [ ] **6.5** Wait CI green on macos-latest + ubuntu-latest.
- [ ] **6.6** Squash-merge + delete branch + reset main.

---

## Acceptance criteria

- [ ] `scripts/lib/credential.sh` exists; 8 public fns documented; backend dispatcher routes plaintext → `secret/plaintext.sh`; keychain/libsecret return `EXIT_TOOL_MISSING` (21) with self-healing hint.
- [ ] `scripts/lib/secret/plaintext.sh` exists; 4-fn API; stdin-only secret flow.
- [ ] `tests/credential.bats` (~15 cases) + `tests/secret_plaintext.bats` (~10 cases) green.
- [ ] `bash tests/lint.sh` exit 0 across 3 tiers.
- [ ] `bash tests/run.sh` ≥323 pass / 0 fail.
- [ ] No verb script files added/modified.
- [ ] `scripts/lib/router.sh` UNTOUCHED.
- [ ] CI green on macos-latest + ubuntu-latest.

---

## Out of scope (explicit — defer with named follow-ups)

| Item | Goes to |
|---|---|
| macOS Keychain backend (`scripts/lib/secret/keychain.sh`) — uses `security` CLI | **part 2b** |
| Linux libsecret backend (`scripts/lib/secret/libsecret.sh`) — uses `secret-tool` | **part 2c** |
| Verb scripts: `scripts/browser-creds-add.sh` / `-list.sh` / `-show.sh` / `-remove.sh` | **part 2d** |
| `migrate-credential` verb (cross-backend moves) | **part 2e** |
| Auto-relogin (single-retry on `EXIT_SESSION_EXPIRED` with stored credentials) | Phase 5 part 3 |
| TOTP (`--enable-totp`, RFC 6238 codes via `oathtool`) | Phase 5 part 4 |
| `mask.sh` for masked show-credential output (--reveal flag with typed-phrase) | part 2d (where it's used) |
| Capture sanitisation (HAR redact, etc) | Phase 7 |

---

## Risk register

| Risk | Mitigation |
|---|---|
| Plaintext backend on disk without disk encryption is paper security | Doctor (Phase 1) already reports FileVault / LUKS status; cheatsheet in part 2d will reinforce; first-use typed-phrase prompt (deferred to 2d's `creds add` verb) explicitly surfaces "this is plaintext at rest" to the user |
| Backend dispatcher exposes a string-eval-shaped vulnerability if `metadata.backend` is attacker-controlled | `metadata.backend` is matched by `case` against an allowlist; unknown values exit `EXIT_USAGE_ERROR` |
| Schema version 1 fixed without migration tooling | Phase 10 introduces `migrate-schema`; until then, `schema_version` is read but not consumed |
| Argv-leak in tests itself (e.g. echoing the password to bash heredoc) | `tests/argv_leak.bats` (Phase 1) sweeps for this; new bats files use `printf 'pw' \| ...` style throughout |
| Backend dispatcher can't easily be tested for keychain/libsecret without the actual binaries | Tests assert the placeholder exit-21 path; real backends arrive in 2b/2c with their own bats |
