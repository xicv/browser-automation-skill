# Phase 5 part 2e — `migrate-credential` cross-backend moves

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans.

**Goal:** Last verb in phase-5 part 2. Lands `scripts/browser-creds-migrate.sh` — moves an existing credential from one backend to another (e.g. plaintext → keychain after the user upgrades their dev box). Closes the credentials track entirely; only auto-relogin (part 3) and TOTP (part 4) remain in Phase 5.

**Strategy — fail-safe ordering:** read from old, write to new, delete from old, update metadata. If the new-backend write fails, the original credential remains intact (degraded only if old-backend delete fails after a successful new-backend write — surface that as a warning, not a crash).

**Branch:** `feature/phase-05-part-2e-migrate-credential`.

---

## File Structure

### New (creates)

| Path | Purpose | Size budget |
|---|---|---|
| `scripts/browser-creds-migrate.sh` | Verb — typed-name confirmation, then `credential_migrate_to` | ≤ 200 LOC |
| `tests/creds-migrate.bats` | Verb integration tests across all 3 backend pairs + plaintext-gate inheritance | ≤ 250 LOC |
| `docs/superpowers/plans/2026-05-03-phase-05-part-2e-migrate-credential.md` | This plan | — |

### Modified

| Path | Change | Estimated diff |
|---|---|---|
| `scripts/lib/credential.sh` | Add `_credential_dispatch_to BACKEND OP NAME` (sibling to `_credential_dispatch_backend`; takes backend explicitly) + `credential_migrate_to NAME NEW_BACKEND` (public migrate primitive) | +~50 LOC |
| `tests/credential.bats` | ~6 new cases for `credential_migrate_to`: each backend pair (plaintext↔keychain↔libsecret), same-backend refusal, unknown-backend refusal, secret roundtrip preserved, metadata.backend updated, old-backend secret cleaned up | +~80 LOC |
| `SKILL.md` | Add `creds migrate` row to verbs table | +~1 LOC |
| `CHANGELOG.md` | New `### Phase 5 part 2e` subsection | +~12 LOC |

### Untouched

- `scripts/lib/router.sh`, `scripts/lib/common.sh`, `scripts/lib/output.sh`, `scripts/lib/site.sh`, `scripts/lib/session.sh`, `scripts/lib/secret_backend_select.sh`, `scripts/lib/mask.sh`
- `scripts/lib/secret/*.sh` (3 backends — Phase 5 part 2a/2b/2c)
- every other `scripts/browser-*.sh` (existing 4 creds verbs unchanged)
- every adapter file
- `tests/lint.sh`

---

## Task 1: `credential_migrate_to` lib helper

Add to `scripts/lib/credential.sh`:

```bash
# _credential_dispatch_to BACKEND OP NAME [...args]
# Like _credential_dispatch_backend, but uses BACKEND directly (instead of
# reading from metadata). Used by credential_migrate_to to write to the new
# backend BEFORE updating metadata, so a failed new-write doesn't leave the
# credential in an orphaned state.
_credential_dispatch_to() {
  local backend="$1" op="$2" name="$3"
  shift 3
  local lib_dir
  lib_dir="$(dirname "${BASH_SOURCE[0]}")/secret"
  case "${backend}" in
    plaintext|keychain|libsecret)
      # shellcheck source=/dev/null
      source "${lib_dir}/${backend}.sh"
      "secret_${op}" "${name}" "$@"
      ;;
    *)
      die "${EXIT_USAGE_ERROR}" "_credential_dispatch_to: unknown backend '${backend}'"
      ;;
  esac
}

# credential_migrate_to NAME NEW_BACKEND
# Move secret material from current backend to NEW_BACKEND, then update
# metadata. Fail-safe ordering: read-from-old, write-to-new, delete-from-old,
# update metadata. If new-write fails, original intact. If old-delete fails
# after successful new-write, both backends transiently hold the secret
# (degraded — verb script warns, doesn't crash; user can manually clean up).
credential_migrate_to() {
  local name="$1" new_backend="$2"
  assert_safe_name "${name}" "credential-name"

  case "${new_backend}" in
    plaintext|keychain|libsecret) ;;
    *) die "${EXIT_USAGE_ERROR}" "credential_migrate_to: unknown target backend '${new_backend}'" ;;
  esac

  local old_meta old_backend
  old_meta="$(credential_load "${name}")"
  old_backend="$(printf '%s' "${old_meta}" | jq -r '.backend')"

  if [ "${old_backend}" = "${new_backend}" ]; then
    die "${EXIT_USAGE_ERROR}" "credential ${name}: backend already '${new_backend}' (no-op refused)"
  fi

  # 1. Read secret from old backend.
  local secret
  secret="$(_credential_dispatch_to "${old_backend}" get "${name}")"

  # 2. Write secret to NEW backend FIRST. If this fails, original intact.
  printf '%s' "${secret}" | _credential_dispatch_to "${new_backend}" set "${name}"

  # 3. Delete secret from OLD backend. Failure here is degraded but not fatal
  # (caller logs a warning). Wrap in `|| true` so the migrate completes.
  _credential_dispatch_to "${old_backend}" delete "${name}" || true

  # 4. Update metadata.backend → new. Bypass credential_save's existence
  # check by writing the new file via tmp+mv (atomic).
  local new_meta path tmp
  new_meta="$(printf '%s' "${old_meta}" | jq --arg b "${new_backend}" '.backend = $b')"
  path="$(_credential_path "${name}")"
  tmp="${path}.tmp.$$"
  ( umask 077; printf '%s\n' "${new_meta}" | jq . > "${tmp}" )
  chmod 600 "${tmp}"
  mv "${tmp}" "${path}"
}
```

Tests in `tests/credential.bats` (~6 cases):
- migrate plaintext → keychain (verify secret in keychain stub, no .secret file in plaintext, metadata.backend = keychain)
- migrate keychain → libsecret (cross-OS-vault)
- migrate libsecret → plaintext (verify .secret file created)
- same-backend refused (`EXIT_USAGE_ERROR`)
- unknown target backend refused
- secret value preserved byte-exactly across migration

---

## Task 2: `creds-migrate` verb

CLI:
```
creds-migrate --as CRED_NAME --to BACKEND [options]

  --as CRED_NAME            credential to migrate (required)
  --to BACKEND              target: keychain | libsecret | plaintext (required)
  --yes-i-know              skip the typed-name confirmation
  --yes-i-know-plaintext    acknowledge plaintext storage (REQUIRED when --to plaintext + marker missing)
  --dry-run                 print planned action; migrate nothing
```

Behavior:
1. Required: `--as`, `--to`. assert_safe_name on `--as`. Validate `--to` ∈ {keychain, libsecret, plaintext}.
2. credential_exists check → else exit 23.
3. Load metadata → check current backend; if `--to == current`, exit 2 (no-op).
4. **First-use plaintext gate inherited from creds-add**: if `--to == plaintext` + marker missing + `--yes-i-know-plaintext` missing → exit 2 with hint. (This is the insight from part 2d-iii — migrate-to-plaintext respects the gate.)
5. dry-run: emit `would_run` summary + exit ok.
6. Typed-name confirmation (mirror remove-session UX): print prompt, read stdin one line, must equal `--as`. `--yes-i-know` skips.
7. Call `credential_migrate_to`.
8. Emit summary JSON: `{verb, tool, why, status, credential, from, to, duration_ms}`. **Privacy invariant: NO secret value in summary** (canary verified).

Tests (~10 cases):
- migrate plaintext → keychain happy path (cross-backend secret roundtrip; old gone, new present)
- migrate keychain → libsecret happy path
- migrate libsecret → plaintext requires `--yes-i-know-plaintext` (gate inherited)
- migrate libsecret → plaintext succeeds with `--yes-i-know-plaintext`
- same-backend refusal (exit 2)
- unknown credential (exit 23)
- unknown target backend (exit 2)
- typed-name mismatch refuses
- `--yes-i-know` skips prompt
- `--dry-run` reports without writing
- summary JSON has required keys
- privacy: summary contains no secret value (canary)

---

## Task 3: SKILL.md + CHANGELOG + lint + ship

- SKILL.md row: `| creds migrate | Move credential to a different backend | … creds-migrate --as prod--admin --to keychain --yes-i-know |`
- CHANGELOG entry summarizing migrate primitive + verb + privacy invariant + plaintext-gate inheritance
- Lint exit 0
- Tests ≥433 pass / 0 fail (421 + ~6 lib + ~10 verb = ~16; minus duplicates the migrate-related tests in credential.bats)

---

## Acceptance criteria

- [ ] `scripts/lib/credential.sh::credential_migrate_to` exists; covers all 3 backend pair migrations.
- [ ] Fail-safe ordering verified: write-to-new before delete-from-old.
- [ ] `scripts/browser-creds-migrate.sh` — typed-name confirmation, plaintext-gate inheritance, dry-run path.
- [ ] Privacy invariant: migrate summary JSON has NO secret value (canary tested).
- [ ] `bash tests/lint.sh` exit 0.
- [ ] `bash tests/run.sh` ≥437 pass / 0 fail.
- [ ] CI green on macos-latest + ubuntu-latest.
- [ ] **Phase 5 part 2 entirely complete** after this PR — no `creds-*` verbs remaining.

---

## Out of scope (defer)

| Item | Goes to |
|---|---|
| Auth-flow detection at migrate time (re-observe single-step vs interactive-required) | Phase 5 part 3 |
| Auto-relogin | Phase 5 part 3 |
| TOTP (`creds rotate-totp`) | Phase 5 part 4 |
| Bulk migrate-all-credentials verb | not needed; users can script `for c in $(creds list); do creds migrate ...; done` |

---

## Risk register

| Risk | Mitigation |
|---|---|
| Old-backend delete fails after new-write succeeds → secret duplicated across backends | Verb script logs `warn` line; degraded but not crashed. User can manually clean via `creds-remove --as` to old-backend OR re-run `creds migrate --to OLD_BACKEND` to consolidate |
| New-backend write fails → original intact (no degradation) | Fail-safe ordering. Test asserts: when new-write fails (e.g. via env var pointing stub at /nonexistent), credential metadata unchanged + old secret still readable |
| Migrate-to-plaintext bypasses first-use gate | Test asserts: marker missing + `--yes-i-know-plaintext` missing → refuses (gate inherited from creds-add) |
| Privacy: secret value leaks into summary JSON | Canary `sekret-do-not-leak-migrate` in test suite; assertion via `grep -q` |
| Bash array IFS bug (lesson from part 2d) | All new helpers use `[@]` quoting + bash arrays where iteration needed |
