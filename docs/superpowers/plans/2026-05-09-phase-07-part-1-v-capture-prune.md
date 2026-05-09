# Phase 7 part 1-v — `capture_prune` retention/prune (Phase 7 closure)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans.

**Goal:** Auto-prune stale captures by count + age thresholds. Last sub-part of Phase 7. Closes the capture pipeline.

**Branch:** `feature/phase-07-part-1-v-capture-prune`
**Tag:** `v0.37.0-phase-07-part-1-v-capture-prune`

---

## Surface

```bash
# Auto-prune triggered at the end of capture_finish:
bash scripts/browser-snapshot.sh --capture
# → captures/NNN/ written
# → _index.json updated
# → if count > retention_count OR oldest_age > retention_days:
#     oldest non-baseline non-in-flight captures pruned
# → emit one warn line per pruned capture (if any pruned)

# Idempotent — re-running on already-pruned state is no-op.
```

Per parent spec §4.5:

```
capture_prune (idempotent):
  while count > 500 OR (oldest.age_days > 14 AND oldest is not a baseline AND not in flight):
    rm -rf captures/$oldest_id
  emit one warn line per pruned capture
```

Default thresholds (per spec §4.5) in `~/.browser-skill/config.json`:

```json
{
  "schema_version": 1,
  "retention_days": 14,
  "retention_count": 500,
  "warn_at_pct": 90
}
```

---

## API additions

### `lib/capture.sh::capture_prune`

```bash
# capture_prune
#   Reads ${CONFIG_FILE} for thresholds (defaults if missing/null).
#   Walks ${CAPTURES_DIR}/*/meta.json; computes age + count.
#   Splices oldest-first while EITHER threshold exceeded.
#   Skip rules: meta.is_baseline == true (Phase 8 forward-compat).
#               meta.status == "in_progress" (in-flight; never prune).
#   After prune: recomputes _index.json (count, total_bytes, latest).
#   Emits warn lines per pruned capture; non-fatal.
#   Idempotent — re-running on stable state is no-op.
```

### `lib/capture.sh::capture_finish` extension

Calls `capture_prune` at the end (after meta.json finalize + _index.json update). Auto-prune on every successful capture.

### `lib/common.sh::init_paths` extension

Exports `CONFIG_FILE="${BROWSER_SKILL_HOME}/config.json"` alongside existing path exports.

### `install.sh::create_state_dir` extension

Writes default `config.json` (mode 0600) on fresh install if absent. Idempotent — never overwrites an existing user-edited config.

---

## Cross-platform age calculation

`started_at` is ISO 8601 UTC (e.g. `"2026-05-09T10:15:00Z"`). Need to convert to epoch seconds for age math. Cross-platform pattern:

```bash
_capture_iso_to_epoch() {
  local iso="$1"
  # GNU date first (Linux + coreutils-installed-Mac); BSD date fallback.
  date -d "${iso}" +%s 2>/dev/null \
    || date -j -f '%Y-%m-%dT%H:%M:%SZ' "${iso}" +%s 2>/dev/null \
    || printf '0'
}
```

Same pattern as `stat -c '%a' || stat -f '%Lp'` already in capture.sh:31-37 (mode read).

---

## What this sub-part does NOT ship

- **No `browser-clean.sh` verb.** Parent spec §3 verb table #29. Auto-prune covers the common case; manual force-prune as a follow-up if user demand surfaces.
- **No `warn_at_pct` warning** when capture count nears threshold. Field is read+written for forward-compat but no warn-on-90% logic in 1-v. Lands as a follow-up.
- **No interactive confirmation** before prune. Auto-prune is silent (just emits warn line per pruned capture). User can disable via `retention_count: 999999` if they want never-prune.
- **No prune by total_bytes.** Threshold is count + age; bytes is informational only.

---

## File structure

### New
- `docs/superpowers/plans/2026-05-09-phase-07-part-1-v-capture-prune.md` — this plan.

### Modified
- `scripts/lib/capture.sh` — add `capture_prune` function + `_capture_iso_to_epoch` helper; `capture_finish` calls `capture_prune` at end.
- `scripts/lib/common.sh::init_paths` — exports `CONFIG_FILE`.
- `install.sh::create_state_dir` — seeds default `config.json` (mode 0600) if absent.
- `tests/capture.bats` (+~8 cases) — prune-by-count, prune-by-age, no-op-under-threshold, idempotent, baseline-skip, in-flight-skip, _index.json correctness post-prune, missing-config defaults.
- `CHANGELOG.md` — `[Unreleased]` Phase 7 part 1-v entry; **Phase 7 COMPLETE** announcement.

### NOT modified
- No verb script changes (auto-prune is library-internal).
- No router/adapter/bridge changes.
- No drift sync needed.

---

## Test plan (~8 cases in `tests/capture.bats`)

1. **`capture_prune` prunes by count** — set `retention_count: 2`; create 3 captures; prune; oldest gone; count=2.
2. **`capture_prune` prunes by age** — set `retention_days: 7`; hand-author meta with `started_at` 30 days ago; prune; pruned.
3. **No-op when under threshold** — count=2 + retention_count=10 + age=1d + retention_days=14 → unchanged.
4. **Idempotent** — run prune; run prune again; second call doesn't change anything.
5. **Baseline skip** — meta.is_baseline:true on the oldest capture; even when count > threshold, baseline preserved (oldest non-baseline pruned instead).
6. **In-flight skip** — meta.status:"in_progress" on the oldest; in-flight preserved (never prune live captures).
7. **`_index.json` correctness post-prune** — count + total_bytes + latest reflect post-prune state; next_id NOT decremented (monotonic).
8. **Missing config → defaults** — config.json absent; `capture_prune` uses retention_count=500, retention_days=14; effectively no-op for small test fixtures.

---

## Tag + push

```bash
git tag v0.37.0-phase-07-part-1-v-capture-prune
git push -u origin feature/phase-07-part-1-v-capture-prune
git push origin v0.37.0-phase-07-part-1-v-capture-prune
gh pr create --title "feat(phase-7-part-1-v): capture_prune retention/prune (Phase 7 COMPLETE)"
```

**Phase 7 closure announcement** in PR body — 5/5 sub-parts shipped; capture pipeline complete.
