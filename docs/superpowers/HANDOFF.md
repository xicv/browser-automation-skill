Continue work on `browser-automation-skill` at `/Users/xicao/Projects/browser-automation-skill`. Read CLAUDE.md (if any), `SKILL.md`, and the most recent specs/plans under `docs/superpowers/specs/` and `docs/superpowers/plans/` before touching code.

## Where the project stands (as of 2026-05-05 — Phase 5 wrap)

main is at tag `v0.21.0-phase-05-part-4-iv-rotate-totp`. **Phase 1, Phase 2, Phase 3, Phase 4 are SHIPPED. Phase 5 is FEATURE-COMPLETE** across 24 sub-parts (PRs #14-#38).

### 🎉 Phase 5 wrap

All HANDOFF queue items shipped. End-to-end flow for an agent on a 2FA-protected site:

```
agent runs verb (snapshot/click/etc.) → session expired (rc=22)
  → invoke_with_retry (3-ii) detects + calls login --auto
  → driver detects 2FA (3-iv)
  → driver auto-replays TOTP via stored secret (4-iii)
  → fresh storageState captured
  → verb retried successfully
```

**Zero agent intervention** from one-time `creds-add` to repeated session-aware verb use.

### Phase 5 part 1 (cdt-mcp track) — FEATURE-COMPLETE

- 8 of 8 cdt-mcp verbs work real-mode against upstream MCP server. Stateless verbs (open / snapshot / eval / audit / inspect / extract) one-shot or daemon-routed; stateful verbs (click / fill) require daemon (refMap precondition).
- Daemon: long-lived MCP child + `eN ↔ uid` ref map + TCP loopback IPC. State at `${BROWSER_SKILL_HOME}/cdt-mcp-daemon.json`.
- Multi-call composition for inspect (list_console_messages + list_network_requests + take_screenshot + selector evaluate_script aggregated).
- Path B router promotion (capture-flags / audit / inspect / extract → cdt-mcp).
- Verb scripts surfaced (browser-audit / browser-extract; browser-inspect un-skipped).
- Chrome `--user-data-dir` passthrough for session loading.

### Phase 5 part 2 (creds track) — FEATURE-COMPLETE

5 verbs (`creds add` / `list` / `show` / `remove` / `migrate`), 3 Tier-1 backends (plaintext / macOS keychain / Linux libsecret), smart per-OS auto-detect, masked `--reveal` with typed-phrase confirmation, first-use plaintext gate.

### Phase 5 part 3 (auth track) — FEATURE-COMPLETE

- `login --auto` programmatic headless re-login from stored creds (AP-7 strict).
- `invoke_with_retry` helper wires transparent retry on `EXIT_SESSION_EXPIRED` into all 7 session-aware verbs.
- `--auth-flow STR` declaration at creds-add time + login --auto enforcement.
- 2FA detection in playwright-driver → exit 25 (`EXIT_AUTH_INTERACTIVE_REQUIRED`).

### Phase 5 part 4 (TOTP track) — FEATURE-COMPLETE

- `creds-add --enable-totp` foundation (forces keychain/libsecret backend; typed ack).
- `creds-totp` verb generates RFC 6238 codes via pure-node `totp-core.mjs` (zero deps; validated against all 5 RFC 6238 §A test vectors).
- `login --auto` auto-replays TOTP after `detect2FA` fires — driver imports `totpAt`, generates code, fills OTP field.
- `creds-rotate-totp` verb for service-forced re-enrollment.

### Tagged sub-part history (Phase 5)

| PR | Tag | What |
|---|---|---|
| #12 | `v0.6.0-phase-05-part-1-chrome-devtools-mcp` | cdt-mcp adapter (Path A — opt-in) |
| #14 | `v0.6.1-phase-05-part-1b-cdt-mcp-bridge` | bridge scaffold + lib-stub pivot |
| #15-#21 | `v0.7.0-v0.8.3` | credentials track (5 verbs + 3 backends) |
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
| #36 | `v0.19.0-phase-05-part-4-ii-totp-codegen` | TOTP code generation + secret persistence |
| #37 | `v0.20.0-phase-05-part-4-iii-totp-auto-replay` | login --auto TOTP auto-replay |
| #38 | `v0.21.0-phase-05-part-4-iv-rotate-totp` | creds rotate-totp verb (Phase 5 closer) |

### Counters

- **22 user-facing verbs**: doctor + 4 site verbs + use + 3 login modes + 3 session verbs + 7 cred verbs (add/list/show/remove/migrate/totp/rotate-totp) + 8 web verbs (open/snapshot/click/fill/inspect/audit/extract/eval).
- **3 of 4 adapters**: playwright-cli, playwright-lib, chrome-devtools-mcp (full real-mode + Path B). obscura → Phase 8.
- **3 of 3 Tier-1 credential backends**: plaintext, keychain (macOS), libsecret (Linux).
- **552 tests pass / 0 fail / lint exit 0** across all 3 tiers. CI green on macos-latest + ubuntu-latest.
- **38 PRs merged total** (24 in Phase 5).

## What's next: Phase 6 — bulk verbs

Per parent spec Appendix A, Phase 6 ships verbs that round out the interaction surface:
- `select` — pick option from a `<select>` element by ref + value/label/index.
- `press` — keyboard input (`Enter`, `Tab`, key combos like `Cmd+S`).
- `hover` — pointer hover by ref or selector (triggers reveal-on-hover UI).
- `drag` — pointer drag from src ref → dst ref. Often paired with `wait` for animation completion.
- `upload` — file input filling. Requires `<input type=file>` ref + a path.
- `wait` — explicit wait: `--selector` (element appears), `--state` (visible/hidden), `--timeout`. Complement to navigation auto-waits.
- `route` — request interception / mocking (cdt-mcp's network domain). Powers offline tests + flaky-API replay.
- `tab-*` — tab management: `tab-list`, `tab-switch`, `tab-close`. New for multi-tab flows.

Likely sequencing (based on dependency depth):
1. **`press` + `select`** — pure stateful keyboard/form ops, builds on existing `click`/`fill` daemon precedent. Smallest first sub-PR.
2. **`hover` + `wait`** — pointer/timing ops. Compose with click for menu interactions.
3. **`drag` + `upload`** — pointer ops with state transitions; uses Playwright's `dragTo` or CDT-MCP's `dispatch_mouse_event`. Upload is fs-touching → security review for path traversal.
4. **`route`** — request interception. Tier 4 capability (only cdt-mcp supports it natively); router rule needs new precedence.
5. **`tab-*`** — tab management. Daemon-side state additions.

Each sub-part likely 1 PR. Estimate: 8-10 PRs for Phase 6.

After Phase 6: Phases 7 (capture pipeline + sanitization), 8 (obscura adapter), 9 (flow runner), 10 (schema migration tooling).

Read parent spec at `docs/superpowers/specs/2026-04-27-browser-automation-skill-design.md` for full design + Appendix A verb table + Appendix B routing matrix.

## Workflow expectations (unchanged from prior HANDOFF)

- **TDD**: bats RED first → impl GREEN → lint → tag → push → PR → CI → squash-merge → reset main. Pattern is muscle-memory now (38 PRs merged).
- **One PR per part**. Tag `vX.Y.Z-phase-NN-part-…` on the feature branch before push.
- **Lint must exit 0** at all three tiers. Drift tier (autogen sync) means run `scripts/regenerate-docs.sh all` after any adapter capability change.
- **Token-efficient output spec** governs the bytes adapters emit: single-line JSON summary terminates every verb, `eN` element refs, files for heavy data, no secrets in argv (AP-7).
- **Privacy-canary pattern** (now 9+ instances): every credential-emitting verb gets a sentinel canary in its bats file's "NEVER includes secret" test. **Convergence threshold long met — `references/recipes/privacy-canary.md` is overdue.**
- **Defensive setup pattern**: bats files using keychain/libsecret stubs MUST `export KEYCHAIN_SECURITY_BIN="${STUBS_DIR}/security"` + `export LIBSECRET_TOOL_BIN="${STUBS_DIR}/secret-tool"` in `setup()`.
- **Cross-platform shell idioms**: GREP THE REPO FIRST. `stat -c '%a'` (GNU) precedes `stat -f '%Lp'` (BSD). See user-memory `feedback_grep_repo_for_idioms_first.md`.
- **Bash NUL-stdin**: `read -r -d ''` per chunk; `$(cat)` strips NULs. See user-memory `feedback_bash_nul_stdin.md`.
- **CI workflow** (`.github/workflows/test.yml`) runs on macos-latest + ubuntu-latest. macOS bash 5 is brew-installed; ubuntu uses `apt install bats jq`. CI does NOT install Playwright or chrome-devtools-mcp — driver real-mode tests are gated; bats coverage is via stubs.
- **Stub patterns shipped**: bash binary stubs (`tests/stubs/{playwright-cli,security,secret-tool}`); lib-stub mode (`BROWSER_SKILL_LIB_STUB=1`); protocol-speaking mock server (`tests/stubs/mcp-server-stub.mjs` for cdt-mcp transport — handles all 9 MCP tools used by the bridge).
- **Test-mode env vars** (production code paths gate on these for testability without real Chrome):
  - `BROWSER_SKILL_DRIVER_TEST_2FA=1` → driver short-circuits to exit 25 (3-iv prop test).
  - `BROWSER_SKILL_DRIVER_TEST_TOTP_REPLAY=1` → driver short-circuits to "totp-replayed" event with empty storageState (4-iii prop test).

## Overdue follow-ups (good docs/light tasks for warm-up)

- **`references/recipes/privacy-canary.md`** — write up the convergence pattern (9+ instances across credential / creds-* / login-auto / cdt-mcp daemon fill / creds-totp / creds-rotate-totp). Recipe doc.
- **`references/recipes/test-mode-env-var-hooks.md`** — document the pattern for adding production-code test-only env vars, when to use them, threat-model notes.
- **`references/recipes/totp-3-chunk-stdin.md`** — document the AP-7 NUL-mux pattern for multi-secret stdin (used by creds-add --totp-secret-stdin and login --auto with totp_enabled).

## When you start (next session)

1. `git checkout main && git pull --ff-only origin main`
2. Confirm tag is `v0.21.0-phase-05-part-4-iv-rotate-totp` and `bats tests/` reports 552 pass (or higher if local hangs on real-playwright e2e tests; CI is authoritative).
3. Pick a sub-part. Recommendation: **start Phase 6 with `press` + `select`** — pure stateful ops, builds on existing click/fill daemon precedent. Smallest first sub-PR; proves the Phase 6 pattern before tackling drag/upload/route. Alternative for warm-up: ship one of the overdue recipe docs (~30 LOC each).
4. Branch `feature/phase-06-part-N-…`. Plan-doc + RED bats + GREEN + lint + tag + PR + CI + squash-merge + reset main.

Start with: read CHANGELOG since `v0.21.0-phase-05-part-4-iv-rotate-totp` (the last tag) to confirm no in-flight work, then propose the next part's scope (option-table pattern: scope envelope + capability surface + test approach + tag) before coding. The user prefers "go for your recommendation" once the option-table is presented; default to the smallest reviewable PR that delivers user-visible value.
