# browser-automation-skill

A [Claude Code](https://claude.com/claude-code) skill for driving real browsers from an LLM. **42 verbs** routed across four tools (chrome-devtools-mcp / playwright-cli / playwright-lib / obscura), with a per-archetype memory cache that lets agents skip LLM ref-resolution on repeat actions and per-schema state migration tooling. Credentials and sessions stay strictly local under `$HOME/.browser-skill/`.

> **Status:** v1.5 — Phases 1–11 ✅ ALL COMPLETE. Phase 10 (schema migration tooling) ✅ shipped. **Phase 11 v2 ✅ FULLY SHIPPED**: events.jsonl writer (cache observability), `self_heal_history[]` audit trail, `--auto-record` proposal flag, pattern-equivalence canonicalization, slug clustering, `recent_urls.jsonl` passive observation log. End-to-end ROI loop closed (`browser-do --intent` → events.jsonl → `browser-doctor.sh` reports real cache-hit-rate). Selector-mode plumbing 3/4 verbs in `browser-do` cache dispatch (`[click fill hover select]`; press deferred). 11 recipes shipped (7 pattern + 4 agent-workflow). **Production-ready v1.5.**

## What it does

- **Sites + sessions + credentials.** Register sites; capture/restore Playwright `storageState`; store credentials in keychain (macOS) / libsecret (Linux) / plaintext-with-typed-confirmation; rotate TOTP shared secrets.
- **Navigation + interaction.** `open` · `snapshot` (eN-indexed accessibility tree) · `click`/`fill`/`hover`/`press`/`select`/`drag`/`upload` by `--ref eN` or `--selector CSS` · `wait` · `route` (network mock) · multi-tab (`tab-list`/`tab-switch`/`tab-close`).
- **Capture pipelines.** `inspect` aggregates console + network (sanitized HAR) + screenshot. `audit` runs Lighthouse. All captures persist under `~/.browser-skill/captures/<NNN>/` with `meta.json` + per-aspect files; auto-prune at retention thresholds (default: 500 captures / 14 days; baselines exempt).
- **Declarative flow runner.** `flow run task.flow.yaml` executes a YAML flow with `${var}` + `${refs.NAME}` templating. `flow record` wraps `playwright codegen` (password-canary write-side: `/password/i` becomes `${secrets.password}` placeholder; literal dropped). `replay <id>` re-executes a capture's steps + emits structured per-step diff. `history list/show/diff/clear` + `baseline save/list/remove` for managing the capture corpus.
- **Per-archetype memory cache (Phase 11).** `browser-do --intent "click delete" --pattern '/devices/:id'` looks up cached selector for the `(site, archetype, intent)` triple; on hit, dispatches the existing verb at zero LLM tokens; on miss, emits `cache_miss` event. `browser-do record` for explicit write-back. `browser-do propose` auto-clusters URLs into patterns. Self-heal: 4 consecutive failures disable the cached selector; agent re-resolves + re-records to heal.

## Security at a glance

- Credentials are on disk only at `$HOME/.browser-skill/` (mode 0700 dir, 0600 files).
- Credentials never appear on argv, in `ps`, in git, or in the Claude transcript (AP-7 stdin-only pattern enforced via `tests/argv_leak.bats`).
- Cache writes refuse `PASSWORD-CANARY` sentinel (privacy guard in `browser-do record`).
- `.gitignore` blocks every credential / session / capture / memory pattern from the repo.
- `.githooks/pre-commit` rejects any staged file or diff that looks like a credential.
- See `SECURITY.md` for the full threat model + `references/recipes/{privacy-canary,cache-write-security,path-security}.md` for codified discipline.

## Requirements

**Skill itself (always required):**
- bash ≥ 4 (`brew install bash` on macOS — system bash 3.2 is too old)
- `jq`
- `python3`

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
scripts/                # 42 verbs + 6 lib/ + 4 lib/tool/ adapters + lib/node/ driver helpers + lib/migrators/
tests/                  # 977 bats; runs in <60s
references/             # routing-heuristics + 11 recipes (7 pattern: cache-write-security, privacy-canary, path-security, body-bytes-not-body, model-routing, anti-patterns-tool-extension, add-a-tool-adapter; + 4 agent-workflow: login-then-scrape, incremental-pattern-discovery, flow-record-and-replay, cache-driven-bulk-operation)
docs/superpowers/       # design specs + per-phase plan-docs + HANDOFF.md
```

## Uninstall

```bash
./uninstall.sh
```

Removes the `~/.claude/skills/browser-automation-skill` symlink. State at `~/.browser-skill/` is preserved by default.

## Roadmap

See `docs/superpowers/specs/2026-04-27-browser-automation-skill-design.md` for the design and `docs/superpowers/plans/` for executable plans. Current "what's next" lives in `docs/superpowers/HANDOFF.md` (refreshed after every shipped PR).

**v1.5 work ✅ COMPLETE.** All Phase 11 v2 hardening shipped (A1-A6: events writer, self-heal audit trail, --auto-record, pattern canonicalization, slug heuristic, recent_urls log). Daemon e2e for playwright-lib selector path shipped (PR #129). Stage 4 part 1 agent-workflow recipes shipped (PR #131). Tier 3 papercut bundle shipped (PR #133: doctor `recent_urls` surface + `fill --selector` short-timeout).

**Next move (per HANDOFF):** Tier 4 7-day dogfood pause on a real site — measure cache hit rate (target ≥70%; useful ≥40%), wall-clock, token cost. Findings shape any further Tier 3 papercuts. Open opt-in items: `press` cache-scope decision; `click --selector` short-timeout (parallel to PR #133's `fill`); `browser-init` wizard; `browser-doctor --fix`. All speculative until dogfood data justifies them.
