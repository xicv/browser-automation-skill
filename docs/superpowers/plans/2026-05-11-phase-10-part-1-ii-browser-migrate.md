# Phase 10 part 1-ii — `browser-migrate` verb

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans.

**Goal:** Second sub-part of Phase 10. Ships `scripts/browser-migrate.sh` — agent + user surface over `lib/migrate.sh` (10-1-i). Sub-mode dispatch + `--yes` flag + typed-phrase fallback + `--schema NAME` filter + lock file. After this PR ships, the verb works end-to-end against any registered migrator (10-1-iii adds the first one).

**Branch:** `phase-10-part-1-ii-browser-migrate`
**Tag:** `v0.58.0-phase-10-part-1-ii-browser-migrate`

---

## Locked decisions (carry-through from design doc)

- **MIG4 — Verb shape: `browser-migrate {check,run,rollback,status,clean-backups}`.** `check` read-only safe; `run`/`rollback`/`clean-backups` destructive (require `--yes` OR typed-phrase confirmation).
- **Open Q3 (now locked):** Confirmation = typed phrase `migrate now` for `run`/`rollback`; `--yes` flag bypasses for scripted use. Mirrors `creds-show --reveal` typed-phrase pattern.
- **Open Q4 (now locked):** Concurrent-migration lock at `${BROWSER_SKILL_HOME}/.migrate.lock` mode 0600. Refuse second `migrate run` when lock present + alive (PID-checked); stale lock (PID dead) auto-cleared.
- **`check` and `status` don't acquire the lock** — they're read-only.
- **`--schema NAME` filter** — applies to `run`/`rollback` (limits scope to one schema). For `check`/`status`, no filter (always full).

## Surface

```
bash scripts/browser-migrate.sh <sub-mode> [flags]

  check                                     read-only; reports schemas needing migration; exit 0
  run [--yes] [--schema NAME]               run all (or one schema); --yes bypasses typed-phrase
  rollback --schema NAME [--yes]            single-step rollback for SCHEMA; --schema required
  status                                    read-only; echoes versions.json + adapter status
  clean-backups [--keep N] [--yes]          discard backups beyond newest N (default 5); --yes bypasses
```

## Behavior

### `check` (read-only)

```
1. Source lib/common.sh + lib/migrate.sh.
2. init_paths.
3. migrate_check (lib already emits _kind:migration_needed events + summary).
4. exit 0 always.
```

### `run` (destructive)

```
1. Source lib/common.sh + lib/migrate.sh.
2. init_paths.
3. Acquire lock at ${BROWSER_SKILL_HOME}/.migrate.lock:
   - Write current PID + ISO timestamp; mode 0600.
   - If lock exists + PID alive → die EXIT_USAGE_ERROR + tell user to wait.
   - If lock exists + PID dead → warn "stale lock cleared" + overwrite.
4. If --yes given → skip confirmation.
   Else → prompt: "type 'migrate now' to confirm:"; read line; refuse if mismatch.
5. migrate_run [SCHEMA].
6. Release lock (rm).
7. Exit code = lib's exit code.
```

### `rollback` (destructive)

```
1. Same as run, but:
2. --schema NAME REQUIRED.
3. Confirmation phrase same: "migrate rollback ${schema}".
4. migrate_rollback SCHEMA.
```

### `status` (read-only)

```
1. migrate_status (echoes versions.json).
2. Exit 0.
```

### `clean-backups` (destructive)

```
1. Lock + confirmation same as run (typed phrase: "clean backups").
2. migrate_clean_backups [N].
3. Release lock.
```

## Implementation strategy

### `scripts/browser-migrate.sh`

Mirror `scripts/browser-history.sh`'s sub-mode dispatch shape (PR #86 precedent). Single bash file ~150 LOC.

### Lock file helper

Inline in browser-migrate.sh (small enough; not promoted to lib until a second verb needs it):

```bash
_acquire_migrate_lock() {
  local lock_path="${BROWSER_SKILL_HOME}/.migrate.lock"
  if [ -f "${lock_path}" ]; then
    local owner_pid
    owner_pid="$(jq -r '.pid // empty' "${lock_path}" 2>/dev/null)"
    if [ -n "${owner_pid}" ] && kill -0 "${owner_pid}" 2>/dev/null; then
      die "${EXIT_USAGE_ERROR}" "browser-migrate: another migration in progress (pid ${owner_pid}); wait or kill it"
    fi
    warn "browser-migrate: stale lock from pid ${owner_pid} cleared"
    rm -f "${lock_path}"
  fi
  printf '%s' "$(jq -nc --arg pid "$$" --arg now "$(now_iso)" '{pid:($pid|tonumber), acquired_at:$now}')" > "${lock_path}"
  chmod 600 "${lock_path}"
  trap '_release_migrate_lock' EXIT
}

_release_migrate_lock() {
  rm -f "${BROWSER_SKILL_HOME}/.migrate.lock"
}
```

### Typed-phrase confirmation

Mirror `scripts/browser-creds-show.sh::--reveal`'s typed-phrase reading pattern. Read one line from stdin; compare; refuse on mismatch.

```bash
_confirm_phrase() {
  local expected="$1"
  if [ "${ARG_YES:-0}" = "1" ]; then return 0; fi
  if [ ! -t 0 ]; then
    die "${EXIT_TTY_REQUIRED}" "browser-migrate: requires --yes or interactive TTY for confirmation"
  fi
  printf 'type %q to confirm:\n' "${expected}" >&2
  IFS= read -r line
  [ "${line}" = "${expected}" ] || die "${EXIT_USAGE_ERROR}" "browser-migrate: confirmation mismatch; aborted"
}
```

## Test cases (RED → GREEN)

`tests/browser-migrate.bats` (new file, ~10 cases):

1. `browser-migrate check` exit 0 + summary `pending:0` (empty registry).
2. `browser-migrate status` exit 0 + echoes versions.json.
3. `browser-migrate run --yes` empty registry → no-op + exit 0 + summary `migrated:0`.
4. `browser-migrate run` without `--yes` and no TTY → exit `EXIT_TTY_REQUIRED` (27).
5. `browser-migrate run` with `--yes` + identity migrator (via `BROWSER_SKILL_MIGRATORS_DIR`) → schema bumped + backup created.
6. `browser-migrate rollback --schema test --yes` after a successful run → version restored.
7. `browser-migrate rollback` without `--schema` → exit `EXIT_USAGE_ERROR` (2).
8. `browser-migrate clean-backups --keep 1 --yes` → keeps newest backup; older discarded.
9. Lock test: write a fake `.migrate.lock` with current shell's PID; `browser-migrate run --yes` refuses with `EXIT_USAGE_ERROR`.
10. Stale lock test: write a fake `.migrate.lock` with PID 999999 (unlikely-alive); `browser-migrate run --yes` clears it + proceeds.
11. Unknown sub-mode → exit `EXIT_USAGE_ERROR` + helpful message.

## Sub-scope (what 10-1-ii does NOT do)

- **No real migrators registered.** 10-1-iii ships first.
- **No verb-router promotion.** `browser-migrate` is invoked directly (not via `pick_tool`); no adapter routing — migration is a pure-bash skill operation.
- **No HANDOFF table change for verb count** — `migrate` is a new verb but it operates on skill-internal state; not part of the browser-driving verb set in the same way as click/fill/etc. Counted separately ("internal verbs: 1 → 2 — `doctor` and `migrate`").
- **No automatic backup-clean on `run`.** Cleanup is explicit via `clean-backups`; `run` only adds backups, doesn't discard.
- **No JSON-formatted prompt.** Prompts go to stderr; only the JSON event stream goes to stdout.

## Acceptance

- `tests/browser-migrate.bats` 10+ cases all green on macos-latest + ubuntu-latest CI.
- `bash tests/lint.sh` exit 0.
- `bash scripts/browser-migrate.sh status` works end-to-end (echoes versions.json after init).
- Lock prevents concurrent runs (test 9); stale-lock auto-clear works (test 10).
- CHANGELOG `[Unreleased]` `[feat]` block + plan-doc reference.

## Notes for follow-ups

- **10-1-iii: first real migrator** — no-op `v1_to_v2` for memory archetype JSONs (just adds `priority:0` field per design doc example). Validates registry + dispatch end-to-end. Closes Phase 10 part 1.
- **Lock file promotion to lib** — if a second verb ever needs file-locking, promote `_acquire/release_*_lock` to a new `lib/lock.sh` helper. Defer until demand.
