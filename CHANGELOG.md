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

### Phase 5 part 2d — `creds add` verb + smart backend select

- [feat] new `scripts/browser-creds-add.sh` — first user-visible auth verb. Registers a credential under `${CREDENTIALS_DIR}/<name>.{json,secret}`. CLI: `creds-add --site SITE --as CRED_NAME --password-stdin [--account ACCOUNT] [--backend keychain|libsecret|plaintext] [--auto-relogin true|false] [--dry-run]`. Validates site exists, cred name safe + not already registered. Auto-detects backend per OS if `--backend` not set.
- [security] AP-7 STRICT: `--password-stdin` is the **only** password-input path. NO `--password VALUE` flag. Lint-style grep test guards against future regression. Password reaches `credential_set_secret` via stdin pipe — never argv.
- [feat] new `scripts/lib/secret_backend_select.sh` — smart per-OS backend auto-detection per parent spec §1. `detect_backend` echoes `keychain` (Darwin + `security` on PATH), `libsecret` (Linux + `secret-tool` on PATH), or `plaintext` (fallback). `BROWSER_SKILL_FORCE_BACKEND` env override honored. Does NOT probe D-Bus reachability for libsecret (too brittle); user can override to `plaintext` if their Linux box has no agent.
- [feat] `scripts/browser-doctor.sh` — new advisory check after adapter aggregation. Walks `${CREDENTIALS_DIR}/*.json` and emits `credentials: N total (keychain: A, libsecret: B, plaintext: C)`. Does NOT increment `problems`; advisory only.
- [internal] `tests/creds-add.bats` (14 cases) — happy path × 3 backends + auto-detect + validation (existing cred / unknown site / unsafe name / missing required flags) + AP-7 grep guard + `--dry-run` + `--account` override + summary JSON shape. Defensive: setup() exports stub bins for keychain + libsecret unconditionally so no test can fall through to a real OS vault.
- [internal] `tests/secret_backend_select.bats` (8 cases) — env override, per-OS detection (Darwin/Linux/other) via a `uname -s` shim, missing-binary fallback to plaintext.
- [internal] `tests/doctor.bats` — added 2 cases: zero-credential state + per-backend breakdown line with hand-written metadata fixture.
- [bugfix] `scripts/lib/credential.sh` — `_CREDENTIAL_REQUIRED_FIELDS` changed from a space-separated string to a bash array. The string form was IFS-dependent: verb scripts set `IFS=$'\n\t'` (default protective hygiene), which silently broke `for field in ${_CREDENTIAL_REQUIRED_FIELDS}` word-splitting. Symptom: validation reported the entire string as one missing-field name. Array + `[@]` quoting is IFS-independent. Tests in part-2a passed because they ran in a `bash -c` subshell with default IFS; the bug surfaced when the verb script (the first IFS-strict caller) hit `credential_save`.
- [docs] `SKILL.md` — added `creds add` row to the verbs table.
- [docs] `docs/superpowers/plans/2026-05-03-phase-05-part-2d-creds-add.md` — phase plan.

NO `creds list/show/remove` this PR — those follow the patterns established here in part 2d-ii. NO `mask.sh` + `--reveal` typed-phrase flow — part 2d-iii. NO `migrate-credential` — part 2e. NO interactive `read -s` password prompt — TTY-aware mocking in bats is complex; deferred. NO first-use plaintext typed-phrase confirmation prompt — lands with the TTY-prompt patterns in 2d-iii.

Untouched per scope discipline: `scripts/lib/router.sh`, `scripts/lib/common.sh`, `scripts/lib/output.sh`, `scripts/lib/site.sh`, `scripts/lib/session.sh`, `scripts/lib/verb_helpers.sh`, `scripts/lib/secret/*.sh` (3 backends, all from parts 2a/2b/2c), every adapter file, `tests/lint.sh`, `tests/router.bats`.

### Phase 5 part 2c — Linux libsecret backend (secret-tool)

- [feat] new `scripts/lib/secret/libsecret.sh` — third (and final Tier-1) secret backend. Completes the per-OS roster: plaintext + keychain + libsecret. 4-fn API mirrors `keychain.sh` shape; shells to `${LIBSECRET_TOOL_BIN:-secret-tool}`; service prefix `${BROWSER_SKILL_LIBSECRET_SERVICE:-browser-skill}`; account = credential name. `secret_set` clear-then-store for idempotent overwrite; `secret_get` via `lookup`; `secret_delete` swallows missing-item exit-1 from `clear`; `secret_exists` probes via `lookup` to /dev/null.
- [security] AP-7 CLEAN — no documented exception. The upstream `secret-tool` CLI reads passwords from stdin natively (via `store` subcommand). The skill's own code pipes stdin directly into `secret-tool store`; password never appears in argv. Contrast with macOS keychain backend (`secret/keychain.sh`) which has a documented AP-7 exception due to the upstream `security` CLI's argv-only design.
- [feat] `scripts/lib/credential.sh` dispatcher: `libsecret` branch shifts from part-2a's `EXIT_TOOL_MISSING` placeholder to actual backend dispatch. **All three backend branches now dispatch to real implementations** — no placeholders remain in `_credential_dispatch_backend`.
- [internal] new `tests/stubs/secret-tool` — bash mock of `secret-tool` CLI. Supports `store/lookup/clear` with attr=val pairs (`service`, `account`). State in `${LIBSECRET_STUB_STORE}` (per-test isolated tempfile). Reads PW from stdin verbatim (no trailing-newline strip). Logs argv to `${STUB_LOG_FILE}` for shape assertions. Lets bats run on macos-latest CI (no libsecret) and ubuntu-latest CI (no D-Bus session) identically.
- [internal] `tests/secret_libsecret.bats` (13 cases) — full backend coverage: AP-7-clean header guard (asserts the absence of "AP-7 documented exception" + presence of stdin-clean affirmation), stdin-roundtrip, idempotent delete, multi-secret, last-write-wins (clear-then-store), service prefix override, byte-exact verbatim roundtrip.
- [internal] `tests/credential.bats` — replaced the part-2a "libsecret returns EXIT_TOOL_MISSING (deferred)" test with positive libsecret-roundtrip-via-stub test. Uses inline env-prefix style matching the existing keychain test.
- [docs] `docs/superpowers/plans/2026-05-02-phase-05-part-2c-libsecret.md` — phase plan.

NO verb scripts this PR. NO doctor changes. NO router/adapter touches. Linux libsecret becomes the **per-OS-default backend on Linux** (when `secret-tool` is on PATH and a D-Bus Secret Service is reachable) once `creds add` lands in part 2d.

Backend roster after this PR (3 of 3 Tier-1 shipped; smart auto-detect lands in 2d):

| OS | Default backend | Fallback |
|---|---|---|
| Darwin | keychain (security CLI) | plaintext-with-typed-phrase |
| Linux (with libsecret) | libsecret (secret-tool) | plaintext-with-typed-phrase |
| Linux (no libsecret) / other | plaintext-with-typed-phrase | (none) |

Untouched per scope discipline: `scripts/lib/router.sh`, `scripts/lib/common.sh`, `scripts/lib/output.sh`, `scripts/lib/secret/plaintext.sh`, `scripts/lib/secret/keychain.sh`, `scripts/browser-doctor.sh`, every `scripts/browser-<verb>.sh`, every adapter file, `SKILL.md`, `tests/lint.sh`.

### Phase 5 part 2b — macOS Keychain backend (security CLI)

- [feat] new `scripts/lib/secret/keychain.sh` — second secret backend. 4-fn API mirrors `plaintext.sh`. Shells to `${KEYCHAIN_SECURITY_BIN:-security}`; service prefix `${BROWSER_SKILL_KEYCHAIN_SERVICE:-browser-skill}`; account = credential name. `secret_set` reads stdin then calls `security add-generic-password -w "${secret}" -U`. `secret_get` echoes via `find-generic-password -w`. `secret_delete` idempotent (`|| true` swallows missing-item exit). `secret_exists` probes via `find-generic-password` without `-w`.
- [security] AP-7 documented exception: macOS `security` CLI takes the password on argv (`-w PASSWORD`); no clean stdin path in upstream tool. Mitigations documented in keychain.sh header — short-lived subprocess (~50ms), -U makes idempotent, Linux libsecret backend (part 2c) uses stdin-clean `secret-tool`. The skill's own code never puts secrets on argv; the leak surface is the brief `security` subprocess. Honest documented exception pattern, NOT silent compromise of the invariant.
- [feat] `scripts/lib/credential.sh` dispatcher: `keychain` branch shifted from part-2a's `EXIT_TOOL_MISSING` placeholder to actual backend dispatch (`source secret/keychain.sh; secret_${op}`). `libsecret` branch unchanged (still placeholder until 2c).
- [internal] new `tests/stubs/security` — bash mock of macOS `security` CLI. Supports `add/find/delete-generic-password` with `-s/-a/-w/-U` flag set the backend uses. State in `${KEYCHAIN_STUB_STORE}` (per-test isolated tempfile). Logs argv to `${STUB_LOG_FILE}` for shape assertions. Mirrors `tests/stubs/playwright-cli` + `tests/stubs/chrome-devtools-mcp` (now-deleted) patterns. Lets bats run on Ubuntu CI without macOS keychain access.
- [internal] `tests/secret_keychain.bats` (13 cases) — full backend coverage: stdin-roundtrip, idempotent delete, multi-secret, last-write-wins, override of service prefix, AP-7 header-comment grep guard.
- [internal] `tests/credential.bats` — replaced the part-2a "keychain returns EXIT_TOOL_MISSING (deferred)" test with positive keychain-roundtrip-via-stub test. libsecret-deferred test stays (still placeholder until 2c).
- [docs] `docs/superpowers/plans/2026-05-02-phase-05-part-2b-keychain.md` — phase plan.

NO verb scripts this PR. NO doctor changes. NO router/adapter touches. macOS Keychain becomes the **per-OS-default backend on macOS** once `creds add` lands in part 2d (smart auto-detect: keychain on macOS, libsecret on Linux with libsecret installed, plaintext fallback otherwise).

Untouched per scope discipline: `scripts/lib/router.sh`, `scripts/lib/common.sh`, `scripts/lib/output.sh`, `scripts/lib/site.sh`, `scripts/lib/session.sh`, `scripts/lib/secret/plaintext.sh`, `scripts/browser-doctor.sh`, every `scripts/browser-<verb>.sh`, every adapter file, `SKILL.md`, `tests/lint.sh`.

### Phase 5 part 2a — credentials foundation (lib + plaintext backend)

- [feat] new `scripts/lib/credential.sh` — credentials substrate. Eight public fns: `credential_save/load/meta_load/list_names/delete/exists/set_secret/get_secret`. Schema v1 (mirror session schema). Two files per credential: `<name>.json` for metadata (mode 0600, NEVER secret values) and `<name>.secret` for backend-owned payload. Backend dispatcher routes secret operations by `metadata.backend` field; sources backends on demand to keep parent-shell namespace clean.
- [feat] new `scripts/lib/secret/plaintext.sh` — first secret backend. Four fns: `secret_set/get/delete/exists`. AP-7-strict: secret material flows via stdin pipes only — never argv. Atomic writes (tmp + mv); mode 0600 files inside mode 0700 `${CREDENTIALS_DIR}`. Idempotent delete. Last-write-wins on overwrite (no implicit `--force` — caller's job to confirm via `credential_delete` first).
- [feat] backend dispatcher returns `EXIT_TOOL_MISSING` (21) with self-healing hint for `keychain` and `libsecret` backends — placeholders until those backends land in phase-05 part 2b (macOS Security framework via `security` CLI) and part 2c (Linux Secret Service via `secret-tool`).
- [security] `credential_load` privacy-invariant test: output MUST NOT contain a `secret` field or any secret value. `tests/credential.bats` asserts this with a sentinel value (`sekret-do-not-leak`) — guards against any future regression that conflates metadata with payload.
- [internal] `tests/credential.bats` (21 cases) + `tests/secret_plaintext.bats` (12 cases) — full lib + backend coverage including: file-mode invariants, dir-mode invariants, schema validation, dispatcher routing, deferred-backend exit codes, path-traversal rejection, AP-7 grep guard.
- [docs] `docs/superpowers/plans/2026-05-02-phase-05-part-2a-creds-foundation.md` — phase plan.

NO verb scripts this PR. `creds add/list/show/remove` land in part 2d once the backend roster (2a/2b/2c) is complete. NO doctor changes — credential count comes in 2d when verbs trigger surface visibility.

Untouched per scope discipline: `scripts/lib/router.sh`, `scripts/lib/common.sh`, `scripts/lib/output.sh`, `scripts/lib/site.sh`, `scripts/lib/session.sh`, `scripts/browser-doctor.sh`, every `scripts/browser-<verb>.sh`, every adapter file, `SKILL.md` (no new verbs to autogen), `tests/lint.sh`.

### Phase 5 part 1b — cdt-mcp bridge scaffold + lib-stub pivot

- [adapter] new `scripts/lib/node/chrome-devtools-bridge.mjs` — node ESM bridge between the chrome-devtools-mcp adapter and the upstream MCP server. Stub mode (`BROWSER_SKILL_LIB_STUB=1`) performs sha256(argv) → `tests/fixtures/chrome-devtools-mcp/<sha>.json` lookup and echoes contents (matches the part-1 hashing form `printf '%s\0' "$@" | shasum -a 256` so existing fixtures work unchanged). Real-mode MCP transport (initialize handshake + `tools/call` + `uid → eN` translation) is deferred to phase-05 part 1c — bridge throws with a self-healing hint pointing at that part.
- [adapter] `scripts/lib/tool/chrome-devtools-mcp.sh` rewired to shell to the bridge via a new `_drive` helper, mirroring `playwright-lib`'s shape exactly. Adapter no longer references `${CHROME_DEVTOOLS_MCP_BIN}` for verb dispatch; the env var still exists but its semantics shifted — it now means "the upstream MCP server binary the bridge spawns in real mode" (defaults to `chrome-devtools-mcp`).
- [adapter] `tool_doctor_check` pivoted from "bin on PATH" to "node on PATH + bridge file present" (mirror `playwright-lib::tool_doctor_check`). Includes a `note` field explaining real-mode transport is deferred to part 1c. Doctor now passes on plain CI without any env override (node is always present).
- [internal] deleted `tests/stubs/chrome-devtools-mcp` (~50 LOC of bash) — replaced by lib-stub mode in the bridge. Mirrors `playwright-lib`'s no-binary-stub model.
- [internal] reverted the part-1 additions to `tests/doctor.bats` (3 sites) and `tests/install.bats` (1 site) — `CHROME_DEVTOOLS_MCP_BIN="${STUBS_DIR}/chrome-devtools-mcp"` overrides are no longer needed because doctor now passes on node-and-bridge alone.
- [internal] `tests/chrome-devtools-mcp_adapter.bats` (21 cases): env var pivoted from `CHROME_DEVTOOLS_MCP_BIN` to `BROWSER_SKILL_LIB_STUB=1`; one test renamed from "stub bin on PATH" to "node on PATH (no env override needed)". Argv-shape assertions via `STUB_LOG_FILE` unchanged — bridge logs argv to that file in stub mode for parity.
- [docs] `references/chrome-devtools-mcp-cheatsheet.md` — new "Architecture" diagram (adapter → bridge → upstream); rewritten "Stub mode" section; new "Environment variables" reference table; "Limitations" section restructured to call out which sub-part lands each remaining capability.
- [docs] `docs/superpowers/plans/2026-05-02-phase-05-part-1b-cdt-mcp-bridge.md` — phase plan.

Untouched per Path A discipline: `scripts/lib/router.sh`, `scripts/lib/common.sh`, `scripts/lib/output.sh`, `scripts/browser-doctor.sh`, every `scripts/browser-<verb>.sh`, `references/routing-heuristics.md`, `tests/router.bats`, both pre-existing adapter files (`playwright-cli.sh`, `playwright-lib.sh`), 8 fixtures under `tests/fixtures/chrome-devtools-mcp/`.

### Phase 5 part 1 — chrome-devtools-mcp adapter (Path A — opt-in)

- [adapter] added `scripts/lib/tool/chrome-devtools-mcp.sh` — third concrete adapter, third on the toolbox roster after `playwright-cli` and `playwright-lib`. Declares all 8 verbs (`open click fill snapshot inspect audit extract eval`) so `--tool=chrome-devtools-mcp` makes the full surface reachable today via the capability filter in `pick_tool`. The flagship verbs (`inspect`, `audit`, `extract`) are the long-term defaults per parent spec Appendix B; router promotion (Path B) is deferred to phase-05 part 1c per anti-pattern AP-4 (no same-PR promotion).
- [adapter] real-mode placeholder: the adapter shells to `${CHROME_DEVTOOLS_MCP_BIN:-chrome-devtools-mcp}`. The upstream is an MCP server (`npx chrome-devtools-mcp@latest`, JSON-RPC over stdio), not a CLI. The stdio bridge that wires the adapter to it is deferred to phase-05 part 1b.
- [adapter] `tool_fill --secret-stdin` is honored (unlike `playwright-cli` which exits 41) — passes the flag through to the bin, which reads stdin. Differentiates from `playwright-cli` (rejects stdin) and matches `playwright-lib` (driver reads stdin in node).
- [internal] `tests/chrome-devtools-mcp_adapter.bats` (21 cases) — contract conformance + flagship verb declarations + happy-path verb dispatch via stub + missing-fixture exit-41 propagation + `--ref`-required guard.
- [internal] `tests/stubs/chrome-devtools-mcp` (mirror of `tests/stubs/playwright-cli`): `sha256(argv joined by NUL)` → fixture lookup; honors `--version` so doctor reports the bin as found under stub override.
- [internal] `tests/fixtures/chrome-devtools-mcp/<sha>.json` × 8 — covers inspect/audit/snapshot/eval/open/click/extract/fill argv shapes.
- [internal] `tests/doctor.bats` + `tests/install.bats` — added `CHROME_DEVTOOLS_MCP_BIN="${STUBS_DIR}/chrome-devtools-mcp"` alongside the playwright-cli stub so the `all checks passed` assertions stay true under the new adapter.
- [docs] `references/chrome-devtools-mcp-cheatsheet.md` — when-to-use, capability declaration, opt-in syntax, stub-mode notes, deferred-bridge call-out.
- [docs] `SKILL.md` + `references/tool-versions.md` — autogenerated 3rd adapter row.
- [docs] `docs/superpowers/plans/2026-05-01-phase-05-part-1-chrome-devtools-mcp.md` — phase plan.

Untouched per Path A discipline (recipe + AP-4): `scripts/lib/router.sh`, `scripts/lib/common.sh`, `scripts/lib/output.sh`, `scripts/browser-doctor.sh`, every `scripts/browser-<verb>.sh`, `references/routing-heuristics.md`, `tests/router.bats`, both pre-existing adapter files.

### Phase 4 part 4e — show-session + remove-session verbs (full session CRUD)

- [feat] `scripts/browser-show-session.sh` — emits session metadata (origin, captured_at, expires_in_hours, source_user_agent) plus storage_state counts (cookie_count, origin_count, file_size_bytes). **CRITICAL:** never emits cookie/token values; the agent has no business seeing raw session material. Test asserts cookie values do not leak into output.
- [feat] `scripts/browser-remove-session.sh` — typed-name confirmed delete of session storageState + meta. Mirrors `remove-site` ergonomics: `--yes-i-know` skips prompt, `--dry-run` reports planned action. Does NOT clear `site.default_session` pointers (cascade is Phase 5); dangling pointers surface clearly via `resolve_session_storage_state`'s self-healing hint at next use.
- [feat] `scripts/lib/session.sh::session_delete` — new lib helper. Idempotent (no-op on missing files), `assert_safe_name` guards path-traversal.
- [docs] `SKILL.md` verbs table gains `show-session` + `remove-session` rows.
- [internal] `tests/show-remove-session.bats` (10) — full coverage incl. cookie-value-leak guard. `tests/session.bats` (+3) — session_delete unit tests.

Session CRUD now complete: `login` (create) / `list-sessions` (read all) / `show-session` (read one) / `remove-session` (delete). Update happens via re-login.

### Phase 4 part 4d — Real-mode interactive login + multi-session ergonomics

- [feat] `playwright-driver.mjs::runLogin` — single-shot headed Chromium flow. Launches browser at `--url`, prints "press Enter when done logging in" to stderr, waits for stdin newline, captures `context.storageState()`, writes to `--output-path` (mode 0600). Independent of the IPC daemon — login is its own ephemeral isolated context.
- [feat] `scripts/browser-login.sh` adds `--interactive` flag (mutually exclusive with `--storage-state-file`). Shells the driver, validates the captured storageState through the same Phase-2 origin-binding pipeline, writes the session + meta sidecar. `--interactive --dry-run` skips the browser launch and reports the planned action. Summary `why` field becomes `interactive-headed-capture` (vs `storageState-file-import` for the file path).
- [feat] `scripts/browser-list-sessions.sh` — new verb. Lists sessions with their bound site + origin + captured_at + expires_in_hours. Optional `--site NAME` filter exposes the **1-many credential model**: a site can have many sessions (e.g. `prod--admin`, `prod--readonly`, `prod--ci`) for per-role/per-account workflows. Storage state itself stays at mode 0600; this verb only emits metadata, never cookie/token values.
- [docs] `SKILL.md` verbs table gains rows for `login --interactive`, `login --storage-state-file`, and `list-sessions`. Login usage block now documents the 1-many model explicitly.
- [internal] `tests/list-sessions.bats` (5 cases) + 3 new login-flag tests. Phase-2 fixture-based login tests unchanged.

### Phase 4 part 4b — IPC daemon + stateful verbs (snapshot/click/fill) real mode

- [feat] `daemonChildMain` becomes an IPC server. Holds `(BrowserServer, Browser, current Context, current Page, refMap)` in closure. Listens on TCP loopback (random port — Unix socket sun_path is 104 chars on macOS; bats temp paths exceed it). State file gains `ipc_host` + `ipc_port` fields.
- [feat] `runSnapshot` / `runClick` / `runFill` route through `ipcCall` — JSON-line protocol over TCP loopback. Daemon executes verbs against held state; clients are thin transports.
- [feat] `runOpen` ALSO routes through IPC when daemon present; the daemon-held context+page persists for snapshot/click/fill. Falls back to one-shot launch when no daemon.
- [feat] `--secret-stdin` for fill: client reads stdin, sends text in JSON IPC message, daemon scrubs Playwright error logs (which echo fill args) before replying. Client reply never contains the secret on any path.
- [feat] Snapshot uses Playwright 1.59's `page.ariaSnapshot()` (replaces dropped `page.accessibility`). Output is YAML; `parseAriaSnapshot()` extracts interactive (role, name) tuples and assigns `eN` ids. Click/fill use `page.getByRole(role, {name}).first()` for stable cross-call locators.
- [internal] Empirical finding documented: `chromium.connect()` clients DO NOT share contexts across connections — that's why daemon-side dispatch (this design) is necessary. `runOpen`'s `attached_to_daemon: true` field now genuinely reflects state persistence.
- [internal] `tests/playwright-lib_stateful_e2e.bats` — 4 gated cases covering full chain (start → open → snapshot → click → stop), no-open-page error, ref-not-found error, and the secret-leak guard.
- [docs] `docs/superpowers/plans/2026-05-01-phase-04-part-4c-ipc-daemon.md` — design doc the implementation followed; kept as historical record.

### Phase 4 part 4a — Daemon lifecycle + open-via-daemon

- [feat] `playwright-driver.mjs` `daemon-start` / `daemon-stop` / `daemon-status` subcommands. Spawns a detached node child that calls `chromium.launchServer()` and writes state (PID + wsEndpoint + started_at) to `${BROWSER_SKILL_HOME}/playwright-lib-daemon.json` (mode 0600). Parent polls (≤10s), prints state, exits. Stopping SIGTERMs the PID and cleans up.
- [feat] `runOpen` attaches to a running daemon when present (chromium.connect via wsEndpoint). Closes pre-existing contexts so the agent's "current context" is unambiguous; a new context+page persists in the daemon for subsequent verbs. Falls back to one-shot launch when no daemon — keeps existing smoke-test ergonomics. Output now includes `attached_to_daemon: bool` so callers can see which path ran.
- [feat] Daemon stderr captured to `${BROWSER_SKILL_HOME}/playwright-lib-daemon.log` (mode 0600) — silent failures (e.g. missing chromium cache) become diagnosable.
- [internal] `tests/playwright-lib_daemon_e2e.bats` — 5 e2e cases gated on `command -v playwright`. Covers start/status/stop, attach-on-open, idempotent start, stop-when-none-running. CI without Playwright skips the file via `setup_file()`.
- [fix] `.gitignore` — daemon state/log files (so accidental driver runs from inside the repo don't pollute git).

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
