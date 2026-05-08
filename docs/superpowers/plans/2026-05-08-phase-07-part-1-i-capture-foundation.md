# Phase 7 part 1-i — capture foundation (`lib/capture.sh` + `snapshot --capture`)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans.

**Goal:** First slice of Phase 7's capture pipeline — durable artifact directory + meta.json contract + atomic NNN allocation. Wired to `snapshot` verb only (structurally safe — no headers/cookies, no leak surface). Sanitization deferred to 7-iii where console.json + network.har enter.

**Branch:** `feature/phase-07-part-1-i-capture-foundation`
**Tag:** `v0.33.0-phase-07-part-1-i-capture-foundation`

---

## Surface

```bash
# New: --capture flag on snapshot
bash scripts/browser-snapshot.sh --capture
# → captures/001/meta.json + captures/001/snapshot.json on disk
# → summary line gets capture_id="001"

# Without --capture (unchanged):
bash scripts/browser-snapshot.sh
# → no capture dir; summary unchanged
```

`--capture` is **opt-in** for 7-i. The `--capture` default-on policy lands later (probably 7-iii or 7-v) once sanitization is in place — capturing without sanitizing is a leak surface, capturing without writing is the safe stance for 7-i's wire-up scope.

---

## `lib/capture.sh` API

Three functions — kept tiny so 7-iii / 7-iv / 7-v extend without rewrite:

```bash
# capture_init_dir
#   Idempotently ensure ${CAPTURES_DIR} exists with mode 0700. Called by
#   capture_start; safe to call directly from doctor.
capture_init_dir

# capture_start <verb>
#   Atomic NNN allocation + meta.json write. Sets and exports two env vars
#   for the verb to use:
#     CAPTURE_ID   = "001" (zero-padded 3-digit; 4+ digits at >=1000)
#     CAPTURE_DIR  = "${CAPTURES_DIR}/${CAPTURE_ID}"
#   Writes meta.json with status:"in_progress". Mode 0700 dir, 0600 meta.
capture_start <verb>

# capture_finish [status]
#   Default status: "ok". Updates meta.json: finished_at, status, total_bytes,
#   files (array of {name, bytes}). Updates _index.json: latest, count,
#   total_bytes. Caller responsible for writing per-aspect files into
#   ${CAPTURE_DIR} between start and finish.
capture_finish [status]
```

---

## meta.json shape (frozen for Phase 7)

```json
{
  "capture_id": "001",
  "verb": "snapshot",
  "schema_version": 1,
  "started_at": "2026-05-08T11:48:30Z",
  "finished_at": "2026-05-08T11:48:30Z",
  "status": "ok",
  "total_bytes": 4096,
  "files": [
    {"name": "snapshot.json", "bytes": 4096}
  ]
}
```

Future sub-parts will add fields without renaming (`sanitized: bool` in 7-iv, `pruned_at` in 7-v). Bump `schema_version` only on a renaming/removing change.

---

## `_index.json` shape

```json
{
  "schema_version": 1,
  "next_id": 2,
  "count": 1,
  "latest": "001",
  "total_bytes": 4096
}
```

`next_id` is **the next unused** id; bumped at allocation time. `count` is the count of captures actually-on-disk (decreases when 7-v's prune runs). `total_bytes` is cached for `doctor` UX; recomputed on each `capture_finish`.

---

## Atomic NNN allocation

Per parent spec §4.5: "tmpfile + mv, no flock".

```bash
# Read current next_id (default 1 if _index missing).
# Write _index.json.tmp with next_id+1.
# rename(2) is atomic on same filesystem.
# Race: two concurrent capture_start calls could read the same next_id and
# both mkdir the same NNN. v1 expected single-process per invocation; not
# worth flock complexity. Documented.
```

If two concurrent calls do collide, the second `mkdir ${CAPTURE_DIR}` will succeed (mkdir -p) and they'll race on writing snapshot.json. Future hardening: `mkdir` without `-p` so the second loser fails fast → retry with bumped id. Out of scope for 7-i.

---

## Timestamps

`date -u +'%Y-%m-%dT%H:%M:%SZ'` — UTC, ISO 8601, second precision. Cross-platform (GNU + BSD both accept). No millisecond precision (parent spec doesn't require it; capture happens human-time, not machine-time).

---

## File structure

### New
- `scripts/lib/capture.sh` — three functions above.
- `tests/capture.bats` — ~10 cases for the lib (contract-level, no verb dependency).
- `docs/superpowers/plans/2026-05-08-phase-07-part-1-i-capture-foundation.md` — this plan.

### Modified
- `scripts/browser-snapshot.sh` — accept `--capture`; on success/failure call `capture_start` / `capture_finish` and write adapter stdout to `${CAPTURE_DIR}/snapshot.json`. `capture_id` joins the summary.
- `tests/browser-snapshot.bats` — ~5 new cases for `--capture` wire-up: dir created mode 0700, meta.json shape, snapshot.json written, capture_id in summary, capture_finish on adapter error keeps status=error in meta.
- `CHANGELOG.md` — `[Unreleased]` Phase 7 part 1-i entry.

### NOT modified (7-i scope discipline)
- No sanitization (7-iii).
- No retention/prune (7-v).
- No `--unsanitized` (7-iv).
- No wire-up to inspect/audit/extract (7-iii).
- `install.sh` doesn't pre-create `captures/` — `capture_init_dir` does it lazily on first capture (mirrors how `sites/` and `sessions/` are created on first add).

---

## Test approach

`tests/capture.bats` — pure-helper tests with no adapter dispatch:

1. `capture_init_dir` creates `${CAPTURES_DIR}` mode 0700 if missing.
2. `capture_init_dir` is idempotent (no-op if already exists).
3. `capture_start verb=snapshot` allocates NNN=001 on first run.
4. `capture_start` zero-pads to 3 digits; bumps to 002 on second run.
5. `capture_start` exports `CAPTURE_ID` + `CAPTURE_DIR`.
6. `capture_start` writes `meta.json` with shape `{capture_id, verb, started_at, status:"in_progress", schema_version:1}`.
7. `capture_start` creates dir mode 0700, meta.json mode 0600.
8. `capture_finish` updates meta.json: `finished_at`, `status`, `total_bytes`, `files[]`.
9. `capture_finish` writes/updates `_index.json` with `count`, `latest`, `total_bytes`.
10. `capture_finish ok` vs `capture_finish error` — status round-trip.
11. Multiple `capture_start`s populate `_index.next_id` correctly across runs (003 after two prior).

`tests/browser-snapshot.bats` (extend) — wire-up:

1. `--capture` writes `captures/001/snapshot.json` containing the adapter stdout.
2. `--capture` summary has `capture_id == "001"`.
3. `--capture` meta.json status=ok on adapter success.
4. `--capture` adapter failure → meta.json status=error (still finalized).
5. Without `--capture` no captures/ dir created (clean state).

---

## Tag + push

```bash
git tag v0.33.0-phase-07-part-1-i-capture-foundation
git push -u origin feature/phase-07-part-1-i-capture-foundation
git push origin v0.33.0-phase-07-part-1-i-capture-foundation
gh pr create --title "feat(phase-7-part-1-i): capture foundation (lib/capture.sh + snapshot --capture)"
```
