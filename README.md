# browser-automation-skill

[![npm version](https://img.shields.io/npm/v/browser-automation-skill.svg)](https://www.npmjs.com/package/browser-automation-skill)
[![license](https://img.shields.io/npm/l/browser-automation-skill.svg)](LICENSE)
[![node](https://img.shields.io/node/v/browser-automation-skill.svg)](package.json)

A [Claude Code](https://claude.com/claude-code) skill, OpenAI Codex plugin, **and MCP server** for driving real browsers from an LLM. **44 verbs + a per-action audit surface** routed across four tools (chrome-devtools-mcp / playwright-cli / playwright-lib / obscura), with a 5-tier cache defense chain (cached selector → fingerprint rescue → local-VLM rescue → cloud LLM → user fixup) that lets agents skip LLM ref-resolution on repeat actions and per-schema state migration tooling. Credentials and sessions stay strictly local under `$HOME/.browser-skill/`.

> **Status:** Phases 1–14 ✅ ALL COMPLETE. **Phase 14 (local-VLM cache rescue + auto-managed VLM stack + MCP server) ✅ shipped** — `scripts/browser-vlm.sh` wraps `llama-server` with idle-stop watchdog + lazy-start; `scripts/lib/visual-rescue-default.sh` is the canonical Path 3 probe (gated by `BROWSER_SKILL_VISION_FALLBACK=1`); `scripts/lib/node/mcp-server.mjs` publishes 6 verbs (open/snapshot/click/fill/extract/list-sites) over JSON-RPC NDJSON for external agents (auto-discovers TOOLS from adapter capabilities + `mcp-tools.json` allowlist); `browser-stats prune` closes the telemetry feedback loop by auto-detecting cache-pollution from `oblivious_success` clusters. **Production-ready v1.3.** Full bats: 1086/1086 green. Architecture map: [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md). New contributors: [`CONTRIBUTING.md`](CONTRIBUTING.md).
>
> **One-command enable Path 3 cache rescue:** `bash scripts/browser-vlm.sh install-env` (idempotent — appends env exports to `~/.zshrc`; lazy auto-start handles the rest).

## What it does

- **Sites + sessions + credentials.** Register sites; capture/restore Playwright `storageState`; store credentials in keychain (macOS) / libsecret (Linux) / plaintext-with-typed-confirmation; rotate TOTP shared secrets.
- **Navigation + interaction.** `open` · `snapshot` (eN-indexed accessibility tree) · `click`/`fill`/`hover`/`press`/`select`/`drag`/`upload` by `--ref eN` or `--selector CSS` · `wait` · `route` (network mock) · multi-tab (`tab-list`/`tab-switch`/`tab-close`).
- **Capture pipelines.** `inspect` aggregates console + network (sanitized HAR) + screenshot. `audit` runs Lighthouse. All captures persist under `~/.browser-skill/captures/<NNN>/` with `meta.json` + per-aspect files; auto-prune at retention thresholds (default: 500 captures / 14 days; baselines exempt).
- **Declarative flow runner.** `flow run task.flow.yaml` executes a YAML flow with `${var}` + `${refs.NAME}` templating. `flow record` wraps `playwright codegen` (password-canary write-side: `/password/i` becomes `${secrets.password}` placeholder; literal dropped). `replay <id>` re-executes a capture's steps + emits structured per-step diff. `history list/show/diff/clear` + `baseline save/list/remove` for managing the capture corpus.
- **Per-archetype memory cache (Phase 11).** `browser-do --intent "click delete" --pattern '/devices/:id'` looks up cached selector for the `(site, archetype, intent)` triple; on hit, dispatches the existing verb at zero LLM tokens; on miss, emits `cache_miss` event. `browser-do record` for explicit write-back. `browser-do propose` auto-clusters URLs into patterns. Self-heal: 4 consecutive failures disable the cached selector; agent re-resolves + re-records to heal.
- **Per-action telemetry + balance-triangle audit (Phase 12).** Every adapter call (`open`/`click`/`fill`/`snapshot`/`extract`) emits one OTel-shaped JSONL event to `~/.browser-skill/memory/stats.jsonl` (mode 0600). `browser-stats report --pareto` rolls events into a route × verb table: success rate, post-condition hit rate, token-proxy byte counts, p50 duration, $$ cost (when `CLAUDE_USAGE_*` env injected), 14-value failure-mode histogram (Phase-14 added `unknown_failure` catch-all), and **`oblivious_success` detection** (adapter said ok but post-condition assertion failed — the dominant invisible-error class for browser agents). `browser-stats tune` surfaces worst-performing `(verb, route)` candidates for `/autoresearch` handoff. **`browser-stats prune` (Phase 14)** closes the feedback loop: finds (site, selector) tuples with ≥3 `oblivious_success` events; `--apply` disables the matching cache interactions so cloud LLM re-derives. `browser-stats mark <span> success|fail[:reason]` records user overrides. Schema follows OpenInference + OTel GenAI v1.40 naming for forward-compat with Langfuse/Phoenix/Jaeger via OTLP exporter. See [`references/browser-stats-cheatsheet.md`](references/browser-stats-cheatsheet.md).
- **Local-VLM cache rescue (Phase 14, Path 3).** 5th tier in the cache defense chain — between Phase-13 fingerprint rescue and cloud-LLM fallback. When `BROWSER_SKILL_VISION_FALLBACK=1` + `BROWSER_SKILL_VISUAL_RESCUE_CMD=<path>` set, browser-do invokes an external hook that probes whether the cached element is still semantically present. Bundled canonical probe `scripts/lib/visual-rescue-default.sh` (text-mode v1) reads the accessibility-tree snapshot + asks a local OpenAI-compatible LLM (default `http://127.0.0.1:8080` — matches `bash scripts/browser-vlm.sh start`) yes/no. Smart-skip when `fail_count ≥ 3` (cache likely fundamentally broken; skip the probe). One env var pair via `bash scripts/browser-vlm.sh install-env` enables everything; lazy-start + 10-min idle-stop watchdog manage the llama-server lifecycle. See [`references/recipes/visual-rescue-hook.md`](references/recipes/visual-rescue-hook.md).
- **MCP server (Phase 14).** `bash scripts/browser-mcp.sh serve` publishes 6 verbs (open / snapshot / click / fill / extract / list-sites) over JSON-RPC NDJSON for external agents (Claude Code, OpenAI Codex, midscene, agent-browser, Stagehand, Continue, Cline). TOOLS auto-discovered from each adapter's `tool_capabilities()` + `scripts/lib/node/mcp-tools.json` allowlist — adding a verb to MCP is a 1-JSON-entry change. Env-var passthrough is whitelisted (AP-7: client's `OPENAI_API_KEY` and other foreign secrets are filtered; only `BROWSER_SKILL_*` / `MIDSCENE_MODEL_*` / `CLAUDE_*` / `PLAYWRIGHT_*` / etc inherit). `browser_fill` has no `secret` field and `additionalProperties: false` — secrets stay on the bash entry point via `--secret-stdin`. See [`references/browser-mcp-cheatsheet.md`](references/browser-mcp-cheatsheet.md).

## Security at a glance

- Credentials are on disk only at `$HOME/.browser-skill/` (mode 0700 dir, 0600 files).
- Credentials never appear on argv, in `ps`, in git, or in the agent transcript (AP-7 stdin-only pattern enforced via `tests/argv_leak.bats`).
- Cache writes refuse `PASSWORD-CANARY` sentinel (privacy guard in `browser-do record`).
- `.gitignore` blocks every credential / session / capture / memory pattern from the repo.
- `.githooks/pre-commit` rejects any staged file or diff that looks like a credential.
- See `SECURITY.md` for the full threat model + `references/recipes/{privacy-canary,cache-write-security,path-security}.md` for codified discipline.

## Requirements

**Skill itself (always required):**
- bash **≥ 5.0** (`brew install bash` on macOS — system bash 3.2 is too old; bash 5.0 needed for `$EPOCHREALTIME` fast path used by the Phase-12 telemetry emitter)
- `jq`
- `sqlite3` (Phase 12 — lazy-built SQLite mirror at `memory/stats.db`; standard on macOS and most Linux distros)

**For real browser flows (install at least one):**
- **chrome-devtools-mcp** (recommended; most-complete adapter): `npx -y chrome-devtools-mcp@latest`
- **playwright-cli**: `npm i -g playwright @playwright/test @playwright/cli && playwright install chromium`
- **playwright-lib**: requires `node` + `npm i -g playwright` (driver lazy-imports)
- **obscura** (single-binary; scrape + stealth-only): download from https://github.com/h4ckf0r0day/obscura/releases

**For tests:** `bats-core` (`brew install bats-core`)

`browser doctor` reports which adapters are present + install hints for missing ones.

## Install

You can use this project three ways: as an **MCP server** (works with MCP-aware clients such as Claude Code, OpenAI Codex, Continue, Cline, midscene, Stagehand, and agent-browser), as a full **Codex plugin** (bundled skill + MCP server), or as a full **Claude Code skill** (all 44 bash verbs + the cache + audit surface).

### Option A — MCP server only (via npm; any MCP client)

Zero-install via `npx`:

```bash
# One-off smoke test
printf '%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' \
  '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}' \
  | npx -y browser-automation-skill@latest serve
```

**Wire into Claude Code (user-scope — every project on the machine):**

```bash
claude mcp add browser-skill --scope user -- npx -y browser-automation-skill@latest serve
claude mcp list   # → browser-skill: ... ✓ Connected
```

**Wire into OpenAI Codex (shared by Codex CLI and the Codex app/IDE):**

```bash
codex mcp add browser-skill -- npx -y browser-automation-skill@latest serve
codex mcp list
```

Equivalent `~/.codex/config.toml` entry:

```toml
[mcp_servers.browser-skill]
command = "npx"
args = ["-y", "browser-automation-skill@latest", "serve"]
startup_timeout_sec = 20
tool_timeout_sec = 60
```

6 tools become available: `browser_open`, `browser_snapshot`, `browser_click`, `browser_fill`, `browser_extract`, `browser_list-sites`. Pin a version (`@0.72.0`) for reproducibility, or omit `@latest` to track the registry tip. Phase 12 (v0.72.0+) auto-flips MCP tool output to TOON format for tabular verbs (40-65% token savings vs JSON, +0.4pp LLM parse accuracy; spec: `docs/superpowers/specs/2026-05-22-toon-output-amendment.md`).

**Other MCP clients (Continue / Cline / midscene / Stagehand):** add a stdio entry pointing at `npx -y browser-automation-skill@latest serve`. Protocol: MCP 2024-11-05, NDJSON over stdio.

Optional global install (skip the `npx` warmup):

```bash
npm i -g browser-automation-skill
browser-automation-skill serve   # same as npx form
```

> **Note:** the MCP surface is intentionally a curated subset (6 verbs). For the full 44-verb CLI + cache + flow runner + telemetry, install as a skill (Option B or Option C).

### Option B — Full Codex plugin (skill + bundled MCP server)

From GitHub:

```bash
codex plugin marketplace add xicv/browser-automation-skill
codex plugin add browser-automation-skill@browser-automation-skill
```

From a local checkout:

```bash
git clone https://github.com/xicv/browser-automation-skill ~/Projects/browser-automation-skill
cd ~/Projects/browser-automation-skill
codex plugin marketplace add .
codex plugin add browser-automation-skill@browser-automation-skill
```

This installs the Codex plugin metadata from `plugins/browser-automation-skill/.codex-plugin/plugin.json`, the bundled skill from `plugins/browser-automation-skill/skills/browser-automation-skill/SKILL.md`, and the bundled MCP server from `plugins/browser-automation-skill/.mcp.json`. Codex stores plugin and MCP enablement in `~/.codex/config.toml`, so the CLI and app/IDE see the same setup.

### Option C — Full Claude Code skill (one machine, all your projects)

```bash
git clone https://github.com/xicv/browser-automation-skill ~/Projects/browser-automation-skill
cd ~/Projects/browser-automation-skill
./install.sh --with-hooks   # --with-hooks enables the credential-leak pre-commit blocker
```

Symlinks `~/.claude/skills/browser-automation-skill` → repo. Creates `~/.browser-skill/` mode 0700. Runs `doctor` at the end.

## Verify (in Claude Code)

```
/browser doctor
```

Expected: exit 0; final line is a JSON summary with `"status":"ok"`. Doctor also enumerates installed adapters.

## Verify (in Codex)

```
/mcp
/skills
codex plugin list
```

Expected: `/mcp` shows the `browser-skill` MCP server and `codex plugin list` shows `browser-automation-skill@browser-automation-skill` as installed and enabled. In `/skills`, Codex may list the bundled skill as `browser-automation-skill` or with its plugin-qualified name, `browser-automation-skill:browser-automation-skill`; it will not necessarily appear as a standalone directory under `~/.codex/skills`.

## Quickstart

```bash
# Register your first site
bash scripts/browser-add-site.sh --name myapp --url 'https://app.example.com'
bash scripts/browser-use.sh --set myapp

# Open + snapshot (uses chrome-devtools-mcp by default)
bash scripts/browser-open.sh --url 'https://app.example.com'
bash scripts/browser-snapshot.sh
# → emits aria_yaml + eN refs you can pass to click/fill/hover/etc.

# Click a ref
bash scripts/browser-click.sh --ref e3

# Or click by CSS (cacheable; required for browser-do cache dispatch)
bash scripts/browser-click.sh --selector 'button.delete'

# Phase 11 cache: record a learned selector once, dispatch zero-LLM-token thereafter
bash scripts/browser-do.sh record \
  --site myapp --intent "click delete" \
  --selector "button.delete" \
  --url 'https://app.example.com/devices/123'

bash scripts/browser-do.sh \
  --site myapp --verb click \
  --intent "click delete" \
  --pattern '/devices/:id'
# → cache hit; dispatches click; bumps success_count

# Phase 12 telemetry: every adapter call above emits one stats event automatically.
# Review the audit:
bash scripts/browser-stats.sh rebuild
bash scripts/browser-stats.sh report --days 7 --pareto

# Assert a post-condition so the audit can flag oblivious_success:
BROWSER_STATS_EXPECT_TYPE=url \
BROWSER_STATS_EXPECT_MATCH=include \
BROWSER_STATS_EXPECT_VALUE='/devices/123' \
  bash scripts/browser-open.sh --url 'https://app.example.com/devices/123'
```

## Output contract

Every verb prints zero or more streaming JSON lines, then ends with a single-line JSON summary. Parse with `jq`; route on `.status` (`ok`, `partial`, `error`, `empty`, `aborted`).

```bash
$ bash scripts/browser-doctor.sh | tail -1 | jq .
{"verb":"doctor","tool":"none","why":"health-check","status":"ok","problems":0,"adapters_ok":4,"duration_ms":42}
```

## Layout

```
install.sh              # preflight + state dir + symlink + (opt) hooks
uninstall.sh            # remove symlink (state preserved)
.agents/plugins/        # repo marketplace entry for Codex plugin install
.claude-plugin/         # legacy-compatible marketplace entry Codex can import
plugins/                # Codex plugin wrapper (manifest, skill, MCP entry)
SKILL.md                # Claude Code skill manifest (verb table; updated at every phase ship)
SECURITY.md             # threat model + disclosure
.gitignore              # blocks credential / session / capture / memory patterns
.githooks/pre-commit    # credential-leak blocker
scripts/                # 42 verbs + browser-stats + 7 lib/ + 4 lib/tool/ adapters + lib/node/ driver helpers + lib/fingerprint-rescue.js + lib/migrators/{memory,recent_urls,stats}
tests/                  # 1002 bats (25 new across Phases 12 + 13); runs in <60s
references/             # routing-heuristics + recipes (incl. fingerprint-rescue.md) + browser-stats-cheatsheet + stats-schema.json + stats-prices.json
docs/superpowers/       # design specs + per-phase plan-docs + HANDOFF.md
```

## Uninstall

```bash
./uninstall.sh
```

Removes the `~/.claude/skills/browser-automation-skill` symlink. State at `~/.browser-skill/` is preserved by default.

## Roadmap

See `docs/superpowers/specs/2026-04-27-browser-automation-skill-design.md` for the design and `docs/superpowers/plans/` for executable plans. Current "what's next" lives in `docs/superpowers/HANDOFF.md` (refreshed after every shipped PR).

**v1.2 work ✅ COMPLETE.** Remaining hardening (all opt-in, none blocking): Phase 11 v2 backlog A2-A6 (slug heuristic / `--auto-record` / pattern-equivalence canonicalization / `self_heal_history[]` audit trail / active observation `recent_urls.jsonl`); daemon e2e for playwright-lib selector path; press cache-scope decision codification; Phase 12 backlog (TOON output mode for tabular verbs, plugin-wrapper distribution shape, wire remaining 25 verbs to `stats_run_adapter_emit`); Phase 13 backlog (strong-fingerprint mode that captures dimensions at `browser-do record` time instead of parsing them out of the cached selector string; LLM-judge upgrade for the `semantic` post-condition matcher).
