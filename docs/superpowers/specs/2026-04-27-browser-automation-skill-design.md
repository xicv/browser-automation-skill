# browser-automation-skill — Design Spec

| Field | Value |
|---|---|
| Status | Draft for review |
| Author | xicao |
| Date | 2026-04-27 |
| Spec ID | 2026-04-27-browser-automation-skill-design |
| Reference skill | `https://github.com/xicv/mqtt-skill` (proven structural template) |
| Successor | This spec → implementation plan via `superpowers:writing-plans` |

---

## 0. Purpose & motivating workflows

A Claude Code skill that gives an LLM a thin, opinionated, locally-secure way to drive a real browser for daily developer tasks: smoke-verifying deploys, debugging via the iterative *capture → root-cause → fix → verify* loop, perf/lighthouse audits, multi-step interactive automation (form fills, submits, notifications), bulk extraction, and unattended cron-driven checks.

The skill is a thin orchestrator: it routes a task verb to one of four upstream tools (Chrome DevTools MCP, Playwright CLI, Playwright lib, Obscura), normalizes their output into a uniform JSON contract, and persists everything under `~/.browser-skill/` (or a project-scoped equivalent) — never online, never in argv, never in the repo.

### Daily workflows the skill must serve

| Workflow | Manual time | With this skill | Saves |
|---|---|---|---|
| Morning health check across N internal tools | 20–30 min | `/browser flow run morning.flow.yaml` → LLM flags exceptions | ~25 min |
| Post-commit verify ("did my last change break X?") | 4–8 min/cycle | `/browser verify --baseline prod-good --site preview` | ~6 min/cycle |
| Reproduce a user's bug | 5–15 min | `/browser flow record` once → `/browser flow run repro.flow.yaml` | ~10 min/repro after first run |
| UI/CSS regression sweep | 10–20 min | `/browser flow run visual-sweep.flow.yaml` → ImageMagick diffs | ~15 min |
| Backend-change form-fill testing | 5+ min/iter | warm session + `fill → click → inspect` | ~5 min/iter |

The transformation isn't "Claude clicks faster than me" — it's that **Claude reads structured DevTools data faster than a developer can mentally parse a rendered page**. The skill turns the browser into a structured data source the LLM can query.

---

## 1. Locked-in decisions (the design's invariants)

| Decision | Choice | Rationale |
|---|---|---|
| Scope | All four canonical tasks + the iterative debugging loop | User confirmed; loop is the centerpiece |
| Profile model | Site profiles + Playwright storageState sessions | Decouples stable site metadata from volatile auth |
| Verb shape | Task-focused; LLM auto-routes via centralized dispatcher | Mirrors MQTT skill's `get`/`check`/`pub`/`sub` |
| Routing strategy | Centralized `lib/router.sh` decision table; `--tool=X` always wins | Single source of truth; unit-testable in isolation |
| Cleanup | 14-day age cap + 500-count cap; oldest-first prune; sessions never auto-deleted | Bounded disk; user controls what survives |
| Install policy | Verify-only with copy-paste hints; no auto-install | Matches MQTT skill; respects user package-manager choice |
| Default browser mode | Headless; `--headed` for debugging; `login` overrides to headed | Speed + suitability for unattended runs |
| Distribution v1 | Git clone + `./install.sh` (MQTT pattern); plugin manifest deferred to v2 | Simple iteration; plugin layout-compatible later |
| Languages | Bash + one ~80-line plain-ESM Node helper for Playwright lib path & flow runner | Right tool for orchestration; one helper for the 5% bash can't do |
| Credential storage tiers | Tier 0: storageState only (default — no credential vault). Tier 1+2: opt-in vault for unattended re-login. | Three explicit choices, smart per-OS default, never silent |
| Backend default (when Tier 1+2 chosen) | Smart per-OS: Keychain on macOS, libsecret on Linux+systemd, plaintext + warn elsewhere | Always print the choice + migration command |
| TOTP | Ship the feature; `--enable-totp` flag + typed-phrase confirmation; force keychain (refuse plaintext) | Otherwise unattended runs against 2FA tools impossible |
| Financial-site protection | Editable `blocklist.txt` + typed-phrase override; warn-and-confirm, never hard-block | Blocks accidents; doesn't paternalize determined users |
| Auto-retry policy | Exactly one auto-retry, only on the session-expired-with-credential case | Generous retries hide real failures |
| Capture sanitization | Default ON: redact `Authorization` / `Set-Cookie` / API-key URL params from HARs and console; `--unsanitized` typed-phrase opt-out | HARs and screenshots are the sneakiest leak vectors |
| Disk-encryption check | `doctor` warns when FileVault / LUKS isn't on | The skill's `0600` mode is paper without disk encryption |

---

## 2. Architecture

### 2.1 High-level shape

The skill is a Bash CLI that wraps four browser-automation tools behind task-focused verbs. The LLM (Claude Code) calls verbs; each verb consults a centralized router to pick the right tool, runs it via a per-tool adapter, writes captures and a single-line JSON summary, and exits.

```
                              ┌─────────────────────────────────┐
  Claude (LLM) ──── /browser  │  SKILL.md  (verbs + contracts)  │
                              └────────────────┬────────────────┘
                                               │ bash
                              ┌────────────────▼────────────────┐
                              │  scripts/browser-<verb>.sh      │
                              └────────────────┬────────────────┘
                                               │ pick_tool()
                              ┌────────────────▼────────────────┐
                              │  scripts/lib/router.sh          │  ◄── tested in isolation
                              │  (single decision table)        │
                              └────────────────┬────────────────┘
                                               │ source lib/tool/<tool>.sh
                  ┌────────────────────────────┼─────────────────────────────┐
        ┌─────────▼────────┐ ┌──────▼─────────┐ ┌▼─────────────────┐ ┌──────▼──────┐
        │ chrome-devtools- │ │ playwright-cli │ │ playwright-lib   │ │ obscura     │
        │ mcp adapter      │ │ adapter        │ │ (node) adapter   │ │ adapter     │
        └─────────┬────────┘ └──────┬─────────┘ └────────┬─────────┘ └──────┬──────┘
                  └─────────────────┴────────────────────┴──────────────────┘
                                               │
                              ┌────────────────▼────────────────┐
                              │  $HOME/.browser-skill/          │ mode 0700
                              │   (or <project>/.browser-skill/)│
                              └─────────────────────────────────┘
```

### 2.2 Three orthogonal contracts

1. **CLI contract** — every verb takes `[--site NAME] [--tool NAME] [--session NAME] [--dry-run] [--headed|--headless]` plus verb-specific flags.
2. **Output contract** — zero-or-more streaming JSON lines, then a final single-line JSON summary with `verb`, `tool`, `why`, `status`, `duration_ms`, `capture_id?`.
3. **Filesystem contract** — `~/.browser-skill/{sites,sessions,credentials,captures,flows,baselines.json,blocklist.txt,config.json,current,version}` with strict modes; `.gitignore` blocks accidental commits.

These three contracts are independent. Adapters can change without touching verbs; routing rules can change without touching adapters; on-disk schema can change without breaking the CLI surface (schema_version field gates migrations).

### 2.3 Repository layout

```
browser-automation-skill/
├── install.sh                     # preflight + symlink (+ optional git hooks); supports --user / --project
├── uninstall.sh                   # mirror; preserves state by default
├── README.md                      # install + first-5-min walkthrough
├── SKILL.md                       # source of truth for verbs/flags, < 500 lines
├── SECURITY.md                    # threat model + disclosure
├── CONTRIBUTING.md                # repo tour + 5 recipes + test conventions + PR process
├── CHANGELOG.md                   # tagged: [feat|fix|security|adapter|schema|breaking|upstream|internal]
├── .gitignore                     # blocks sessions/captures/keys/.env/*.creds.json
├── .githooks/pre-commit           # credential-leak blocker
├── .github/
│   └── PULL_REQUEST_TEMPLATE.md   # change type / recipe / security-tests / docs / verified-locally
├── scripts/
│   ├── browser-doctor.sh
│   ├── browser-site.sh            # add / list / show / remove
│   ├── browser-use.sh             # set / show current site
│   ├── browser-credential.sh      # add / list / show / remove / migrate / rotate-totp
│   ├── browser-relogin.sh         # force re-running auto-login
│   ├── browser-login.sh           # one-time storageState capture (always headed)
│   ├── browser-open.sh
│   ├── browser-snapshot.sh
│   ├── browser-click.sh           # + dblclick (sub-mode)
│   ├── browser-fill.sh            # + type
│   ├── browser-select.sh          # + check / uncheck (sub-modes)
│   ├── browser-press.sh           # + hotkey
│   ├── browser-hover.sh           # + drag
│   ├── browser-upload.sh          # + download
│   ├── browser-wait.sh
│   ├── browser-eval.sh
│   ├── browser-route.sh
│   ├── browser-tab.sh             # tab-list / tab-new / tab-close / tab-select
│   ├── browser-inspect.sh         # console + network + screenshot snapshot
│   ├── browser-verify.sh          # assert + diff vs baseline
│   ├── browser-audit.sh           # lighthouse + perf trace (CDT-MCP)
│   ├── browser-extract.sh         # selector / eval / multi-URL scrape
│   ├── browser-flow.sh            # run / record sub-modes
│   ├── browser-replay.sh
│   ├── browser-history.sh         # list / show / diff / clear
│   ├── browser-baseline.sh        # save / list / remove (named blessed captures)
│   ├── browser-report.sh          # markdown digest of recent captures
│   ├── browser-clean.sh           # prune captures by age + count
│   ├── install-git-hooks.sh
│   └── lib/
│       ├── common.sh              # paths, modes, logging, summary writer, exit codes (readonly),
│       │                            BROWSER_SKILL_HOME walk-up resolver
│       ├── site.sh                # site profile read/write + template
│       ├── session.sh             # storageState read/write + expiry probe + origin binding
│       ├── credential.sh          # credential record read/write + backend dispatcher
│       ├── login_detect.sh        # session-expired heuristic + form auto-detection
│       ├── capture.sh             # next_capture_id + meta.json + retention
│       ├── sanitize.sh            # HAR / console / DOM redactor (jq-based)
│       ├── schema-migrate.sh      # per-schema migrators (idempotent, additive only)
│       ├── router.sh              # pick_tool VERB ARGS → "tool why"
│       ├── route_explain.sh       # debug helper for "why did router pick X?"
│       ├── mask.sh                # credential masking for show-* verbs
│       ├── secret/
│       │   ├── plaintext.sh
│       │   ├── keychain.sh        # macOS Security framework
│       │   └── libsecret.sh       # Linux Secret Service
│       ├── tool/
│       │   ├── chrome-devtools-mcp.sh
│       │   ├── playwright-cli.sh
│       │   ├── playwright-lib.sh   # shells to lib/node/playwright-driver.mjs
│       │   └── obscura.sh
│       └── node/
│           ├── playwright-driver.mjs   # ~80 LOC, plain ESM, no package.json
│           └── flow-runner.mjs         # ~120 LOC, plain ESM
├── references/
│   ├── routing-heuristics.md
│   ├── playwright-cli-cheatsheet.md
│   ├── chrome-devtools-mcp-tools.md
│   ├── obscura-cheatsheet.md
│   ├── storage-state-schema.md
│   ├── auth-flows.md
│   ├── credential-storage.md
│   ├── debugging-loop-recipes.md
│   ├── exit-codes.md
│   ├── installation.md
│   ├── tool-versions.md
│   ├── security.md
│   ├── architecture-tour.md       # codebase reading order: common → router → adapter → verb
│   ├── why-bash.md                # defends language choice with concrete trade-offs
│   ├── limits.md
│   └── recipes/
│       ├── add-a-verb.md
│       ├── add-a-tool-adapter.md
│       ├── change-a-routing-rule.md
│       ├── migrate-an-on-disk-schema.md
│       └── update-an-upstream-tool-version.md
├── examples/
│   ├── morning-check.flow.yaml
│   ├── post-commit-verify.flow.yaml
│   ├── reproduce-bug-template.flow.yaml
│   ├── visual-regression.flow.yaml
│   ├── form-fill-template.flow.yaml
│   └── README.md
└── tests/
    ├── helpers.bash
    ├── stubs/                              # mock binaries for adapter contract tests
    │   ├── playwright-cli
    │   ├── npx
    │   └── obscura
    ├── fixtures/
    │   ├── playwright-cli/                 # JSON responses keyed by argv hash
    │   ├── chrome-devtools-mcp/
    │   ├── obscura/
    │   └── dummy-server/server.mjs         # 50-line Express for e2e
    ├── common.bats
    ├── site.bats
    ├── session.bats
    ├── credential.bats
    ├── secret_plaintext.bats
    ├── secret_keychain.bats
    ├── secret_libsecret.bats
    ├── router.bats                         # decision table: positive + negative per rule
    ├── capture.bats                        # ID atomicity, retention, baselines
    ├── sanitize.bats                       # HAR/console redaction
    ├── mask.bats
    ├── git_leak.bats                       # security regression — runs every commit
    ├── argv_leak.bats                      # password never appears in argv
    ├── install.bats                        # --user / --project / auto-detection / idempotency
    ├── uninstall.bats
    ├── doctor.bats                         # zero-network, exit codes, repo sweep
    ├── clean.bats
    ├── flow_yaml.bats
    ├── schema-migrate.bats                  # forward migration + idempotency + refusal-to-downgrade
    ├── routing-doc-sync.bats                # router.sh table ↔ references/routing-heuristics.md
    ├── verb-table-sync.bats                 # scripts/browser-*.sh ↔ SKILL.md table ↔ Appendix A
    ├── schema-fixture-sync.bats             # fixtures declare current schema_version
    ├── lint.sh                              # shellcheck + banned-patterns + size limits + no-tabs
    ├── e2e_login_inspect_verify.bats       # full debug loop vs dummy server
    ├── e2e_flow_run.bats
    ├── e2e_session_expiry_relogin.bats
    ├── e2e_extract_scrape.bats
    ├── e2e_audit_perf.bats
    ├── e2e_origin_mismatch_refused.bats
    ├── e2e_fresh_install.sh                # docker container; nightly only
    └── run.sh
```

---

## 3. Components

### 3.1 Shared library (`scripts/lib/`)

| File | Responsibility |
|---|---|
| `common.sh` | paths, modes, color/no-color logging, exit codes, `summary_json`, `next_capture_id`, `with_timeout`, `resolve_browser_skill_home` |
| `site.sh` | `site_load` `site_save` `site_delete` `site_list` `site_show_masked` |
| `session.sh` | `session_load` `session_save` `session_expiry_summary` `session_bind_origin_check` |
| `credential.sh` | `credential_add` `credential_load` `credential_remove` `credential_migrate` (backend abstraction) |
| `login_detect.sh` | `detect_login_form`, `is_session_expired_response` |
| `capture.sh` | `capture_start`, `capture_attach`, `capture_finish`, `capture_prune` |
| `sanitize.sh` | `sanitize_har` `sanitize_console` `sanitize_dom_dump` (jq-based redactors) |
| `router.sh` | `pick_tool VERB ARGS...` → echoes `TOOL\tWHY` |
| `route_explain.sh` | Verbose form for debugging routing decisions |
| `mask.sh` | `mask_string` `mask_json` |
| `secret/{plaintext,keychain,libsecret}.sh` | Backend implementations exposing `secret_set` `secret_get` `secret_delete` |
| `tool/<tool>.sh` | Per-tool adapter; uniform contract (see 3.3) |
| `node/playwright-driver.mjs` | `login` flow + complex frame work; plain ESM |
| `node/flow-runner.mjs` | Executes a `.flow.yaml` step-by-step |

### 3.2 Verb scripts (~30 verbs)

Grouped by purpose. Each verb is one file (~100–250 lines).

#### Setup & lifecycle
- `doctor` — health check + repo credential sweep + disk-encryption check; never network
- `add-site` / `list-sites` / `show-site` / `remove-site`
- `use` — get/set current site
- `clean` — prune captures by age + count; baselines protected
- `add-credential` / `list-credentials` / `show-credential` / `remove-credential` / `migrate-credential` / `rotate-totp`
- `relogin` — force re-running auto-login
- `login` — headed flow → captures storageState

#### Navigation & inspection
- `open`, `snapshot`, `inspect`, `verify`, `audit`

#### Interactive primitives
- `click` (+ `dblclick`), `fill` (+ `type`), `select`, `check`/`uncheck`, `press`/`hotkey`,
  `hover`/`drag`, `upload`/`download`, `wait`, `eval`, `route`,
  `tab-list`/`tab-new`/`tab-close`/`tab-select`

#### High-level composition & history
- `flow run <file>` — execute a declarative `.flow.yaml`
- `flow record` — headed recorder → `.flow.yaml` (uses playwright-cli's codegen)
- `extract` — selector / eval / multi-URL `--scrape`
- `replay <id>` — re-run a capture, save as new entry, auto-diff
- `history list / show / diff / clear`
- `baseline save <id> --as NAME` / `baseline list` / `baseline remove`
- `report --since "yesterday" --format markdown`

### 3.3 Tool adapter contract

Every `lib/tool/<tool>.sh` exports the same uniform API:

```bash
tool_open()         # --session, --url, --headed, --viewport, ...
tool_click()
tool_fill()
tool_snapshot()
tool_inspect()      # console + network + screenshot + selector text
tool_audit()        # may exit 41 if unsupported
tool_extract()
tool_eval()
tool_capabilities() # echoes JSON of what this tool supports
```

If an adapter doesn't support a verb, its function exits 41 (`TOOL_UNSUPPORTED_OP`). The router never picks an unsupporting tool, so this is defensive only.

> **See also:** [Tool Adapter Extension Model design spec](2026-04-30-tool-adapter-extension-model-design.md) for the full ABI surface (identity vs verb-dispatch functions, `abi_version`), the loading model (lazy single-source for verb dispatch + subshell iteration for cross-tool aggregation), capability-driven routing (`ROUTING_RULES` array of rule functions + `_tool_supports()` capability filter), autogeneration of `references/tool-versions.md` and `SKILL.md` Tools section, lint enforcement (static + dynamic + drift), the two-path recipe (Path A: ship-without-promotion with zero core edits; Path B: promote-to-default), and worked WRONG/RIGHT anti-pattern examples. §13.2 Recipe 2 here remains the high-level checklist; the linked spec provides the detailed contract.

> **See also:** [Token-Efficient Adapter Output design spec](2026-05-01-token-efficient-adapter-output-design.md) for the bytes an adapter actually emits — seven principles (semantic summary, reference over value, single-line JSON summary, stable `eN` element refs, self-healing errors, progressive flags, files-for-large-data) condensed from chrome-devtools-mcp's published design principles plus microsoft/playwright-cli's `--raw` / `--json` / `--depth` flag conventions and `eN` ref scheme. Mandates a single-line summary per verb, captures-as-paths-not-inline, and a six-pair WRONG/RIGHT anti-pattern list. Phase 3's `scripts/lib/output.sh` helper is the deliverable that enforces it; lint tier 3 in the extension-model spec §7 enforces drift.

### 3.4 On-disk format

All paths below are relative to the resolved `BROWSER_SKILL_HOME` (default `~/.browser-skill/`; project-scoped mode resolves to `<project>/.browser-skill/`). The structure is identical in both modes.

```
$BROWSER_SKILL_HOME/                         mode 0700
├── version                                   1                     [shareable]
├── current                                   prod-app              [personal]
├── config.json                               retention/warn config [shareable]
├── blocklist.txt                             financial-site list   [shareable]
├── baselines.json                            blessed capture index [shareable]
├── .gitignore                                *
├── sites/
│   ├── prod-app.json                         site profile          [shareable]
│   └── prod-app.meta.json                    mtime/last-used       [shareable]
├── sessions/                                                       [PERSONAL — gitignored]
│   ├── prod-app--admin.json                  Playwright storageState
│   └── prod-app--admin.meta.json             expiry, source UA
├── credentials/                                                    [PERSONAL — gitignored]
│   ├── prod-app--admin.json                  selectors + backend ref (NEVER password if backend != plaintext)
│   └── prod-app--admin.meta.json             created_at, last_used_at, last_relogin_at
├── captures/                                                       [PERSONAL — gitignored]
│   ├── 001/
│   │   ├── meta.json
│   │   ├── console.json
│   │   ├── network.har                       (sanitized by default)
│   │   ├── screenshot.png
│   │   ├── trace.zip                         (perf trace, opt-in)
│   │   ├── lighthouse.json                   (audit verb only)
│   │   ├── snapshot.json                     (refs)
│   │   └── downloads/
│   └── _index.json                           latest, count, total_bytes
└── flows/                                                          [shareable]
    └── create-user.flow.yaml
```

### 3.5 Site profile schema

```json
{
  "name": "prod-app",
  "url": "https://app.example.com",
  "viewport": {"width": 1280, "height": 800},
  "user_agent": null,
  "stealth": false,
  "default_session": "prod-app--admin",
  "default_tool": null,
  "label": "Production app",
  "schema_version": 1
}
```

### 3.6 Credential record schema

```json
{
  "name": "prod-app--admin",
  "origin": "https://app.example.com",
  "username": "alice@example.com",
  "username_field": "input[name=email]",
  "password_field": "input[name=password]",
  "submit": "button[type=submit]",
  "secret_backend": "keychain",
  "keychain_service": "browser-skill:prod-app--admin",
  "totp_backend": null,
  "session_name": "prod-app--admin",
  "auto_relogin": true,
  "observed_flow_shape": "single-step-username-password",
  "schema_version": 1
}
```

(Password is never in this JSON unless `secret_backend == "plaintext"`.)

**`auto_relogin` is decided by `add-credential`, not user-toggled.** During the initial setup, the skill observes the actual login flow shape:
- Single-step username+password with no 2FA prompt → `auto_relogin: true`, `observed_flow_shape: "single-step-username-password"`.
- Multi-step (email → next → password) → `auto_relogin: true`, `observed_flow_shape: "multi-step-username-password"` (relogin runs the same recorded steps).
- 2FA / SMS / WebAuthn / CAPTCHA detected → `auto_relogin: false`, `observed_flow_shape: "interactive-required"` (relogin always falls back to `--headed`).

The user can override `auto_relogin: true → false` after the fact via `migrate-credential`, but cannot flip `false → true` without re-running `add-credential` against the live site (the skill must observe a clean flow).

---

## 4. Data flow

### 4.1 Single verb call

```
Claude → bash scripts/browser-inspect.sh --site prod-app --selector ".error" --capture-console
       → site_load → URL, viewport, default_session
       → session_load → cookies + localStorage from disk
       → pick_tool inspect "$@" → "chrome-devtools-mcp\t--capture-console requested"
       → capture_start → allocate NNN, write meta.json
       → source lib/tool/chrome-devtools-mcp.sh; tool_inspect "$@"
         → spawn `npx chrome-devtools start --user-data-dir=…`
         → call evaluate_script, list_console_messages, list_network_requests, take_screenshot
         → write captures/NNN/{console.json,network.har,screenshot.png}
         → emit streaming JSON lines per significant event
       → sanitize.sh → redact captures/NNN/network.har in place
       → capture_finish + summary_json
```

Three invariants:
- All credentials enter via stdin or file path. Never argv. `ps` cannot leak.
- Streaming first, summary last. The LLM can stop reading after the first error; the summary always lands on the final line.
- Capture before summary. If writing fails, exit 31; status="error". Never silently lost.

### 4.2 Iterative debugging loop (the centerpiece)

```
1. /browser inspect --site prod-app --session task-1 --selector "#main" \
                    --capture-console --capture-network
   → capture 042; summary: {console_errors:3, network_failures:1, capture_id:"042"}

2. Claude reads captures/042/console.json
   → identifies bug at src/api/users.ts:42

3. Claude edits source via Edit tool

4. /browser verify --session task-1 --baseline 042
   (same warm browser session — session task-1 is still alive in playwright-cli)
   → diffs new capture 043 vs baseline 042
   → summary: {status:"ok", diff:{console_errors:{before:3,after:0}}, capture_id:"043"}

5. Claude marks the bug fixed.
```

Steps 1 and 4 share `--session task-1`. The browser is warm; reload+verify is ~300 ms vs ~3 s cold. Across 5–10 cycles, this is the difference between a 90 s and a 15 s session.

### 4.3 Multi-step interactive flow

Two modes:
- **Ad-hoc**: LLM composes per turn (`snapshot → fill e3 Alice → fill e5 ... → click e12 → wait .toast → inspect`). Each step its own verb call sharing a session.
- **Saved (`flow run <file>`)**: declarative YAML file ↓

```yaml
# flows/create-user.flow.yaml
name: create-user
session: task-1
steps:
  - open: { path: /users/new }
  - snapshot: {}
  - fill:   { ref: ${refs.Name},  text: Alice }
  - fill:   { ref: ${refs.Email}, text: alice@example.com }
  - select: { ref: ${refs.Role},  value: admin }
  - check:  { ref: ${refs.Send invite} }
  - click:  { ref: ${refs.Create user} }
  - wait:   { selector: .toast-success, timeout: 5000 }
  - assert: { selector: .toast-success, text_contains: "successfully" }
  - inspect: { capture_console: true, capture_network: true }
```

`flow-runner.mjs` is the **only** code path that performs multi-step orchestration; everything else is single-verb.

### 4.4 Authentication lifecycle (three tiers)

```
ONE-TIME PER SITE:
  /browser add-credential --site prod-app --as admin
    └─ navigate, auto-detect form via snapshot
    └─ prompt for username + password (read -s, never echoed)
    └─ pick storage backend (keychain default on Mac, plaintext + warn elsewhere)
    └─ JSON written without password (unless plaintext); password to backend via stdin

ONE-TIME OR ON-EXPIRY:
  /browser login --site prod-app --as admin [--auto]
    └─ headed (default) or auto if --auto and credential allows
    └─ load credential → retrieve password from backend
    └─ navigate, fill, submit, wait for post-login state
    └─ context.storageState() → sessions/prod-app--admin.json
    └─ summary: {expires_in_hours:168, status:"ok"}

EVERY VERB CALL (transparent):
  /browser inspect --site prod-app --selector ".dashboard"
    ├─ session valid? → use it
    └─ expired AND credential exists AND auto_relogin=true:
       └─ silent re-login (one attempt) → retry verb → summary includes auto_relogin:true
       └─ (if relogin needed 2FA → exit 25, surface to user)
```

### 4.5 Capture write & retention

```
capture_start → atomic ID allocation (tmpfile + mv, no flock)
              → mkdir captures/NNN/ mode 0700
              → write meta.json status:"in_progress"

(verb runs, writes per-aspect files; sanitizers run on HAR + console)

capture_finish → update meta.json (status, finished_at, file inventory, total_bytes)
              → update _index.json
              → capture_prune if count > 500 OR oldest_age_days > 14

capture_prune (idempotent):
  while count > 500 OR (oldest.age_days > 14 AND oldest is not a baseline AND not in flight):
    rm -rf captures/$oldest_id
  emit one warn line per pruned capture
```

Thresholds in `~/.browser-skill/config.json`:
```json
{ "retention_days": 14, "retention_count": 500, "warn_at_pct": 90 }
```

### 4.6 LLM reading model (token-cost mitigation)

| Read | When |
|---|---|
| Single-line JSON summary | After every verb — enough to route the next decision |
| `captures/NNN/meta.json` | When the LLM wants the verb's full record |
| `captures/NNN/console.json` | When `console_errors > 0` in summary |
| `captures/NNN/network.har` | When `network_failures > 0` in summary |
| `captures/NNN/screenshot.png` | Rare — screenshots are expensive |
| `references/routing-heuristics.md` | Once at session start |

This tiered model is the primary token-cost mitigation. The LLM reads ~200 tokens per summary and reaches into per-aspect files only on signal — 10–50× cheaper per debugging cycle than MCP-style "always return everything."

---

## 5. Error handling

### 5.1 Exit-code table (single source of truth)

| Code | Symbol | `status` | Meaning |
|---|---|---|---|
| 0 | OK | ok | Success |
| 1 | GENERIC_ERROR | error | Unspecified bash trap |
| 2 | USAGE_ERROR | error | Bad flags |
| 11 | EMPTY_RESULT | empty | Selector matched 0; scrape returned 0 |
| 12 | PARTIAL_RESULT | partial | Multi-step flow completed N of M |
| 13 | ASSERTION_FAILED | error | `verify` failed |
| 20 | PREFLIGHT_FAILED | error | Deps missing |
| 21 | TOOL_MISSING | error | Tool binary not on PATH |
| 22 | SESSION_EXPIRED | error | Session expired AND auto-relogin not possible |
| 23 | SITE_NOT_FOUND | error | `--site X` doesn't exist |
| 24 | CREDENTIAL_AMBIGUOUS | error | Multiple match; need `--as` |
| 25 | AUTH_INTERACTIVE_REQUIRED | error | 2FA / CAPTCHA / WebAuthn prompted |
| 26 | KEYCHAIN_LOCKED | error | OS keychain locked |
| 27 | TTY_REQUIRED | error | Verb needed TTY for typed-phrase |
| 28 | BLOCKLIST_REJECTED | error | Origin matched blocklist; user did not type override |
| 30 | NETWORK_ERROR | error | DNS / TCP / TLS reaching the site |
| 31 | CAPTURE_WRITE_FAILED | error | Disk full / EPERM |
| 32 | RETENTION_BLOCKED | error | All baselines / in-flight; can't prune |
| 33 | SCHEMA_MIGRATION_REQUIRED | error | On-disk schema older than code; run `migrate-schema` |
| 41 | TOOL_UNSUPPORTED_OP | error | Adapter doesn't support this verb |
| 42 | TOOL_CRASHED | error | Tool subprocess died |
| 43 | TOOL_TIMEOUT | error | Tool exceeded `--timeout` |
| 130 | INTERRUPTED | aborted | SIGINT |
| 137 | KILLED_OOM | aborted | SIGKILL |
| 143 | TERMINATED | aborted | SIGTERM |

### 5.2 The single auto-retry: session-expired

The **only** automatic recovery the skill performs without telling the user.

- Exactly one retry attempt.
- The auto-relogin is loud in the summary: `auto_relogin: true, relogin_duration_ms: 423`.
- If auto-relogin fails for any reason, the original verb fails immediately. No multi-step dance.
- 2FA detected during relogin → exit 25 with helpful error.

### 5.3 Streaming and partial-failure semantics

For `flow run`, `extract --scrape`, `inspect --watch`:
- Every streamed line carries `"status"` so the LLM can stop reading on first error.
- The final summary always carries the verb's overall verdict and `page_state_capture_id` referencing a capture taken at the failure point.
- The capture at the failure point has full DOM snapshot + console + network.

### 5.4 `--dry-run` is the debug primitive

Every mutating verb supports `--dry-run`: performs all preflight, prints `would_run` JSON, makes zero network calls, writes zero captures.

### 5.5 What we explicitly don't catch

- Underlying tool stack traces — surfaced as-is in `error_details`.
- CSP / mixed-content errors — surfaced as `console_errors`; we don't retry with relaxed flags.
- Browser crashes mid-session — exit 42; user starts fresh session.
- Disk-full during capture write — exit 31; capture left half-written; `_index.json` reflects partial state.
- DNS failures — exit 30; no fallback.
- Origin mismatch on session load — exit 22; we never load cookies into the wrong origin "to be helpful."

### 5.6 `doctor` as the diagnostic surface

`doctor` is the user's "what's wrong?" command. After every error where it makes sense, the verb's error message ends with `→ run /browser doctor for full diagnosis`.

`doctor` checks (over MQTT skill's set):
- bash 5.2 / jq / python3 / node ≥ 20 / playwright-cli / chrome-devtools-mcp / playwright browsers / obscura
- `~/.browser-skill` mode 0700, .gitignore present, scripts symlink active
- Sites registered, sessions with expiry hours
- Credentials with backend reachability
- Captures: count / oldest / total bytes
- Baselines: count
- Blocklist patterns active count
- TOTP-enabled credentials count
- Disk encryption: FileVault status (macOS) / LUKS (Linux)
- Skill-home mode: user-level vs project-scoped

Doctor makes **zero network calls** and finishes in <2 s.

---

## 6. Installation modes

### 6.1 Two modes

| Mode | Use case | State at |
|---|---|---|
| **User-level** | Personal daily-driver | `~/.browser-skill/` |
| **Project-level** | Team-shared site profiles + flows | `<project>/.browser-skill/` |

### 6.2 What's shareable vs. personal in project mode

```
Shareable (commit to git):
  sites/<name>.json
  flows/<name>.flow.yaml
  baselines.json
  blocklist.txt
  config.json
  version

Personal (gitignored):
  sessions/<name>.json
  credentials/<name>.json
  captures/
  current
```

### 6.3 BROWSER_SKILL_HOME resolution

```bash
resolve_browser_skill_home() {
  # 1. Explicit env var wins
  [ -n "${BROWSER_SKILL_HOME:-}" ] && { echo "$BROWSER_SKILL_HOME"; return; }
  # 2. Walk up from $PWD looking for .browser-skill/
  local dir="$PWD"
  while [ "$dir" != "/" ]; do
    [ -d "$dir/.browser-skill" ] && { echo "$dir/.browser-skill"; return; }
    dir="$(dirname "$dir")"
  done
  # 3. Fall back
  echo "$HOME/.browser-skill"
}
```

`doctor` always prints the resolved home + mode at the top.

### 6.4 install.sh flags

```
./install.sh [options]

Modes:
  --user                 (default) symlink to ~/.claude/skills/, state at ~/.browser-skill/
  --project              create <project-root>/.browser-skill/, add .gitignore entries
  --project-root PATH    override project-root auto-detection

Options:
  --with-hooks           enable .githooks/pre-commit credential-leak blocker
  --no-symlink           skip user-level symlink (--user only; advanced)
  --reinstall            force re-create state dir (refuses if non-empty unless --force)
  --force                with --reinstall, allow wiping state (typed-phrase prompt)
  --dry-run              print what would happen, change nothing
  -h, --help

Auto-detection: if invoked from a path matching */.claude/skills/browser-automation-skill/
                AND a .git/ exists above .claude/, suggest --project (typed confirmation).
```

### 6.5 Three install paths shown in the README

```bash
### Personal (one machine, all projects)
git clone https://github.com/xicv/browser-automation-skill ~/Projects/browser-automation-skill
cd ~/Projects/browser-automation-skill
./install.sh --with-hooks

### Team (shared site profiles + flows in one repo)
cd <your-project>
git submodule add https://github.com/xicv/browser-automation-skill .claude/skills/browser-automation-skill
bash .claude/skills/browser-automation-skill/install.sh --project --with-hooks

### Verify (in Claude Code)
/browser doctor

### First flow (60 seconds)
/browser add-site --name my-app --url https://app.example.com
/browser login --site my-app --as me
/browser inspect --site my-app --selector "#main" --capture-console
```

### 6.6 uninstall.sh flags

```
./uninstall.sh [--user|--project] [--keep-state] [--dry-run]
```

Default: keep state. `--project` removes `<project>/.browser-skill/` after typed confirmation; removes the gitignore markers.

### 6.7 Plugin marketplace (deferred)

v2 will add `.claude-plugin/plugin.json` for `/plugin marketplace add ...` distribution. Layout is plugin-ready.

---

## 7. Testing strategy

### 7.1 Inverted pyramid

We test the routing layer + adapter contract heavily; we don't re-test Playwright/Chrome.

- ~140 unit tests (bats)
- ~20 adapter contract tests with mock binaries
- ~5 e2e tests against a local dummy Express server
- 1 fresh-install nightly test in a docker container

Total fast-lane CI time: ~45 s. E2E + fresh-install on PR + nightly only.

### 7.2 Per-suite coverage

| File | Covers |
|---|---|
| `common.bats` | path resolution, walk-up, summary writer, exit codes, color/no-color |
| `site.bats` | profile CRUD, schema migration, --dry-run |
| `session.bats` | storageState round-trip, expiry summary, origin-mismatch refusal |
| `credential.bats` | record CRUD, blocklist enforcement, typed-phrase, password masking |
| `secret_*.bats` | each backend in isolation; keychain uses temp keychain |
| `router.bats` | every routing rule has positive + negative test; `--tool` override; capability matrix |
| `capture.bats` | atomic ID, retention prunes oldest, baselines protected, disk-full path |
| `sanitize.bats` | HAR / console / DOM redaction never leaks redacted patterns |
| `mask.bats` | password masking is leak-proof |
| `git_leak.bats` | pre-commit blocks every credential pattern (runs every commit) |
| `argv_leak.bats` | password never appears in subprocess argv (runs every commit) |
| `install.bats` | --user, --project, --project-root, idempotency, auto-detection |
| `doctor.bats` | every check has dedicated test; never network |
| `clean.bats` | retention; baseline protection; --keep / --days overrides |
| `flow_yaml.bats` | YAML schema, ${refs.X} resolution, error helpfulness |

### 7.3 Mock binary strategy

`tests/stubs/playwright-cli` etc. are tiny shell scripts that:
- Log argv to `_argv.log` (the argv-leak test greps this).
- Look up a fixture by sha256 of argv.
- Echo the fixture's JSON; exit per fixture's `exit` field.

When upstream tools change CLI flags, the hash changes, the fixture goes missing, the test fails loudly.

### 7.4 Local e2e dummy server

`tests/fixtures/dummy-server/server.mjs` — a 50-line Express app with `/login`, `/dashboard`, `/api/users`, `/slow`, `/regression`. Five e2e tests cover the full debug loop, flow run, expiry+relogin, scrape, audit.

### 7.5 What we don't test

- Real-world sites — brittle, networked, slow.
- Visual rendering correctness — screenshot existence + size only.
- Performance regressions of upstream tools — their CI.
- Cross-browser parity beyond chromium (smoke only).

### 7.6 CI matrix

```yaml
unit:    every commit, ubuntu + macos, ~30 s
e2e:     PR + nightly only, ubuntu + chromium, ~3 min
fresh:   nightly only, docker ubuntu:24.04
```

---

## 8. Security

### 8.1 Threat model

| In scope | Out of scope |
|---|---|
| Credentials leaking via argv / `ps` | Malware on your machine |
| Credentials leaking via git | Compromised OS / kernel |
| Credentials leaking via Claude transcript | Targeted nation-state attacker |
| Credentials in shell history | OS keychain compromise |
| Captures leaking auth tokens (HARs / console) | Compromised upstream tool |
| Sessions injected into wrong origin | Compromised npm/cargo dependency |
| Accidental commits | Network-level MITM |
| Accidental use against unintended sites | Insider with shell access to home |

### 8.2 The seven defense layers

1. **Filesystem perms** — 0700 dirs, 0600 files, `umask 077` everywhere.
2. **Process invariants** — credentials never on argv; `read -s` for prompts; argv-leak test on every commit.
3. **Git defenses** — `.gitignore` + pre-commit hook + repo content sweep in `doctor`.
4. **OS-level secret stores** — Keychain on macOS, libsecret on Linux+systemd, plaintext warned. TOTP forced to keychain; refused in plaintext.
5. **Origin binding** — sessions only load into matching `scheme://host:port`.
6. **User friction proportional to risk** — typed-phrase confirmations for blocklist override, TOTP enable, plaintext on Mac, `--reveal`, `--unsanitized`. "y" never accepted.
7. **Capture sanitization** — HAR, console, and DOM dumps redact `Authorization` / `Set-Cookie` / API-key URL params / `password|secret|token` fields by default.

### 8.3 Capture sanitization

`lib/sanitize.sh` runs on every HAR + console capture before write:

```jq
.log.entries[].request.headers |=
  map(if (.name | ascii_downcase) | IN("authorization","cookie","x-api-key","x-auth-token")
      then .value = "***REDACTED***" else . end)
| .log.entries[].response.headers |=
  map(if (.name | ascii_downcase) | IN("set-cookie","authorization")
      then .value = "***REDACTED***" else . end)
| .log.entries[].request.url |=
  if test("(api_key|token|access_token|client_secret)=")
  then sub("(?<k>(api_key|token|access_token|client_secret))=[^&]*"; "\(.k)=***")
  else . end
```

`--unsanitized` requires the typed phrase: `I want raw network/console data including auth tokens`.

### 8.4 Credential lifecycle (security view)

```
Add    → read -s for password; backend chosen; stdin to backend; JSON without password
Use    → password retrieved JIT; handed to playwright-cli via stdin or --storage-state file;
         in-memory variable unset on exit; temp files shred-deleted (`rm -P` / `shred`)
Rotate → migrate-credential / rotate-session / rotate-totp; old keychain item deleted
Remove → shred-delete JSON; delete keychain item; offer to remove linked session;
         orphans flagged by doctor next run
```

### 8.5 Audit & observability

| Question | Answered by |
|---|---|
| What credentials exist? | `/browser list-credentials` (masked) |
| What's stored on disk? | `/browser doctor --audit` |
| What did this verb do? | capture meta.json + JSON summary + dry-run preview |
| Did anything leak via git? | `/browser doctor` repo sweep + pre-commit log |
| What versions of upstream tools? | `/browser doctor` |
| Is FileVault on? | `/browser doctor` |
| Did a verb run --unsanitized? | meta.json carries `sanitized:false`; doctor counts these |

### 8.6 Supply chain trust signals

- Pinned major versions in `references/tool-versions.md`.
- `doctor` warns on major version mismatch.
- We never auto-install. No `curl | bash`. No auto-updater.
- Obscura binary is GPG-verifiable; canonical signing key documented.
- Signed git tags for each release.
- `SECURITY.md` with disclosure path + PGP key.
- `tests/git_leak.bats` runs every commit; status badge.

### 8.7 What we tell users to be paranoid about

`references/security.md` ships a plain-language list of:
- What we can protect (creds in argv / git / transcript / shell history; sessions cross-origin; auth tokens in captures; financial-site accidents; TOTP plaintext)
- What we cannot (malware, compromised browser, backups copying state, bugs in this skill)

---

## 9. Out of scope (v1)

- **Plugin marketplace publishing** — deferred to v2; layout is plugin-ready.
- **Native OS dialogs** (Windows print dialog, native file picker) — Playwright can't address them.
- **Browser extensions requiring manual install** — we use ephemeral profiles each session.
- **System-level audio/video capture** — Playwright records the page only.
- **Real-world site smoke tests in CI** — flaky and brittle; we use a local dummy server.
- **Cross-browser test matrix beyond chromium** — firefox/webkit are opt-in; smoke-tested only.
- **Auto-installer / `curl | bash` quickstart** — deliberate; respects user choice + audit.

---

## 10. Open questions / explicit non-decisions

These are **deliberately not decided** at the spec level — implementation will surface the right answer:

1. **Where does the Node helper resolve `playwright`?** Likely `npx -p playwright -c "..."`; alternative is a documented `npm link` step. Decided in implementation when we hit the first "playwright not found in helper" case.
2. **TOTP code generation library**: probably the system `oathtool` if available, falling back to a small bash+openssl HOTP implementation. Confirm during implementation.
3. **HAR sanitization granularity**: jq filter as drafted is the v1; future iteration may add user-customizable rule sets. Out of scope for v1.
4. **Visual diff backend**: `compare` from ImageMagick is the v1 default for `verify --visual`. If unavailable, fall back to per-pixel sha256 only. Out of scope to make this configurable yet.
5. **Replay verb's exact diff shape**: structured per-aspect diff for console/network/text; raw byte diff for screenshots. Concrete schema deferred to implementation.

---

## 11. Acceptance criteria

The skill is "v1 done" when:

1. All verbs in Appendix A are implemented with `--dry-run` support where applicable.
2. `install.sh` works in `--user` and `--project` modes; `doctor` reports green on a fresh macOS + Ubuntu install.
3. The full unit + adapter contract test suite passes in <60 s on macOS + Ubuntu.
4. The five e2e tests pass against the dummy server.
5. The two security regression tests (`git_leak.bats`, `argv_leak.bats`) pass on every commit.
6. The iterative debugging loop (login → inspect → patch → verify) demonstrably works against a real but harmless site (e.g., `httpbin.org` or a fixture site we control), end-to-end, in under 30 s after the initial `login`.
7. `references/` ships all documented references (15 files + 5 recipe files); `examples/` ships all 5 flow templates.
8. README's "first 5 minutes" walkthrough is real — a new user from `git clone` to first capture in under 5 minutes.
9. `tests/lint.sh` passes cleanly (shellcheck + banned-patterns + size limits + no-tabs + no trailing whitespace).
10. The three sync-tests pass (`routing-doc-sync.bats`, `verb-table-sync.bats`, `schema-fixture-sync.bats`) — the docs cannot lie.
11. `CONTRIBUTING.md` is real — a contributor can follow any of the five recipes without asking the author a question.
12. `.github/PULL_REQUEST_TEMPLATE.md` is in place and CI gates the security regression checkboxes.

---

## 12. Implementation sequencing (preview)

The implementation plan (handed to `superpowers:writing-plans`) will sequence roughly:

1. **Foundation** — `install.sh`, `lib/common.sh`, `~/.browser-skill/` skeleton, `doctor`, `.gitignore`, pre-commit hook. Mirror MQTT skill's setup.
2. **Site + session core** — `add-site`/`use`/`login` + storageState read/write. Hand-tested against dummy server.
3. **First adapter (playwright-cli)** — single-tool path for `open`/`snapshot`/`click`/`fill`/`inspect`. End-to-end one tool first.
4. **Router + second adapter (chrome-devtools-mcp)** — introduce `lib/router.sh`, then layer in CDT-MCP for `inspect`/`audit`. Validates the routing pattern.
5. **Credentials + auto-relogin** — `lib/credential.sh`, three secret backends, login_detect, the single retry path.
6. **Remaining tools (playwright-lib helper, obscura)** — fill in adapters; complete the routing table.
7. **Capture + sanitization + retention** — full capture writer, baselines, sanitize.sh, clean.
8. **Composition & history** — `flow run`, `flow record`, `replay`, `history`, `report`, `verify` w/ baselines.
9. **Project mode + final polish** — `install.sh --project`, examples/, references/, security.md, fresh-install nightly test.
10. **Maintainability scaffolding** — `CONTRIBUTING.md`, `references/recipes/*.md`, `references/architecture-tour.md`, `references/why-bash.md`, `.github/PULL_REQUEST_TEMPLATE.md`, `tests/lint.sh`, the three sync-tests. This phase is the difference between "works" and "maintainable" — do not skip.

Each phase ends green: tests pass, doctor reports green, one slice works end-to-end before the next begins.

---

## 13. Maintainability (the "easy to change later" properties)

The skill will live longer than its first author's attention span. These properties are deliberate design choices that make change cheap, drift detectable, and onboarding fast.

### 13.1 The "one place to look" principle

Every cross-cutting concern has exactly **one** authoritative home. Code grep against the home file is enough; nothing is sprinkled.

| Concern | Single home |
|---|---|
| Routing decisions | `scripts/lib/router.sh` (decision table; rules sourced once) |
| Exit codes | `scripts/lib/common.sh` (declared as `readonly EXIT_*` constants) |
| Path layout | `scripts/lib/common.sh` (`BROWSER_SKILL_HOME`, `SITES_DIR`, ... constants) |
| Schema versions | `scripts/lib/schema-migrate.sh` (per-schema migrators) |
| Sanitization rules | `scripts/lib/sanitize.sh` (jq filters as functions) |
| Backend abstraction | `scripts/lib/credential.sh` + `scripts/lib/secret/*.sh` |
| Adapter contract surface | `scripts/lib/tool/<tool>.sh` (each implements identical function set) |
| Mocked-binary fixtures | `tests/fixtures/<tool>/` (one dir per tool) |

Reviewing a PR that touches more than one of these for one logical change is a smell — flag it.

### 13.2 The five recipes that cover 80% of changes

Every contributor (including future-you) follows one of five recipes. Each recipe is a checklist file in `references/recipes/`, and each is enforced by tests + the PR template.

```
references/recipes/
├── add-a-verb.md
├── add-a-tool-adapter.md
├── change-a-routing-rule.md
├── migrate-an-on-disk-schema.md
└── update-an-upstream-tool-version.md
```

#### Recipe 1 — Add a verb (~15-min change)
1. Create `scripts/browser-<verb>.sh` (copy `browser-open.sh` as scaffold).
2. Add row to SKILL.md verb table + Appendix A.
3. Add `<verb>.bats` covering: happy path, --dry-run, exit-code-on-error, capture summary shape.
4. (If it routes) add a row to the table in `lib/router.sh` AND a positive+negative test in `router.bats`.
5. (If adapter touches) add `tool_<verb>` to every adapter's capability matrix + impl OR exit-41.
6. Update `references/routing-heuristics.md` if a new rule was added.

#### Recipe 2 — Add a tool adapter (~3-hour change)
1. Create `scripts/lib/tool/<tool>.sh`; implement the uniform contract from §3.3.
2. Implement `tool_capabilities()` declaring supported verbs.
3. Add stub at `tests/stubs/<tool>` + fixtures at `tests/fixtures/<tool>/`.
4. Add adapter contract test; assert argv-shape, no creds in argv, JSON line schema.
5. Add a routing rule in `lib/router.sh` so the new tool actually gets picked.
6. Add doctor check for the binary; pin tested version in `references/tool-versions.md`.
7. Update `SKILL.md` "Tools" section + add `references/<tool>-cheatsheet.md`.

#### Recipe 3 — Change a routing rule (~5-min change)
1. Edit `lib/router.sh` decision table.
2. Update `references/routing-heuristics.md` to match (one-to-one with the table).
3. Update tests in `router.bats` (positive + negative for the new rule + replace the obsoleted one).
4. (No verb script changes needed — that's the point of centralized routing.)

#### Recipe 4 — Migrate an on-disk schema (~2-hour change)
1. Bump `schema_version` in the affected schema.
2. Add `migrate_<schema>_v<from>_to_v<to>()` to `lib/schema-migrate.sh`.
3. Migration is **idempotent and additive**: never delete unknown fields, never break v<from>-shape readers in the same release.
4. `doctor` runs the migration check on every invocation; emits exit code 33 (`SCHEMA_MIGRATION_REQUIRED`) when migration needed.
5. Add `tests/schema-migrate.bats` covering: forward migration, idempotency, refusal to downgrade.

#### Recipe 5 — Update an upstream tool version (~30-min change)
1. Update `references/tool-versions.md` with the new pinned version.
2. Re-record the affected fixtures in `tests/fixtures/<tool>/` (delete + re-run e2e against real tool).
3. If CLI flags changed: update `lib/tool/<tool>.sh`; argv-hash mismatch will fail tests until adapters match.
4. Update `CHANGELOG.md` with `[upstream]` tag.

### 13.3 File-size discipline

A growing file is a refactor signal. Limits enforced by `tests/lint.sh`:

| File class | Soft limit | Hard limit |
|---|---|---|
| `scripts/browser-<verb>.sh` | 150 LOC | 250 LOC (refactor: extract to `lib/`) |
| `scripts/lib/*.sh` | 250 LOC | 400 LOC (split by responsibility) |
| `scripts/lib/tool/<tool>.sh` | 350 LOC | 500 LOC (adapters are inherently larger) |
| `scripts/lib/node/*.mjs` | 150 LOC | 200 LOC (Node helpers should stay tiny) |
| `tests/*.bats` | 300 LOC | 500 LOC (split by sub-concern) |
| `references/*.md` | 250 LOC | 500 LOC (split into recipes/ if needed) |
| `SKILL.md` | 400 LOC | 500 LOC (Anthropic best-practice cap) |

Hard-limit violations fail CI. Soft-limit violations emit a warning that's logged but not failed.

### 13.4 Lint discipline

`tests/lint.sh` runs in the unit-test job on every commit:

1. **`shellcheck` on every `.sh`** with `-S style` (warnings fail; `# shellcheck disable=...` allowed inline only with a comment explaining why).
2. **Banned patterns** grep — fail on:
   - `eval ` (use printf-based composition)
   - `set +e` (we want hard fail; only `lib/common.sh` may use trap-based recovery)
   - `IFS=` outside `lib/common.sh` (causes subtle field-split bugs)
   - Unquoted `$variable` in the right-hand side of redirections / arguments to `cp`/`mv`/`rm`
   - `echo` for sensitive values (always `printf` + `read -s` for creds)
3. **Line-length** — soft 100 col, hard 200 col (table rows excepted in `.md`).
4. **No tabs** in any file.
5. **Trailing whitespace** — fail.
6. **`prettier`** for `.mjs` files only (Node helpers); not for shell or markdown (per "no formatting commits" instruction).

Lint additions get the `[internal]` CHANGELOG tag and never block on the developer's machine — only in CI — so local iteration stays fast.

### 13.5 Drift detection

Three independent watches catch silent breakage:

| Watch | Surface |
|---|---|
| **Routing-rule drift** — `lib/router.sh` table vs. `references/routing-heuristics.md` doc | `tests/routing-doc-sync.bats`: parse both, assert equivalent rule sets |
| **Verb-table drift** — verb scripts on disk vs. `SKILL.md` verb table vs. Appendix A | `tests/verb-table-sync.bats`: every `scripts/browser-*.sh` has a row in both |
| **Schema-version drift** — JSON files in test fixtures vs. current `schema_version` | `tests/schema-fixture-sync.bats`: fixtures must declare current version |

Every doc that has a corresponding code surface has a sync-test. The doc cannot lie for long.

### 13.6 PR template

`.github/PULL_REQUEST_TEMPLATE.md` ships with these boxes (CI gates the security ones):

```markdown
## Change type
- [ ] feat (new verb / new flag)
- [ ] fix (bug fix)
- [ ] refactor (no behavior change)
- [ ] adapter (added/updated tool adapter)
- [ ] schema (on-disk schema migration)
- [ ] docs / examples
- [ ] internal (lint, tests, CI, no user-visible change)

## Recipes followed
- [ ] add-a-verb.md (if applicable)
- [ ] add-a-tool-adapter.md (if applicable)
- [ ] change-a-routing-rule.md (if applicable)
- [ ] migrate-an-on-disk-schema.md (if applicable)
- [ ] update-an-upstream-tool-version.md (if applicable)

## Security regression tests (must remain green)
- [ ] git_leak.bats (CI-enforced)
- [ ] argv_leak.bats (CI-enforced)
- [ ] sanitize.bats (CI-enforced)

## Docs touched
- [ ] SKILL.md (if a verb / flag changed)
- [ ] references/<file>.md (if cheatsheet / heuristic / cheat changed)
- [ ] CHANGELOG.md (always; tag = [feat|fix|security|adapter|schema|docs|internal])

## Verified locally
- [ ] tests/run.sh (unit + contract, ~30 s)
- [ ] /browser doctor exits green
- [ ] If e2e-touching: tests/e2e.sh
```

The `[security]` CHANGELOG tag automatically tags the maintainer for a second-pair-of-eyes review on next release.

### 13.7 Onboarding artifacts

A new contributor (or future-you-after-six-months) should be productive in <30 min:

| Artifact | Purpose |
|---|---|
| `README.md` "first 5 minutes" | Install + first capture |
| `CONTRIBUTING.md` | Repo tour + the five recipes + test conventions + PR process |
| `references/architecture-tour.md` | "Reading the codebase in dependency order: common.sh → router.sh → adapter → verb" |
| `references/why-bash.md` | Defends the language choice with concrete trade-offs (so contributors don't waste cycles asking "why not Rust?") |
| `examples/` | 5 working flows you can copy-modify |
| `references/recipes/*.md` | Step-by-step for the 5 common changes |

`docs/CODEMAP.md` (per the user's `/update-codemaps` workflow) is generated and committed at every release: a top-down "where does X live?" map.

### 13.8 Change cadence and deprecation

- **Breaking changes** require a major version bump and a `migrate-schema` path. CHANGELOG `[breaking]` tag.
- **Deprecation** lifecycle: a verb / flag is marked deprecated for one minor release with a runtime warning (`status: ok` but `warnings: [...]` in summary), then removed in the next major.
- **Upstream tool incompatibility** — when an upstream version we depend on goes EOL, a `[upstream-deprecation]` issue is filed; doctor surfaces it; we have one minor release to migrate.

`★ Insight ─────────────────────────────────────`
The maintainability story is the project's true product. A skill that's hard to change ossifies: contributors avoid it, bugs accumulate, the LLM-routing table drifts from reality, security regressions sneak in. The five-recipe pattern + sync-tests + lint discipline + PR template aren't bureaucracy — they're the **forcing functions that make the spec a living document instead of a one-time artifact**. The MQTT skill works because its 32 files follow this same discipline; this skill should inherit the discipline along with the structure.
`─────────────────────────────────────────────────`

---

## Appendix A — Verb table (full)

| # | Verb | Purpose | Default tool |
|---:|---|---|---|
| 1 | `doctor` | Health check + repo sweep + disk-encryption check | n/a |
| 2 | `add-site` | Register site profile | n/a |
| 3 | `list-sites` | List sites (masked) | n/a |
| 4 | `show-site` | Show one (masked) | n/a |
| 5 | `remove-site` | Delete site | n/a |
| 6 | `use` | Set/show current site | n/a |
| 7 | `add-credential` | Interactive credential setup | playwright-cli (form detection) |
| 8 | `list-credentials` | List (masked) | n/a |
| 9 | `show-credential` | Show one (masked unless --reveal+typed-phrase) | n/a |
| 10 | `remove-credential` | Shred-delete + remove keychain item | n/a |
| 11 | `migrate-credential` | Move between backends | n/a |
| 12 | `rotate-totp` | Re-prompt + replace TOTP seed | n/a |
| 13 | `relogin` | Force re-running auto-login | playwright-lib |
| 14 | `login` | One-time storageState capture | playwright-lib (headed) |
| 15 | `open` | Navigate | playwright-cli |
| 16 | `snapshot` | A11y-tree refs | playwright-cli |
| 17 | `click` (+ dblclick) | Click | playwright-cli |
| 18 | `fill` (+ type) | Text entry | playwright-cli |
| 19 | `select` (+ check / uncheck) | Form controls | playwright-cli |
| 20 | `press` (+ hotkey) | Keyboard | playwright-cli |
| 21 | `hover` (+ drag) | Pointer | playwright-cli |
| 22 | `upload` (+ download) | File transfer | playwright-cli |
| 23 | `wait` | Selector / network-idle / predicate | playwright-cli |
| 24 | `eval` | JS expression | playwright-cli |
| 25 | `route` | Mock URL | playwright-cli |
| 26 | `tab-*` | Multi-tab | playwright-cli |
| 27 | `inspect` | Console + network + screenshot snapshot | chrome-devtools-mcp (when --capture-* requested) |
| 28 | `verify` | Assert + diff vs baseline | chrome-devtools-mcp / playwright-cli |
| 29 | `audit` | Lighthouse + perf trace | chrome-devtools-mcp |
| 30 | `extract` | Selector / eval / multi-URL scrape | obscura (when --scrape or --stealth) |
| 31 | `flow run / record` | Execute / record a .flow.yaml | playwright-cli + node helper |
| 32 | `replay <id>` | Re-run a capture, diff | (matches what produced original) |
| 33 | `history` | list / show / diff / clear | n/a |
| 34 | `baseline` | save / list / remove (named blessed) | n/a |
| 35 | `report` | Markdown digest | n/a |
| 36 | `clean` | Prune captures by age + count | n/a |

**Verb count.** Appendix A lists 36 numbered rows. Sub-modes (e.g., `dblclick` under `click`, `tab-list/new/close/select` collapsed into one row, `flow run` and `flow record` as one row) are counted within their parent row. Counting parent rows: 36. Counting fully-distinct top-level invocations including sub-modes: ~50. The acceptance-criteria phrase "all verbs in Appendix A" refers to all 36 rows with their sub-modes implemented.

---

## Appendix B — Routing decision table

| Trigger | Tool | Why |
|---|---|---|
| `--capture-console` / `--capture-network` requested | chrome-devtools-mcp | Dedicated console + network tools, low task-token cost |
| `--lighthouse` / `--perf-trace` / verb=`audit` | chrome-devtools-mcp | Only tool with `lighthouse_audit`, `performance_*` |
| `--firefox` / `--webkit` / multi-browser | playwright-cli | Only one with non-Chromium support |
| verb=`login` (storageState capture) | playwright-lib (node helper) | Best storageState API; multi-step login support |
| `--scrape <urls...>` or `--stealth` | obscura | Parallel scrape + built-in anti-detection |
| `--mcp-fallback` and CDT-MCP unavailable | playwright-mcp | Escape hatch; never default |
| (default) `open`/`click`/`fill`/`screenshot`/`eval` | playwright-cli | Microsoft's recommended path for coding agents (4× cheaper than Playwright MCP) |
| `--tool=X` | X | Always wins |

---

## Appendix C — References

- `mqtt-skill` repo (proven structural template): `https://github.com/xicv/mqtt-skill`
- Playwright CLI skills: `https://github.com/microsoft/playwright-cli`
- Chrome DevTools MCP: `https://github.com/ChromeDevTools/chrome-devtools-mcp`
- Obscura: `https://github.com/h4ckf0r0day/obscura`
- Anthropic Skill authoring best practices: `https://docs.claude.com/en/docs/agents-and-tools/agent-skills/best-practices`
