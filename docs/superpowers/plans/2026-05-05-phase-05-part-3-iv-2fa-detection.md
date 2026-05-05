# Phase 5 part 3-iv — 2FA detection in `login --auto` → exit 25

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans.

**Goal:** When `login --auto` lands on a 2FA challenge page after submitting credentials, exit cleanly with `EXIT_AUTH_INTERACTIVE_REQUIRED` (25) instead of timing out for 15s and capturing an unauthenticated session.

**Branch:** `feature/phase-05-part-3-iv-2fa-detection`
**Tag:** `v0.17.0-phase-05-part-3-iv-2fa-detection`.

---

## Heuristic

After the existing submit-form + wait-for-navigation sequence, the driver runs `detect2FA(page)` which checks (in order):

1. `input[autocomplete="one-time-code"]` — RFC-standard OTP input.
2. Common OTP/code field name attributes:
   - `input[name*="otp" i]`
   - `input[name*="code" i]`
   - `input[name*="verification" i]`
   - `input[name*="two_factor" i]`
   - `input[name*="2fa" i]`
   - `input#otp`, `input#code`
3. Page-body text matching any of:
   - `two-factor`, `two factor`, `2fa`
   - `verification code`, `one-time code`, `one-time password`
   - `authenticator app`, `authenticator code`
   - `enter the code`, `enter code`

On match → close browser → emit `auto-relogin-2fa-required` JSON to stdout → exit 25.

## File Structure

### Modified

| Path | Change |
|---|---|
| `scripts/lib/node/playwright-driver.mjs` | + detect2FA(page) heuristic; runAutoRelogin calls it post-submit. + test-mode env var hook (BROWSER_SKILL_DRIVER_TEST_2FA=1) for bats. |
| `scripts/browser-login.sh` | --auto path captures driver rc; on 25 dies EXIT_AUTH_INTERACTIVE_REQUIRED with --interactive hint. |
| `tests/login.bats` | +1 case using test-mode env var. |
| `CHANGELOG.md` | Phase 5 part 3-iv subsection. |

### New
- `docs/superpowers/plans/2026-05-05-phase-05-part-3-iv-2fa-detection.md`

### Untouched
- `scripts/lib/credential.sh` (totp_enabled field already exists for part 4 future use; not used here)
- All other verbs / adapters / lib

---

## Test approach

`tests/login.bats` adds:
```
BROWSER_SKILL_DRIVER_TEST_2FA=1 \
  run bash browser-login.sh --site prod --as prod--2fa --auto
[ "${status}" = "${EXIT_AUTH_INTERACTIVE_REQUIRED}" ]
```

Production paths never set the env var → no behavioral change for real invocations. The env var hook lets us verify the bash-side propagation without Chrome.

Real-world detection is validated by users on real 2FA-protected sites (manual testing). The heuristic is best-effort — push-notification flows (no input field, "waiting" UI) and unusual text patterns may slip through.

---

## Out of scope

- **Real-browser e2e test of the heuristic** — would need a fixture site with a 2FA challenge page. Add to `tests/fixtures/dummy-server` if/when that infrastructure expands.
- **TOTP support** — Phase 5 part 4 — agent generates the code itself via stored secret.
- **Push-notification 2FA detection** — different UI shape (no input). Out of scope.

---

## Tag + push

```
git tag v0.17.0-phase-05-part-3-iv-2fa-detection
git push -u origin feature/phase-05-part-3-iv-2fa-detection
git push origin v0.17.0-phase-05-part-3-iv-2fa-detection
gh pr create --title "feat(phase-5-part-3-iv): 2FA detection in login --auto → exit 25"
```
