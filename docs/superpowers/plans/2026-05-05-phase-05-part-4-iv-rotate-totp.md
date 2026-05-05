# Phase 5 part 4-iv — `creds rotate-totp` verb (closes Phase 5)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans.

**Goal:** Final HANDOFF queue item. Re-enroll TOTP shared secret for an existing totp_enabled credential when the service forces a new secret (re-issued QR code during account recovery, security-incident rotation, etc.).

**Branch:** `feature/phase-05-part-4-iv-rotate-totp`
**Tag:** `v0.21.0-phase-05-part-4-iv-rotate-totp` — closes Phase 5 feature-complete.

---

## Design

Mirrors `creds-migrate` shape:
- Required `--as CRED_NAME` + `--totp-secret-stdin` (AP-7).
- Typed-phrase confirmation (default; `--yes-i-know` skips).
- Validates cred exists + is totp_enabled.
- Reads new secret from stdin (single chunk; no NUL split needed since it's not multiplexed with anything).
- Calls `credential_set_totp_secret NAME` to overwrite the `<name>__totp` backend slot.
- Metadata + password slot UNCHANGED.
- Privacy canary: new secret never appears in stdout/stderr.

## File Structure

### New
- `scripts/browser-creds-rotate-totp.sh` — verb script.
- `tests/creds-rotate-totp.bats` — 11 cases.
- `docs/superpowers/plans/2026-05-05-phase-05-part-4-iv-rotate-totp.md` — this plan.

### Modified
- `SKILL.md` — new `creds totp` + `creds rotate-totp` rows.
- `CHANGELOG.md` — Phase 5 part 4-iv subsection + Phase 5 wrap announcement.

### Untouched
- `scripts/lib/credential.sh` — uses existing `credential_set_totp_secret` from 4-ii.
- All other verbs / adapters / router.

---

## Test approach

`tests/creds-rotate-totp.bats` covers:
1. `--as` required.
2. `--totp-secret-stdin` required (AP-7 enforcement).
3. Unknown cred → EXIT_SITE_NOT_FOUND.
4. Non-totp_enabled cred refused.
5. Empty stdin refused.
6. `--dry-run` skips mutation (slot value preserved).
7. Confirmation mismatch aborts (no mutation).
8. `--yes-i-know` happy path overwrites slot.
9. **Privacy canary** — new secret never in stdout/stderr.
10. Password slot UNCHANGED (regression guard).
11. Metadata UNCHANGED — totp_enabled stays true (regression guard).

---

## Phase 5 wrap

After this PR, all HANDOFF queue items are shipped:
- Part 1 (cdt-mcp): 8/8 verbs real-mode + Path B promotion + session loading.
- Part 2 (creds): 5 verbs + 3 backends.
- Part 3 (auth): login --auto + retry + auth-flow + 2FA detection.
- Part 4 (TOTP): foundation + codegen + auto-replay + rotation.

End-to-end agent flow for a 2FA-protected site:
```
agent runs verb (snapshot/click/etc.) → session expired (rc=22)
  → invoke_with_retry (3-ii) detects + calls login --auto
  → driver detects 2FA (3-iv)
  → driver auto-replays TOTP via stored secret (4-iii)
  → fresh storageState captured
  → verb retried successfully
```

Zero agent intervention from cred-add to repeated-use.

---

## Tag + push

```
git tag v0.21.0-phase-05-part-4-iv-rotate-totp
git push -u origin feature/phase-05-part-4-iv-rotate-totp
git push origin v0.21.0-phase-05-part-4-iv-rotate-totp
gh pr create --title "feat(phase-5-part-4-iv): creds rotate-totp verb (Phase 5 FEATURE-COMPLETE)"
```
