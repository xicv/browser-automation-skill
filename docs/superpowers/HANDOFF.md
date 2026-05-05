Continue work on `browser-automation-skill` at `/Users/xicao/Projects/browser-automation-skill`. Read CLAUDE.md (if any), `SKILL.md`, and the most recent specs/plans under `docs/superpowers/specs/` and `docs/superpowers/plans/` before touching code.

## Where the project stands (as of 2026-05-05)

main is at tag `v0.18.0-phase-05-part-4-i-totp-plumbing`. **Phase 1, Phase 2, Phase 3, Phase 4** are SHIPPED. **Phase 5 is now ~95% complete** across 21 sub-parts (PRs #14-#34):

### Phase 5 part 1 (cdt-mcp track) — FEATURE-COMPLETE

- **part 1, 1b, 1c**: chrome-devtools-mcp adapter Path A (opt-in via `--tool=`) → bridge scaffold (lib-stub mode) → real MCP stdio transport (initialize + `tools/call` + `uid → eN` translation, stateless verbs).
- **part 1c-ii**: cdt-mcp daemon + `eN ↔ uid` ref persistence. Stateful `click` and `fill` work via daemon (TCP loopback IPC, MCP child long-lived).
- **part 1d**: router promotion (Path B). 4 new rules: `rule_capture_flags`, `rule_audit_or_perf`, `rule_inspect_default`, `rule_extract_default`. cdt-mcp now default for capture-* / audit / inspect / extract per parent spec Appendix B.
- **part 1e-i**: verb scripts. New `scripts/browser-audit.sh`, `scripts/browser-extract.sh`. `tests/browser-inspect.bats` un-skipped + re-aimed at cdt-mcp lib-stub. `browser-inspect.sh` flag set widened to capture-* + screenshot.
- **part 1e-ii**: bridge dispatch for `inspect` + `extract` real-mode. Multi-call composition in inspect (list_console_messages + list_network_requests + take_screenshot + selector evaluate_script aggregated). Extract via single evaluate_script. Both daemon + one-shot paths share `dispatchInspect`/`dispatchExtract` via extracted `makeMcpCall` factory + new `withMcpClient(fn)` helper. **8/8 cdt-mcp verbs now real-mode end-to-end.**
- **part 1f**: Chrome `--user-data-dir` passthrough. New `mcpSpawnArgs()` helper at all 3 spawn sites. `CHROME_USER_DATA_DIR` env var → `--user-data-dir DIR` CLI arg on the spawned MCP child. Chrome reuses profile (cookies, localStorage, extensions persist).

### Phase 5 part 2 (credentials track) — FEATURE-COMPLETE (shipped 2026-05-03)

5 verbs (`creds add` / `list` / `show` / `remove` / `migrate`), 3 Tier-1 backends (plaintext / macOS keychain / Linux libsecret), smart auto-detect, masked `--reveal` with typed-phrase confirmation, first-use plaintext gate uniformly enforced, doctor surface. Privacy invariant tested with sentinel canaries on every credential-emitting verb.

### Phase 5 part 3 (auth track) — FEATURE-COMPLETE for the design surface

- **part 3 (shipped 2026-05-03)**: `login --auto` programmatic headless re-login from stored credentials. AP-7 strict (`account\0password` over stdin only). Best-effort form selectors handle common single-step flows.
- **part 3-ii**: transparent verb-retry on `EXIT_SESSION_EXPIRED`. New `invoke_with_retry VERB ARGS...` helper in `verb_helpers.sh` + `_can_auto_relogin` + `_resolve_relogin_cred_name` + `_silent_relogin`. Wired into all 7 session-aware verbs (open / snapshot / click / fill / inspect / audit / extract — login NOT wired to avoid recursion). Per parent spec §4.4: every verb → silent re-login → retry, exactly one attempt.
- **part 3-iii**: `--auth-flow STR` declaration at `creds add` time. Allowed values: `single-step-username-password` (default) / `multi-step-username-password` / `username-only` / `custom`. `login --auto` refuses non-single-step values up-front with hint pointing at `--interactive` (replaces cryptic mid-flight selector failures).
- **part 3-iv**: 2FA detection in `login --auto` → exit 25 (`EXIT_AUTH_INTERACTIVE_REQUIRED`). New `detect2FA(page)` heuristic checks `input[autocomplete="one-time-code"]`, common OTP/code field name attrs, page-text for 2FA keywords. Bash side propagates 25 with `--interactive` hint.

### Phase 5 part 4 (TOTP track) — FOUNDATION shipped, codegen + replay + rotation pending

- **part 4-i**: `creds-add --enable-totp` flag persists `totp_enabled: true` in metadata. Requires `--yes-i-know-totp` typed acknowledgment. Refuses `--backend plaintext` (TOTP shared secrets are categorically more sensitive than passwords because they don't expire/rotate; plaintext storage means anyone with read access can generate codes for the lifetime of the secret).

### Tagged sub-part history (Phase 5)

| PR | Tag | What |
|---|---|---|
| #12 | `v0.6.0-phase-05-part-1-chrome-devtools-mcp` | cdt-mcp adapter (Path A — opt-in) |
| #13 | (no tag, docs PR) | `references/adapter-candidates.md` — pinchtab declined |
| #14 | `v0.6.1-phase-05-part-1b-cdt-mcp-bridge` | bridge scaffold + lib-stub pivot |
| #15 | `v0.7.0-phase-05-part-2a-creds-foundation` | credentials lib + plaintext backend |
| #16 | `v0.7.1-phase-05-part-2b-keychain` | macOS Keychain backend (security CLI) |
| #17 | `v0.7.2-phase-05-part-2c-libsecret` | Linux libsecret backend (secret-tool) |
| #18 | `v0.8.0-phase-05-part-2d-creds-add` | creds-add verb + smart backend select |
| #19 | `v0.8.1-phase-05-part-2d-ii-creds-crud` | creds list/show/remove verbs |
| #20 | `v0.8.2-phase-05-part-2d-iii-mask-and-reveal` | mask.sh + creds show --reveal + first-use plaintext gate |
| #21 | `v0.8.3-phase-05-part-2e-migrate` | creds migrate cross-backend moves |
| #22 | `v0.9.0-phase-05-part-1c-cdt-mcp-transport` | cdt-mcp real MCP stdio transport |
| #23 | `v0.9.1-phase-05-part-3-auto-relogin` | login --auto auto-relogin |
| #25 | `v0.10.0-phase-05-part-1c-ii-cdt-mcp-daemon` | cdt-mcp daemon + ref persistence |
| #26 | `v0.11.0-phase-05-part-1d-router-promotion` | router promotion (Path B) |
| #27 | `v0.12.0-phase-05-part-1e-i-audit-extract-scripts` | browser-audit + browser-extract scripts |
| #28 | `v0.13.0-phase-05-part-1e-ii-bridge-inspect-extract` | bridge dispatch for inspect/extract |
| #29 | `v0.14.0-phase-05-part-1f-user-data-dir` | CHROME_USER_DATA_DIR passthrough |
| #30 | `v0.15.0-phase-05-part-3-ii-verb-retry-helper` | invoke_with_retry helper + snapshot wired |
| #31 | `v0.15.1-phase-05-part-3-ii-wire-remaining-verbs` | wire retry helper into 6 remaining verbs |
| #32 | `v0.16.0-phase-05-part-3-iii-auth-flow-declaration` | --auth-flow declaration + login --auto enforcement |
| #33 | `v0.17.0-phase-05-part-3-iv-2fa-detection` | 2FA detection in login --auto → exit 25 |
| #34 | `v0.18.0-phase-05-part-4-i-totp-plumbing` | TOTP foundation: --enable-totp flag |

### Counters

- **20 user-facing verbs**: `doctor`, 4 site verbs (`add-site` / `list-sites` / `show-site` / `remove-site`), `use`, 3 login modes (`login`, `login --auto`, `login --storage-state-file`), 3 session verbs (`list-sessions` / `show-session` / `remove-session`), 5 cred verbs (`creds add` / `list` / `show` / `remove` / `migrate`), 8 web verbs (`open` / `snapshot` / `click` / `fill` / `inspect` / `audit` / `extract` / `eval`).
- **3 of 4 adapters**: `playwright-cli`, `playwright-lib`, `chrome-devtools-mcp` (full real-mode with Path B promotion). `obscura` planned for Phase 8.
- **3 of 3 Tier-1 credential backends**: plaintext, keychain (macOS), libsecret (Linux).
- **522 tests pass / 0 fail / lint exit 0** across all 3 tiers. CI green on macos-latest + ubuntu-latest.
- **34 PRs merged total** (21 in Phase 5; ~10 of those in the 2026-05-05 session).

## Phase 5 remaining

Auth track wraps the design surface. **The only remaining queue item is part 4 sub-parts:**

1. **Phase 5 part 4-ii** — TOTP codegen. New `creds totp` verb produces a current code via `oathtool` (macOS: `brew install oath-toolkit`; Linux: `apt install oathtool`). Or a node port if shell is preferred. Manual replay path: agent reads code from verb stdout, types into browser via existing `fill` flow. Also: TOTP secret persistence — `credential_set_totp_secret NAME` reads from stdin, dispatches to backend with `<name>:totp` slot suffix.

2. **Phase 5 part 4-iii** — auto-replay. `login --auto` reads cred metadata.totp_enabled; on detection of 2FA challenge page (extends part 3-iv's detect2FA), reads TOTP secret via `credential_get_totp_secret`, generates code, fills the OTP field, submits. Closes the loop end-to-end.

3. **Phase 5 part 4-iv** — `creds rotate-totp` verb for re-enrolling when service forces a new TOTP secret. Mirrors `creds-migrate`'s typed-phrase confirmation pattern.

After Phase 5: Phases 6 (bulk verbs: select / press / hover / drag / upload / wait / route / tab-*), 7 (capture pipeline + sanitization), 8 (obscura adapter), 9 (flow runner), 10 (schema migration tooling).

Read parent spec at `docs/superpowers/specs/2026-04-27-browser-automation-skill-design.md` for full design + Appendix A verb table + Appendix B routing matrix.

## Workflow expectations

- **TDD**: write the bats failing first, then impl, then green. Pattern is muscle-memory: branch + plan-doc + RED + GREEN + lint + tag + push + PR + CI + squash-merge + reset main.
- **One PR per part** (34 PRs merged so far). Each PR small + reviewable + CI-green-first-try (95%+ this session). Tag `vX.Y.Z-phase-NN-part-…` on the feature branch before push.
- **Lint must exit 0** at all three tiers. Drift tier (autogen sync) means run `scripts/regenerate-docs.sh all` after any adapter capability change.
- **Token-efficient output spec** governs the bytes adapters emit: single-line JSON summary terminates every verb, `eN` element refs, files for heavy data (capture paths, never inline), no secrets in argv (AP-7).
- **Privacy-canary pattern** (now 8+ instances across credential / creds-add / creds-list / creds-show / creds-show-reveal-mismatch / creds-migrate / login-auto-dry-run / cdt-mcp daemon fill-secret-stdin): any verb that emits credential-related JSON gets a sentinel canary in its bats file's "NEVER includes secret" test. **Convergence threshold met — document in `references/recipes/privacy-canary.md` is overdue.**
- **Defensive setup pattern**: any bats file using keychain or libsecret stubs MUST `export KEYCHAIN_SECURITY_BIN="${STUBS_DIR}/security"` + `export LIBSECRET_TOOL_BIN="${STUBS_DIR}/secret-tool"` in `setup()`, NOT inline per-test.
- **Cross-platform shell idioms**: GREP THE REPO FIRST. `stat -c '%a'` (GNU) precedes `stat -f '%Lp'` (BSD) — reverse breaks Linux. See `scripts/lib/common.sh:186` for the canonical comment + `feedback_grep_repo_for_idioms_first.md` user-memory entry.
- **CI workflow** (`.github/workflows/test.yml`) runs on macos-latest + ubuntu-latest. macOS bash 5 is brew-installed; ubuntu uses `apt install bats jq`. CI does NOT install Playwright or chrome-devtools-mcp by default — driver real-mode tests are gated; bats coverage is via stubs.
- **Stub patterns shipped**: bash binary stubs (`tests/stubs/{playwright-cli,security,secret-tool}`); lib-stub mode (`BROWSER_SKILL_LIB_STUB=1` in playwright-driver + chrome-devtools-bridge); protocol-speaking mock server (`tests/stubs/mcp-server-stub.mjs` for cdt-mcp transport tests, now also handles click / fill / list_console_messages / list_network_requests / take_screenshot).

## Next-session test-mode hooks (introduced in 2026-05-05 session)

- `BROWSER_SKILL_DRIVER_TEST_2FA=1` — forces `playwright-driver.mjs::runAutoRelogin` to short-circuit with exit 25. Used by `tests/login.bats` to verify the bash-side propagation harness without a real Chrome + 2FA challenge page. Production callers never set this.

## When you start

1. `git checkout main && git pull --ff-only origin main`
2. Confirm tag is `v0.18.0-phase-05-part-4-i-totp-plumbing` and `bats tests/` reports 522 pass.
3. Pick a sub-part. Recommendation: **part 4-ii (TOTP codegen + secret persistence)** — biggest user-visible win remaining. Or alternative: **document the privacy-canary recipe** at `references/recipes/privacy-canary.md` (overdue per convergence threshold).
4. Branch `feature/phase-05-part-4-ii-…`. Plan-doc + RED bats + GREEN + lint + tag + PR + CI + squash-merge + reset main.

Start with: read CHANGELOG since `v0.18.0-phase-05-part-4-i-totp-plumbing` (the last tag) to confirm no in-flight work, then propose the next part's scope (option-table pattern: scope envelope + capability surface + test approach + tag) before coding. The user prefers "go for your recommendation" once the option-table is presented; default to the smallest reviewable PR that delivers user-visible value.
