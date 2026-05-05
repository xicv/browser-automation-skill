# Phase 5 part 4-iii — `login --auto` TOTP auto-replay (closes auth track)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans.

**Goal:** Close the auth track end-to-end. When a session-aware verb hits `EXIT_SESSION_EXPIRED`, the transparent retry (part 3-ii) triggers `login --auto`. For TOTP-enabled creds, the driver should automatically replay the TOTP code on the 2FA challenge instead of exiting 25 (part 3-iv).

**Branch:** `feature/phase-05-part-4-iii-totp-auto-replay`
**Tag:** `v0.20.0-phase-05-part-4-iii-totp-auto-replay`.

---

## Architecture

### Stdin protocol extension

Pre-4-iii: `login --auto` pipes `account\0password` to driver stdin (AP-7).
4-iii: when cred is `totp_enabled`, pipe `account\0password\0totp_secret` (3 NUL-separated chunks).

Driver parses 1st-NUL-split → `username` + `rest`; 2nd-NUL-split of `rest` → `password` + `totpSecret` (optional, null if absent). Backward compatible — non-totp creds still produce 2 chunks.

### Driver-side TOTP integration

`scripts/lib/node/playwright-driver.mjs::runAutoRelogin` after submit + 15s navigation budget:
1. `detect2FA(page)` runs (existing 3-iv heuristic).
2. **If 2FA detected AND totpSecret present:**
   - Import `totpAt` from `./totp-core.mjs` (refactored out of `totp.mjs` for this purpose).
   - Generate current code using same logic as `creds-totp` verb (RFC 6238 SHA1, 30s window, 6 digits).
   - Fill OTP field via best-effort selectors (mirror 2FA detection signal):
     - `input[autocomplete="one-time-code"]`
     - `input[name*="otp" i]`, `input[name*="code" i]`, `input[name*="verification" i]`
     - `input#otp`, `input#code`
   - Click submit (use existing submit-button selectors + "Verify"/"Continue").
   - Wait for navigation (15s budget, same as login submit).
   - Fall through to normal `ctx.storageState()` capture path.
3. **If 2FA detected AND totpSecret absent:** exit 25 (existing 3-iv behavior).
4. **If 2FA not detected:** continue as today.

### Bash-side stdin mux

`scripts/browser-login.sh::--auto` reads cred metadata.totp_enabled. When true:

```bash
{
  printf '%s\0' "${cred_account}"
  credential_get_secret "${as}"
  printf '\0'
  credential_get_totp_secret "${as}"
} | node ... auto-relogin --url X --output-path Y
```

When false: existing 2-chunk pipe.

### Test harness

Driver tests against real Chrome + 2FA fixture site are out of CI scope. Use the same test-mode hook pattern as 3-iv: env var `BROWSER_SKILL_DRIVER_TEST_TOTP_REPLAY=1` short-circuits the driver to:
1. Read 3 chunks from stdin (validate the 3rd is non-empty).
2. Import totpAt and generate a code (validates totp-core import path).
3. Write empty storageState to `--output-path`.
4. Emit `auto-relogin-totp-replayed` JSON.
5. Exit 0.

Bats sets the env var + verifies bash side passes the 3rd chunk via stdin and the driver round-trips successfully.

---

## File Structure

### New
- `scripts/lib/node/totp-core.mjs` — `totpAt` + `base32Decode` exports (extracted from `totp.mjs` for reuse).
- `docs/superpowers/plans/2026-05-05-phase-05-part-4-iii-totp-auto-replay.md` — this plan.

### Modified
- `scripts/lib/node/totp.mjs` — refactored to import from `totp-core.mjs`; CLI behavior unchanged.
- `scripts/lib/node/playwright-driver.mjs` — 3-chunk stdin parsing + TOTP auto-replay branch in `runAutoRelogin` + new test-mode env var hook.
- `scripts/browser-login.sh` — when cred totp_enabled, append `\0totp_secret` to the driver's stdin pipe.
- `tests/login.bats` — +2 cases (totp-replay path via test-mode hook; non-totp regression).
- `CHANGELOG.md` — Phase 5 part 4-iii subsection.

### Untouched
- `scripts/lib/credential.sh` — already has `credential_get_totp_secret` from 4-ii.
- `scripts/lib/secret/*.sh` — backends already store the slot.
- All other verbs / adapters / router.

---

## Risks + mitigations

| Risk | Mitigation |
|---|---|
| OTP field selectors miss the 2FA page's actual input | Best-effort, mirrors detect2FA signals. Falls back to driver crash exit 30 if `fillFirstMatch` throws — bash propagates as EXIT_TOOL_CRASHED. User retries with --interactive. |
| TOTP code window expires between generate and fill | 30s window + sub-second fill latency. Acceptable per RFC 6238 standard practice. |
| Real-browser e2e test of the heuristic | Out of CI scope. The test-mode hook validates the stdin-mux + totp-core import. Real-Chrome validation manual. |

---

## Tag + push

```
git tag v0.20.0-phase-05-part-4-iii-totp-auto-replay
git push -u origin feature/phase-05-part-4-iii-totp-auto-replay
git push origin v0.20.0-phase-05-part-4-iii-totp-auto-replay
gh pr create --title "feat(phase-5-part-4-iii): login --auto TOTP auto-replay (closes auth track)"
```
