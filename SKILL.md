---
name: browser-automation-skill
description: Drives a real browser from Claude Code by routing across four backends (chrome-devtools-mcp, playwright-cli, playwright-lib, obscura), so verbs like open/click/fill/scrape/inspect/audit pick the cheapest adapter that supports each operation. Persists credentials, sessions, captures, and per-action telemetry strictly local under $HOME/.browser-skill/ (mode 0700 dir, 0600 files); secrets never appear on argv, in git, or in the Claude transcript. Surfaces a balance-of-tokens-accuracy-latency audit via browser-stats.
when_to_use: User mentions a browser task — registering a site, capturing a session, verifying a page, filling a form, capturing console errors, running a lighthouse audit, scraping multiple URLs, debugging a UI bug iteratively, replaying a recorded flow, or auditing skill efficiency (browser-stats report/tune).
argument-hint: [verb] [--site NAME] [--session NAME] [--tool NAME] [--dry-run]
allowed-tools: Bash(bash *) Bash(jq *) Bash(chmod *) Bash(mkdir *) Bash(stat *) Bash(rm *) Bash(mv *) Bash(cat *) Bash(sqlite3 *) Bash(awk *) Bash(sed *) Bash(grep *) Bash(openssl *) Bash(date *) Bash(wc *) Bash(tr *) Bash(tail *) Bash(head *) Bash(sleep *) Bash(printf *) Bash(python3 *)
model: sonnet
effort: low
---

# browser-automation-skill

Drive a real browser from Claude Code via four routed tools (chrome-devtools-mcp / playwright-cli / playwright-lib / obscura). 42 verbs covering site/session/credential management, navigation, snapshot+ref-based interaction, capture pipelines (console/network/screenshot/Lighthouse), declarative flow runner with replay+diff, a per-archetype memory cache (`browser-do`) that lets agents skip LLM ref-resolution on repeat actions, and per-schema state migration tooling (`browser-migrate`).

## Verbs

### Site + session + credential management

| Verb | What it does | Example |
|---|---|---|
| `doctor`        | Health check: deps, state dir mode, disk encryption, adapters | `bash "${CLAUDE_SKILL_DIR}/scripts/browser-doctor.sh"` |
| `add-site`      | Register a site profile | `… add-site --name prod --url https://app.example.com` |
| `list-sites`    | List registered sites | `… list-sites` |
| `show-site`     | Show one site's profile JSON | `… show-site --name prod` |
| `remove-site`   | Typed-name confirmed delete | `… remove-site --name prod --yes-i-know` |
| `use`           | Get / set / clear current site | `… use --set prod` |
| `login`         | Capture a Playwright storageState into a session | `… login --site prod --as prod--admin --interactive` |
| `list-sessions` | List captured sessions (optionally filter by site) | `… list-sessions --site prod` |
| `show-session`  | Show session metadata (NEVER cookie/token values) | `… show-session --as prod--admin` |
| `remove-session`| Typed-name confirmed delete of a captured session | `… remove-session --as prod--admin --yes-i-know` |
| `creds-add`     | Register credential (smart per-OS backend; AP-7 stdin-only; declares `--auth-flow`) | `printf 'pw' \| … creds-add --site prod --as prod--admin --password-stdin --auth-flow single-step-username-password` |
| `creds-list`    | List credentials (optional `--site` filter; metadata only) | `… creds-list --site prod` |
| `creds-show`    | Show credential metadata (NEVER secret unless `--reveal` typed-phrase confirmed) | `… creds-show --as prod--admin` |
| `creds-remove`  | Typed-name confirmed delete | `… creds-remove --as prod--admin --yes-i-know` |
| `creds-migrate` | Move credential between backends (fail-safe ordering) | `… creds-migrate --as prod--admin --to keychain --yes-i-know` |
| `creds-totp`    | Generate current 6-digit TOTP code (RFC 6238) | `… creds-totp --as prod--admin` |
| `creds-rotate-totp` | Re-enroll TOTP shared secret (typed-phrase confirmed) | `printf '%s' NEW_BASE32 \| … creds-rotate-totp --as prod--admin --totp-secret-stdin --yes-i-know` |

### Navigation + interaction

| Verb | What it does | Example |
|---|---|---|
| `open`          | Open a URL in the picked browser adapter | `… open --url https://app.example.com` |
| `snapshot`      | Capture an `eN`-indexed accessibility snapshot | `… snapshot` |
| `click`         | Click element by `--ref eN` or `--selector CSS` | `… click --ref e3` |
| `fill`          | Fill input — `--text VALUE` or `--secret-stdin`; `--ref eN` or `--selector CSS` | `… fill --ref e3 --text "search query"` |
| `hover`         | Pointer hover — `--ref eN` or `--selector CSS` | `… hover --ref e5` |
| `press`         | Keyboard key (Enter, Tab, Cmd+S, etc.) — focused element | `… press --key Enter` |
| `select`        | Pick option from `<select>` — `--ref eN`/`--selector CSS` + `--value`/`--label`/`--index` | `… select --ref e7 --value US` |
| `drag`          | Drag from `--src-ref` to `--dst-ref` | `… drag --src-ref e3 --dst-ref e9` |
| `wait`          | Wait for selector / state | `… wait --selector .toast --state visible --timeout 5000` |
| `upload`        | Upload file to `<input type=file>` ref | `… upload --ref e2 --file path.png` |
| `route`         | Network mock / fulfill pattern | `… route --pattern '*/api/users' --status 200 --body '{}'` |
| `tab-list`      | List open tabs | `… tab-list` |
| `tab-switch`    | Switch active tab | `… tab-switch --to tab2` |
| `tab-close`     | Close a tab | `… tab-close --to tab2` |

### Stateful sessions — one persistent browser across verbs *and* adapters

Multi-step work on a logged-in site shares **one** persistent Chrome held by the playwright-lib daemon. Cookies, the DOM, and the open page survive across verbs — and across adapters: a `chrome-devtools-mcp` verb (`extract --eval`, `upload`, `press`, …) acts on the **same live page** a `playwright-lib` verb (`open`, `click`, `fill`) opened, because every adapter attaches to the daemon's Chrome over CDP.

- **Auto-start.** When a verb runs with a `--site` session active, the daemon starts automatically and its CDP endpoint is exported to every adapter — no manual step. Opt out with `BROWSER_SKILL_AUTOSTART_DAEMON=0`; start by hand with `daemon-start`.
- **Per-session isolation.** Each session (and each re-login) gets its own browser profile, keyed by the captured storageState — switching `--as` or re-logging in never reuses another session's cookies/localStorage.
- **Headed autostart.** The auto-started daemon is headless by default; set `BROWSER_SKILL_HEADED=1` to launch it headed.
- **Just run verbs in sequence** — each sees the prior step's state. No `flow` and no `curl` needed.
- **Never replay session cookies outside the browser** (e.g. `curl`). Captured cookies are bound to the browser context; out-of-browser replay bounces to the login page. Drive the live browser instead.
- **Cross-adapter refs (caveat).** `playwright-lib` (`eN`) and `chrome-devtools-mcp` (`uid`) use different ref namespaces. Selector/eval-based cdt verbs and one-shot cdt verbs attach to the shared browser automatically, but a `snapshot` taken by one adapter does **not** produce refs the other can use. For ref-based cdt verbs (`upload`/`select`/`hover`/`drag` by `--ref`), take the `snapshot` with the same adapter (`--tool chrome-devtools-mcp`) so the refs match, or use the selector/path form.
- One active session/daemon at a time (v1).

### Capture + extract + audit

| Verb | What it does | Example |
|---|---|---|
| `inspect`       | Page inspection — `--capture-console`, `--capture-network`, `--screenshot`, `--selector` (multi-flag aggregation; sanitized HAR + console; cdt-mcp real-mode) | `… inspect --capture-console --capture-network --capture` |
| `audit`         | Lighthouse / perf-trace audit (cdt-mcp real-mode) | `… audit --lighthouse` |
| `extract`       | Selector or JS extraction — `--selector CSS` / `--eval JS` (cdt-mcp); `--scrape u1 u2 ...` / `--stealth URL --eval EXPR` (obscura) | `… extract --selector .title` · `… extract --scrape https://a https://b --format json` |
| `assert`        | Assertion — `--selector` + `--text-contains` predicate | `… assert --selector .toast-success --text-contains "Saved"` |

### Flow runner

> Optional. With stateful sessions (see *Stateful sessions* above) sequential verbs already share one browser, so most flows are unnecessary — reach for `flow` only to declaratively replay/diff a recorded sequence.

| Verb | What it does | Example |
|---|---|---|
| `flow run`      | Execute a `.flow.yaml` file (declarative steps; `${var}` + `${refs.NAME}` templating; whole-flow capture); `--check` validates + prints plan without executing; `--continue-on-error` continues past failed steps (default: abort on first failure) | `… flow run task.flow.yaml --var url_path=/users` · `… flow run task.flow.yaml --check` |
| `flow record`   | Wrap `playwright codegen`; emit `.flow.yaml`; password-canary write-side | `… flow record --site prod --out task.flow.yaml` |
| `replay`        | Re-execute a capture's steps; structured per-step diff | `… replay 042 --strict` |
| `history list`  | Enumerate captures (newest first) | `… history list --limit 10` |
| `history show`  | Show one capture's meta + steps | `… history show 042` |
| `history diff`  | Diff two captures' step events | `… history diff 041 042` |
| `history clear` | Manual prune (`--keep N` / `--days D` / `--not-baseline`); honors `is_baseline:true` skip-rule | `… history clear --keep 100` |
| `baseline save` | Mark capture as baseline (`meta.is_baseline:true` + `baselines.json` entry) | `… baseline save 042 --as after-redesign` |
| `baseline list` | List named baselines | `… baseline list` |
| `baseline remove` | Remove baseline marker (capture dir untouched) | `… baseline remove after-redesign --yes-i-know` |

### Telemetry / audit / tuning (`browser-stats`)

| Verb | What it does | Example |
|---|---|---|
| `stats rebuild`  | Tail `memory/stats.jsonl` from cursor → upsert into `memory/stats.db`. Idempotent; builds schema on first run. | `bash scripts/browser-stats.sh rebuild` |
| `stats report`   | Human-readable per-route × verb summary: success rate, post-condition hit-rate, p50 token-proxy bytes, avg duration, failure-mode histogram, oblivious_success count, cost ($) when `CLAUDE_USAGE_*` env injected. `--pareto` adds composite efficiency score. | `bash scripts/browser-stats.sh report --days 7 --pareto` |
| `stats mark`     | User override: record `success` / `fail[:reason]` for one `span_id`. Audit-report applies overrides over self-reported outcomes. | `bash scripts/browser-stats.sh mark a1b2c3d4e5f6a7b8 fail:wrong_element_acted` |
| `stats tune`     | Surface worst-performing `(verb, route)` candidates over last N days for `/autoresearch` handoff. Human-in-loop — never auto-mutates the skill. | `bash scripts/browser-stats.sh tune --days 30` |

Per-action events are emitted automatically by `open`, `click`, `fill`,
`snapshot`, and `extract` (covering all 4 routes). Adding emission to a new
verb = 3 lines (see [`references/browser-stats-cheatsheet.md`](references/browser-stats-cheatsheet.md)).
Schema: [`references/stats-schema.json`](references/stats-schema.json) — follows
OpenInference + OTel GenAI v1.40 conventions for forward-compat with
Langfuse/Phoenix/Jaeger exporters.

### Memory cache (`browser-do`)

| Verb | What it does | Example |
|---|---|---|
| `do --intent`   | Look up cached selector for `(site, archetype, intent)`; on hit dispatch existing verb (zero LLM tokens); on miss emit `cache_miss` event | `… do --site prod --verb click --intent "click delete" --pattern '/devices/:id'` |
| `do record`     | Explicit cache write-back; auto-derives pattern + archetype-id; refuses `PASSWORD-CANARY` | `… do record --site prod --intent "click delete" --selector "button.delete" --url 'https://prod/devices/123'` |
| `do propose`    | Auto-cluster URLs into URL patterns (`:id`, `:uuid`); emits proposals for clusters >= threshold; suppresses already-known | `… do propose --site prod --threshold 3 --url 'https://x/devices/1' --url '...'` |

### Schema migration (`browser-migrate`)

| Verb | What it does | Example |
|---|---|---|
| `migrate check`         | Read-only — enumerate pending migrations (one `_kind:migration_needed` event per registered migrator with current schema_version == from). No lock acquired; safe to call any time (and `doctor` does). | `bash scripts/browser-migrate.sh check` |
| `migrate status`        | Echo current per-schema versions from `~/.browser-skill/versions.json`. Read-only. | `bash scripts/browser-migrate.sh status` |
| `migrate run`           | Apply registered migrators. Atomic-swap + automatic backup; refuses bump on JSON validation failure. Destructive: requires `--yes` flag OR interactive typed-phrase `migrate now`. `--schema NAME` narrows scope. PID-tracked lock prevents concurrent runs. | `bash scripts/browser-migrate.sh run --yes --schema memory` |
| `migrate rollback`      | Restore one schema from its most-recent backup. Requires `--schema NAME`. Destructive: requires `--yes` OR typed-phrase `migrate rollback <schema>`. | `bash scripts/browser-migrate.sh rollback --schema memory --yes` |
| `migrate clean-backups` | Prune old backups; keep newest `--keep N` per schema (default 5). Destructive: requires `--yes` OR typed-phrase `clean backups`. | `bash scripts/browser-migrate.sh clean-backups --keep 3 --yes` |

## Migration & schema evolution

Skill state (`~/.browser-skill/`) is versioned per-schema (`versions.json`). Each schema (sites / sessions / credentials / captures / baselines / memory / config) carries its own `schema_version`; migrating one doesn't touch the others. When the skill ships a schema bump, it lands a migrator under `scripts/lib/migrators/<schema>/v<from>_to_<to>.sh`; the migrator becomes pending on every machine until the user runs `browser-migrate run`.

Key invariants:
- **Doctor never auto-migrates.** It only surfaces pending count as a `warn:` line; user runs `browser-migrate run` explicitly.
- **Atomic-swap + automatic backup.** Each migrated file is backed up to `backups/<schema>/<basename>.bak.v<prior_version>` (mode 0600) before the migrator runs. JSON validation via `jq -e .` precedes the version bump; failure restores from backup.
- **Manual rollback.** Single-step `rollback --schema NAME` restores from the newest backup. Multi-version chains require multiple invocations.
- **Lock file** (`~/.browser-skill/.migrate.lock`) prevents concurrent runs; stale PID auto-cleared.

Today's only real migration is the no-op `memory v1_to_v2` identity bump (bumps `schema_version` from 1 to 2; no data shape change). Future per-schema migrators land case-by-case (~30 LOC + ~3 bats per new migrator).

`${CLAUDE_SKILL_DIR}` is the absolute path Claude Code injects when invoking the skill — symlink under `~/.claude/skills/`.

`${CLAUDE_SKILL_DIR}` is the absolute path that Claude Code injects when it
invokes the skill — it points at the symlink under `~/.claude/skills/`. Use it
in command examples so they work whether the user installed at `--user` or
`--project` scope.

## Agent-workflow recipes (end-to-end command sequences)

See [`references/recipes/agent-workflows/`](references/recipes/agent-workflows/README.md) for tutorial-shaped walkthroughs:

- [`login-then-scrape.md`](references/recipes/agent-workflows/login-then-scrape.md) — first task: register site, capture session, bulk scrape
- [`incremental-pattern-discovery.md`](references/recipes/agent-workflows/incremental-pattern-discovery.md) — passive observation → propose → cache-hit loop end-to-end
- [`flow-record-and-replay.md`](references/recipes/agent-workflows/flow-record-and-replay.md) — capture a manual interaction, replay, diff against baseline
- [`cache-driven-bulk-operation.md`](references/recipes/agent-workflows/cache-driven-bulk-operation.md) — 50+ actions at zero LLM tokens (ROI proof)

For pattern recipes (codified discipline: privacy-canary, path-security, cache-write-security, etc.) see [`references/recipes/`](references/recipes/).

**Stateful logged-in session — attach, interact, extract, all on one browser:**

```
# session already captured via `login`
… open    --site example-site --as example--admin --url https://app.example.com/dashboard
… fill    --site example-site --selector '#search' --text widget
… click   --site example-site --selector 'button[type=submit]'
… extract --site example-site --eval 'document.querySelector(".result-count")?.textContent'
# extract (chrome-devtools-mcp) reads the same page open/fill/click (playwright-lib) drove
```

## Tools

The skill routes verbs to one of these underlying tools (precedence is decided
by [router.sh](scripts/lib/router.sh); see [routing heuristics](references/routing-heuristics.md)
for the rules):

<!-- BEGIN AUTOGEN: tools-table — generated by scripts/regenerate-docs.sh -->
| Tool | Strengths | Cheatsheet |
|---|---|---|
| chrome-devtools-mcp | declares 18 verbs | [references/chrome-devtools-mcp-cheatsheet.md](references/chrome-devtools-mcp-cheatsheet.md) |
| obscura | declares 1 verbs | [references/obscura-cheatsheet.md](references/obscura-cheatsheet.md) |
| playwright-cli | declares 4 verbs | [references/playwright-cli-cheatsheet.md](references/playwright-cli-cheatsheet.md) |
| playwright-lib | declares 5 verbs | [references/playwright-lib-cheatsheet.md](references/playwright-lib-cheatsheet.md) |
<!-- END AUTOGEN: tools-table -->

## Before running anything

If `doctor` reports `~/.browser-skill` missing, run `./install.sh` (or
`./install.sh --with-hooks` for the credential-leak blocker).

`doctor` also surfaces (advisory; never fails):

- **Pending schema migrations** — `warn: N pending migration(s) — run 'browser-migrate check' for details`.
  Doctor never auto-migrates (MIG4 invariant from Phase 10 design); apply via `browser-migrate run`.
- **Memory cache hit-rate** — `ok: memory cache hit rate: X% (H/T events)` once
  `browser-do --intent` has run at least once (writer landed in Phase 11 v2 part 1;
  events.jsonl is lazy-created mode 0600 inside the mode-0700 memory dir).
  Cheapest daily ROI signal: high hit-rate = the cache is paying for itself; low/empty = repetition isn't compounding yet.

## Output contract

Every verb prints zero or more streaming JSON lines, then ends with a
single-line JSON summary. Parse with jq; route on `.status` (`ok`,
`partial`, `error`, `empty`, `aborted`).

```
$ bash scripts/browser-doctor.sh | tail -1 | jq .
{"verb":"doctor","tool":"none","why":"health-check","status":"ok","problems":0,"duration_ms":42}
```

## Storage layout

```
~/.browser-skill/                       # mode 0700
├── version                              # schema marker
├── config.json                          # mode 0600; retention thresholds
├── current                              # current site name (mode 0600, [personal])
├── baselines.json                       # mode 0600; named baseline registry (Phase 9)
├── playwright-lib-daemon.json           # running session daemon's pid + CDP endpoint
├── profiles/default/                    # persistent browser profile (cookies + localStorage) for the session daemon
├── sites/    <name>.json + .meta.json   # mode 0600 ([shareable])
├── sessions/ <name>.json + .meta.json   # mode 0600 ([PERSONAL — gitignored])
├── credentials/                         # Phase 5 (keychain / libsecret / plaintext)
├── captures/  <NNN>/                    # Phase 7 (snapshot.json, console.json, network.har, steps.jsonl, meta.json)
└── memory/    <site>/                   # Phase 11 ([PERSONAL — gitignored])
    ├── patterns.json                    # mode 0600; URL pattern → archetype-id
    └── archetypes/<id>.json             # mode 0600; cached interactions per archetype
```

## Delegation policy (browser-delegate — opt-in, OFF by default)

`browser-delegate` runs a whole multi-step task on a **secondary LLM** (GLM via Webwright), offloading the agent loop off Claude's context. It is **opt-in and `off` by default** — users without Webwright + a GLM key are unaffected.

Per-user preference lives in `$BROWSER_SKILL_HOME/config.json` (`.delegate`):

```bash
… browser-delegate.sh config get                 # resolved policy + availability
… browser-delegate.sh config set --mode auto      # off | ask | auto
… browser-delegate.sh config set --mode ask --min-steps 4 --exclude auth
```

Modes govern when **Claude** reaches for delegation (the CLI always works when invoked by hand):
- `off` (default): never auto-use delegation.
- `ask`: when a task looks suitable, propose delegation and wait for confirmation.
- `auto`: default to delegation for suitable tasks; fall back automatically otherwise.

**Claude — before choosing a browser approach, run `browser-delegate.sh config get` and honor it:**
- `available:false` or `mode:"off"` → primitive/cached verbs only.
- `mode:"ask"` + task *suitable* → propose delegation, await OK.
- `mode:"auto"` + task *suitable* → delegate.
- **Suitable** = novel (not a cached/replayable flow) AND multi-step (≳ `min_steps`) AND no-auth (delegate hard-refuses credentialed sites) AND not in `auto_exclude`.
- Otherwise (single-step, repeatable, or auth) → primitive/cached verbs (`open/click/fill/snapshot/do/replay`).

## Roadmap

See `docs/superpowers/specs/2026-04-27-browser-automation-skill-design.md` for
the full design and `docs/superpowers/plans/` for phase plans.
