# Changelog

Every entry has a tag in `[brackets]`:
- `[feat]` user-visible new behavior
- `[fix]` user-visible bug fix
- `[security]` anything touching credentials, sessions, captures, hooks
- `[adapter]` added/updated tool adapter
- `[schema]` on-disk schema migration
- `[breaking]` requires action from existing users
- `[upstream]` updated pinned upstream tool version
- `[internal]` lint, tests, CI — no user-visible change
- `[docs]` README / SKILL.md / references / examples

## [Unreleased]

### Phase 1 — Foundation

- [feat] `install.sh --user --with-hooks --dry-run` ships
- [feat] `uninstall.sh` ships (symlink-only by default)
- [feat] `doctor` verb: deps + bash version + home dir mode + disk encryption (advisory)
- [feat] `lib/common.sh`: exit codes, logging, summary_json, BROWSER_SKILL_HOME resolver, with_timeout, now_ms
- [security] `.gitignore` blocks credentials/sessions/captures/keys/.env
- [security] `.githooks/pre-commit` blocks staged credentials and password-shaped diff content
- [docs] SKILL.md, README.md, SECURITY.md scaffolded
- [internal] bats unit suite (~44 tests) runs in <10 s

### Phase 1 — Pre-Phase-2 cleanup (post v0.1.0-phase-01-foundation)

- [fix] `now_ms()` moved from `browser-doctor.sh` into `lib/common.sh` so future verb scripts can compute `duration_ms` without copy-paste.
- [fix] `node` check in doctor downgraded to advisory: missing node now warns but does not increment `problems` (Phase 1 does not require node yet; Phase 3 will elevate).
- [internal] new `check_cmd_advisory` helper in doctor for warn-but-do-not-fail dependency checks.
