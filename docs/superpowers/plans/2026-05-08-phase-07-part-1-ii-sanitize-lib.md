# Phase 7 part 1-ii — `lib/sanitize.sh` (jq-function library; unit-tested in isolation)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans.

**Goal:** Pure jq-function library for redacting sensitive fields from HAR + console capture artifacts. **No verb integration** — TDD the redaction rules in isolation so they're rock-solid before composing with capture write paths in 7-1-iii.

**Branch:** `feature/phase-07-part-1-ii-sanitize-lib`
**Tag:** `v0.34.0-phase-07-part-1-ii-sanitize-lib`

---

## Surface

```bash
# Library (sourced):
source scripts/lib/sanitize.sh

# Function calls take JSON on stdin, emit JSON on stdout:
sanitize_har    < har_input.json     > har_redacted.json
sanitize_console < console_input.json > console_redacted.json
```

Per parent spec §8.3 (verbatim jq filter shape):

```jq
# HAR redaction:
.log.entries[].request.headers |=
  map(if (.name | ascii_downcase) | IN("authorization","cookie","x-api-key","x-auth-token")
      then .value = "***REDACTED***" else . end)
| .log.entries[].response.headers |=
  map(if (.name | ascii_downcase) | IN("set-cookie","authorization")
      then .value = "***REDACTED***" else . end)
| .log.entries[].request.url |=
  if test("(api_key|token|access_token|client_secret)=")
  then sub("(?<k>(api_key|token|access_token|client_secret))=[^&]*"; "\(.k)=***")
  else . end
```

**Sentinel string: `***REDACTED***`** (matches parent spec §8.3 exactly). URL param replacement: `<key>=***` (preserves the param name; replaces only the value).

Console redaction: any console message text containing `password: <value>`, `secret: <value>`, `token: <value>` (case-insensitive key) → `<key>: ***`. Field-value mask, not whole-message redact.

---

## What this sub-part does NOT ship

Per 7-ii sub-scope discipline:

- **No verb integration.** `inspect --capture-console --capture-network --capture` wire-up is 7-1-iii.
- **No `--unsanitized` flag.** The typed-phrase opt-out lands in 7-1-iv.
- **No `meta.sanitized:false` audit field.** Also 7-1-iv.
- **No retention/prune.** That's 7-1-v.
- **No fixture HAR generation from real Chrome.** Bats fixtures are synthetic JSON files we hand-author for predictable tests.

Sanitize is a pure read-write transformation. Verbs sandwich it between capture write and final disk persist; the lib doesn't know about verbs or capture paths.

---

## File structure

### New
- `scripts/lib/sanitize.sh` — two functions (`sanitize_har`, `sanitize_console`); pure jq dispatch via stdin → stdout.
- `tests/sanitize.bats` — ~10 unit cases.
- `tests/fixtures/sanitize/har-with-auth.json` — synthetic HAR with Authorization + Set-Cookie + api_key URL param.
- `tests/fixtures/sanitize/har-clean.json` — HAR with no sensitive headers (negative case).
- `tests/fixtures/sanitize/har-multi-params.json` — URL with multiple sensitive params (api_key + token + access_token).
- `tests/fixtures/sanitize/console-with-secrets.json` — console messages containing password/secret/token values.
- `tests/fixtures/sanitize/console-clean.json` — console messages without sensitive values.
- `docs/superpowers/plans/2026-05-08-phase-07-part-1-ii-sanitize-lib.md` — this plan.

### Modified
- `CHANGELOG.md` — `[Unreleased]` Phase 7 part 1-ii entry.

### NOT modified
- No verb scripts.
- No bridge.
- No router.
- No adapter capabilities.
- Drift sync (`scripts/regenerate-docs.sh all`) not needed — capabilities unchanged.

---

## Test cases (~10)

### `sanitize_har`
1. Authorization header → `***REDACTED***` (case-insensitive name match: `Authorization`, `authorization`, `AUTHORIZATION` all redact).
2. Cookie header → `***REDACTED***`.
3. Set-Cookie response header → `***REDACTED***`.
4. X-API-Key header → `***REDACTED***`.
5. URL with `?api_key=XYZ` → `?api_key=***` (param name preserved, value masked).
6. URL with multiple sensitive params (`?api_key=A&token=B&other=C`) → `?api_key=***&token=***&other=C` (preserves non-sensitive params).
7. **Idempotent** — running twice gives the same result as running once.
8. Negative — HAR with no sensitive headers/params → output identical to input.

### `sanitize_console`
9. `"console.log: password: hunter2"` → `"console.log: password: ***"` (case-insensitive key; value masked through next non-word boundary).
10. Console array with mix of sensitive + non-sensitive messages → only sensitive ones masked; rest unchanged.

---

## jq compatibility caveat

Parent spec §8.3 shows jq with **named groups** in regex (`(?<k>...)`). Need to verify CI's pinned jq supports this. Cross-platform check during GREEN: macOS Homebrew jq (recent) + Ubuntu apt-get jq (pinned by CI runner) both must accept the syntax. If named groups fail on either runner, fallback: split into two-step `match` + `sub` using captured indices instead of named groups. Document the fallback in lib comment.

---

## Tag + push

```bash
git tag v0.34.0-phase-07-part-1-ii-sanitize-lib
git push -u origin feature/phase-07-part-1-ii-sanitize-lib
git push origin v0.34.0-phase-07-part-1-ii-sanitize-lib
gh pr create --title "feat(phase-7-part-1-ii): sanitize lib (jq-function library; unit-tested)"
```
