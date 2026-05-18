# browser-automation-skill

A [Claude Code](https://claude.com/claude-code) skill for driving real browsers from an LLM. **42 verbs + a per-action audit surface** routed across four tools (chrome-devtools-mcp / playwright-cli / playwright-lib / obscura), with a per-archetype memory cache that lets agents skip LLM ref-resolution on repeat actions and per-schema state migration tooling. Credentials and sessions stay strictly local under `$HOME/.browser-skill/`.

> **Status:** Phases 1–13 ✅ ALL COMPLETE. Phase 10 (schema migration tooling) ✅ shipped. Phase 11 v2 part 1 (events.jsonl writer) ✅ shipped — end-to-end ROI loop is closed (`browser-do --intent` → events.jsonl → `browser-doctor.sh` reports real cache-hit-rate). Selector-mode plumbing 3/4 verbs in `browser-do` cache dispatch (`[click fill hover select]`; press deferred). **Phase 12 (per-action telemetry + balance-triangle audit) ✅ shipped** — `browser-stats` surface emits one OTel-shaped JSONL event per adapter call into `memory/stats.jsonl`, with a lazy SQLite mirror, post-condition asserter, `oblivious_success` detection, and `/autoresearch` handoff via `browser-stats tune`. **Phase 13 (pre-LLM fingerprint rescue tier) ✅ shipped** — on a cache-hit-then-fail, the skill scores live-DOM candidates by weak-fingerprint similarity (tag + classes + attrs Jaccard, threshold 0.70) BEFORE incrementing fail_count. If a candidate scores ≥ threshold AND the retry succeeds, the cache silently heals (selector overwritten, `self_heal_history[]` appended with `event:"rescued"`, dedicated `browser-do.fingerprint_rescue` event in stats audit). **Production-ready v1.2.**

## What it does

- **Sites + sessions + credentials.** Register sites; capture/restore Playwright `storageState`; store credentials in keychain (macOS) / libsecret (Linux) / plaintext-with-typed-confirmation; rotate TOTP shared secrets.
- **Navigation + interaction.** `open` · `snapshot` (eN-indexed accessibility tree) · `click`/`fill`/`hover`/`press`/`select`/`drag`/`upload` by `--ref eN` or `--selector CSS` · `wait` · `route` (network mock) · multi-tab (`tab-list`/`tab-switch`/`tab-close`).
- **Capture pipelines.** `inspect` aggregates console + network (sanitized HAR) + screenshot. `audit` runs Lighthouse. All captures persist under `~/.browser-skill/captures/<NNN>/` with `meta.json` + per-aspect files; auto-prune at retention thresholds (default: 500 captures / 14 days; baselines exempt).
- **Declarative flow runner.** `flow run task.flow.yaml` executes a YAML flow with `${var}` + `${refs.NAME}` templating. `flow record` wraps `playwright codegen` (password-canary write-side: `/password/i` becomes `${secrets.password}` placeholder; literal dropped). `replay <id>` re-executes a capture's steps + emits structured per-step diff. `history list/show/diff/clear` + `baseline save/list/remove` for managing the capture corpus.
- **Per-archetype memory cache (Phase 11).** `browser-do --intent "click delete" --pattern '/devices/:id'` looks up cached selector for the `(site, archetype, intent)` triple; on hit, dispatches the existing verb at zero LLM tokens; on miss, emits `cache_miss` event. `browser-do record` for explicit write-back. `browser-do propose` auto-clusters URLs into patterns. Self-heal: 4 consecutive failures disable the cached selector; agent re-resolves + re-records to heal.
- **Per-action telemetry + balance-triangle audit (Phase 12).** Every adapter call (`open`/`click`/`fill`/`snapshot`/`extract`) emits one OTel-shaped JSONL event to `~/.browser-skill/memory/stats.jsonl` (mode 0600). `browser-stats report --pareto` rolls events into a route × verb table: success rate, post-condition hit rate, token-proxy byte counts, p50 duration, $$ cost (when `CLAUDE_USAGE_*` env injected), 13-value failure-mode histogram, and **`oblivious_success` detection** (adapter said ok but post-condition assertion failed — the dominant invisible-error class for browser agents). `browser-stats tune` surfaces worst-performing `(verb, route)` candidates for `/autoresearch` handoff. `browser-stats mark <span> success|fail[:reason]` records user overrides. Schema follows OpenInference + OTel GenAI v1.40 naming for forward-compat with Langfuse/Phoenix/Jaeger via OTLP exporter. See [`references/browser-stats-cheatsheet.md`](references/browser-stats-cheatsheet.md).

## Security at a glance

- Credentials are on disk only at `$HOME/.browser-skill/` (mode 0700 dir, 0600 files).
- Credentials never appear on argv, in `ps`, in git, or in the Claude transcript (AP-7 stdin-only pattern enforced via `tests/argv_leak.bats`).
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

### Personal (one machine, all your projects)

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
