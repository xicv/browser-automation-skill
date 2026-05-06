Continue work on `browser-automation-skill` at `/Users/xicao/Projects/browser-automation-skill`. Read CLAUDE.md (if any), `SKILL.md`, and the most recent specs/plans under `docs/superpowers/specs/` and `docs/superpowers/plans/` before touching code.

## Where the project stands (as of 2026-05-06 — Phase 6 tab-* trilogy complete)

main is at tag `v0.31.0-phase-06-part-8-iii-tab-close`. **Phases 1-5 SHIPPED** (Phase 5 feature-complete with TOTP track). **Phase 6 is 10/10 declared verbs done**. The tab-* trilogy (8-i/ii/iii) shipped this round. Only `route fulfill` (7-ii) remains as an independent Phase 6 sub-PR.

### Phase 6 progress (PRs #40-#51)

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
| 6-8-i | `tab-list` | ✅ | Read-only enum. Daemon `tabs[]` slot. Returns `[{tab_id, url, title}]`; `tab_id` is bridge-assigned 1-based, stable per call |
| 6-8-ii | `tab-switch` | ✅ | Mutex `--by-index N` ⊕ `--by-url-pattern STR`. Daemon `currentTab` slot. `tab-list` annotates `is_current` + `current_tab_id`. `refreshTabs()` helper auto-runs when `tabs[]` empty |
| 6-8-iii | `tab-close` | ✅ | Mutex `--tab-id N` ⊕ `--by-url-pattern STR`. Splice `tabs[]` + close upstream + null `currentTab` on match. **`tab_id` stays stable across closes** (no renumbering) |

### Counters

- **33 user-facing verbs**: doctor + 4 site verbs + use + 3 login modes + 3 session verbs + 7 cred verbs + 8 web verbs (open/snapshot/click/fill/inspect/audit/extract/eval) + 10 Phase 6 verbs (press/select/hover/wait/drag/upload/route/tab-list/tab-switch/tab-close).
- **3 of 4 adapters real-mode**: playwright-cli, playwright-lib, chrome-devtools-mcp (full + Path B promotion). obscura → Phase 8.
- **3 of 3 Tier-1 credential backends**.
- **~660+ tests pass / 0 fail / lint exit 0** locally (CI-authoritative; local hangs on real-playwright e2e files when playwright globally installed; `tests/browser-select.bats:6` fails locally on newer jq versions where `label` is reserved — pre-existing, tracked as follow-up).
- **53 PRs merged total** (24 in Phase 5, 12 in Phase 6 + 4 ancillary docs/CI).

## Next session: pick up at Phase 6 part 7-ii (route fulfill) or jump to Phase 7

Recommended start: **`route fulfill` (Phase 6 part 7-ii)**. Closes Phase 6 entirely so Phase 7 starts clean.

Surface:
```
printf '{"users":[]}' | bash scripts/browser-route.sh \
  --pattern "https://*.tracking.com/api/*" \
  --action fulfill \
  --status 200 \
  --body-stdin
```

Scope:
- Add `--action fulfill` to `browser-route.sh` (currently rejects with hint pointing at 7-ii).
- Add `--status N` (HTTP status code) and `--body BODY` / `--body-stdin` (mutex).
- Body must be **binary-safe**. Use AP-7 NUL-stdin pattern (`read -r -d ''`) for `--body-stdin` so bash variables can hold arbitrary bytes (well, except NUL itself — multipart bodies that legitimately contain NUL would need a different transport; document the limitation).
- Persist `{pattern, action: "fulfill", status, body}` in daemon's `routeRules` slot (currently stores `{pattern, action}`). Body lives in-memory only — not on-disk persistence (rules die with daemon).
- Stub MCP tool name: `route_url` already there from 7-i; pass through `status` + `body` to it. Stub echoes `fulfilled <pattern> with <status>`.
- Tests:
  - bash bats (+~6): `--action fulfill` requires `--status`, requires body, mutex on `--body` / `--body-stdin`, binary-safe body roundtrips, etc.
  - daemon e2e (+~3): rule_count grows, body stored verbatim, status echoed in MCP ack.

After 7-ii: Phase 7 (capture pipeline + sanitization) per parent spec. Phase 8 (obscura adapter), Phase 9 (flow runner), Phase 10 (schema migration tooling).

**Alternative pick**: skip 7-ii, start Phase 7 now. 7-ii becomes "open follow-up" tracked in CHANGELOG. Reasoning: 7-ii's body management is heavier than the typical Phase 6 sub-part and may not be worth the context-switch from a Phase 7 perspective. Decide with the user.

## Workflow expectations (proven across 53 PRs)

- **TDD muscle-memory**: branch + bats RED → GREEN → lint → tag → push → PR → CI → squash-merge → reset main. ~95%+ CI-green-first-try across the project.
- **Phase 6 sub-part shape** (mechanical now): bridge daemon dispatch case + capability declaration + tool dispatcher + router rule + verb script + bats + stub handler + drift sync (`scripts/regenerate-docs.sh all`) + plan-doc + CHANGELOG.
- **Lint must exit 0** at all 3 tiers. Drift-tier triggers when adapter capabilities change → run `regenerate-docs.sh all`.
- **Test-mode env vars** for testability without real Chrome (production paths gate on these):
  - `BROWSER_SKILL_LIB_STUB=1` — bridge fixture lookup mode.
  - `BROWSER_SKILL_DRIVER_TEST_2FA=1` / `BROWSER_SKILL_DRIVER_TEST_TOTP_REPLAY=1` — driver short-circuit hooks.
- **Cross-platform shell idioms**: GREP REPO FIRST. `stat -c '%a'` (GNU) precedes `stat -f '%Lp'` (BSD). `read -r -d ''` for NUL-stdin (bash vars can't hold NUL).
- **CI workflow** runs on macos-latest + ubuntu-latest. Doesn't install Playwright/cdt-mcp by default — driver real-mode tests gated; bats coverage via stubs (`tests/stubs/mcp-server-stub.mjs` handles 19 MCP tools used by the bridge).
- **Privacy-canary pattern** (10+ instances now): every credential-emitting verb gets a sentinel canary in its bats file. Recipe doc at `references/recipes/privacy-canary.md` is **overdue**.
- **Path-security pattern** (introduced in 6-6 upload): sensitive-pattern reject + `--allow-sensitive` ack + realpath canonicalization. Recipe doc at `references/recipes/path-security.md` is **overdue**.
- **HANDOFF-refresh-as-separate-PR pattern** (proven 3 times now: PR #47, #50, current): tiny docs PR between substantive sub-parts. Doesn't bloat code-review PRs with state-tracking churn. Useful when shipping a multi-PR session.

## Daemon state slots (shipped through 8-iii)

| Slot | Type | Phase | Notes |
|---|---|---|---|
| `refMap` | array | 5 part 1c-ii | eN ↔ uid translation, populated by snapshot |
| `routeRules` | array | 6 part 7-i | `{pattern, action}` entries; appended by route, never removed in 7-i. **7-ii will extend** to `{pattern, action: "fulfill", status, body}` |
| `tabs` | array | 6 part 8-i | `{tab_id, url, title}` entries; replaced wholesale by `refreshTabs()` helper; spliced (no renumbering) by tab-close |
| `currentTab` | number \| null | 6 part 8-ii | tab_id pointer; updated by tab-switch; nulled by tab-close on match |

All four are still flat closures inside `daemonChildMain`. A `DaemonState` object refactor is deferred until they start interacting (e.g. per-tab refMap in Phase 7+, route rules scoped to current tab).

## Stub coverage (mcp-server-stub.mjs, 19 tool handlers)

| Tool | Purpose | Phase introduced |
|---|---|---|
| click | stateful click | 5 part 1c-ii |
| close_page | tab-close (best-effort name) | 6 part 8-iii |
| drag | pointer drag (2 uids) | 6 part 5 |
| evaluate_script | eval/extract/inspect-selector | 5 part 1c |
| fill | stateful fill | 5 part 1c-ii |
| hover | pointer hover | 6 part 3 |
| lighthouse_audit | audit verb | 5 part 1c |
| list_console_messages | inspect --capture-console | 5 part 1e-ii |
| list_network_requests | inspect --capture-network | 5 part 1e-ii |
| list_pages | tab-list (and auto-refresh in tab-switch / tab-close) | 6 part 8-i |
| navigate_page | open verb | 5 part 1c |
| press_key | press verb | 6 part 1 |
| route_url | route verb (best-effort name; real upstream may differ); 7-ii will pass `status` + `body` through | 6 part 7-i |
| select_option | select verb | 6 part 2 |
| select_page | tab-switch (best-effort name) | 6 part 8-ii |
| take_screenshot | inspect --screenshot | 5 part 1e-ii |
| take_snapshot | snapshot verb | 5 part 1c |
| upload_file | upload verb | 6 part 6 |
| wait_for | wait verb | 6 part 4 |

Plus `initialize` + `notifications/initialized` (MCP handshake). 19 tool handlers total.

## When you start (next session)

1. `git checkout main && git pull --ff-only origin main`
2. Confirm tag is `v0.31.0-phase-06-part-8-iii-tab-close` and main HEAD matches.
3. Pick a sub-part. Recommendation: **`route fulfill` (Phase 6 part 7-ii)** — closes Phase 6 entirely. Or skip and jump to Phase 7.
4. Branch `feature/phase-06-part-7-ii-route-fulfill`. Plan-doc + RED bats + GREEN + lint + drift + tag + PR + CI + squash-merge + reset main.

Start with: read CHANGELOG since `v0.31.0-phase-06-part-8-iii-tab-close` (the last tag) to confirm no in-flight work, then propose the next part's scope before coding. The user prefers "go for your recommendation" once the option-table is presented; default to the smallest reviewable PR delivering user-visible value.
