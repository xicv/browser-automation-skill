# Phase 9 part 1-v — `history` + `baseline` (CLOSES Phase 9)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans.

**Goal:** Fifth sub-part of Phase 9. Read-side composition over Phase 7's capture pipeline + named-blessed-capture management. **Closes Phase 9.** Folds in HANDOFF's `browser-clean.sh` follow-up (carry-over since Phase 7) as `history clear`.

**Branch:** `phase-09-part-1-v-history-and-baseline`
**Tag:** `v0.46.0-phase-09-part-1-v-history-and-baseline`

---

## Locked decisions

### H1: Single-verb-with-sub-modes per command

`history list / show / diff / clear` — single verb (`scripts/browser-history.sh`) with sub-modes. Same for `baseline save / list / remove` (`scripts/browser-baseline.sh`). Mirrors `flow run` / `flow record` shape; cleaner mental model than 7 separate verbs.

### H2: `history diff <id1> <id2>` reuses `flow_diff_steps` from 9-1-iv

Composition over re-implementation. `flow_diff_steps` already strips `duration_ms` (timing not semantic); same primitive applies for capture-vs-capture step diff. Per workflow pattern "Composition-over-ABI-extension" (HANDOFF entry).

Rejected: re-implement file-level diff — the per-step diff via `flow_diff_steps` IS the meaningful diff (steps.jsonl is the per-aspect file).

### H3: `history clear` flag set = `--keep N` + `--days D` + `--not-baseline`; all composable

Composes with Phase 7's `capture_prune` (auto-prune already honors `is_baseline:true` skip-rule). Folds in HANDOFF's `browser-clean.sh` follow-up.

```
history clear                        # use config defaults (Phase 7's retention_days/count)
history clear --keep 100             # keep newest 100 captures only
history clear --days 7               # purge captures older than 7 days
history clear --not-baseline         # purge all except baselines (no count/age limits)
history clear --keep 100 --days 7    # both: must satisfy BOTH (keep ≤100 newest AND age ≤7d)
```

`--not-baseline` is implicit-default for all clear ops (Phase 7's prune already skips baselines per `is_baseline:true`).

### B1: `baseline save <id> --as NAME` writes to `${BROWSER_SKILL_HOME}/baselines.json`

Schema (frozen at 9-1-v ship; v1):
```json
{
  "schema_version": 1,
  "baselines": [
    {
      "name": "after-redesign",
      "capture_id": "042",
      "saved_at": "2026-05-10T12:34:56Z",
      "summary": {"verb": "flow", "flow_name": "create-user", "step_count": 5}
    }
  ]
}
```

`baseline save` ALSO sets `meta.is_baseline:true` on `${CAPTURES_DIR}/<id>/meta.json` so Phase 7's `capture_prune` honors it (the prune skip-rule already checks this field — landed in 7-1-v as forward-compat for Phase 9). **No new prune logic needed.**

`baseline remove <name>` clears `meta.is_baseline:true` AND splices the entry from `baselines.json`. **Does NOT delete the capture dir** — `history clear` is for that.

`baseline list` reads `baselines.json` + emits one summary line per baseline. Includes the original capture's summary fields (flow_name, step_count) for easy identification.

### O1: Mode 0600 on `baselines.json`; lazy-creation on first `baseline save`

Same as Phase 7's `_index.json` + Phase 11's planned `memory/_index.json`. `[PERSONAL]` per parent spec §3.4 — concrete user data; gitignored.

## API additions

### `scripts/browser-history.sh` (new entry point; sub-modes)

```bash
bash scripts/browser-history.sh list [--limit N] [--since DATE]
bash scripts/browser-history.sh show <capture-id>
bash scripts/browser-history.sh diff <id1> <id2>
bash scripts/browser-history.sh clear [--keep N] [--days D] [--not-baseline]
```

### `scripts/browser-baseline.sh` (new entry point; sub-modes)

```bash
bash scripts/browser-baseline.sh save <capture-id> --as NAME
bash scripts/browser-baseline.sh list
bash scripts/browser-baseline.sh remove <NAME>
```

### `scripts/lib/baseline.sh` (new lib helper)

Three-fn API:
```bash
baseline_save <capture-id> <name>     # set is_baseline:true; append to baselines.json
baseline_list                          # emit one JSON line per baseline entry
baseline_remove <name>                 # clear is_baseline; splice from baselines.json
```

### `scripts/lib/history.sh` (new lib helper)

Three-fn API:
```bash
history_list <limit?> <since?>        # walk captures/*/meta.json; emit per-capture summary
history_show <capture-id>             # emit meta.json + steps.jsonl content
history_diff <id1> <id2>              # reuse flow_diff_steps for per-step diff
```

`history_clear` deferred to inline browser-history.sh (it composes `capture_prune` directly).

## Test cases (RED → GREEN)

`tests/history.bats` (new file, ~8 cases):

1. `history list` empty → exit 0; emits zero rows.
2. `history list` with N captures → emits N summary rows + summary line.
3. `history list --limit 2` → emits only newest 2.
4. `history show <id>` → emits meta.json + steps.jsonl pretty-printed.
5. `history show <nonexistent>` → exit 2 USAGE_ERROR.
6. `history diff <id1> <id2>` of two identical-step captures → all `replay_diff` events have `match:true`.
7. `history clear --keep 1` keeps only the newest capture (Phase 7 prune-mechanics composition).
8. `history clear --not-baseline` purges all except baselines (verifies Phase 7's prune skip-rule honors flag).

`tests/baseline.bats` (new file, ~6 cases):

1. `baseline save <id> --as NAME` → writes baselines.json mode 0600 + sets is_baseline:true on meta.json.
2. `baseline save <id>` missing `--as` → EXIT_USAGE_ERROR.
3. `baseline save <nonexistent>` → EXIT_USAGE_ERROR.
4. `baseline list` empty → exit 0; zero rows.
5. `baseline list` after 2 saves → 2 entries with name + capture_id + saved_at.
6. `baseline remove <NAME>` → clears is_baseline + splices baselines.json; capture dir UNTOUCHED.

## Sub-scope (what 9-1-v does NOT do)

- **No `report --since "yesterday" --format markdown`** (parent spec verb 35) — defer to Phase 10+.
- **No `history diff` for non-flow captures** — only flow/replay captures have steps.jsonl. Non-flow captures: error with helpful message.
- **No baseline-rename** — `baseline remove + baseline save` round-trip is the workaround.
- **No baseline-with-tags / baseline-with-notes** — v1 schema is name + capture_id + saved_at + summary only.
- **No history pagination beyond `--limit N` + `--since DATE`** — sufficient for v1.

## Acceptance

- `tests/history.bats` 8+ cases all green.
- `tests/baseline.bats` 6+ cases all green.
- `bash tests/lint.sh` exit 0 (all three tiers).
- `baselines.json` mode 0600; gitignored (verify via existing .gitignore wildcard or new entry).
- `history clear` composes Phase 7's `capture_prune` correctly (no duplicate prune logic).
- `history diff` reuses `flow_diff_steps` from 9-1-iv (composition pattern).
- CHANGELOG `[Unreleased]` `[feat]` tag.

## Phase 9 closure note

With 9-1-v merged, **all 5 sub-parts of Phase 9 are shipped.** The flow runner phase delivers:
1. Declarative composition (9-1-i `flow run`)
2. Templating + assertion (9-1-ii `${refs.NAME}` + `assert`)
3. Recording (9-1-iii `flow record` + password canary)
4. Replay + structured diff (9-1-iv)
5. History + baseline management (this PR)

Next phases per sequencing:
- Phase 10 — schema migration tooling
- Phase 11 — memory (per-archetype selector/action cache; design doc shipped, implementation queued AFTER Phase 9)

Recipe candidate post-Phase-9: `references/recipes/flow-record-secrets.md` — already documented in Phase 9-1-iii closure note. Tiny pure-docs PR; not blocking.
