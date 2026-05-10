# Phase 9 part 1-iv — `replay <id>` (re-execute capture's steps + structured diff)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans.

**Goal:** Fourth sub-part of Phase 9. New `scripts/browser-replay.sh` verb. Loads `captures/NNN/meta.json` + `steps.jsonl`; re-executes the steps via existing `flow_dispatch`; writes a NEW capture with `replay_of: NNN` + `replay_match: bool`; emits structured diff (per-step status diff + per-step output diff). New `--strict` flag flips partial→error mapping.

**Branch:** `phase-09-part-1-iv-replay`
**Tag:** `v0.45.0-phase-09-part-1-iv-replay`

---

## Locked decisions

### D1: Diff structure = **per-step status diff + per-step output diff** (not aggregate-only)

Per-step granularity is more useful for debugging (which step diverged, how) than aggregate-level. Aggregate counts derive from the per-step list.

Per-step diff event shape:
```json
{
  "event": "replay_diff",
  "step_index": 3,
  "verb": "fill",
  "status_match": false,           // old.status vs new.status
  "old_status": "ok",
  "new_status": "error",
  "output_match": true,             // jq-equal on summary line
  "output_diff": null              // populated only when output_match=false
}
```

Aggregate `replay_diff_summary`:
```json
{
  "event": "replay_diff_summary",
  "old_capture_id": "042",
  "new_capture_id": "043",
  "total_steps": 5,
  "matched_steps": 3,
  "diverged_steps": 2,
  "replay_match": false
}
```

### D2: Capture chain = forward-only (`captures/NNN.meta.replay_of: MMM`); no two-way back-reference

Reverse-lookup ("which capture replayed 042?") via grep is acceptable for v1. Two-way writes double meta.json updates per replay; cost > benefit.

**Rejected:** D2-b (back-reference) — needs to write `captures/MMM.meta.replayed_by: NNN`; doubles writes; complicates Phase 7's auto-prune (an orphaned `replayed_by` reference if the new capture is pruned).

### D3: `--strict` semantics = any divergence → exit non-zero (binary match/no-match)

Default behavior:
- All steps match → `status: ok`, `replay_match: true`, exit 0.
- Some matched, some diverged → `status: partial`, `replay_match: false`, exit 0 (partial is informational).
- All steps failed OR replay aborted mid-flow → `status: error`, exit non-zero.

`--strict`: ANY divergence (per-step status OR output mismatch) → exit non-zero (`EXIT_ASSERTION_FAILED` = 13). Same exit code as `assert` verb (composability — CI scripts can grep for 13).

### D4: Per-step output diff = jq-equal on summary line (no per-aspect file diff in v1)

Per-step `output_diff` populated only when `output_match=false`. For v1: a string showing both summaries (no structured field-by-field diff yet). Per-aspect file diff (console.json / network.har / screenshots) DEFERRED to a follow-up — needs decisions on byte-vs-structural diff per file type, and most flow runs won't have per-aspect files attached anyway (capture composition writes only meta.json + steps.jsonl unless `inspect` step explicitly captures).

**Rejected:** D4-a (full structural diff via jq-diff) — adds 100+ LOC of jq filtering; defers to user feedback on what diff fields actually matter.

### R1: Replay verb = `scripts/browser-replay.sh <capture-id>`, NOT a sub-mode of `browser-flow.sh`

Cleaner mental model: `flow run <file>` and `replay <capture-id>` are conceptually distinct (run a YAML vs re-run a capture). Per parent spec verbs 31 + 32 (separately listed). The lib helpers are shared (`flow_dispatch` from `lib/flow.sh`).

## API additions

### `scripts/browser-replay.sh` (new entry point)

```bash
bash scripts/browser-replay.sh <capture-id> [--strict] [--session NAME] [--dry-run]
```

- `<capture-id>` — required positional. Looks up `${CAPTURES_DIR}/<capture-id>/`. Numeric (3-digit zero-padded per Phase 7).
- `--strict` — flips partial→error mapping per D3. Exit 13 on any divergence.
- `--session NAME` — overrides the original capture's `meta.session`. Optional; replay against a fresh session.
- `--dry-run` — loads + prints planned step list; no execution.

Capture-load → step iteration → diff per step → emit diff events + summary.

### `scripts/lib/flow.sh::flow_diff_steps` (new helper)

```bash
flow_diff_steps <old-step-event-json> <new-step-event-json>
  # Compares two step-event JSON lines (from steps.jsonl).
  # Emits one `event:replay_diff` line on stdout.
  # Returns 0 if the two events match (status + output); 1 if diverged.
```

## Test cases (RED → GREEN)

`tests/replay.bats` (new file, ~10 cases):

1. `flow_diff_steps`: identical events → `output:replay_diff` with `status_match:true`, `output_match:true`; returns 0.
2. `flow_diff_steps`: status divergence (old:ok, new:error) → `status_match:false`; returns 1.
3. `flow_diff_steps`: output divergence (same status, different summary fields) → `output_match:false`; returns 1.
4. `browser-replay.sh`: missing `<capture-id>` → EXIT_USAGE_ERROR.
5. `browser-replay.sh`: nonexistent capture-id → EXIT_USAGE_ERROR with "no such capture".
6. `browser-replay.sh` end-to-end: replay a freshly-recorded simple-flow capture → new capture with `replay_of: NNN` + `replay_match: true`; status=ok; exit 0.
7. `browser-replay.sh`: replay where stub fixture flips a step's outcome → diff events emitted; `replay_match: false`; status=partial; exit 0.
8. `browser-replay.sh --strict`: divergent replay → exit 13 (`EXIT_ASSERTION_FAILED`).
9. `browser-replay.sh --dry-run`: prints planned step list; exit 0; no new capture written.
10. `browser-replay.sh`: new capture's meta.json carries `replay_of` + `replay_match` fields.

`tests/fixtures/replay/` — possibly a pre-baked capture dir to replay against (or generate at test setup time via flow run).

## Sub-scope (what 9-1-iv does NOT do)

- **No per-aspect file diff** (console.json, network.har, screenshots). Deferred to a follow-up after user feedback on diff field shape.
- **No two-way capture chain** (forward-only).
- **No replay-of-replay-of-replay tracking** (each replay's `replay_of` points back one level only; the chain isn't recursively walked).
- **No `--diff-format` flag** (v1 emits one fixed shape; future iteration if user demand surfaces).
- **No replay-of-non-flow captures** — replay only consumes captures with `verb: flow` (ones written by `flow run` or another replay). Non-flow captures (e.g. `verb: snapshot`, `verb: inspect`) don't have `steps.jsonl`; reject with helpful message.
- **No history / baseline** (9-1-v).

## Acceptance

- `tests/replay.bats` 10+ cases all green.
- `bash tests/lint.sh` exit 0 (all three tiers).
- `flow_diff_steps` testable in isolation; emits jq-friendly diff events.
- New `meta.json` fields (`replay_of`, `replay_match`) are non-breaking schema additions (no `schema_version` bump).
- `browser-replay.sh --strict` exit 13 path matches `browser-assert.sh`'s exit code (composability).
- CHANGELOG `[Unreleased]` `[feat]` tag.

## Notes for follow-ups

- **9-1-v: `history` + `baseline`** — read-side ops; closes Phase 9.
- **Per-aspect file diff** — post-9-1-iv follow-up; needs per-file-type decision (jq-diff for JSON/HAR; sha256 for screenshots).
- **`--diff-format` flag** — let users choose terse / verbose / per-step-only.
