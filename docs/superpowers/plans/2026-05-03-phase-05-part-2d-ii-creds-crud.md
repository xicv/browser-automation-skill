# Phase 5 part 2d-ii — `creds list/show/remove` verbs

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans.

**Goal:** Three small verbs in one PR, mirroring the existing `list-sessions` / `show-session` / `remove-session` shape exactly. Closes the basic CRUD loop on credentials. After this PR, the lifecycle is: `creds add` (part 2d) → `creds list` / `creds show` (read) → `creds remove` (delete).

**Out of scope:**
- `creds show --reveal` typed-phrase flow + `mask.sh` → part 2d-iii
- `creds migrate` cross-backend moves → part 2e

**Branch:** `feature/phase-05-part-2d-ii-creds-crud`.

---

## File Structure

### New (creates)

| Path | Purpose | Size budget |
|---|---|---|
| `scripts/browser-creds-list.sh` | Walk `${CREDENTIALS_DIR}`, optional `--site` filter; one summary JSON object listing all matching credentials (metadata only) | ≤ 100 LOC |
| `scripts/browser-creds-show.sh` | Show one credential's metadata (NEVER secret value) | ≤ 80 LOC |
| `scripts/browser-creds-remove.sh` | Typed-name confirmation; delete metadata + secret via `credential_delete` | ≤ 100 LOC |
| `tests/creds-list.bats` | List verb integration tests | ≤ 150 LOC |
| `tests/creds-show.bats` | Show verb integration tests | ≤ 150 LOC |
| `tests/creds-remove.bats` | Remove verb integration tests (× 3 backends via stubs) | ≤ 250 LOC |

### Modified

| Path | Change | Estimated diff |
|---|---|---|
| `SKILL.md` | Add 3 rows: `creds list`, `creds show`, `creds remove` | +~3 LOC |
| `CHANGELOG.md` | New `### Phase 5 part 2d-ii` subsection | +~12 LOC |

### Untouched

- `scripts/lib/*.sh`, `scripts/lib/secret/*.sh`, every adapter file
- `scripts/browser-doctor.sh`, `scripts/browser-creds-add.sh`
- `tests/lint.sh`

---

## Patterns mirrored

- **List shape** ← `browser-list-sessions.sh`: optional `--site` filter; emits one summary JSON with a `credentials: [...]` array; `status` is `"empty"` when count = 0, `"ok"` otherwise; `why` is `"list-all"` or `"list-by-site"`.
- **Show shape** ← `browser-show-session.sh`: required `--as`; emits metadata JSON only; **NEVER** echoes the secret payload (privacy invariant — bats grep guard with sentinel canary).
- **Remove shape** ← `browser-remove-session.sh`: required `--as`; typed-name confirmation prompt unless `--yes-i-know`; `--dry-run` reports without writing; calls `credential_delete` (which removes both `<name>.json` + `<name>.secret` via backend dispatcher).

---

## Test coverage

| File | Cases | Highlights |
|---|---|---|
| `creds-list.bats` | ~6 | empty state, populated state, `--site` filter, summary shape, no `secret` field in any row, multi-backend mix |
| `creds-show.bats` | ~6 | existing cred, missing cred (exit non-zero), privacy invariant (no secret value in output), `--as` required, summary shape, output contains expected metadata fields |
| `creds-remove.bats` | ~10 | typed-name happy path, mismatch refusal, `--yes-i-know` skip, `--dry-run`, missing cred exit, plaintext backend (file gone after), keychain backend (entry gone via stub), libsecret backend (entry gone via stub), summary shape, idempotent on already-deleted |

Setup() in remove + show bats unconditionally exports `KEYCHAIN_SECURITY_BIN`/`LIBSECRET_TOOL_BIN` stubs (defensive — same pattern as creds-add.bats). Same lesson preserved.

---

## Acceptance criteria

- [ ] All 3 verb scripts exist, are executable, and emit single-line JSON summaries.
- [ ] `creds show` privacy invariant: bats asserts no secret payload appears in output (sentinel canary like part 2a).
- [ ] `creds remove` idempotent w/ `--dry-run`; typed-name confirmation matches `remove-session` UX.
- [ ] `creds remove` works for all 3 backends via stubs (delete on plaintext = file gone; on keychain/libsecret = entry gone in stub store).
- [ ] `bash tests/lint.sh` exit 0 across 3 tiers.
- [ ] `bash tests/run.sh` ≥404 pass / 0 fail (382 + ~22 new).
- [ ] `scripts/lib/router.sh` UNTOUCHED.
- [ ] CI green on macos-latest + ubuntu-latest.

---

## Out of scope

| Item | Goes to |
|---|---|
| `mask.sh` lib + `creds show --reveal` typed-phrase flow | **part 2d-iii** |
| First-use plaintext typed-phrase confirmation | **part 2d-iii** |
| Interactive `read -s` password prompt for `creds add` | follow-up |
| `migrate-credential` cross-backend moves | **part 2e** |
