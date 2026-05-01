Continue work on `browser-automation-skill` at `/Users/xicao/Projects/browser-automation-skill`. Read CLAUDE.md (if any), `SKILL.md`, and the most recent specs/plans under `docs/superpowers/specs/` and `docs/superpowers/plans/` before touching code.

## Where the project stands (as of 2026-05-01)

main is at tag `v0.5.2-phase-04-part-4e-session-crud`. Phase 1 (foundation), Phase 2 (sites + sessions), Phase 3 (adapter extension model + 5 sibling verbs + token-efficient output spec + autogen + 3-tier lint), Phase 4 (real Playwright via two adapters: `playwright-cli` binary path + `playwright-lib` node-bridge with IPC daemon + interactive login + full session CRUD) are SHIPPED.

- **14 user-facing verbs**: `doctor`, `add-site` / `list-sites` / `show-site` / `remove-site`, `use`, `login` (interactive + storage-state-file modes), `list-sessions` / `show-session` / `remove-session`, `open`, `snapshot`, `click`, `fill`, `inspect` (currently skipped — no adapter declares it yet; that's Phase 5 work).
- **2 adapters**: `scripts/lib/tool/playwright-cli.sh` (shells to `playwright-cli` binary), `scripts/lib/tool/playwright-lib.sh` (node-bridge to `scripts/lib/node/playwright-driver.mjs`).
- **IPC daemon** (TCP loopback) lets snapshot/click/fill share state across separate node-driver invocations.
- **274 tests pass / 0 fail / lint exit 0 / CI green on macos-latest + ubuntu-latest**. Three lint tiers: static (function presence, file-size cap, no `cd` at scope), dynamic (metadata schema, name<->filename, abi sync), drift (autogen sync, every-adapter-sources-output.sh).
- **Multi-session 1→many model** is shipped: a site can have many sessions (`prod--admin`, `prod--readonly`, `prod--ci`); `meta.site` binds session→site; `list-sessions --site` filters.

## Phase 5 scope (per parent spec deferred list)

Substantial — split into parts. Likely sequence:

1. **Phase 5 part 1 — chrome-devtools-mcp adapter.** Implement `scripts/lib/tool/chrome-devtools-mcp.sh` per the existing Phase-3 ABI. Declares `inspect`, `audit`, `extract` (network capture), and capture-flag variants of existing verbs. Routing rules promote it for `inspect`/`audit` and for `--capture-console`/`--capture-network`. Likely needs an MCP-client transport (stdio or http) since `chrome-devtools-mcp` runs as an MCP server. Stub-mode mirrors playwright-cli/playwright-lib pattern. Test with the existing 3-tier lint.

2. **Phase 5 part 2 — credentials vault (Tier 1).** macOS Keychain (`security` CLI) + libsecret on Linux + plaintext-warned-and-confirmed fallback. Smart per-OS default per parent spec §1. New verbs: `creds add` / `creds list` / `creds show` / `creds remove`. Storage at `${BROWSER_SKILL_HOME}/credentials/` for the plaintext fallback (mode 0600); keyring entries on the OS-vault path. Migration command surfaces the choice clearly.

3. **Phase 5 part 3 — auto-relogin.** When session is `EXIT_SESSION_EXPIRED`, the auto-retry policy (parent spec §1: "exactly one auto-retry, only on the session-expired-with-credential case") kicks in. Headless Playwright login flow scripted from credentials. Refuse for sites without an adapter that supports it.

4. **Phase 5 part 4 — TOTP.** `--enable-totp` flag with typed-phrase confirmation; force-keychain (refuse plaintext); generates RFC 6238 codes via `oathtool` or a node port.

Read parent spec at `docs/superpowers/specs/2026-04-27-browser-automation-skill-design.md` before scoping. The `references/recipes/add-a-tool-adapter.md` Path A checklist is the canonical recipe for Phase 5 part 1.

## Workflow expectations

- **TDD**: write the bats failing first, then impl, then green. Phase 1+ already establishes the helpers (`tests/helpers.bash`, `setup_temp_home`, `assert_status`, `assert_output_contains`).
- **One PR per part** (10 PRs done so far; that pattern works). Commit + tag (`vX.Y.Z-phase-NN-part-…`) + push + open PR + wait for CI green + merge with `--squash --delete-branch` + reset main + branch fresh.
- **Lint must exit 0** at all three tiers. Drift tier (autogen sync) means run `scripts/regenerate-docs.sh all` after any adapter capability change.
- **Token-efficient output spec** (`docs/superpowers/specs/2026-05-01-token-efficient-adapter-output-design.md`) governs the bytes adapters emit: single-line JSON summary terminates every verb, `eN` element refs, files for heavy data (capture paths, never inline), no secrets in argv (AP-7).
- **CI workflow** (`.github/workflows/test.yml`) runs on macos-latest + ubuntu-latest. macOS bash 5 is brew-installed; ubuntu uses `apt install bats jq`. CI does NOT install Playwright by default — playwright-lib daemon e2e tests skip via `command -v playwright` check in `setup_file()`.

## When you start

1. `git checkout main && git pull --ff-only origin main`
2. Read parent spec + the most recent CHANGELOG entries to confirm Phase-4 is closed.
3. Decide Phase 5 part 1 scope (chrome-devtools-mcp adapter). Write a focused plan at `docs/superpowers/plans/2026-05-01-phase-05-part-1-chrome-devtools-mcp.md`.
4. Branch `feature/phase-05-part-1-chrome-devtools-mcp`. Implement task-by-task. Open PR. CI green. Merge.

Start with: read the parent spec sections that mention `chrome-devtools-mcp` (use `grep -n "chrome-devtools" docs/superpowers/specs/*.md`) plus the routing matrix at parent spec §13.4. Then propose the plan before coding.
