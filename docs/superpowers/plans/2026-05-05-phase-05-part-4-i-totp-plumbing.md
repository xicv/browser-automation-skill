# Phase 5 part 4-i — TOTP foundation: `--enable-totp` flag at `creds add` time

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans.

**Goal:** Foundation PR for TOTP support. Mark a credential as TOTP-enabled in metadata; gate behind a typed acknowledgment; forbid plaintext backend (TOTP secrets are categorically more sensitive than passwords).

**Sub-scope (4-i minimal — plumbing only, no codegen / no replay / no rotation):**
- `--enable-totp` flag persists `totp_enabled: true` in cred metadata.
- `--yes-i-know-totp` typed-phrase ack required when `--enable-totp` is set.
- Plaintext backend refused for TOTP-enabled creds.
- No TOTP secret persistence yet (part 4-ii).
- No code generation (part 4-ii).
- No login --auto replay of TOTP code (part 4-iii).
- No rotate-totp verb (part 4-iv).

**Branch:** `feature/phase-05-part-4-totp`
**Tag:** `v0.18.0-phase-05-part-4-i-totp-plumbing`.

---

## Threat model

A TOTP shared secret is the seed for an HMAC-based code generator. Anyone with the secret can generate auth codes indefinitely (until re-enrollment with the service). Even more sensitive than a password because:
- Passwords typically expire or rotate (forced by service or user practice).
- TOTP secrets typically don't — issued once, valid for years.
- Compromise window is therefore orders of magnitude longer.

Implication for storage: plaintext on-disk storage means anyone with read access to the cred file owns the TOTP forever. **Refuse plaintext.** Force OS keychain (Darwin) / libsecret (Linux) — both encrypt at rest and gate access on user authentication.

The typed acknowledgment (`--yes-i-know-totp`) makes the threat model explicit at add time so users can't enable TOTP carelessly.

---

## File Structure

### Modified

| Path | Change |
|---|---|
| `scripts/browser-creds-add.sh` | + `--enable-totp` flag; + `--yes-i-know-totp` ack flag; + plaintext refusal when totp enabled; + persist `totp_enabled` in metadata from flag (was hardcoded false) |
| `tests/creds-add.bats` | +4 cases (refusal w/o ack, refusal of plaintext, happy path persists, default-false regression) |
| `CHANGELOG.md` | Phase 5 part 4-i subsection |

### New
- `docs/superpowers/plans/2026-05-05-phase-05-part-4-i-totp-plumbing.md` — this plan.

### Untouched
- `scripts/lib/credential.sh` (schema unchanged — `totp_enabled` field already in metadata template since part 2d)
- `scripts/lib/secret/*.sh` (no backend ABI changes — TOTP secret storage is part 4-ii using name-suffix convention)
- Every other verb script
- All adapters

---

## Test approach

`tests/creds-add.bats` adds:
1. `--enable-totp` without `--yes-i-know-totp` → EXIT_USAGE_ERROR mentioning the ack flag.
2. `--enable-totp` + `--backend plaintext` → EXIT_USAGE_ERROR explaining the plaintext refusal.
3. `--enable-totp` + `--backend keychain` + `--yes-i-know-totp` → succeeds; metadata.totp_enabled is true.
4. No `--enable-totp` (regression) → metadata.totp_enabled defaults to false.

---

## Tag + push

```
git tag v0.18.0-phase-05-part-4-i-totp-plumbing
git push -u origin feature/phase-05-part-4-totp
git push origin v0.18.0-phase-05-part-4-i-totp-plumbing
gh pr create --title "feat(phase-5-part-4-i): TOTP foundation — --enable-totp flag at creds-add"
```
