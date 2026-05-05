# Phase 5 part 4-ii — TOTP code generation + secret persistence

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans.

**Goal:** Generate RFC 6238 TOTP codes from stored credentials. Plumb TOTP shared secret persistence through the existing backend dispatcher. New `creds totp` verb produces a current code; agent reads it then types into the browser via `fill`.

**Branch:** `feature/phase-05-part-4-ii-totp-codegen`
**Tag:** `v0.19.0-phase-05-part-4-ii-totp-codegen`.

---

## Design

### Pure-node TOTP generator

`scripts/lib/node/totp.mjs` (~50 LOC, no external deps). Reads base32 secret from stdin; emits 6-digit code on stdout. Uses node's `crypto.createHmac` (HMAC-SHA1 by default — what virtually all TOTP issuers use).

RFC 6238 algorithm:
1. Counter = floor(unix_timestamp_seconds / 30)
2. HMAC = createHmac(SHA1, secret_bytes).update(counter_be64)
3. Offset = HMAC[last byte] & 0x0f
4. Truncated = (HMAC[offset] & 0x7f) << 24 | HMAC[offset+1] << 16 | HMAC[offset+2] << 8 | HMAC[offset+3]
5. Code = (truncated % 10^digits) zero-padded

Test hooks: `TOTP_TIME_T` env var overrides "now" so bats can verify against the RFC 6238 §A test vectors (T=59, 1111111109, 1111111111, 1234567890, 2000000000).

### TOTP secret backend slot

TOTP secret stored in the SAME backend as the password but at a sibling slot:

| Cred name | Password slot | TOTP slot |
|---|---|---|
| `prod--admin` | `prod--admin` | `prod--admin__totp` |

Why `__totp` (double underscore)? `assert_safe_name`'s regex `^[A-Za-z0-9_-]+$` allows underscores but rejects `:`, `.`, `/`, etc. The backends validate every name they receive. Using a regex-allowed suffix means backend code paths don't need a "skip validation" mode.

Edge: a user-facing cred named `<X>__totp` would alias `<X>`'s TOTP slot. `creds-add` rejects that case.

### Stdin mux for password + TOTP secret

`creds-add --totp-secret-stdin` reads `password\0totp_secret` (NUL-separated). Bash `$(cat)` strips embedded NULs ("warning: ignored null byte in input"), so use `IFS= read -r -d ''` which reads up to a NUL delimiter byte-faithfully. Two reads: first for password (NUL-terminated), second for TOTP secret (EOF-terminated; `read` returns non-zero but populates the variable).

### `creds-totp` verb

Reads cred metadata, validates `totp_enabled: true`, pipes the TOTP secret to `totp.mjs`, emits the code on stdout. Privacy canary tested: secret never appears in stdout.

---

## File Structure

### New
- `scripts/lib/node/totp.mjs` — pure-node TOTP code generator (RFC 6238 SHA1).
- `scripts/browser-creds-totp.sh` — `creds-totp --as NAME` verb.
- `tests/totp-codegen.bats` — RFC 6238 §A test vectors + edge cases.
- `tests/creds-totp.bats` — end-to-end coverage of `creds-add --totp-secret-stdin` + `creds-totp` against keychain stub.
- `docs/superpowers/plans/2026-05-05-phase-05-part-4-ii-totp-codegen.md` — this plan.

### Modified
- `scripts/lib/credential.sh` — new `credential_set_totp_secret NAME` + `credential_get_totp_secret NAME` + internal helper `_credential_dispatch_backend_internal`.
- `scripts/browser-creds-add.sh` — `--totp-secret-stdin` flag; NUL-mux read; TOTP slot write; collision guard for `__totp` suffix in user names.
- `CHANGELOG.md` — Phase 5 part 4-ii subsection.

### Untouched
- `scripts/lib/secret/*.sh` — backends unchanged. Slot names use the regex-allowed `__totp` suffix so backends validate normally.
- `scripts/browser-login.sh` — auto-replay is part 4-iii.
- `scripts/lib/node/playwright-driver.mjs` — driver-side TOTP integration is 4-iii.
- All adapters / router rules.

---

## Test approach

5 RFC 6238 §A test vectors directly exercise the pure-node generator:

| T (seconds) | Expected SHA1 8-digit |
|---|---|
| 59 | 94287082 |
| 1111111109 | 07081804 |
| 1111111111 | 14050471 |
| 1234567890 | 89005924 |
| 2000000000 | 69279037 |

Plus default-6-digit, empty-stdin rejection, invalid-base32 rejection.

End-to-end via keychain stub: `creds-add` with `--totp-secret-stdin` stores secret at `<name>__totp` slot; `creds-totp` reads it back; generated code is 6 digits; secret is never echoed in stdout. Privacy canary explicit.

---

## Out of scope (deferred to follow-ups)

- **Part 4-iii — auto-replay**: `login --auto` reads cred metadata.totp_enabled; on `detect2FA` match (part 3-iv), reads TOTP secret, generates code via `totp.mjs`, fills the OTP field, submits. Closes the loop end-to-end.
- **Part 4-iv — `creds rotate-totp` verb**: re-enroll TOTP when service forces a new secret. Mirrors `creds-migrate`'s typed-phrase confirmation pattern.
- **TTY-only gate on `creds-totp`**: codes are short-lived (30s) but shell history could capture. Could land as 4-ii cont. with `--allow-non-tty` flag for scripted use.

---

## Tag + push

```
git tag v0.19.0-phase-05-part-4-ii-totp-codegen
git push -u origin feature/phase-05-part-4-ii-totp-codegen
git push origin v0.19.0-phase-05-part-4-ii-totp-codegen
gh pr create --title "feat(phase-5-part-4-ii): TOTP code generation + secret persistence"
```
