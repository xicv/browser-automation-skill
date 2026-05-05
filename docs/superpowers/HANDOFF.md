Continue work on `browser-automation-skill` at `/Users/xicao/Projects/browser-automation-skill`. Read CLAUDE.md (if any), `SKILL.md`, and the most recent specs/plans under `docs/superpowers/specs/` and `docs/superpowers/plans/` before touching code.

## Where the project stands (as of 2026-05-05 — Phase 6 part 7 of 8)

main is at tag `v0.28.0-phase-06-part-7-i-route`. **Phases 1-5 SHIPPED** (Phase 5 feature-complete with TOTP track). **Phase 6 is 7/8 verbs done**, with route 7-i shipped (block + allow); only `tab-*` and route 7-ii (fulfill) remain.

### Phase 6 progress (PRs #40-#46)

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
| 6-8-i | `tab-list` | 🔲 | Foundation: daemon `tabs[]` slot + tab-list returning `[{tab_id, url, title}]` |
| 6-8-ii | `tab-switch` | 🔲 | `--by-index N` or `--by-url-pattern STR` (mutex). Updates daemon's currentTab pointer |
| 6-8-iii | `tab-close` | 🔲 | `--tab-id N` or `--by-url-pattern STR`. Removes from tabs[] + close in upstream MCP |

### Counters

- **30 user-facing verbs**: doctor + 4 site verbs + use + 3 login modes + 3 session verbs + 7 cred verbs + 8 web verbs (open/snapshot/click/fill/inspect/audit/extract/eval) + 7 Phase 6 verbs (press/select/hover/wait/drag/upload/route).
- **3 of 4 adapters real-mode**: playwright-cli, playwright-lib, chrome-devtools-mcp (full + Path B promotion). obscura → Phase 8.
- **3 of 3 Tier-1 credential backends**.
- **~620+ tests pass / 0 fail / lint exit 0** locally (CI-authoritative; local hangs on real-playwright e2e files when playwright globally installed).
- **46 PRs merged total** (24 in Phase 5, 7 in Phase 6).

## Next session: pick up at Phase 6 part 8-i

Recommended start: **`tab-list` foundation**. Smallest possible tab-* verb — daemon adds `tabs[]` state slot + `tab-list` returns the array. No state mutation; just enumeration. Sets the state shape for 8-ii/8-iii.

```
bash scripts/browser-tab-list.sh
# → {verb: 'tab-list', tabs: [{tab_id: 1, url: 'https://...', title: '...'}, ...]}
```

Daemon-side: maintain `tabs[]` array; populate from MCP `list_pages` (or equivalent) tool. cdt-mcp upstream may differ — name as `list_pages` for stub, document as best-effort.

After 8-i, sequence: 8-ii (tab-switch — first state-mutation on tabs[]) → 8-iii (tab-close).

Optional sub-part 7-ii (route fulfill) can land before or after tab-* — independent. fulfill is heavier (body management); land it AFTER tab-* if you want the easier wins first.

After Phase 6 wraps: Phase 7 (capture pipeline + sanitization), Phase 8 (obscura adapter), Phase 9 (flow runner), Phase 10 (schema migration tooling) per parent spec.

## Workflow expectations (proven across 46 PRs)

- **TDD muscle-memory**: branch + bats RED → GREEN → lint → tag → push → PR → CI → squash-merge → reset main. 95%+ CI-green-first-try this run.
- **Phase 6 sub-part shape** (mechanical now): bridge daemon dispatch case + capability declaration + tool dispatcher + router rule + verb script + bats + stub handler + drift sync (`scripts/regenerate-docs.sh all`) + plan-doc + CHANGELOG.
- **Lint must exit 0** at all 3 tiers. Drift-tier triggers when adapter capabilities change → run `regenerate-docs.sh all`.
- **Test-mode env vars** for testability without real Chrome (production paths gate on these):
  - `BROWSER_SKILL_LIB_STUB=1` — bridge fixture lookup mode.
  - `BROWSER_SKILL_DRIVER_TEST_2FA=1` / `BROWSER_SKILL_DRIVER_TEST_TOTP_REPLAY=1` — driver short-circuit hooks.
- **Cross-platform shell idioms**: GREP REPO FIRST. `stat -c '%a'` (GNU) precedes `stat -f '%Lp'` (BSD). `read -r -d ''` for NUL-stdin (bash vars can't hold NUL).
- **CI workflow** runs on macos-latest + ubuntu-latest. Doesn't install Playwright/cdt-mcp by default — driver real-mode tests gated; bats coverage via stubs (`tests/stubs/mcp-server-stub.mjs` handles 11+ MCP tools used by the bridge).
- **Privacy-canary pattern** (10+ instances now): every credential-emitting verb gets a sentinel canary in its bats file. Recipe doc at `references/recipes/privacy-canary.md` is **overdue**.
- **Path-security pattern** (introduced in 6-6 upload): sensitive-pattern reject + `--allow-sensitive` ack + realpath canonicalization. Recipe doc at `references/recipes/path-security.md` is **overdue**.

## Stub coverage (mcp-server-stub.mjs, in alphabetical order)

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
| navigate_page | open verb | 5 part 1c |
| press_key | press verb | 6 part 1 |
| route_url | route verb (best-effort name; real upstream may differ) | 6 part 7-i |
| select_option | select verb | 6 part 2 |
| take_screenshot | inspect --screenshot | 5 part 1e-ii |
| take_snapshot | snapshot verb | 5 part 1c |
| upload_file | upload verb | 6 part 6 |
| wait_for | wait verb | 6 part 4 |

Plus `initialize` + `notifications/initialized` (MCP handshake). 16 tool handlers total.

## When you start (next session)

1. `git checkout main && git pull --ff-only origin main`
2. Confirm tag is `v0.28.0-phase-06-part-7-i-route` and main HEAD matches.
3. Pick a sub-part. Recommendation: **`tab-list` (Phase 6 part 8-i)** — smallest remaining; foundation for tab-switch/close.
4. Branch `feature/phase-06-part-8-i-tab-list`. Plan-doc + RED bats + GREEN + lint + drift + tag + PR + CI + squash-merge + reset main.

Start with: read CHANGELOG since `v0.28.0-phase-06-part-7-i-route` (the last tag) to confirm no in-flight work, then propose the next part's scope before coding. The user prefers "go for your recommendation" once the option-table is presented; default to the smallest reviewable PR delivering user-visible value.
