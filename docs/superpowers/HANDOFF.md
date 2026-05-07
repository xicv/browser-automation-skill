Continue work on `browser-automation-skill` at `/Users/xicao/Projects/browser-automation-skill`. Read CLAUDE.md (if any), `SKILL.md`, and the most recent specs/plans under `docs/superpowers/specs/` and `docs/superpowers/plans/` before touching code.

## Where the project stands (as of 2026-05-07 — Phase 6 COMPLETE)

main is at tag `v0.32.0-phase-06-part-7-ii-route-fulfill`. **Phases 1-5 SHIPPED** (Phase 5 feature-complete with TOTP track). **Phase 6 is 11/11 declared verbs done — Phase 6 COMPLETE.** route fulfill (7-ii) shipped this round, closing the block/allow/fulfill triad.

### Phase 6 progress (PRs #40-#53)

| Sub-part | Verb | Status | Notes |
|---|---|---|---|
| 6-1 | `press` | ✅ | Stateless. `--key`. RFC keys (Enter/Tab/Cmd+S/etc.) |
| 6-2 | `select` | ✅ | Stateful. `--ref` + `--value`/`--label`/`--index` (mutex) |
| 6-3 | `hover` | ✅ | Stateful. `--ref` only; `--selector` deferred |
| 6-4 | `wait` | ✅ | Stateless. `--selector` + `--state` (visible/hidden/attached/detached) + `--timeout` |
| 6-5 | `drag` | ✅ | Stateful. `--src-ref` + `--dst-ref`. First 2-ref verb |
| 6-6 | `upload` | ✅ | Stateful. `--ref` + `--path` + path-security (sensitive-pattern reject + `--allow-sensitive` ack + realpath canonicalization) |
| 6-7-i | `route` | ✅ | Daemon-state-mutating. `--pattern` + `--action` (block\|allow). New `routeRules` daemon slot |
| 6-7-ii | `route fulfill` | ✅ | `--action fulfill` + `--status N` (100-599) + `--body STR` ⊕ `--body-stdin`. Body in-memory only; `body_bytes` in reply (not body itself); body verbatim (no trailing-newline strip, unlike `fill --secret-stdin`); 3-layer validation (bash/bridge/daemon-child) |
| 6-8-i | `tab-list` | ✅ | Read-only enum. Daemon `tabs[]` slot. Returns `[{tab_id, url, title}]`; `tab_id` is bridge-assigned 1-based, stable per call |
| 6-8-ii | `tab-switch` | ✅ | Mutex `--by-index N` ⊕ `--by-url-pattern STR`. Daemon `currentTab` slot. `tab-list` annotates `is_current` + `current_tab_id`. `refreshTabs()` helper auto-runs when `tabs[]` empty |
| 6-8-iii | `tab-close` | ✅ | Mutex `--tab-id N` ⊕ `--by-url-pattern STR`. Splice `tabs[]` + close upstream + null `currentTab` on match. **`tab_id` stays stable across closes** (no renumbering) |

### Counters

- **34 user-facing verbs**: doctor + 4 site verbs + use + 3 login modes + 3 session verbs + 7 cred verbs + 8 web verbs (open/snapshot/click/fill/inspect/audit/extract/eval) + 11 Phase 6 verbs (press/select/hover/wait/drag/upload/route(block|allow|fulfill)/tab-list/tab-switch/tab-close).
- **3 of 4 adapters real-mode**: playwright-cli, playwright-lib, chrome-devtools-mcp (full + Path B promotion). obscura → Phase 8.
- **3 of 3 Tier-1 credential backends**.
- **~672 tests pass / 0 fail / lint exit 0** locally (CI-authoritative; local hangs on real-playwright e2e files when playwright globally installed; `tests/browser-select.bats:6` fails locally on newer jq versions where `label` is reserved — pre-existing, tracked as follow-up).
- **54 PRs merged total** (24 in Phase 5, 13 in Phase 6 + 4 ancillary docs/CI; not counting this HANDOFF refresh).

## Next session: jump to Phase 7 (capture pipeline + sanitization)

Phase 6 is closed. Per parent spec (`docs/superpowers/specs/2026-04-27-browser-automation-skill-design.md`), Phase 7 introduces the **capture pipeline** with **sanitization**. This is a meaningfully different surface than Phase 6 verb-shipping — it's about a structured capture artifact format + redaction rules + a `captures/` directory under `~/.browser-skill/`.

### Phase 7 scoping (need a sub-part split before coding)

Likely sub-parts (rough — confirm with parent spec on the way in):
- **7-i** capture format design + a `--capture` flag on existing primitives (open/snapshot/click/fill/eval) that writes a tarball to `${BROWSER_SKILL_HOME}/captures/`.
- **7-ii** sanitizer: redaction-rules pass over capture artifacts (cookie-token blanking, env-var redaction, etc.) prior to write.
- **7-iii** `capture inspect` / `capture replay` verbs (read-side) — TBD whether replay lands in Phase 7 or Phase 9 (flow runner).

**Open Phase 7 questions** to settle BEFORE plan-doc:
- Capture artifact: tar.gz? json + sidecar files? OCI layer? Parent spec is opinionated — read first.
- Where does sanitization gate? Pre-write (capture-side) or pre-read (replay-side)? Pre-write is safer (redacted bytes never hit disk) but couples capture to redaction.
- Does sanitization run on existing snapshot/inspect artifacts already on disk, or only on Phase 7 captures? Migration question.

### Recipe-doc catch-up (alternative for the very next session)

Two recipes are explicitly "overdue" in this HANDOFF and would be useful **before** Phase 7's sanitization work (path-security generalizes there):
- `references/recipes/privacy-canary.md` — sentinel-canary-in-bats pattern (10+ instances).
- `references/recipes/path-security.md` — sensitive-pattern reject + `--allow-sensitive` ack + realpath canonicalization (introduced 6-6 upload).
- New candidate from this session: `references/recipes/body-bytes-not-body.md` — when reply-shape ingests caller-supplied content, ship a length contract (`body_bytes`), not the content itself. Avoids re-emitting agent-supplied data into stdout / logs / terminal capture. Two instances now: route fulfill 7-ii (body) and the older fill `--secret-stdin` reply scrub.

Pure docs PR. Low risk. Useful primer for Phase 7's sanitization design.

## Workflow expectations (proven across 54 PRs)

- **TDD muscle-memory**: branch + bats RED → GREEN → lint → tag → push → PR → CI → squash-merge → reset main. ~95%+ CI-green-first-try across the project.
- **Phase 6 sub-part shape** (mechanical now): bridge daemon dispatch case + capability declaration + tool dispatcher + router rule + verb script + bats + stub handler + drift sync (`scripts/regenerate-docs.sh all`) + plan-doc + CHANGELOG.
- **Lint must exit 0** at all 3 tiers (`bash tests/lint.sh`). Drift-tier triggers when adapter capabilities change → run `regenerate-docs.sh all`.
- **Test-mode env vars** for testability without real Chrome (production paths gate on these):
  - `BROWSER_SKILL_LIB_STUB=1` — bridge fixture lookup mode.
  - `BROWSER_SKILL_DRIVER_TEST_2FA=1` / `BROWSER_SKILL_DRIVER_TEST_TOTP_REPLAY=1` — driver short-circuit hooks.
- **Cross-platform shell idioms**: GREP REPO FIRST. `stat -c '%a'` (GNU) precedes `stat -f '%Lp'` (BSD). `read -r -d ''` for NUL-stdin (bash vars can't hold NUL — but for stdin passthrough to a node bridge, the bash side doesn't read stdin at all; bridge's `readAllStdin` does).
- **CI workflow** runs on macos-latest + ubuntu-latest. Doesn't install Playwright/cdt-mcp by default — driver real-mode tests gated; bats coverage via stubs (`tests/stubs/mcp-server-stub.mjs` handles 19 MCP tools used by the bridge).
- **Privacy-canary pattern** (10+ instances now): every credential-emitting verb gets a sentinel canary in its bats file. Recipe doc at `references/recipes/privacy-canary.md` is **overdue**.
- **Path-security pattern** (introduced in 6-6 upload): sensitive-pattern reject + `--allow-sensitive` ack + realpath canonicalization. Recipe doc at `references/recipes/path-security.md` is **overdue**.
- **Body-bytes-not-body pattern** (new in 7-ii): when a verb ingests caller-supplied content (HTTP body, large blobs), ship the byte length in the reply, not the content. Avoids re-emitting agent-supplied data. Recipe doc candidate.
- **Defense-in-depth validation pattern** (codified in 7-ii): same validation at three layers (bash verb → bridge → daemon-child). Each layer is cheap (<10 lines). Daemon-child layer is the only required test surface for non-CLI IPC paths. Use when the IPC boundary could be exercised by callers other than the verb script.
- **HANDOFF-refresh-as-separate-PR pattern** (proven 4 times now: PR #47, #50, #52, current): tiny docs PR between substantive sub-parts / between phases. Doesn't bloat code-review PRs with state-tracking churn. Especially valuable at phase boundaries.

## Daemon state slots (shipped through 7-ii)

| Slot | Type | Phase | Notes |
|---|---|---|---|
| `refMap` | array | 5 part 1c-ii | eN ↔ uid translation, populated by snapshot |
| `routeRules` | array | 6 part 7-i / 7-ii | `{pattern, action}` for block/allow; `{pattern, action: "fulfill", status, body}` for fulfill. In-memory only — dies with daemon |
| `tabs` | array | 6 part 8-i | `{tab_id, url, title}` entries; replaced wholesale by `refreshTabs()` helper; spliced (no renumbering) by tab-close |
| `currentTab` | number \| null | 6 part 8-ii | tab_id pointer; updated by tab-switch; nulled by tab-close on match |

All four are still flat closures inside `daemonChildMain`. A `DaemonState` object refactor is deferred until slots start interacting (e.g. per-tab refMap in Phase 7+, route rules scoped to current tab). Phase 7's capture surface may finally trigger this — capturing should snapshot the daemon state.

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
| route_url | route verb (best-effort name; real upstream may differ); 7-ii passes `status` + `body` through for fulfill rules | 6 part 7-i / 7-ii |
| select_option | select verb | 6 part 2 |
| select_page | tab-switch (best-effort name) | 6 part 8-ii |
| take_screenshot | inspect --screenshot | 5 part 1e-ii |
| take_snapshot | snapshot verb | 5 part 1c |
| upload_file | upload verb | 6 part 6 |
| wait_for | wait verb | 6 part 4 |

Plus `initialize` + `notifications/initialized` (MCP handshake). 19 tool handlers total.

## When you start (next session)

1. `git checkout main && git pull --ff-only origin main`
2. Confirm tag is `v0.32.0-phase-06-part-7-ii-route-fulfill` and main HEAD matches.
3. **Read parent spec** `docs/superpowers/specs/2026-04-27-browser-automation-skill-design.md` for Phase 7's capture-pipeline shape — Phase 6 was mostly mechanical verbs; Phase 7 is a meaningfully different surface (artifacts, sanitization, replay) and the parent spec opinions matter.
4. Propose Phase 7 sub-part split BEFORE coding — Phase 7 is too big for one PR. The user prefers "go for your recommendation" once the option-table is presented; default to the smallest reviewable PR delivering user-visible value.

**Alternative pick** (lower risk, useful before Phase 7's sanitization work): write the three overdue recipe docs (privacy-canary, path-security, body-bytes-not-body) as a single docs-only PR. Doesn't move the roadmap, does cement reusable patterns.

Start with: read CHANGELOG since `v0.32.0-phase-06-part-7-ii-route-fulfill` (the last tag) to confirm no in-flight work, then propose Phase 7 part 7-i scope (or recipe docs alternative).
