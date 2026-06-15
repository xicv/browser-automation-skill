# browser-automation-skill

[![npm version](https://img.shields.io/npm/v/browser-automation-skill.svg)](https://www.npmjs.com/package/browser-automation-skill)
[![license](https://img.shields.io/npm/l/browser-automation-skill.svg)](LICENSE)
[![node](https://img.shields.io/node/v/browser-automation-skill.svg)](package.json)

**Drive a real browser from an AI coding agent — and turn flaky one-off automation into repeatable, auditable daily jobs.**

Works as a [Claude Code](https://claude.com/claude-code) skill, an OpenAI Codex plugin, or a standalone **MCP server** for any MCP-aware client. Under the hood it routes **45 verbs** (open, click, fill, snapshot, extract, audit, flow, …) across four browser backends — **chrome-devtools-mcp**, **playwright-cli**, **playwright-lib**, and **obscura** — and picks the cheapest one that supports each action. Credentials and sessions stay strictly local under `$HOME/.browser-skill/`.

> **Status — v0.75.0.** Stateful sessions, persistent CDP, real YAML flows, a per-archetype selector cache, full per-action telemetry, opt-in Webwright delegation, and doctor/readiness checks have all shipped. The bundled MCP server exposes 6 verbs over JSON-RPC; the full 45-verb CLI ships in the repo. 1,202 bats tests, green. Architecture: [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) · Contributing: [`CONTRIBUTING.md`](CONTRIBUTING.md).

---

## Why this exists

Browser agents are expensive and fragile for three structural reasons. This skill is built to attack all three:

| Problem | What usually happens | What this does |
|---|---|---|
| **Cost** | Every click re-asks an LLM "which element is this?" | Caches learned selectors per `(site, page-archetype, intent)`. Repeat actions dispatch at **zero LLM tokens**. |
| **State** | Each call spawns a cold browser; multi-step login → navigate → act falls apart | Persistent login **sessions** + a live browser **daemon** held across steps, so real workflows actually complete. |
| **Honesty** | "Success" means *the driver returned ok* — even when the page did nothing | Every action emits one telemetry event; the audit flags **`oblivious_success`** (driver ok, but your assertion failed) — the dominant invisible-error class for browser agents. |

The guiding idea: **a daily browser job should get more deterministic every time it runs.** The first run explores. The tenth run reuses a stored session, cached selectors, a replayable flow, and explicit post-conditions — cheap, fast, and verifiable.

## A real daily job

Say you log into an internal app every morning, upload a report, and confirm it landed.

```bash
# 1. Register the site + capture a logged-in session once
bash scripts/browser-add-site.sh --name myapp --url 'https://app.example.com'
bash scripts/browser-use.sh --set myapp
bash scripts/browser-login.sh --site myapp          # session stored locally, reused next time

# 2. Drive it — snapshot returns an accessibility tree with eN refs
bash scripts/browser-open.sh --url 'https://app.example.com/reports'
bash scripts/browser-snapshot.sh                    # → eN refs for click/fill/upload
bash scripts/browser-upload.sh --selector 'input[type=file]' --file ./report.pdf

# 3. Verify the outcome, not just the click — flips status to error if the toast never shows
BROWSER_STATS_EXPECT_TYPE=text \
BROWSER_STATS_EXPECT_MATCH=include \
BROWSER_STATS_EXPECT_VALUE='Upload complete' \
  bash scripts/browser-click.sh --selector 'button.submit'
```

Run it daily and it hardens itself: record the steps once (`browser-do record` / `flow record`), and later runs replay from cache, skip LLM ref-resolution, and assert the same business facts. `browser-stats report --pareto` tells you which steps are still flaky.

## Strategy — the route ladder

Pick the cheapest route that can both **complete** the task and **verify** the outcome. Full reference: [`references/routing-heuristics.md`](references/routing-heuristics.md).

| Task shape | Route | Why |
|---|---|---|
| Known, repeated action on a URL archetype | `browser-do` cache / `replay` | Zero-LLM-token dispatch of a learned selector |
| Known multi-step workflow | `flow run` / `replay` | Deterministic, templated, re-runnable |
| Simple, no-secret interaction | **MCP tools** | Lightweight; works from any MCP client |
| Login / secrets / stateful work | **local CLI verbs** | Secrets stay on disk + stdin, never MCP argv |
| Uncertain / debugging a broken page | `inspect` · `extract` · `audit` | Console + network + screenshot + Lighthouse evidence |
| Novel, no-auth, long-horizon task | `browser-delegate` (opt-in) | Offloads the agent loop to a secondary LLM, off your context |

Primitive verbs are routed by [`scripts/lib/router.sh`](scripts/lib/router.sh): storage-state work → `playwright-lib`; console/network/Lighthouse → `chrome-devtools-mcp`; multi-URL scrape / stealth → `obscura`; `--tool NAME` always overrides.

## Features

- **Sites · sessions · credentials.** Register sites; capture/restore Playwright `storageState`; store credentials in the macOS Keychain / Linux libsecret / plaintext-with-typed-confirmation; rotate TOTP secrets.
- **Navigation + interaction.** `open` · `snapshot` (eN-indexed accessibility tree) · `click`/`fill`/`hover`/`press`/`select`/`drag`/`upload` by `--ref eN` or `--selector CSS` · `wait` · `route` (network mock) · multi-tab (`tab-list`/`tab-switch`/`tab-close`).
- **Capture pipelines.** `inspect` aggregates console + network (sanitized HAR) + screenshot; `audit` runs Lighthouse. Captures persist under `~/.browser-skill/captures/<NNN>/` with auto-prune (default 500 captures / 14 days; baselines exempt).
- **Declarative flows.** `flow run task.flow.yaml` executes a YAML flow with `${var}` and `${refs.NAME}` templating; top-level `site:`/`session:` is inherited per step. `flow record` wraps `playwright codegen` (passwords become `${secrets.password}` placeholders, never literals). `replay <id>` re-runs a capture and emits a per-step diff.
- **Per-archetype selector cache.** `browser-do --intent "click delete" --pattern '/devices/:id'` looks up a cached selector for the `(site, archetype, intent)` triple and dispatches at zero LLM tokens on a hit. Self-healing: 4 consecutive failures disable a stale selector so the agent re-resolves and re-records.
- **5-tier cache rescue chain.** cached selector → fingerprint rescue → **local-VLM rescue** → cloud LLM → user fixup. The local-VLM tier (`bash scripts/browser-vlm.sh install-env`, one idempotent setup) asks a local model whether the cached element is still present before paying for the cloud.
- **Telemetry + balance-triangle audit.** Every adapter call emits one OTel-shaped JSONL event to `~/.browser-skill/memory/stats.jsonl`. `browser-stats report --pareto` rolls events into a route × verb table — success rate, post-condition hit rate, token-proxy bytes, p50 latency, cost, failure-mode histogram, and `oblivious_success` detection. `browser-stats prune` disables cache entries that keep silently failing; `browser-stats tune` surfaces the worst `(verb, route)` pairs. Schema follows OpenInference + OTel GenAI naming (Langfuse / Phoenix / Jaeger via OTLP). See [`references/browser-stats-cheatsheet.md`](references/browser-stats-cheatsheet.md).
- **MCP server.** `bash scripts/browser-mcp.sh serve` publishes 6 verbs (`open`/`snapshot`/`click`/`fill`/`extract`/`list-sites`) over JSON-RPC NDJSON (MCP 2024-11-05). Foreign secrets are filtered from env passthrough (AP-7); tabular output auto-flips to TOON (40–65% fewer tokens than JSON). See [`references/browser-mcp-cheatsheet.md`](references/browser-mcp-cheatsheet.md).
- **Webwright delegation (opt-in).** `browser-delegate` offloads a novel **no-auth** multi-step task to Webwright driven by a secondary LLM (e.g. GLM), so the observe-act-inspect token cost lands off your agent's context. Off by default, never router-selected, task text passed via a mode-0600 file — never argv. Bound runs with `--max-steps`. See [`references/browser-delegate-cheatsheet.md`](references/browser-delegate-cheatsheet.md).

## Security

- Credentials and sessions live only at `$HOME/.browser-skill/` (mode `0700` dir, `0600` files).
- Secrets never appear on argv, in `ps`, in git, or in the agent transcript — stdin-only (AP-7), enforced by `tests/argv_leak.bats`.
- Delegation is **no-auth only**: `browser-delegate` refuses any site that has stored credentials.
- Cache and flow writes refuse the `PASSWORD-CANARY` sentinel (privacy guard).
- `.gitignore` blocks every credential / session / capture / memory pattern; `.githooks/pre-commit` rejects anything that looks like a credential.
- Full threat model in [`SECURITY.md`](SECURITY.md).

## Requirements

**Always:** bash **≥ 5.0** (`brew install bash` — system 3.2 is too old), `jq`, `sqlite3`.

**At least one browser backend:**
- **chrome-devtools-mcp** (recommended, most complete): `npx -y chrome-devtools-mcp@latest`
- **playwright-cli**: `npm i -g playwright @playwright/test @playwright/cli && playwright install chromium`
- **playwright-lib**: `node` + `npm i -g playwright`
- **obscura** (single binary; scrape + stealth): [releases](https://github.com/h4ckf0r0day/obscura/releases)

**Tests:** `bats-core`. **Delegation (optional):** Webwright + an Anthropic-compatible key (e.g. GLM) — see [`references/webwright-setup.md`](references/webwright-setup.md).

`browser doctor` reports which backends are present and how to install the rest.

## Install

Three ways to use the project, smallest to largest surface:

### A — MCP server only (any MCP client, via npm)

```bash
# Smoke test with no install
printf '%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' \
  '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}' \
  | npx -y browser-automation-skill@latest serve
```

Wire into Claude Code (user scope — every project on the machine):

```bash
claude mcp add browser-skill --scope user -- npx -y browser-automation-skill@latest serve
claude mcp list   # → browser-skill: ... ✓ Connected
```

Wire into OpenAI Codex (shared by the Codex CLI and app/IDE):

```bash
codex mcp add browser-skill -- npx -y browser-automation-skill@latest serve
codex mcp list
```

Equivalent `~/.codex/config.toml`:

```toml
[mcp_servers.browser-skill]
command = "npx"
args = ["-y", "browser-automation-skill@latest", "serve"]
startup_timeout_sec = 20
tool_timeout_sec = 60
```

This exposes `browser_open`, `browser_snapshot`, `browser_click`, `browser_fill`, `browser_extract`, `browser_list-sites`. Pin a version (`@0.75.0`) for reproducibility. Other clients (Continue / Cline / midscene / Stagehand): add a stdio entry pointing at the same `serve` command.

> The MCP surface is a deliberate 6-verb subset. For the full 45-verb CLI + cache + flows + telemetry, install as a skill or plugin below.

### B — Codex plugin (skill + bundled MCP server)

```bash
codex plugin marketplace add xicv/browser-automation-skill
codex plugin add browser-automation-skill@browser-automation-skill
```

Or from a local checkout:

```bash
git clone https://github.com/xicv/browser-automation-skill ~/Projects/browser-automation-skill
cd ~/Projects/browser-automation-skill
codex plugin marketplace add .
codex plugin add browser-automation-skill@browser-automation-skill
```

Installs the plugin manifest, bundled skill, and MCP entry; Codex records enablement in `~/.codex/config.toml` so CLI and app/IDE share one setup.

### C — Claude Code skill (one machine, all your projects)

```bash
git clone https://github.com/xicv/browser-automation-skill ~/Projects/browser-automation-skill
cd ~/Projects/browser-automation-skill
./install.sh --with-hooks   # --with-hooks enables the credential-leak pre-commit blocker
```

Symlinks `~/.claude/skills/browser-automation-skill` → repo, creates `~/.browser-skill/` (mode `0700`), and runs `doctor`.

## Verify

In Claude Code: `/browser doctor` → exit 0, final line is a JSON summary with `"status":"ok"` and the installed-adapter list.

In Codex: `/mcp` shows the `browser-skill` server and `codex plugin list` shows the plugin enabled.

## Output contract

Every verb prints zero or more streaming JSON lines, then one final single-line JSON summary. Parse with `jq`; route on `.status` (`ok` · `partial` · `error` · `empty` · `aborted`).

```bash
$ bash scripts/browser-doctor.sh | tail -1 | jq .
{"verb":"doctor","tool":"none","why":"health-check","status":"ok","problems":0,"adapters_ok":4,"duration_ms":42}
```

## Project layout

```
install.sh / uninstall.sh   # preflight + state dir + symlink (+ opt hooks); state preserved on uninstall
SKILL.md                    # Claude Code skill manifest (verb table)
SECURITY.md                 # threat model + disclosure
scripts/                    # 45 verbs + 4 backend adapters + router + driver helpers + migrators
plugins/                    # Codex plugin wrapper (manifest, skill, MCP entry)
references/                 # routing-heuristics, cheatsheets, recipes, stats schema/prices
tests/                      # 1,202 bats tests; runs in <60s
docs/                       # architecture, design specs, per-phase plans, HANDOFF
```

## Roadmap

Design: `docs/superpowers/specs/2026-04-27-browser-automation-skill-design.md`. Executable plans: `docs/superpowers/plans/`. Current "what's next": `docs/superpowers/HANDOFF.md` (refreshed after every shipped PR).

Core (v1.2) is complete. Remaining work is opt-in hardening: pattern-equivalence canonicalization and `--auto-record` for the cache, playwright-lib selector-path daemon e2e, a strong-fingerprint capture mode, and an LLM-judge upgrade for the `semantic` post-condition matcher.
