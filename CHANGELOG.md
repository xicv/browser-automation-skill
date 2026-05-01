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

### Phase 4 part 3 — Real-mode driver (open) + sessions threaded into all verbs

- [feat] `scripts/lib/node/playwright-driver.mjs` real-mode `open` — single-shot launch + navigate + close. Lazy-imports `playwright` via `createRequire` with `npm root -g` fallback (or `BROWSER_SKILL_NPM_GLOBAL` override) so users can keep playwright globally installed without project-level package.json.
- [feat] Stateful verbs (snapshot/click/fill/login) emit a clear "daemon mode required (Phase 4 part 4)" hint in real mode; stub mode + playwright-cli routes remain functional.
- [feat] `scripts/browser-snapshot.sh`, `browser-click.sh`, `browser-fill.sh` now call `resolve_session_storage_state` between argv parse and `pick_tool` — sessions thread through every verb script that has an adapter.
- [feat] `lib/session.sh::session_save` validates `storageState.origins[*].localStorage` is an array. Real Playwright errors at `browser.newContext()` if the field is missing — the new guard surfaces it at save time with a clear pointer. Hand-edited storageState files (Phase-2 login flow input) trip on the original shape; real captures (`context.storageState()`) come out correctly.

### Phase 4 — Real Playwright (node-bridge adapter) + session loading

- [adapter] `scripts/lib/tool/playwright-lib.sh` — second concrete adapter; shells to a Node ESM driver that speaks the real Playwright API directly. Declares `session_load: true` capability, supports `--secret-stdin` natively (driver reads stdin in node), declares `login` verb (replaces the Phase-2 stub).
- [feat] `scripts/lib/node/playwright-driver.mjs` — Node ESM bridge. Stub mode (`BROWSER_SKILL_LIB_STUB=1`) hashes argv → reads `tests/fixtures/playwright-lib/<hash>.json` so CI runs without Playwright installed. Real mode: deferred to follow-up (lazy-imports playwright; launches chromium; applies storageState).
- [feat] `scripts/lib/verb_helpers.sh::resolve_session_storage_state` — maps `--site` / `--as` to a storageState file path; exports `BROWSER_SKILL_STORAGE_STATE`. Origin enforcement via Phase-2 `session_origin_check`. `--as` without `--site` is a usage error.
- [feat] `scripts/lib/router.sh::rule_session_required` — placed before `rule_default_navigation`; prefers `playwright-lib` when `BROWSER_SKILL_STORAGE_STATE` is set.
- [feat] `parse_verb_globals` adds `--as SESSION` (sets `ARG_AS`).
- [feat] `scripts/browser-open.sh` calls `resolve_session_storage_state`; verb scripts now thread sessions transparently.
- [fix] `scripts/browser-login.sh` summary tag changes from `tool=playwright-lib-stub` to `tool=playwright-lib` (Phase-2 carry-forward closed).
- [docs] `references/playwright-lib-cheatsheet.md` — new cheatsheet covering the node-bridge specifics.
- [docs] `SKILL.md` verbs table gains a session-loading example row.
- [internal] `tests/playwright-lib_adapter.bats` (17 cases — 6 driver stub-mode + 11 adapter contract). `tests/session-loading.bats` (10 cases — full --site/--as resolution coverage including origin mismatch + missing-session paths).

### Phase 3 part 3 — Sibling verb scripts

- [feat] `scripts/browser-snapshot.sh` — `eN`-indexed accessibility snapshot via picked adapter; passes through optional `--depth N`.
- [feat] `scripts/browser-click.sh` — click by `--ref eN` (preferred) or `--selector CSS` (mutually exclusive; one required).
- [feat] `scripts/browser-fill.sh` — fill by `--ref eN` with `--text VALUE` or `--secret-stdin` (mutually exclusive). `--secret-stdin` reads the secret from stdin and pipes it through to the adapter; the secret string never appears in argv (test asserts the leak guard).
- [feat] `scripts/browser-inspect.sh` — inspect by `--selector CSS`.
- [docs] `SKILL.md` verbs table gains `snapshot` / `click` / `fill` / `inspect` rows.
- [internal] 4 new bats files (19 cases) + 2 new stub fixtures (`fill --ref e3 --text hello`, `inspect --selector h1`).

### Phase 3 part 2 — Real verb scripts

- [feat] `scripts/lib/verb_helpers.sh` — `parse_verb_globals` + `source_picked_adapter` shared boilerplate for all verb scripts.
- [feat] `scripts/browser-open.sh` — first real verb script: `--site`/`--tool`/`--dry-run`/`--raw` global flags, `--url` required arg, full router → adapter → emit_summary pipeline.
- [docs] `SKILL.md` verbs table gains `open` row.
- [internal] `tests/verb_helpers.bats` (5) + `tests/browser-open.bats` (6) — full pipeline coverage via the playwright-cli stub.

### Phase 3 — Tool adapter extension model + first adapter

#### Added
- [feat] `BROWSER_SKILL_TOOL_ABI=1` constant in `scripts/lib/common.sh` — single-source ABI version for adapters; `LIB_TOOL_DIR` exported by `init_paths`.
- [feat] `scripts/lib/output.sh` — token-efficient output helpers (`emit_summary` / `emit_event` / `capture_path`) implementing `2026-05-01-token-efficient-adapter-output-design.md` §3.
- [feat] `scripts/lib/router.sh` — single-source routing precedence with `ROUTING_RULES` array of rule functions; `pick_tool` + `_tool_supports` capability filter; `rule_default_navigation` routes open/click/fill/snapshot/inspect to playwright-cli.
- [adapter] First concrete adapter `scripts/lib/tool/playwright-cli.sh` implementing the contract (3 identity + 8 verb-dispatch fns); sources `output.sh`.
- [feat] `scripts/regenerate-docs.sh` — manual generator for `references/tool-versions.md` and `SKILL.md` Tools block; idempotent.
- [internal] `tests/lint.sh` — three-tier adapter lint (static + dynamic + drift) with `lint.bats` coverage; drift tier enforces autogen sync + every-adapter-sources-output.sh.
- [internal] `tests/routing-capability-sync.bats` — drift test ensuring router rules align with adapter-declared capabilities.
- [internal] `tests/stubs/playwright-cli` + `tests/fixtures/playwright-cli/` — argv-hash-keyed adapter contract tests.
- [docs] `references/playwright-cli-cheatsheet.md`.
- [docs] `references/recipes/add-a-tool-adapter.md` — two-path recipe (Path A: ship-without-promotion; Path B: promote-to-default).
- [docs] `references/recipes/anti-patterns-tool-extension.md` — 9 WRONG/RIGHT examples.

#### Changed
- [adapter] `scripts/browser-doctor.sh` — adapter aggregation loop walks `scripts/lib/tool/*.sh` in subshells; `node` elevated from advisory to required; status semantics ok/partial/error per adapter outcomes.
- [docs] `SKILL.md` — added autogenerated `## Tools` section between markers.

#### Documentation
- New design spec: `docs/superpowers/specs/2026-04-30-tool-adapter-extension-model-design.md` augmenting parent spec §3.3 + §13.2.
- New design spec: `docs/superpowers/specs/2026-05-01-token-efficient-adapter-output-design.md` codifying the bytes adapters emit (sources: chrome-devtools-mcp design principles + microsoft/playwright-cli + browser-act/skills).

### Phase 2 — Site & session core

- [feat] `add-site` / `list-sites` / `show-site` / `remove-site` verbs ship (typed-name confirm on remove)
- [feat] `use` verb: get / set / clear current site
- [feat] `login` verb (Phase 2 stub): consumes a hand-edited Playwright storageState file, validates origins against the site URL, writes session + meta sidecar
- [feat] `lib/site.sh`: site profile CRUD with atomic write, mode 0600, schema_version=1
- [feat] `lib/session.sh`: storageState read/write, `session_origin_check` (spec §5.5), `session_expiry_summary`
- [feat] `common.sh`: `now_iso` helper added (UTC, second precision)
- [security] sessions inherit the same gitignored / 0600-files invariant as Phase 1
- [internal] `tests/helpers.bash` now sources `lib/common.sh`; `${EXIT_*:-N}` fallback pattern dropped from all `.bats` files
- [docs] SKILL.md verb table reflects new verbs; mode wording corrected to "0700 dir, 0600 files"; `CLAUDE_SKILL_DIR` explainer added

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
