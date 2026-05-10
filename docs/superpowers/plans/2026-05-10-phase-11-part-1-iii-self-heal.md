# Phase 11 part 1-iii — self-heal loop (CLOSES Phase 11 part 1)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans.

**Goal:** Close Phase 11 part 1 by wiring `memory_record_failure` (storage primitive shipped in 1-i) into `browser-do --intent`'s post-dispatch failure path. End-to-end self-heal: cached selector breaks → fail_count increments → threshold-disables → next call skips disabled (already implemented in `memory_lookup`) → agent re-resolves → `record` overwrites disabled entry with `fail_count:0` + `disabled:false`.

**Branch:** `phase-11-part-1-iii-self-heal`
**Tag:** `v0.49.0-phase-11-part-1-iii-self-heal`

---

## Locked decisions (from HANDOFF "Open shape questions")

- **D1 — Exit-code trigger whitelist:** `memory_record_failure` is invoked only when the dispatched verb exits with `EXIT_EMPTY_RESULT (11)` or `EXIT_ASSERTION_FAILED (13)`. These are the canonical "selector miss" / "expected element absent" signals. **Network errors (30), tool crashes (42), timeouts (43)** are environmental — they shouldn't poison the cache. Same for any other code (incl. 0 success, 2 usage, 22 session expired).
- **D2 — Re-record heals disabled:** `memory_record` on the existing-intent upsert path resets `fail_count:0` AND `disabled:false`. This is the missing piece — without it, a successfully re-resolved selector can't overwrite the prior disabled state. **Tiny memory.sh tweak** (3 lines in the existing-intent jq block).
- **D3 — Disabled-aware lookup:** `memory_lookup` already filters `disabled:true` interactions (lib-side filter shipped in 1-i). No change. **Disabled entries are indistinguishable from "intent never seen"** at the verb layer — both result in `cache_miss reason:intent_not_cached`. This is intentional; the agent's response is identical (snapshot+pick+record) so distinguishing the two would be informational-only and add coupling for no behavior change.
- **D4 — Self-heal trigger fires only on cache-hit dispatch failure:** Cache-miss paths never call `memory_record_failure` (there's nothing to mark as failed). Only the verified hit-then-dispatch-failed case triggers the counter. Avoids spurious failures from miss-and-no-dispatch flows.
- **D5 — Best-effort failure recording:** Mirrors 1-ii's best-effort write-back. If `memory_record_failure` itself fails (disk full, perms), we `warn:` to stderr but don't change the dispatched verb's exit code. Cache-state freshness < action correctness.

## API additions

### `scripts/lib/memory.sh` — tweak `memory_record`

Existing-intent upsert branch gains 2 jq operations:

```jq
.fail_count = 0
| .disabled = false
```

So a successful `memory_record` on a previously-disabled entry resets both, restoring the entry to "fresh" state. New-intent insert path already initializes both correctly; only the upsert path needs the tweak.

### `scripts/browser-do.sh` — post-dispatch failure trigger

After `bash "${verb_script}" --selector "${selector}" "${extra_args[@]+"${extra_args[@]}"}"`, conditionally invoke `memory_record_failure`:

```bash
if [ "${dispatch_rc}" -eq 0 ]; then
  # ... existing success path: bump success_count, hit_count
elif [ "${dispatch_rc}" -eq "${EXIT_EMPTY_RESULT}" ] || [ "${dispatch_rc}" -eq "${EXIT_ASSERTION_FAILED}" ]; then
  if ! memory_record_failure "${site}" "${archetype_id}" "${arg_intent}" 2>/dev/null; then
    warn "browser-do: cache fail_count update failed (best-effort; action exit unchanged)"
  fi
fi
```

The summary line gains a `self_heal_triggered` boolean (true iff `memory_record_failure` was called). Useful for tests + agent observability.

## Test cases (RED → GREEN)

`tests/browser-do.bats` (gains 4 cases, total 19):

1. Dispatched verb exits **11** (EMPTY_RESULT) → `memory_record_failure` invoked → `fail_count == 1`.
2. Dispatched verb exits **13** (ASSERTION_FAILED) → `memory_record_failure` invoked.
3. Dispatched verb exits **30** (NETWORK_ERROR) → `memory_record_failure` NOT invoked → `fail_count == 0`.
4. After 4 consecutive failures + next `--intent` → `cache_miss` (because `memory_lookup` skips `disabled:true`) → then `record` resets disabled+fail_count to 0+false.

`tests/memory.bats` (gains 1 case, total 13):

5. `memory_record` on existing **disabled** intent resets `fail_count:0` + `disabled:false` + selector overwritten + `success_count++`. Tests the D2 contract directly at the lib layer.

**Fixture additions:** none (failure cases use the stub's "no fixture for argv-hash" path — exit 41 by default; tests need to control exit code via STUB_LOG_FILE indirection or new fixtures emitting specific exit codes). Need to investigate stub's exit-code knob.

## Implementation strategy for triggering specific exit codes in bats

The playwright-cli stub returns 0 on fixture match, 41 on no-match. To test exit codes 11 + 13 in cache-hit dispatch tests, options:

- **Option A:** Use a stub-`browser-click` (override the dispatched verb path with a mock that respects an env var like `MOCK_CLICK_EXIT=11`). Cleanest test isolation.
- **Option B:** Add fixture content shapes that downstream verb logic interprets as exit-11 / exit-13. Brittle — depends on click verb's interpretation.

**Going with Option A.** Add a tiny mock-click stub at `tests/stubs/mock-click.sh` that reads `MOCK_CLICK_EXIT=N` from env and exits N. Inject by symlinking or by setting `BROWSER_DO_DISPATCH_OVERRIDE` env var (read in browser-do.sh — overrides the verb-script path resolution). Smallest test-only seam.

Actually simpler — bats can write a tiny dispatch-override script in setup, and the browser-do.sh test reads it via env. No production change needed if we add a `BROWSER_DO_DISPATCH_OVERRIDE` env hook.

**Resolved approach:** Tests create a wrapper script that exits with whatever code the test wants (controlled by env), and pass `BROWSER_DO_DISPATCH_OVERRIDE=/path/to/wrapper` to browser-do.sh. browser-do.sh respects this env var (test-only seam, documented in source) and dispatches to it instead of `scripts/browser-${verb}.sh`. Production callers don't set this env var; it's invisible.

## Sub-scope (what 1-iii does NOT do)

- **No reason:disabled distinction in cache_miss event.** D3 — disabled is indistinguishable from "never cached" at the verb layer. Agent response is identical.
- **No `--no-self-heal` opt-out flag.** Self-heal is the design intent; opt-out adds complexity without surfacing demand.
- **No backoff between retries.** Each invocation is independent; the failure counter accumulates across calls. If a selector breaks transiently and recovers, fail_count rolls up over invocations — no per-invocation retry loop.
- **No `self_heal_history[]` population.** The schema field exists (1-i) but stays empty in v1. Future audit-trail use case.
- **No automated re-resolution.** On disabled-skip + cache_miss, the agent does the snapshot+pick+record cycle; the verb does NOT call LLM internally (skill stays model-agnostic; same as 1-ii Q1).
- **No impact on cache-miss paths.** `memory_record_failure` only fires after a confirmed cache-hit-then-dispatch-failed sequence.

## Acceptance

- `tests/browser-do.bats` 19 cases all green on macos-latest + ubuntu-latest.
- `tests/memory.bats` 13 cases all green.
- `bash tests/lint.sh` exit 0.
- Self-heal end-to-end: 4 dispatch failures → next lookup miss (transparently disabled) → record after agent re-resolves → fail_count back to 0 + disabled false. Verified by test 4.
- CHANGELOG `[Unreleased]` `[feat]` block + plan-doc reference.
- HANDOFF refresh: closes Phase 11 part 1 (3/3 sub-parts shipped).

## Notes for follow-ups

- **Phase 11 part 2** unblocked. Per design doc: 11-2-i (manual `--pattern` flag on `browser-do`) + 11-2-ii (auto-cluster URL pattern detection).
- **Recipe `cache-write-security.md`** — codify whitelist + canary + best-effort + self-heal-on-{11,13} into a recipe doc post-Phase-11-part-1. **Now unblocked since part 1 closes here.**
- **Selector-mode plumbing for fill/hover/press/select** — independent prerequisite for expanding `--verb` whitelist beyond `[click]`. Adapter ABI work.
- **`self_heal_history[]` audit trail** — schema field exists; could log `{disabled_at, re_resolved_at, prev_selector}` entries on each heal. Useful for "why did this selector change?" debugging. Defer until demand surfaces.
