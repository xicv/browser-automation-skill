# Phase 5 part 3-ii — Transparent verb-retry on EXIT_SESSION_EXPIRED

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans.

**Goal:** Make session expiry invisible to the agent. When a verb's adapter call exits with `EXIT_SESSION_EXPIRED` (22) AND a credential exists for the current site with `auto_relogin: true`, the verb script silently re-logins via `bash scripts/browser-login.sh --auto` and retries the verb exactly ONCE. Per parent spec §4.4: "every verb call → silent re-login → retry, exactly one attempt".

**Sub-scope (3-ii minimal — helper + one wiring):**
- Add `invoke_with_retry VERB ARGS...` helper to `scripts/lib/verb_helpers.sh`.
- Wire into ONE exemplar verb: `scripts/browser-snapshot.sh`.
- Remaining verbs (open / click / fill / inspect / audit / extract / login) deferred to follow-up sub-PR (3-ii-ii or one PR per verb pair). Pattern is replicated mechanically.

**Why split:** the helper + tests + design docs justify one cohesive PR. Wiring into 7+ other verbs is mechanical churn — better as a separate review.

**Branch:** `feature/phase-05-part-3-ii-verb-retry`
**Tag:** `v0.15.0-phase-05-part-3-ii-verb-retry-helper`.

---

## File Structure

### New
| Path | Purpose |
|---|---|
| `tests/verb-retry.bats` | Unit-tests for `invoke_with_retry` via bash function mocking + counter file |
| `docs/superpowers/plans/2026-05-05-phase-05-part-3-ii-verb-retry.md` | This plan |

### Modified
| Path | Change |
|---|---|
| `scripts/lib/verb_helpers.sh` | +invoke_with_retry / _can_auto_relogin / _silent_relogin / _resolve_relogin_cred_name (+~70 LOC) |
| `scripts/browser-snapshot.sh` | swap `set +e; out=$(tool_snapshot ...); rc=$?` block for `invoke_with_retry snapshot ...` |
| `CHANGELOG.md` | Phase 5 part 3-ii subsection |

### Untouched
- All other verb scripts (deferred to follow-up).
- Adapters (no change — they already return 22 when they detect expiry; that's the wire signal).
- `resolve_session_storage_state` (still dies on pre-adapter session-not-found; the runtime retry helper handles in-flight expiry detected by adapters).

---

## Helper API

```bash
# invoke_with_retry VERB ARGS... — runs tool_${VERB} ARGS, returning its
# stdout + exit code. On EXIT_SESSION_EXPIRED (22), if a credential with
# auto_relogin: true exists for the current --site / --as, runs login --auto
# silently then retries the verb ONCE. Caller sees a single stdout + final rc.
#
# Returns: tool's stdout via printf; exit code = tool's exit code (post-retry
# if applicable).
invoke_with_retry() {
  local verb="$1"; shift
  local out rc
  set +e
  out="$(tool_"${verb}" "$@")"; rc=$?
  set -e

  if [ "${rc}" -ne "${EXIT_SESSION_EXPIRED}" ]; then
    printf '%s' "${out}"; return "${rc}"
  fi
  if ! _can_auto_relogin; then
    printf '%s' "${out}"; return "${rc}"
  fi
  if ! _silent_relogin >/dev/null 2>&1; then
    printf '%s' "${out}"; return "${rc}"
  fi
  resolve_session_storage_state
  set +e
  out="$(tool_"${verb}" "$@")"; rc=$?
  set -e
  printf '%s' "${out}"; return "${rc}"
}
```

### `_can_auto_relogin`

Returns 0 iff:
- `ARG_SITE` set (verb invoked with `--site NAME`)
- A credential exists for the resolved name (`ARG_AS` OR site's `default_session`)
- That credential's metadata has `auto_relogin: true` (default per creds-add)

### `_silent_relogin`

Runs `bash <verb_helpers_dir>/../browser-login.sh --auto --site ARG_SITE --as <cred_name>`. Stdout/stderr suppressed. Returns its exit code.

### `_resolve_relogin_cred_name`

Mirrors session-resolution: prefer `ARG_AS`; fall back to `site.default_session`; return non-zero if neither.

---

## Test approach

`tests/verb-retry.bats` — unit-test the helper via bash function mocking. No real adapter or login involved.

```bash
@test "invoke_with_retry: tool returning 0 → no retry, output unchanged"
@test "invoke_with_retry: tool returning rc != 22 → no retry, propagated"
@test "invoke_with_retry: tool returning 22 + no auto-relogin context → no retry, propagated"
@test "invoke_with_retry: tool returning 22 + auto-relogin context + relogin OK → retry once → final rc/output from retry"
@test "invoke_with_retry: tool returning 22 + relogin fails → no retry, original error propagated"
@test "invoke_with_retry: tool returning 22 twice (retry also fails 22) → final rc=22 (no double-retry)"
```

Mocking pattern (per-test):
```bash
COUNTER="$(mktemp)"; echo 0 > "${COUNTER}"
tool_test() {
  local n; n="$(cat "${COUNTER}")"; echo $((n+1)) > "${COUNTER}"
  if [ "${n}" = "0" ]; then printf 'first'; return 22; fi
  printf 'second'; return 0
}
_can_auto_relogin() { return 0; }
_silent_relogin() { return 0; }
resolve_session_storage_state() { return 0; }  # no-op for tests

source "${LIB_DIR}/verb_helpers.sh"
out="$(invoke_with_retry test arg1)"; rc=$?
```

For the "snapshot wired" assertion: extend `tests/browser-snapshot.bats` with a case that exercises the retry path against a custom adapter stub.

Actually — simpler: skip per-verb integration in 3-ii. Helper unit tests + a follow-up "wire in remaining verbs + integration tests" sub-part is cleaner.

---

## Risks + mitigations

| Risk | Mitigation |
|---|---|
| Infinite-retry loop (relogin returns 22 too) | Helper retries EXACTLY ONCE; second 22 propagates as final rc |
| Login --auto blocks on stdin (interactive prompt) | login --auto reads from cred backend, not stdin (AP-7); no blocking |
| Verb's `tool_VERB` writes intermediate output to stdout BEFORE returning 22 | Captured to `out`; on retry, tool's second output replaces the first. Caller sees only final retry's output (intentional — first attempt's session-expired error is internal noise) |
| `set +e/-e` toggling masks unrelated failures | Localized to two specific lines; wrapping is the established pattern (see browser-click.sh:76-79) |

---

## Tag + push

```
git tag v0.15.0-phase-05-part-3-ii-verb-retry-helper
git push -u origin feature/phase-05-part-3-ii-verb-retry
git push origin v0.15.0-phase-05-part-3-ii-verb-retry-helper
gh pr create --title "feat(phase-5-part-3-ii): invoke_with_retry helper + wire into snapshot"
```
