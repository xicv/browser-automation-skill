# Phase 5 part 3-iii — Auth-flow declaration at `creds add` time

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans.

**Goal:** Persist a per-credential `auth_flow` declaration so that `login --auto` can refuse non-supported flows up front instead of mid-flight failing on selectors. Pre-3-iii: cred metadata's `auth_flow` was hardcoded to `single-step-username-password`. Now: user supplies it at `creds add` time via a new `--auth-flow STR` flag.

**Sub-scope (3-iii minimal — declaration; observation deferred):**
- `creds add --auth-flow STR` flag with validation against allowed set:
  `single-step-username-password | multi-step-username-password | username-only | custom`
- Default unchanged: `single-step-username-password` (backwards compatible).
- `login --auto` reads `cred_meta.auth_flow`; if not `single-step-username-password`, refuses with clear hint pointing at `--interactive`.

**Out of scope (deferred):**
- **Observation at add time** — open the site's login URL, scrape DOM, infer the flow shape. Substantial: needs a headless browser dispatch + heuristics. Could land as a 3-iii follow-up if user demand surfaces.
- **Multi-step / username-only / custom auto-relogin support** — needs different selector strategies in `playwright-driver.mjs::runAutoRelogin`. Substantial enough to warrant its own sub-part (call it 3-iii-ii: multi-step support).

**Branch:** `feature/phase-05-part-3-iii-auth-flow-detection`
**Tag:** `v0.16.0-phase-05-part-3-iii-auth-flow-declaration`.

---

## File Structure

### Modified

| Path | Change |
|---|---|
| `scripts/browser-creds-add.sh` | + `--auth-flow STR` flag; validation against 4-value enum; persist user value (not hardcoded) in metadata JSON |
| `scripts/browser-login.sh` | reads `cred_auth_flow` from cred metadata; refuses `--auto` for any value other than `single-step-username-password` |
| `tests/creds-add.bats` | +5 cases (default, 3 valid values, 1 invalid) |
| `tests/login.bats` | +4 cases (3 refuse-on-non-standard, 1 regression for single-step still works); `_seed_auto_cred` helper extended with optional 5th arg |
| `SKILL.md` | `creds add` row mentions `--auth-flow` |
| `CHANGELOG.md` | Phase 5 part 3-iii subsection |

### New
- `docs/superpowers/plans/2026-05-05-phase-05-part-3-iii-auth-flow-detection.md` — this plan.

### Untouched
- `scripts/lib/credential.sh` — schema unchanged (auth_flow field already existed; just made user-controllable).
- `scripts/lib/node/playwright-driver.mjs::runAutoRelogin` — selector strategies unchanged (multi-step support is 3-iii-ii follow-up).

---

## Allowed values

| Value | Meaning | login --auto support |
|---|---|---|
| `single-step-username-password` | One form: username + password + submit on same page. Default. | YES (default selectors) |
| `multi-step-username-password` | Username form → next page → password form → submit. (Google, Microsoft Online, Okta-fronted apps.) | NO — refused with `--interactive` hint |
| `username-only` | Passwordless / magic-link: username, then external authentication path. | NO — refused |
| `custom` | Explicit "we don't know; user must use --interactive". | NO — refused |

When `login --auto` lands multi-step support (3-iii-ii follow-up), it will gate selector dispatch by this field.

---

## Tag + push

```
git tag v0.16.0-phase-05-part-3-iii-auth-flow-declaration
git push -u origin feature/phase-05-part-3-iii-auth-flow-detection
git push origin v0.16.0-phase-05-part-3-iii-auth-flow-declaration
gh pr create --title "feat(phase-5-part-3-iii): --auth-flow declaration at creds-add + login --auto enforcement"
```
