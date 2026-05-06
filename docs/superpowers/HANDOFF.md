Continue work on `browser-automation-skill` at `/Users/xicao/Projects/browser-automation-skill`. Read CLAUDE.md (if any), `SKILL.md`, and the most recent specs/plans under `docs/superpowers/specs/` and `docs/superpowers/plans/` before touching code.

## Where the project stands (as of 2026-05-06 — Phase 6 part 8-ii of 10)

main is at tag `v0.30.0-phase-06-part-8-ii-tab-switch`. **Phases 1-5 SHIPPED** (Phase 5 feature-complete with TOTP track). **Phase 6 is 9/10 declared verbs done**, with tab-list (8-i) + tab-switch (8-ii) shipped. Only `tab-close` (8-iii) and route fulfill (7-ii) remain.

### Phase 6 progress (PRs #40-#49)

| Sub-part | Verb | Status | Notes |
|---|---|---|---|
| 6-1 | `press` | ✅ | Stateless. `--key`. RFC keys (Enter/Tab/Cmd+S/etc.) |
| 6-2 | `select` | ✅ | Stateful. `--ref` + `--value`/`--label`/`--index` (mutex) |
| 6-3 | `hover` | ✅ | Stateful. `--ref` only; `--selector` deferred |
| 6-4 | `wait` | ✅ | Stateless. `--selector` + `--state` (visible/hidden/attached/detached) + `--timeout` |
| 6-5 | `drag` | ✅ | Stateful. `--src-ref` + `--dst-ref`. First 2-ref verb |
| 6-6 | `upload` | ✅ | Stateful. `--ref` + `--path` + path-security (sensitive-pattern reject + `--allow-sensitive` ack + realpath canonicalization) |
| 6-7-i | `route` | ✅ | Daemon-state-mutating. `--pattern` + `--action` (block\|allow). New `routeRules` daemon slot. fulfill = 7-ii |
| 6-7-ii | `route fulfill` | 🔲 | `--action fulfill` + `--status N` + `--body BODY` (or `--body-stdin` per AP-7). Body management adds stdin-mux + binary-safety + body persistence in routeRules |
| 6-8-i | `tab-list` | ✅ | Read-only enum. New `tabs[]` daemon slot. Returns `[{tab_id, url, title}]`; `tab_id` is bridge-assigned 1-based, stable per call |
| 6-8-ii | `tab-switch` | ✅ | First state-mutation on `tabs[]`. Mutex `--by-index N` ⊕ `--by-url-pattern STR`. New `currentTab` slot. `tab-list` now annotates `is_current` + `current_tab_id` |
| 6-8-iii | `tab-close` | 🔲 | `--tab-id N` ⊕ `--by-url-pattern STR`. Splice from `tabs[]` + close in upstream MCP + invalidate `currentTab` if match |

### Counters

- **32 user-facing verbs**: doctor + 4 site verbs + use + 3 login modes + 3 session verbs + 7 cred verbs + 8 web verbs (open/snapshot/click/fill/inspect/audit/extract/eval) + 9 Phase 6 verbs (press/select/hover/wait/drag/upload/route/tab-list/tab-switch).
- **3 of 4 adapters real-mode**: playwright-cli, playwright-lib, chrome-devtools-mcp (full + Path B promotion). obscura → Phase 8.
- **3 of 3 Tier-1 credential backends**.
- **~640+ tests pass / 0 fail / lint exit 0** locally (CI-authoritative; local hangs on real-playwright e2e files when playwright globally installed; `tests/browser-select.bats:6` fails locally on newer jq versions where `label` is reserved — pre-existing, tracked as follow-up).
- **49 PRs merged total** (24 in Phase 5, 9 in Phase 6).

## Next session: pick up at Phase 6 part 8-iii

Recommended start: **`tab-close`**. Smallest remaining tab-* verb. Mirrors tab-switch's mutex selectors but with splice + upstream close semantics + `currentTab` invalidation when the closed tab matches.

```
bash scripts/browser-tab-close.sh --tab-id 2
bash scripts/browser-tab-close.sh --by-url-pattern "tracking"
```

Daemon-side dispatch: resolve selector → tab object, call MCP `close_page` (best-effort name; real upstream may differ), splice out of `tabs[]`, null `currentTab` if match. Return `{closed_tab:{tab_id,url,title}, current_tab_id, tab_count, ...}`.

After 8-iii, sequence: optional 7-ii route fulfill (independent track — body management adds stdin-mux + binary-safety + persistence in `routeRules`).

After Phase 6 wraps: Phase 7 (capture pipeline + sanitization), Phase 8 (obscura adapter), Phase 9 (flow runner), Phase 10 (schema migration tooling) per parent spec.

## Workflow expectations (proven across 49 PRs)

- **TDD muscle-memory**: branch + bats RED → GREEN → lint → tag → push → PR → CI → squash-merge → reset main. 95%+ CI-green-first-try this run.
- **Phase 6 sub-part shape** (mechanical now): bridge daemon dispatch case + capability declaration + tool dispatcher + router rule + verb script + bats + stub handler + drift sync (`scripts/regenerate-docs.sh all`) + plan-doc + CHANGELOG.
- **Lint must exit 0** at all 3 tiers. Drift-tier triggers when adapter capabilities change → run `regenerate-docs.sh all`.
- **Test-mode env vars** for testability without real Chrome (production paths gate on these):
  - `BROWSER_SKILL_LIB_STUB=1` — bridge fixture lookup mode.
  - `BROWSER_SKILL_DRIVER_TEST_2FA=1` / `BROWSER_SKILL_DRIVER_TEST_TOTP_REPLAY=1` — driver short-circuit hooks.
- **Cross-platform shell idioms**: GREP REPO FIRST. `stat -c '%a'` (GNU) precedes `stat -f '%Lp'` (BSD). `read -r -d ''` for NUL-stdin (bash vars can't hold NUL).
- **CI workflow** runs on macos-latest + ubuntu-latest. Doesn't install Playwright/cdt-mcp by default — driver real-mode tests gated; bats coverage via stubs (`tests/stubs/mcp-server-stub.mjs` handles 18+ MCP tools used by the bridge).
- **Privacy-canary pattern** (10+ instances now): every credential-emitting verb gets a sentinel canary in its bats file. Recipe doc at `references/recipes/privacy-canary.md` is **overdue**.
- **Path-security pattern** (introduced in 6-6 upload): sensitive-pattern reject + `--allow-sensitive` ack + realpath canonicalization. Recipe doc at `references/recipes/path-security.md` is **overdue**.

## Daemon state slots (shipped through 8-ii)

| Slot | Type | Phase | Notes |
|---|---|---|---|
| `refMap` | array | 5 part 1c-ii | eN ↔ uid translation, populated by snapshot |
| `routeRules` | array | 6 part 7-i | `{pattern, action}` entries; appended by route, never removed in 7-i |
| `tabs` | array | 6 part 8-i | `{tab_id, url, title}` entries; replaced wholesale by `refreshTabs()` |
| `currentTab` | number \| null | 6 part 8-ii | tab_id pointer; updated by tab-switch; 8-iii will null on close-match |

All four are still flat closures inside `daemonChildMain`. A `DaemonState` object refactor is deferred until they start interacting (e.g. per-tab refMap in Phase 7+).

## Stub coverage (mcp-server-stub.mjs, 18 tool handlers)

| Tool | Purpose | Phase introduced |
|---|---|---|
| click | stateful click | 5 part 1c-ii |
| drag | pointer drag (2 uids) | 6 part 5 |
| evaluate_script | eval/extract/inspect-selector | 5 part 1c |
| fill | stateful fill | 5 part 1c-ii |
| hover | pointer hover | 6 part 3 |
| lighthouse_audit | audit verb | 5 part 1c |
| list_console_messages | inspect --capture-console | 5 part 1e-ii |
| list_network_requests | inspect --capture-network | 5 part 1e-ii |
| list_pages | tab-list (and auto-refresh in tab-switch) | 6 part 8-i |
| navigate_page | open verb | 5 part 1c |
| press_key | press verb | 6 part 1 |
| route_url | route verb (best-effort name; real upstream may differ) | 6 part 7-i |
| select_option | select verb | 6 part 2 |
| select_page | tab-switch (best-effort name) | 6 part 8-ii |
| take_screenshot | inspect --screenshot | 5 part 1e-ii |
| take_snapshot | snapshot verb | 5 part 1c |
| upload_file | upload verb | 6 part 6 |
| wait_for | wait verb | 6 part 4 |

Plus `initialize` + `notifications/initialized` (MCP handshake). 18 tool handlers total.

## When you start (next session)

1. `git checkout main && git pull --ff-only origin main`
2. Confirm tag is `v0.30.0-phase-06-part-8-ii-tab-switch` and main HEAD matches.
3. Pick a sub-part. Recommendation: **`tab-close` (Phase 6 part 8-iii)** — smallest remaining; closes the tab-* trilogy.
4. Branch `feature/phase-06-part-8-iii-tab-close`. Plan-doc + RED bats + GREEN + lint + drift + tag + PR + CI + squash-merge + reset main.

Start with: read CHANGELOG since `v0.30.0-phase-06-part-8-ii-tab-switch` (the last tag) to confirm no in-flight work, then propose the next part's scope before coding. The user prefers "go for your recommendation" once the option-table is presented; default to the smallest reviewable PR delivering user-visible value.
