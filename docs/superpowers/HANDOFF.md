Continue work on `browser-automation-skill` at `/Users/xicao/Projects/browser-automation-skill`. Read CLAUDE.md (if any), `SKILL.md`, and the most recent specs/plans under `docs/superpowers/specs/` and `docs/superpowers/plans/` before touching code.

## Where the project stands (as of 2026-05-03)

main is at tag `v0.9.1-phase-05-part-3-auto-relogin`. **Phase 1, Phase 2, Phase 3, Phase 4** are SHIPPED (see prior handoff). **Phase 5** is now substantially landed across 11 sub-parts (PR #14–#23):

- **Phase 5 part 1, 1b, 1c**: chrome-devtools-mcp adapter shipped Path A (opt-in via `--tool=`) → bridge scaffold (lib-stub mode) → real MCP stdio transport (initialize handshake + `tools/call` + `uid → eN` translation, stateless verbs only). 4 stateless verbs (`open` / `snapshot` / `eval` / `audit`) work end-to-end via the real upstream MCP server. 4 stateful verbs (`click` / `fill` / `inspect` / `extract`) exit 41 with hint pointing at part 1c-ii.
- **Phase 5 part 2a–2e**: credentials track is **feature-complete**. 5 verbs (`creds add` / `list` / `show` / `remove` / `migrate`), 3 Tier-1 backends (plaintext / macOS keychain via `security` / Linux libsecret via `secret-tool`), smart per-OS auto-detect, masked `--reveal` flow with typed-phrase confirmation, first-use plaintext gate uniformly enforced (`creds add` + `creds migrate`), doctor surface (advisory credentials count line). Privacy invariant tested with sentinel canaries on every credential-emitting verb.
- **Phase 5 part 3**: `login --auto` ships programmatic headless re-login from stored credentials. AP-7 strict (`account\0password` over stdin only). Best-effort form selectors handle common single-step username+password sites; non-standard sites fall back to `--interactive`.

### Tagged sub-part history

| PR | Tag | What |
|---|---|---|
| #12 | `v0.6.0-phase-05-part-1-chrome-devtools-mcp` | cdt-mcp adapter (Path A — opt-in) |
| #13 | (no tag, docs PR) | `references/adapter-candidates.md` — pinchtab declined, triggers documented |
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

### Counters

- **19 user-facing verbs**: `doctor`, `add-site` / `list-sites` / `show-site` / `remove-site`, `use`, `login` (interactive | storage-state-file | **--auto**), `list-sessions` / `show-session` / `remove-session`, `creds add` / `list` / `show` / `remove` / `migrate`, `open`, `snapshot`, `click`, `fill`, `inspect` (skipped — needs verb-side wiring in part 1e).
- **3 of 4 adapters**: `playwright-cli`, `playwright-lib`, `chrome-devtools-mcp` (Path A; real-mode for stateless verbs). `obscura` planned for Phase 8.
- **3 of 3 Tier-1 credential backends**: plaintext, keychain (macOS), libsecret (Linux). All wired into `lib/credential.sh`'s dispatcher (zero placeholder branches).
- **457 tests pass / 0 fail / lint exit 0** across all 3 tiers. CI green on macos-latest + ubuntu-latest.
- **23 PRs merged total** (11 in the 2026-05-03 session — 8 auth-track + 2 cdt-mcp track + 1 docs).

## Phase 5 remaining

Substantial work remains in the cdt-mcp track + Phase 5 parts 3-ii through 4. Likely sequence:

1. **Phase 5 part 1c-ii** — cdt-mcp daemon + `eN ↔ uid` ref persistence across calls. Without this, the 4 stateful verbs (`click` / `fill` / `inspect` / `extract`) exit 41 in real mode. Likely mirrors playwright-lib's IPC daemon precedent (Phase 4 part 4b). ~250 LOC node.
2. **Phase 5 part 1d** — Path B router promotion: `--capture-console` / `--capture-network` / `--lighthouse` / verb=`audit` / verb=`inspect` / verb=`extract` → cdt-mcp default per parent spec Appendix B. Small router edit + bats. Done after 1c-ii so promotion is meaningful.
3. **Phase 5 part 1e** — verb scripts: `scripts/browser-audit.sh`, `scripts/browser-extract.sh`; un-skip `tests/browser-inspect.bats`. Surface integration so the CLI exposes audit/extract/inspect without `--tool=`.
4. **Phase 5 part 1f** — Chrome `--user-data-dir` session loading for cdt-mcp (different mechanism from playwright-lib's storageState).
5. **Phase 5 part 3-ii** — transparent verb-retry on `EXIT_SESSION_EXPIRED` (parent spec §4.4: every verb call → silent re-login → retry, exactly one attempt). Wires into `verb_helpers::resolve_session_storage_state`. Compounds part 3's `login --auto` value: session expiry becomes invisible to the user.
6. **Phase 5 part 3-iii** — auth-flow detection at `creds add` time. Currently part 2d hardcodes `auth_flow: "single-step-username-password"`; observation at add time + persistence in metadata + replay at relogin time would harden against non-standard forms.
7. **Phase 5 part 3-iv** — 2FA detection → exit 25 (per parent spec §4.4).
8. **Phase 5 part 4** — TOTP. `--enable-totp` flag with typed-phrase confirmation; force-keychain (refuse plaintext); generates RFC 6238 codes via `oathtool` or a node port. `creds rotate-totp` verb.

After Phase 5: Phases 6 (bulk verbs: select / press / hover / drag / upload / wait / route / tab-*), 7 (capture pipeline + sanitization), 8 (obscura adapter), 9 (flow runner), 10 (schema migration tooling).

Read parent spec at `docs/superpowers/specs/2026-04-27-browser-automation-skill-design.md` for full design + Appendix A verb table + Appendix B routing matrix.

## Workflow expectations

- **TDD**: write the bats failing first, then impl, then green. Pattern is muscle-memory now: branch + plan-doc + RED + GREEN + lint + tag + push + PR + CI + squash-merge + reset main.
- **One PR per part** (23 PRs merged so far; that pattern works). Each PR small + reviewable + CI-green-first-try (95%+ this session). Tag `vX.Y.Z-phase-NN-part-…` on the feature branch before push so the merge commit on main + the tag both exist.
- **Lint must exit 0** at all three tiers. Drift tier (autogen sync) means run `scripts/regenerate-docs.sh all` after any adapter capability change.
- **Token-efficient output spec** (`docs/superpowers/specs/2026-05-01-token-efficient-adapter-output-design.md`) governs the bytes adapters emit: single-line JSON summary terminates every verb, `eN` element refs, files for heavy data (capture paths, never inline), no secrets in argv (AP-7).
- **Privacy-canary pattern** (now 6+ instances across credential / creds-add / creds-list / creds-show / creds-show-reveal-mismatch / creds-migrate / login-auto-dry-run): any verb that emits credential-related JSON gets a sentinel canary (`sekret-do-not-leak-XXX` style) in its bats file's "NEVER includes secret" test. Convergence threshold for documenting in `references/recipes/` once a 7th instance lands.
- **Defensive setup pattern**: any bats file that uses keychain or libsecret backends MUST `export KEYCHAIN_SECURITY_BIN="${STUBS_DIR}/security"` + `export LIBSECRET_TOOL_BIN="${STUBS_DIR}/secret-tool"` in `setup()`, NOT inline per-test. Rationale: a real `security add-generic-password` call on a macOS dev box without a default keychain pops a system dialog that hangs the test indefinitely (incident in part 2b's PR review). Setup-level export is the safety guarantee.
- **CI workflow** (`.github/workflows/test.yml`) runs on macos-latest + ubuntu-latest. macOS bash 5 is brew-installed; ubuntu uses `apt install bats jq`. CI does NOT install Playwright or chrome-devtools-mcp by default — driver real-mode tests are gated; bats coverage is via stubs (lib-stub for playwright + chrome-devtools-bridge; mock-MCP server for cdt-mcp transport tests).
- **Stub patterns shipped**: bash binary stubs (`tests/stubs/{playwright-cli,security,secret-tool}`); lib-stub mode (`BROWSER_SKILL_LIB_STUB=1` in playwright-driver + chrome-devtools-bridge); protocol-speaking mock server (`tests/stubs/mcp-server-stub.mjs` for cdt-mcp transport). Pick the right one based on what the test exercises.

## When you start

1. `git checkout main && git pull --ff-only origin main`
2. Read parent spec + the most recent CHANGELOG entries to confirm where Phase 5 stands.
3. Pick a sub-part (recommendation: **part 1c-ii** to unblock cdt-mcp stateful verbs, OR **part 3-ii** to make session expiry invisible). Write a focused plan at `docs/superpowers/plans/2026-05-03-phase-05-part-XX.md`.
4. Branch `feature/phase-05-part-XX-…`. Implement task-by-task. Open PR. CI green. Merge.

Start with: read CHANGELOG since `v0.9.1` (the last tag) to confirm no in-flight work, then propose the next part's scope (with the option-table pattern from prior sessions: scope envelope + capability surface + test approach + tag) before coding. The user prefers "go for your recommendation" once the option-table is presented; default to the smallest reviewable PR that delivers user-visible value.
