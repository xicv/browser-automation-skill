# Changelog

Every entry has a tag in `[brackets]`:
- `[feat]` user-visible new behavior
- `[fix]` user-visible bug fix
- `[security]` anything touching credentials, sessions, captures, hooks
- `[adapter]` added/updated tool adapter
- `[schema]` on-disk schema migration
- `[breaking]` requires action from existing users
- `[upstream]` updated pinned upstream tool version
- `[internal]` lint, tests, CI — no user-visible change
- `[docs]` README / SKILL.md / references / examples

## [Unreleased]

### Phase 7 part 1-i — capture foundation (`lib/capture.sh` + `snapshot --capture`)

- [feat] new `scripts/lib/capture.sh` — three-function API: `capture_init_dir` (idempotent mkdir 0700), `capture_start <verb>` (atomic NNN allocation + meta.json `status:"in_progress"` + exports `CAPTURE_ID` + `CAPTURE_DIR`), `capture_finish [status]` (updates meta.json with `finished_at`/`status`/`total_bytes`/`files[]`; updates `_index.json` with `latest`/`count`/`total_bytes`/`next_id`).
- [feat] `scripts/browser-snapshot.sh` — opt-in `--capture` flag. When set, persists adapter stdout to `${CAPTURES_DIR}/NNN/snapshot.json` and writes meta.json. `capture_id` joins the summary line. `--capture` is **stripped before adapter dispatch** (verb-script-level flag, not for adapters). Without `--capture`, `~/.browser-skill/captures/` is not created — clean state preserved.
- [feat] **Atomic NNN allocation** via tmpfile + rename(2) per parent spec §4.5 ("tmpfile + mv, no flock"). Single-process per invocation expected; concurrent capture_starts race → documented as known limitation. Future hardening (mkdir without `-p` so the second loser fails fast) tracked.
- [feat] **Failure path:** when the adapter fails (`adapter_rc != 0`), `capture_finish error` still runs — meta.json is finalized with `status: "error"` so the artifact directory is never left in `in_progress` state. Test asserts this directly.
- [security] Dir mode 0700, all written files mode 0600. `meta.json` + `_index.json` permissions verified by bats.
- [fix] `scripts/lib/common.sh::summary_json` numeric autodetect rejects leading-zero integers (`001` → string, not `1`). Capture IDs are zero-padded 3-digit identifiers; the spec contract is "NNN string" not "integer". Future capture-id-style fields preserve their padding through the summary serializer.
- [internal] new `tests/capture.bats` (12 cases) — three-function contract: dir mode 0700, idempotent init, NNN=001 first run, zero-pad to 3 digits, bumps to 002 on second run, exports `CAPTURE_ID`+`CAPTURE_DIR`, meta.json shape (capture_id/verb/schema_version/started_at/status), dir+meta perms, capture_finish updates {finished_at/status/total_bytes/files[]}, status=ok/error round-trip, default status=ok, _index.json shape, two-capture cycle (latest=002, count=2, next_id=3).
- [internal] `tests/browser-snapshot.bats` (+5 cases) — `--capture` writes snapshot.json + meta.json + capture_id in summary; perms (700/600); _index.json updated; without `--capture` no captures dir created; adapter failure → meta.json status=error.
- [docs] `docs/superpowers/plans/2026-05-08-phase-07-part-1-i-capture-foundation.md` — phase plan.

**Sub-scope (7-i):**
- Wired only to `snapshot` — structurally safe (refs only, no headers/cookies, no leak surface). Console/HAR/screenshot wire-ups arrive when sanitization lands.
- `--capture` is **opt-in**, not default. Default-on policy waits for sanitization (capturing without sanitizing is a leak surface; capturing without writing is the safe stance for 7-i).
- `lib/capture.sh` does NOT call any adapter — pure filesystem helpers. Verbs sandwich their per-aspect file writes between `capture_start` and `capture_finish`.

**Deferred sub-parts (Phase 7 plan):**
- 7-ii: `lib/sanitize.sh` — pure jq-function library (sanitize_har, sanitize_console). Unit-tested in isolation.
- 7-iii: wire sanitizer into `inspect --capture-console --capture-network --capture` (writes console.json + network.har, sanitized by default).
- 7-iv: `--unsanitized` typed-phrase ack + `meta.json::sanitized:false` audit flag + `doctor` counter.
- 7-v: `capture_prune` (count>500 / age>14d) + retention thresholds in `~/.browser-skill/config.json`.

### Recipe-doc catch-up — three reusable patterns extracted (pre-Phase-7)

- [docs] `references/recipes/privacy-canary.md` — sentinel-byte regression test for any verb that ingests caller-supplied secrets via stdin. Layered bash + daemon coverage; canary-string discipline (unique per test, ASCII, ≥10 chars, distinct from injected payload); negative-grep + positive-shape combo (rejects "no output false-pass"); explicit "DON'T grep `${BROWSER_SKILL_HOME}`" rule (disk persistence is the credential-backend test's invariant, not the privacy canary's). Ten existing instances cited.
- [docs] `references/recipes/path-security.md` — four-step block (existence + regular-file → readable → sensitive-pattern reject → realpath canonicalize) for any verb taking `--path PATH`. Source of truth: `scripts/browser-upload.sh:74-103`. Documents resolve-then-check vs check-then-resolve ordering trade-off (browser-upload shipped check-then-resolve; resolve-first is paranoid form for new verbs). Cross-platform `realpath || readlink -f || printf` fallback chain explained.
- [docs] `references/recipes/body-bytes-not-body.md` — for caller-supplied content (HTTP bodies, blobs), reply ships `<thing>_bytes` (length), never `<thing>` (content). Source of truth: `scripts/lib/node/chrome-devtools-bridge.mjs::case 'route'` fulfill branch. `Buffer.byteLength` vs `.length` gotcha (utf-16 code-unit mismatch); bash `wc -c` analogue; defensive double-scrub idiom from fill verb (line ~432).
- [docs] `docs/superpowers/HANDOFF.md` — marks all three recipes shipped; removes "overdue" markers from workflow-expectations section; PR count 55.

**Why now (pre-Phase-7):** Phase 7 (capture pipeline + sanitization) will reuse path-security as a primitive (sanitization-write-to-file gate) and body-bytes-not-body for sanitizer-output replies. Cheaper to extract patterns now than mid-Phase-7. Pure-docs PR; near-zero risk.

### Phase 6 part 7-ii — `route` verb extension: `--action fulfill` (closes Phase 6)

- [feat] `scripts/browser-route.sh` — accept `--action fulfill` (block/allow/fulfill triad complete). Adds `--status N` (HTTP code, integer 100-599) + body transport (`--body STR` ⊕ `--body-stdin`, mutex). Bash-side validation: `--status` / `--body*` rejected when paired with `block`/`allow`; fulfill requires both status + body; status range + integer-shape enforced. Body-via-stdin uses the same passthrough pattern as `fill --secret-stdin` (browser-fill.sh:87) — bash forwards the `--body-stdin` flag and stdin inherits naturally to the bridge subprocess.
- [feat] `scripts/lib/node/chrome-devtools-bridge.mjs::runRouteViaDaemon` — parses `--status` / `--body` / `--body-stdin`; reads stdin via existing `readAllStdin` helper on `--body-stdin`; passes status + body through IPC to daemon child.
- [feat] `scripts/lib/node/chrome-devtools-bridge.mjs` daemon-child `case 'route'` — `routeRules` slot extends from `{pattern, action}` to `{pattern, action: 'fulfill', status, body}` for fulfill rules; defensive validation re-checks status range + body presence (defense in depth — surface area for non-CLI callers); calls upstream MCP `route_url` with `{pattern, action, status?, body?}`. Reply adds `fulfill_status` + `body_bytes` (byte length, not the body itself — avoids re-emitting agent-supplied content; large bodies stay out of stdout).
- [feat] **Body verbatim policy.** Unlike `fill --secret-stdin` (which strips a trailing newline since secrets shouldn't carry one), `route fulfill` stores the body **as-is** including trailing bytes — HTTP bodies are content where round-trip fidelity matters. Daemon e2e test asserts roundtrip.
- [security] Body lives **in-memory only** in the daemon process (mirrors 7-i routeRules). Never written to disk; dies with the daemon. `body_bytes` (not `body`) ships in the reply by default — avoids accidental terminal/log capture.
- [adapter] `scripts/lib/tool/chrome-devtools-mcp.sh::tool_route` — no change required. Existing `rest=()` passthrough already forwards `--status` / `--body` / `--body-stdin` to the bridge.
- [internal] `tests/stubs/mcp-server-stub.mjs` — `route_url` handler echoes `(status N, M bytes)` suffix on `action: 'fulfill'` so e2e can assert the call shape end-to-end.
- [internal] `tests/browser-route.bats` (+8 cases, 1 rewritten) — fulfill happy dry-run with `fulfill_status` + `body_bytes` in summary; missing-status; missing-body; body / body-stdin mutex; `--status 99` out of range (mentions "100-599"); `--status notanumber` non-integer; `--status` with `--action block` rejected; `--body` with `--action allow` rejected. Old "fulfill rejected with 7-ii hint" case rewritten as positive happy-path test.
- [internal] `tests/chrome-devtools-mcp_daemon_e2e.bats` (+3 cases) — fulfill via daemon registers extended rule + persists status + body length + observes `route_url` MCP call with `status` + `body` args; `--body-stdin` body roundtrips verbatim (byte length matches); out-of-range status arriving at the bridge (defensive) returns error event mentioning "100-599".
- [docs] `docs/superpowers/plans/2026-05-07-phase-06-part-7-ii-route-fulfill.md` — phase plan.

**Sub-scope (7-ii):**
- Three actions accepted: `block` | `allow` | `fulfill`. The fulfill-only flags (`--status`, `--body`, `--body-stdin`) are validated bash-side AND daemon-side (defense in depth). Bridge layer is the validating boundary if the IPC is exercised by a non-CLI caller.
- Body byte length is the contract surfaced in the reply (`body_bytes`); the body string itself is not re-emitted.
- Body-stdin transport: bash → bridge stdin (passthrough, no bash-side stdin read) → bridge `readAllStdin` → IPC `body` field → daemon-child store.

**Documented limitations:**
- Bash variables and JSON IPC strings can't carry the NUL byte itself. Multipart bodies legitimately containing NUL would need a different transport (file path? base64?). Not in scope for 7-ii.
- `readAllStdin` reads as utf-8. Non-utf8 binary bytes aren't a target use case for 7-ii (HTTP API mocking is the primary motivation).

**Phase 6 progress: 11 of 11 declared verbs.** ✅ **Phase 6 COMPLETE.**

### Phase 6 part 8-iii — `tab-close` verb (last tab-* verb; closes Phase 6 tab trilogy)

- [feat] new `scripts/browser-tab-close.sh` verb — mutex selectors `--tab-id N` ⊕ `--by-url-pattern STR`. Symmetric with tab-switch but uses canonical `--tab-id` (matches `tab_id` from tab-list output) instead of `--by-index` (positional). Reasoning: index drifts as the array shrinks during successive closes; canonical id is unambiguous. **Daemon-required.** Routes to chrome-devtools-mcp via new `rule_tab_close_default`.
- [feat] `scripts/lib/node/chrome-devtools-bridge.mjs` — new `runTabCloseViaDaemon` (defensively re-validates the mutex). Dispatch case `'tab-close'`: auto-refreshes `tabs[]` if empty (mirrors tab-switch); resolves selector → tab object; calls upstream MCP `close_page` (best-effort name; real upstream may differ); splices the matching entry from `tabs[]`; nulls `currentTab` if it pointed at the closed tab. Returns `{closed_tab, current_tab_id, tab_count}`. **`tab_id` values stay stable on remaining entries** — agents holding a `tab_id` reference shouldn't see it silently rebound.
- [feat] `scripts/lib/router.sh::rule_tab_close_default` — verb=`tab-close` → chrome-devtools-mcp.
- [adapter] `scripts/lib/tool/chrome-devtools-mcp.sh` — `tab-close` capability declared (`flags: ["--tab-id", "--by-url-pattern"]`); new `tool_tab-close` dispatcher.
- [internal] `tests/stubs/mcp-server-stub.mjs` — `close_page` handler echoes `closed tab N (URL)`.
- [internal] new `tests/browser-tab-close.bats` (8 cases) — missing-both-flags, mutex, `--tab-id 0` (1-based), empty `--by-url-pattern`, ghost-tool, capability filter, dry-run, router routing.
- [internal] `tests/chrome-devtools-mcp_daemon_e2e.bats` (+7) — by-tab-id happy + `close_page` MCP call observed; by-url-pattern substring resolution; closing currentTab nulls `current_tab_id`; closing non-current preserves `current_tab_id`; out-of-range `--tab-id` error; no-match pattern error; no-daemon exit-41.
- [docs] `SKILL.md` — chrome-devtools-mcp adapter row auto-bumped to 18 verbs.
- [docs] `docs/superpowers/plans/2026-05-06-phase-06-part-8-iii-tab-close.md` — phase plan.

**Sub-scope (8-iii):**
- Mutex selectors only — exactly one of canonical id / pattern.
- `tab_id` stability across closes is an explicit contract (no renumbering).
- `currentTab` invalidation on close-match — agents see `current_tab_id: null` in subsequent `tab-list` output.
- No auto-fallback to a remaining tab on close — keeps the agent's mental model explicit.

**Phase 6 progress: 10 of 10 declared verbs.** All Phase 6 tab-* verbs done (tab-list / tab-switch / tab-close). Only route fulfill (7-ii) remains as an independent track within Phase 6 (deferred — body management adds stdin-mux + binary-safety + persistence in `routeRules`).

### Phase 6 part 8-ii — `tab-switch` verb (first state-mutation on `tabs[]`)

- [feat] new `scripts/browser-tab-switch.sh` verb — mutex selectors `--by-index N` (1-based) ⊕ `--by-url-pattern STR` (substring-contains, first-match-wins). **Daemon-required.** Routes to chrome-devtools-mcp via new `rule_tab_switch_default`.
- [feat] `scripts/lib/node/chrome-devtools-bridge.mjs` — new `runTabSwitchViaDaemon` (defensively re-validates the mutex). Daemon child gains `currentTab` slot (number | null — the tab_id pointer; tab metadata stays in `tabs[]`). New `refreshTabs()` helper shared between `tab-list` and `tab-switch` (the latter auto-refreshes `tabs[]` when empty so agents needn't remember to call `tab-list` first). Dispatch case `'tab-switch'` resolves selector → tab object, calls upstream MCP `select_page` (best-effort name; real upstream may differ — binding hardening tracked downstream), updates `currentTab`, returns `{ current_tab: { tab_id, url, title }, ... }`.
- [feat] `scripts/lib/node/chrome-devtools-bridge.mjs` — `tab-list` output now annotates `is_current: true` on the entry whose `tab_id` matches `currentTab`, plus `current_tab_id` field at top level. Was queued for 8-iii but folded in here since `currentTab` is introduced in this sub-part.
- [feat] `scripts/lib/router.sh::rule_tab_switch_default` — verb=`tab-switch` → chrome-devtools-mcp.
- [adapter] `scripts/lib/tool/chrome-devtools-mcp.sh` — `tab-switch` capability declared (`flags: ["--by-index", "--by-url-pattern"]`); new `tool_tab-switch` dispatcher.
- [internal] `tests/stubs/mcp-server-stub.mjs` — `select_page` handler echoes `selected tab N (URL)`.
- [internal] new `tests/browser-tab-switch.bats` (8 cases) — missing-both-flags, mutex, `--by-index 0` (1-based), empty `--by-url-pattern`, ghost-tool, capability filter, dry-run, router routing.
- [internal] `tests/chrome-devtools-mcp_daemon_e2e.bats` (+7) — by-index happy + `select_page` MCP call observed; by-url-pattern substring resolution; auto-refresh when `tabs[]` empty (no preceding tab-list); by-url-pattern no-match error; by-index out-of-range error; no-daemon exit-41; `is_current` annotation in `tab-list` output after switch.
- [docs] `SKILL.md` — chrome-devtools-mcp adapter row auto-bumped to 17 verbs.
- [docs] `docs/superpowers/plans/2026-05-06-phase-06-part-8-ii-tab-switch.md` — phase plan.

**Sub-scope (8-ii):**
- Mutex selectors only — exactly one of index / pattern.
- Substring-contains is intentionally simple. `--by-url-regex` / `--by-url-glob` deferred to follow-up.
- `currentTab` is just the `tab_id` (number) — single source of truth for tab metadata stays in `tabs[]`.

**Deferred to part 8-iii (`tab-close`):**
- `--tab-id N` ⊕ `--by-url-pattern STR` (mutex). Splice from `tabs[]` + close upstream page.
- `currentTab` invalidation when the closed tab matches.

Phase 6 progress: **9 of 10 declared verbs** (press / select / hover / wait / drag / upload / route / tab-list / tab-switch). Remaining: tab-close (8-iii); route fulfill (7-ii) is independent.

### Phase 6 part 8-i — `tab-list` verb foundation (multi-tab daemon-state slot)

- [feat] new `scripts/browser-tab-list.sh` verb — no required flags. Routes to chrome-devtools-mcp via new `rule_tab_list_default`. **Daemon-required** (mirrors route precedent — caches tabs in the daemon's new `tabs` slot so 8-ii / 8-iii can mutate the same shape). Without daemon → exit 41 with hint.
- [feat] `scripts/lib/node/chrome-devtools-bridge.mjs` — new `runTabListViaDaemon` (parallel to `runRouteViaDaemon`, no args). Daemon child gains `tabs` state slot (array of `{tab_id, url, title}`). Dispatch case `'tab-list'` calls upstream MCP `list_pages` (best-effort name; real upstream may use a different tool — binding hardening tracked in 8-ii / 8-iii), normalizes to `[{tab_id, url, title}]`, **replaces** (not appends) the cache, returns it with `tab_count`.
- [feat] `scripts/lib/router.sh::rule_tab_list_default` — verb=`tab-list` → chrome-devtools-mcp.
- [adapter] `scripts/lib/tool/chrome-devtools-mcp.sh` — `tab-list` capability declared (`flags: []`); new `tool_tab-list` dispatcher.
- [internal] `tests/stubs/mcp-server-stub.mjs` — `list_pages` handler returns canned 2-page array (`example.com/`, `example.org/news`).
- [internal] new `tests/browser-tab-list.bats` (5 cases) — ghost-tool, capability filter rejects (playwright-cli has no `tab-list`), dry-run shape, router routing, capability declaration.
- [internal] `tests/chrome-devtools-mcp_daemon_e2e.bats` (+3) — daemon happy (`tab_count==2` + `tab_id`/`url`/`title` shape + `list_pages` MCP call observed), idempotent (second call replaces cache, doesn't accumulate), no-daemon exit-41.
- [docs] `SKILL.md` — chrome-devtools-mcp adapter row auto-bumped to 16 verbs.
- [docs] `docs/superpowers/plans/2026-05-06-phase-06-part-8-i-tab-list.md` — phase plan.

**Sub-scope (8-i — minimal):**
- Read-only enumeration. `tab_id` is bridge-assigned (1-based, stable per `list_pages` call). Upstream's CDP target id never escapes the bridge — agents only see the stable `tab_id` contract.
- Foundation: `tabs[]` daemon slot ships before any verb mutates it.

**Deferred to part 8-ii (`tab-switch`):**
- `--by-index N` ⊕ `--by-url-pattern STR` (mutex). Updates a new `currentTab` pointer in the daemon.
- Active-tab annotation in `tab-list` output.

**Deferred to part 8-iii (`tab-close`):**
- `--tab-id N` ⊕ `--by-url-pattern STR`. Splices the matching entry out of `tabs[]` + closes the page upstream.

**Deferred (part 7-ii is independent):**
- Real upstream binding (canonical MCP tool name; `list_pages` is the bridge's best-effort convention — upstream may use `pages.list`, `targets.list`, etc.).

Phase 6 progress: **8 of 8 verbs declared** (press / select / hover / wait / drag / upload / route / tab-list); tab-switch + tab-close (8-ii / 8-iii) and route fulfill (7-ii) remain as separate sub-PRs.

### Phase 6 part 7-i — `route` verb foundation (block + allow only; fulfill deferred)

- [feat] new `scripts/browser-route.sh` verb — `--pattern URL_PATTERN` + `--action allow|block` (required). Routes to chrome-devtools-mcp via new `rule_route_default`. **Daemon-state-mutating** (registers `{pattern, action}` in daemon's `routeRules` array). Daemon-required.
- [feat] `scripts/lib/node/chrome-devtools-bridge.mjs` — new `runRouteViaDaemon` dispatcher (parallel to `runStatefulViaDaemon` but no refMap dependency). Daemon child gains `routeRules` state slot (array of `{pattern, action}` entries). Dispatch case `'route'` validates action against `{block, allow}`, appends rule, best-effort calls MCP `route_url` (real upstream tool name may differ — binding hardening is part 7-ii), emits ack with `rule_count`.
- [feat] `scripts/lib/router.sh::rule_route_default` — verb=`route` → chrome-devtools-mcp.
- [adapter] `scripts/lib/tool/chrome-devtools-mcp.sh` — `route` capability declared (`flags: ["--pattern", "--action"]`); new `tool_route` dispatcher.
- [internal] `tests/stubs/mcp-server-stub.mjs` — `route_url` handler echoes `routed <pattern> → <action>`.
- [internal] new `tests/browser-route.bats` (8 cases) — missing-pattern, missing-action, fulfill rejected with hint, invalid-action, ghost-tool, capability filter, dry-run, router routing.
- [internal] `tests/chrome-devtools-mcp_daemon_e2e.bats` (+4) — daemon block-action happy (rule registered, MCP ack), 2 calls accumulate (`rule_count == 2`), invalid-action error event, no-daemon exit-41.
- [docs] `SKILL.md` — `route` row added (auto-regenerated).
- [docs] `docs/superpowers/plans/2026-05-05-phase-06-part-7-i-route.md` — phase plan.

**Sub-scope (7-i — minimal):**
- `block` and `allow` actions only.
- Foundation for daemon-side rule storage; runtime application of rules to actual network requests is upstream MCP's responsibility.

**Deferred to part 7-ii:**
- `--action fulfill` with `--status N` and `--body BODY` (synthetic responses). Body via stdin per AP-7 since bodies can be arbitrary content.
- Rule removal (`route remove --pattern X`) and listing (`route list`).
- Real upstream binding (correct MCP tool name + canonical action verbs). Current `route_url` is a stub-only convention.

Phase 6 progress: **7 of 8 verbs** (press / select / hover / wait / drag / upload / route). Remaining: tab-*.

### Phase 6 part 6 — `upload` verb (`<input type=file>` upload with path security)

- [feat] new `scripts/browser-upload.sh` verb — `--ref eN` + `--path PATH`. Routes to chrome-devtools-mcp via new `rule_upload_default`. Stateful (refMap precondition).
- [security] **Path security validation, bash-side BEFORE adapter dispatch:**
  1. Path must exist and be a regular file (not dir, not device).
  2. Path must be readable by the current user.
  3. Path must NOT match common sensitive patterns (`*.ssh/*`, `*/.aws/credentials`, `*.env`, `*credentials*`, `*/private_key*`, `*/id_rsa*`/`id_ed25519*`/`id_ecdsa*`).
  4. Override sensitive-pattern reject via `--allow-sensitive` ack flag (covers legit "upload my GPG key" use cases).
  5. Resolve to canonical path via `realpath`/`readlink -f` (eliminates symlink shenanigans) before forwarding to MCP.
- [feat] `scripts/lib/router.sh::rule_upload_default` — verb=`upload` → chrome-devtools-mcp.
- [adapter] `scripts/lib/tool/chrome-devtools-mcp.sh` — `upload` declared in capabilities (`flags: ["--ref", "--path"]`); new `tool_upload` dispatcher.
- [feat] `scripts/lib/node/chrome-devtools-bridge.mjs::runStatefulViaDaemon` — `upload` early-return branch (parallel to drag's 2-arg shape) parses `<ref> <path>`. Daemon dispatch resolves ref → uid, calls MCP `upload_file` with `{uid, path}`. Path is forwarded as-is (already validated bash-side).
- [internal] `tests/stubs/mcp-server-stub.mjs` — `upload_file` handler echoes `uploaded <path> to <uid>`.
- [internal] new `tests/browser-upload.bats` (12 cases) — missing-ref, missing-path, nonexistent-path, dir-not-file, unreadable-file, SSH-key reject, .env reject, --allow-sensitive bypass, ghost-tool, capability filter, dry-run, router routing.
- [internal] `tests/chrome-devtools-mcp_daemon_e2e.bats` (+2) — daemon happy via uid translation, no-daemon exit-41.
- [docs] `SKILL.md` — `upload` row added (auto-regenerated).
- [docs] `docs/superpowers/plans/2026-05-05-phase-06-part-6-upload.md` — phase plan.

After this PR, `bash scripts/browser-upload.sh --ref e3 --path ~/Downloads/file.pdf` works end-to-end (with daemon). Sensitive-path defense protects against agent-misdirection attacks where a webpage's instructions try to coerce uploading SSH keys / .env files / credentials.

Phase 6 progress: **6 of 8 verbs** (press / select / hover / wait / drag / upload). Remaining: route / tab-*.

### Phase 6 part 5 — `drag` verb (pointer drag from src → dst by refs)

- [feat] new `scripts/browser-drag.sh` verb — `--src-ref eA` + `--dst-ref eB` (both required). Routes to chrome-devtools-mcp via new `rule_drag_default`. Stateful — refMap precondition for **both** refs (mirrors click/select shape, with two-ref translation).
- [feat] `scripts/lib/router.sh::rule_drag_default` — verb=`drag` → chrome-devtools-mcp.
- [adapter] `scripts/lib/tool/chrome-devtools-mcp.sh` — `drag` declared in capabilities (`flags: ["--src-ref", "--dst-ref"]`); new `tool_drag` dispatcher.
- [feat] `scripts/lib/node/chrome-devtools-bridge.mjs::runStatefulViaDaemon` — drag has 2-ref argv shape (`drag <src-ref> <dst-ref>`), special-cased above the single-ref shape used by click/fill/select/hover. Daemon dispatch `case 'drag'` resolves both refs → uids, calls MCP `drag` tool with `{src_uid, dst_uid}`.
- [internal] `tests/stubs/mcp-server-stub.mjs` — `drag` handler echoes `dragged <src> → <dst>`.
- [internal] new `tests/browser-drag.bats` (6 cases) — missing-src-ref, missing-dst-ref, ghost-tool, capability filter, dry-run, router routing.
- [internal] `tests/chrome-devtools-mcp_daemon_e2e.bats` (+4) — daemon happy (both refs translated), no-daemon exit-41, unknown src ref error, unknown dst ref error.
- [docs] `SKILL.md` — `drag` row added (auto-regenerated).
- [docs] `docs/superpowers/plans/2026-05-05-phase-06-part-5-drag.md` — phase plan.

After this PR, `bash scripts/browser-drag.sh --src-ref e3 --dst-ref e7` works end-to-end (with daemon). Phase 6 progress: 5 of 8 verbs (press / select / hover / wait / drag). Remaining: upload / route / tab-*.

Selector-based drag (`--src-selector`/`--dst-selector`) deferred to follow-up.

### Phase 6 part 4 — `wait` verb (explicit element-state wait)

- [feat] new `scripts/browser-wait.sh` verb — `--selector CSS` + `--state visible|hidden|attached|detached` (default visible) + `--timeout MS` (default: MCP server's default). Routes to chrome-devtools-mcp via new `rule_wait_default`. Stateless — works one-shot or daemon-routed (parallel to eval/audit).
- [feat] `scripts/lib/router.sh::rule_wait_default` — verb=`wait` → chrome-devtools-mcp.
- [adapter] `scripts/lib/tool/chrome-devtools-mcp.sh` — `wait` declared in capabilities (`flags: ["--selector", "--state", "--timeout"]`); new `tool_wait` dispatcher.
- [feat] `scripts/lib/node/chrome-devtools-bridge.mjs` — `translateVerb`/`shapeResponse`/`runStatelessViaDaemon`/daemon dispatch all gain `wait` cases. Passes `{selector, state?, timeout?}` to MCP `wait_for` tool.
- [internal] `tests/stubs/mcp-server-stub.mjs` — `wait_for` handler echoes `waited for <selector> to be <state>`.
- [internal] new `tests/browser-wait.bats` (6 cases) — missing-selector, invalid-state, ghost-tool, capability filter, dry-run, router routing.
- [internal] `tests/chrome-devtools-bridge_real.bats` (+1) — one-shot real-mode wait dispatches `wait_for`.
- [internal] `tests/chrome-devtools-mcp_daemon_e2e.bats` (+1) — daemon-routed wait emits `attached_to_daemon: true`.
- [docs] `SKILL.md` — `wait` row added (auto-regenerated).
- [docs] `docs/superpowers/plans/2026-05-05-phase-06-part-4-wait.md` — phase plan.

After this PR, `bash scripts/browser-wait.sh --selector ".dashboard" --state visible --timeout 5000` works end-to-end. Phase 6 progress: 4 of 8 verbs (press / select / hover / wait). Remaining: drag / upload / route / tab-*.

### Phase 6 part 3 — `hover` verb (pointer hover by ref)

- [feat] new `scripts/browser-hover.sh` verb — `--ref eN`. Routes to chrome-devtools-mcp via new `rule_hover_default`. Stateful (refMap precondition; mirrors click/select).
- [feat] `scripts/lib/router.sh::rule_hover_default` — verb=`hover` → chrome-devtools-mcp. Slotted between `rule_select_default` and `rule_default_navigation`.
- [adapter] `scripts/lib/tool/chrome-devtools-mcp.sh` — `hover` declared in capabilities (`flags: ["--ref"]`); new `tool_hover` dispatcher.
- [feat] `scripts/lib/node/chrome-devtools-bridge.mjs::runStatefulViaDaemon` — extended for `hover` (parallel to click). Daemon dispatch `case 'hover'` resolves ref → uid, calls MCP `hover` tool.
- [internal] `tests/stubs/mcp-server-stub.mjs` — `hover` handler echoes `hovered <uid>`.
- [internal] new `tests/browser-hover.bats` (5 cases) — missing-ref, ghost-tool, capability filter, dry-run, router routing.
- [internal] `tests/chrome-devtools-mcp_daemon_e2e.bats` (+3) — daemon happy path (uid translation), no-daemon exit-41, unknown-ref error.
- [docs] `SKILL.md` — `hover` row added (auto-regenerated).
- [docs] `docs/superpowers/plans/2026-05-05-phase-06-part-3-hover.md` — phase plan.

`--selector` path deferred to follow-up if user demand surfaces (current shape is `--ref`-only mirroring click/select).

### Phase 6 part 2 — `select` verb (`<select>` option pick by ref)

- [feat] new `scripts/browser-select.sh` verb — `--ref eN` (required) + exactly one of `--value VAL` / `--label LABEL` / `--index N`. Mode-flag mutex enforced (uses-counter idiom).
- [feat] `scripts/lib/router.sh::rule_select_default` — verb=`select` → chrome-devtools-mcp. Slotted between `rule_press_default` and `rule_default_navigation`.
- [adapter] `scripts/lib/tool/chrome-devtools-mcp.sh` — `select` declared in capabilities (`flags: ["--ref", "--value", "--label", "--index"]`); new `tool_select` dispatcher.
- [feat] `scripts/lib/node/chrome-devtools-bridge.mjs::runStatefulViaDaemon` — extended to handle `select`. New daemon dispatch case translates `eN → uid` from refMap, calls MCP `select_option` with `uid` + value/label/index. Stateful — refMap precondition (mirrors click/fill).
- [internal] `tests/stubs/mcp-server-stub.mjs` — `select_option` handler echoes `selected <uid> by <mode>=<val>`.
- [internal] new `tests/browser-select.bats` (7 cases) — missing-ref, missing-mode, mode mutex, ghost-tool, capability filter, dry-run, router routing.
- [internal] `tests/chrome-devtools-mcp_daemon_e2e.bats` (+5) — daemon-routed select via value / label / index, no-daemon exit-41, unknown-ref error.
- [docs] `SKILL.md` — `select` row added (auto-regenerated).
- [docs] `docs/superpowers/plans/2026-05-05-phase-06-part-2-select.md` — phase plan.

After this PR, `bash scripts/browser-select.sh --ref e3 --value alpha` works end-to-end (with a running daemon) against a real upstream chrome-devtools-mcp server.

Untouched per scope discipline: every other adapter / verb / lib / test (only Phase 6 part 2 surface).

### Phase 6 part 1 — `press` verb (keyboard input via cdt-mcp)

Phase 6 begins. Bulk verbs (press / select / hover / wait / drag / upload / route / tab-*) round out the interaction surface per parent spec Appendix A. Smallest first: pure stateless keyboard input.

- [feat] new `scripts/browser-press.sh` verb — `--key KEY` (e.g. `Enter`, `Tab`, `Escape`, `ArrowDown`, `Cmd+S`). Routes to chrome-devtools-mcp by default via new `rule_press_default`.
- [feat] `scripts/lib/router.sh::rule_press_default` — verb=`press` → chrome-devtools-mcp. Slotted between `rule_extract_default` and `rule_default_navigation`. playwright-cli/lib don't declare press today (could be added later via their `keyboard.press` APIs).
- [adapter] `scripts/lib/tool/chrome-devtools-mcp.sh` — `press` declared in capabilities (`flags: ["--key"]`). New `tool_press` dispatcher shells to bridge.
- [feat] `scripts/lib/node/chrome-devtools-bridge.mjs` — daemon dispatch + one-shot `press` translation → MCP `press_key` tool. Stateless w.r.t. refMap; works in both daemon and one-shot paths (mirrors `eval`/`audit`/`open`).
- [feat] `scripts/lib/node/chrome-devtools-bridge.mjs::shapeResponse` — new `press` case emits `key` field alongside the standard summary.
- [internal] `tests/stubs/mcp-server-stub.mjs` — `press_key` handler emits `pressed <key>` content.
- [internal] new `tests/browser-press.bats` (6 cases) — happy lib-stub path, missing-flag rejection, ghost-tool rejection, capability-filter rejection of `--tool=playwright-cli`, dry-run, router routing assertion.
- [internal] `tests/chrome-devtools-bridge_real.bats` (+1) — one-shot real-mode press dispatches `press_key`.
- [internal] `tests/chrome-devtools-mcp_daemon_e2e.bats` (+1) — daemon-routed press emits `attached_to_daemon: true`; stub log verifies key passthrough.
- [docs] `SKILL.md` — `press` row added (auto-regenerated by `scripts/regenerate-docs.sh`).
- [docs] `references/chrome-devtools-mcp-cheatsheet.md` — auto-regenerated capability table now lists press.

After this PR, `bash scripts/browser-press.sh --key Enter` works end-to-end against a real upstream chrome-devtools-mcp server (one-shot) or via the daemon when running. Foundation for Phase 6's remaining verbs (select / hover / wait / drag / upload / route / tab-*).

Untouched per scope discipline: `scripts/lib/tool/playwright-{cli,lib}.sh` (could declare press in a follow-up if `keyboard.press` integration desired), `scripts/browser-{open,click,fill,snapshot,inspect,audit,extract,eval}.sh` (unchanged), all credentials/session libs.


### Phase 5 part 4-iv — `creds rotate-totp` verb (Phase 5 FEATURE-COMPLETE)

- [feat] new `scripts/browser-creds-rotate-totp.sh` — re-enroll TOTP shared secret for an existing totp_enabled credential. Use case: service forces a new TOTP secret (re-issued QR code during account recovery, security-incident rotation, etc.). Replaces the `<name>__totp` backend slot with a new value; metadata.totp_enabled stays true; password slot UNCHANGED.
- [security] **AP-7 strict** — new TOTP secret comes via stdin only (`--totp-secret-stdin` required). Refuses argv-based secrets.
- [security] **Typed-phrase confirmation** mirrors `creds-migrate` and `creds-remove` patterns. Default: prompts for cred name; `--yes-i-know` skips for scripted use.
- [security] Refuses non-totp_enabled creds (use `creds-add --enable-totp` for first-time enrollment).
- [security] Privacy invariant: new TOTP secret NEVER appears in stdout/stderr. Sentinel canary tested (`sekret-do-not-leak-rotate-totp`).
- [internal] new `tests/creds-rotate-totp.bats` (11 cases) — `--as` required, `--totp-secret-stdin` required (AP-7 enforcement), unknown cred → EXIT_SITE_NOT_FOUND, non-totp refusal, empty-stdin refusal, `--dry-run` skips mutation, confirmation mismatch aborts, `--yes-i-know` happy path overwrites, **privacy canary**, password slot regression guard (untouched), metadata regression guard (totp_enabled stays true).
- [docs] `SKILL.md` — new `creds totp` and `creds rotate-totp` rows.
- [docs] `docs/superpowers/plans/2026-05-05-phase-05-part-4-iv-rotate-totp.md` — phase plan.

**🎉 Phase 5 is FEATURE-COMPLETE.** All HANDOFF queue items shipped:
- Part 1 (cdt-mcp track): adapter + bridge + daemon + 8/8 verbs real-mode + Path B router + verb scripts + session loading.
- Part 2 (creds track): 5 verbs + 3 backends + smart auto-detect + masked reveal + first-use plaintext gate.
- Part 3 (auth track): login --auto + transparent verb-retry + auth-flow declaration + 2FA detection.
- Part 4 (TOTP track): foundation flag + codegen + auto-replay + rotation. **End-to-end auto-relogin for 2FA-protected sites.**

Next phases (per parent spec): 6 (bulk verbs), 7 (capture pipeline), 8 (obscura adapter), 9 (flow runner), 10 (schema migration tooling).

Untouched per scope discipline: every other verb script, all adapters, router rules, common.sh, all session/site/credential libs (uses existing `credential_set_totp_secret` API from part 4-ii).

### Phase 5 part 4-iii — `login --auto` TOTP auto-replay (closes auth track)

- [feat] `scripts/lib/node/totp-core.mjs` — extracted from `totp.mjs` so other modules can import the same `totpAt` / `base32Decode` primitives. CLI `totp.mjs` is now a thin shim. Both share zero-dep RFC 6238 logic; existing 8 RFC test vectors still pass.
- [feat] `scripts/lib/node/playwright-driver.mjs::runAutoRelogin` — when stdin includes a 3rd NUL-separated chunk (TOTP shared secret), and `detect2FA(page)` fires after the username+password submit, the driver imports `totpAt` from `totp-core.mjs`, generates the current code, fills the OTP field via best-effort selectors (`input[autocomplete="one-time-code"]`, `input[name*="otp" i]`, etc.), submits, awaits navigation, then captures `storageState` (the normal happy path). When TOTP secret absent: existing exit-25 path.
- [feat] `scripts/browser-login.sh::--auto` — when cred metadata `totp_enabled: true`, appends `\0` + TOTP secret to the stdin pipe. Fully transparent — non-totp creds preserve the 2-chunk stdin protocol unchanged.
- [feat] **End-to-end auto-relogin for 2FA-protected sites.** Agent registers a TOTP-enabled cred once (`creds-add --enable-totp --yes-i-know-totp --totp-secret-stdin`). On any session-aware verb that hits `EXIT_SESSION_EXPIRED`, the verb's transparent retry (part 3-ii) → `login --auto` → driver detects 2FA → driver auto-replays TOTP → captures fresh storageState → verb retries successfully. **Zero agent intervention** for sites with TOTP-only 2FA.
- [internal] Driver test-mode hook `BROWSER_SKILL_DRIVER_TEST_TOTP_REPLAY=1` short-circuits to a "totp-replayed" path that exercises the totp-core import + emits an `auto-relogin-totp-replayed` event without launching a real Chrome. Lets bats verify the bash-side stdin-mux + totp-core wiring.
- [internal] `tests/login.bats` (+2 cases) — `_seed_totp_cred` helper creates a totp_enabled cred via `credential_set_totp_secret`. Test 1: totp_enabled cred → driver receives 3rd stdin chunk + emits totp-replayed event. Test 2: non-totp cred → 2 chunks (regression dry-run path).
- [docs] `docs/superpowers/plans/2026-05-05-phase-05-part-4-iii-totp-auto-replay.md` — phase plan.

After this PR, the **auth track is fully end-to-end**: passwords-only sites work via part 3 + 3-ii; 2FA sites with stored TOTP work via 4-iii. The only remaining auth-track item is `creds rotate-totp` (part 4-iv) for service-forced TOTP re-enrollment.

Untouched per scope discipline: `scripts/lib/credential.sh` (already had `credential_get_totp_secret` from part 4-ii), `scripts/lib/secret/*.sh`, every other verb script, all adapters, router rules.

### Phase 5 part 4-ii — TOTP code generation + secret persistence

- [feat] new `scripts/lib/node/totp.mjs` — pure-node RFC 6238 TOTP code generator. Uses node's `crypto.createHmac` (no external deps). Reads base32-encoded shared secret from stdin; emits 6-digit code on stdout for the current 30s window. Supports env-var overrides for tests: `TOTP_TIME_T` (override "now"), `TOTP_DIGITS`, `TOTP_PERIOD`, `TOTP_ALG`. **Validated against all 5 RFC 6238 §A test vectors** for SHA1.
- [feat] `scripts/lib/credential.sh` — new `credential_set_totp_secret NAME` + `credential_get_totp_secret NAME` API. TOTP shared secret stored in the same backend as the password but under a sibling slot named `<NAME>__totp` (double-underscore suffix is allowed by `assert_safe_name`'s regex `^[A-Za-z0-9_-]+$` so backends validate the slot name through their normal path). Each cred's metadata still has only one entry; the backend has two secret slots (password + TOTP).
- [feat] `scripts/browser-creds-add.sh` — new `--totp-secret-stdin` flag. Reads `password\0totp_secret` from stdin (NUL-separated, AP-7: secrets never on argv). Requires `--enable-totp`. Uses `read -r -d ''` because `$(cat)` strips embedded NUL bytes ("warning: ignored null byte"). Stores TOTP secret via `credential_set_totp_secret` after the regular password write.
- [feat] new `scripts/browser-creds-totp.sh` verb — `--as CRED_NAME` reads stored TOTP secret, pipes it to `totp.mjs`, emits 6-digit code on stdout. Refuses if cred is not totp_enabled. Refuses unknown cred (EXIT_SITE_NOT_FOUND). Privacy invariant: shared secret never appears in stdout. `--dry-run` skips code generation.
- [security] Edge collision guard: `creds-add` rejects user-facing names matching `*__totp` to prevent collision with the internal slot naming convention. (E.g. user can't create a cred named `prod--admin__totp` because it would alias `prod--admin`'s TOTP slot.)
- [internal] new `tests/totp-codegen.bats` (8 cases) — 5 RFC 6238 §A test vectors, default 6-digit length, empty-stdin rejection, invalid-base32 rejection.
- [internal] new `tests/creds-totp.bats` (9 cases) — `--totp-secret-stdin` mutex with `--enable-totp`; missing-NUL-chunk rejection; happy-path stores in keychain stub at `<name>__totp` slot; `creds-totp` produces 6-digit code; refuses non-totp creds; `--as` required; unknown cred → EXIT_SITE_NOT_FOUND; `--dry-run` skips; **privacy canary** — shared secret never appears in stdout.
- [docs] `docs/superpowers/plans/2026-05-05-phase-05-part-4-ii-totp-codegen.md` — phase plan.

After this PR, an agent with a TOTP-enabled credential can run `bash scripts/browser-creds-totp.sh --as prod--admin` and get a current 6-digit code, then type/fill it into a 2FA challenge field. Auto-replay (login --auto generates the code automatically when 2FA detected) is **part 4-iii** — the final auth-track sub-part.

**Out of scope (deferred):**
- Auto-replay in `login --auto` after 2FA detection — part 4-iii. Wires `credential_get_totp_secret` + `totp.mjs` into the playwright-driver after `detect2FA` triggers.
- `creds rotate-totp` verb — part 4-iv. Re-enrollment when service forces a new TOTP secret.
- TTY-only / `--allow-non-tty` gate on `creds-totp` stdout — codes are short-lived (30s) but could leak via shell history. Could land as a 4-ii cont.

Untouched per scope discipline: `scripts/browser-login.sh` (auto-replay is part 4-iii), every other verb script, all adapters, router rules.

### Phase 5 part 4-i — TOTP foundation: `--enable-totp` flag at `creds add` time

- [feat] `scripts/browser-creds-add.sh` — new `--enable-totp` flag persists `totp_enabled: true` in cred metadata. Required co-flags: `--yes-i-know-totp` (typed acknowledgment that TOTP shared secrets are highly sensitive). Refuses `--backend plaintext` (TOTP secrets must go through OS keychain / libsecret per parent spec §1 — plaintext on-disk storage of a TOTP shared secret means anyone with read access can generate auth codes for the lifetime of the secret).
- [security] Even gated, the plaintext refusal stands: TOTP shared secrets are categorically more sensitive than passwords because they don't expire/rotate (typical service issues one secret valid until manually re-enrolled). Plaintext storage of such secrets violates parent spec §1 in spirit even if the password gate were satisfied.
- [internal] `tests/creds-add.bats` (+4 cases) — `--enable-totp` requires `--yes-i-know-totp`; refuses plaintext; happy path persists `totp_enabled=true`; regression — no `--enable-totp` defaults to false.
- [docs] `docs/superpowers/plans/2026-05-05-phase-05-part-4-i-totp-plumbing.md` — phase plan.

**Sub-scope (4-i — plumbing only):**
- Marks the cred as TOTP-enabled in metadata.
- Forbids plaintext backend for TOTP creds.
- Doesn't yet store TOTP shared secret, generate codes, or replay during login.

**Deferred to follow-up sub-parts of part 4:**
- **4-ii (codegen)** — `creds totp` verb produces a current code via `oathtool` (or node port). Manual replay path: user reads code, types into browser.
- **4-iii (auto-replay)** — `login --auto` reads TOTP secret + generates code + fills 2FA field after detecting the challenge page. Closes the loop.
- **4-iv (rotation)** — `creds rotate-totp` verb for re-enrollment when service forces a new TOTP secret.

After this PR, the TOTP track has its declaration foundation. Codegen and replay can layer on top without metadata-schema churn — part 4-ii's TOTP secret-storage uses the existing `credential.sh` backend dispatcher with a name-suffix convention (e.g. `<name>:totp` for the second slot).

Untouched per scope discipline: `scripts/lib/credential.sh` (no schema changes — `totp_enabled` field already in metadata template since part 2d), `scripts/lib/secret/*.sh` (no backend ABI changes), every other verb script, all adapters.

### Phase 5 part 3-iv — 2FA detection in `login --auto` → exit 25

- [feat] `scripts/lib/node/playwright-driver.mjs::runAutoRelogin` — new `detect2FA(page)` heuristic runs after the submit-form-and-wait sequence. Checks (in order): `input[autocomplete="one-time-code"]`, common OTP/code field name attributes (`input[name*="otp" i]`, etc.), and page text for 2FA keywords (`two-factor`, `verification code`, `authenticator app`, etc.). On match: closes the browser, emits `auto-relogin-2fa-required` JSON, exits 25 (matches bash `EXIT_AUTH_INTERACTIVE_REQUIRED`).
- [feat] `scripts/browser-login.sh::--auto` — propagates driver exit 25 as `EXIT_AUTH_INTERACTIVE_REQUIRED` with hint `"site requires 2FA / interactive challenge — re-run with --interactive (or wait for phase-5 part 4 TOTP)"`. Other non-zero exit codes from the driver still propagate as `EXIT_TOOL_CRASHED`.
- [internal] `scripts/lib/node/playwright-driver.mjs` — test-mode env var `BROWSER_SKILL_DRIVER_TEST_2FA=1` short-circuits the driver to exit 25 immediately (no browser launch). Lets bats verify the bash-side propagation without a real Chrome + 2FA challenge page. Production callers never set this.
- [internal] `tests/login.bats` (+1 case) — driver returning 25 propagates as `EXIT_AUTH_INTERACTIVE_REQUIRED` with the hint mentioning "2FA" and "interactive".
- [docs] `docs/superpowers/plans/2026-05-05-phase-05-part-3-iv-2fa-detection.md` — phase plan.

**Heuristic limitations (out of scope):**
- Push-notification 2FA flows (no input field, just a "waiting" UI) — won't be caught by selectors. The driver will time out at the navigate-after-submit wait and capture an unauthenticated session. User sees the failure later when verbs return EXIT_SESSION_EXPIRED.
- SMS-prompt fallbacks where the page asks "did you receive a code?" before showing the input — depends on text-keyword match; coverage varies.
- Real-world detection coverage validated by users; the heuristic is best-effort.

After this PR, an agent that triggers `login --auto` against a 2FA-protected site sees a clean `EXIT_AUTH_INTERACTIVE_REQUIRED` (25) within seconds rather than a 15s timeout + cryptic "no matching submit button" error. TOTP-driven 2FA (where the agent itself can produce the code) is part 4.

Untouched per scope discipline: every other adapter, router rules, common.sh exit codes (already had `EXIT_AUTH_INTERACTIVE_REQUIRED=25`), `scripts/browser-creds-*.sh`, all verb scripts other than `browser-login.sh`.

### Phase 5 part 3-iii — `--auth-flow` declaration at `creds add` time

- [feat] `scripts/browser-creds-add.sh` — new `--auth-flow STR` flag. Allowed values: `single-step-username-password` (default — backwards compatible), `multi-step-username-password`, `username-only`, `custom`. Persisted in cred metadata. Pre-3-iii the field was hardcoded to `single-step-username-password` regardless of the actual site flow.
- [feat] `scripts/browser-login.sh` — `--auto` reads `cred_meta.auth_flow` and refuses any value other than `single-step-username-password` with a clear hint pointing at `--interactive`. Pre-3-iii, `--auto` would attempt single-step selectors against any auth flow → fail mid-flight on the password field selector. Now the refusal is up-front + actionable.
- [internal] `tests/creds-add.bats` (+5 cases) — default flow, 3 valid values persisted, invalid value rejected with EXIT_USAGE_ERROR.
- [internal] `tests/login.bats` (+4 cases) — 3 refuse-on-non-standard cases (multi-step, username-only, custom), 1 regression test for single-step still working via dry-run path. `_seed_auto_cred` helper extended with optional 5th arg for auth_flow.
- [docs] `SKILL.md` — `creds add` row mentions `--auth-flow STR` flag.
- [docs] `docs/superpowers/plans/2026-05-05-phase-05-part-3-iii-auth-flow-detection.md` — phase plan.

**Out of scope (deferred):**
- **Auto-observation at add time** — open the site's login URL, scrape DOM, infer the flow shape. Substantial: needs a headless browser dispatch + heuristics. Could land as a 3-iii follow-up if user demand surfaces.
- **Multi-step / username-only auto-relogin support in playwright-driver** — needs different selector strategies in `runAutoRelogin`. Substantial enough to warrant its own sub-part (call it 3-iii-ii: multi-step support).

After this PR, `login --auto` fails fast on credentials whose `auth_flow` declares a non-standard shape — preserving the agent's time and emitting a clear hint instead of cryptic Playwright selector errors. The harness is ready when 3-iii-ii lands the actual multi-step replay logic.

Untouched per scope discipline: `scripts/lib/credential.sh` (schema unchanged — auth_flow field already in metadata), `scripts/lib/node/playwright-driver.mjs::runAutoRelogin` (selector strategies unchanged), all other verb scripts, all adapters.

### Phase 5 part 3-ii (cont.) — Wire `invoke_with_retry` into all remaining session-aware verbs

- [feat] `scripts/browser-open.sh` / `browser-click.sh` / `browser-fill.sh` / `browser-inspect.sh` / `browser-audit.sh` / `browser-extract.sh` — all 6 swap their `tool_${verb}` adapter call for `invoke_with_retry ${verb}`. Mechanical churn replicating the pattern shipped for `browser-snapshot.sh` in the previous sub-PR. Now session expiry → silent re-login → retry is uniform across the verb surface.
- [security] No new exit code paths; no new privacy boundaries. The retry helper's gate (`_can_auto_relogin`: requires ARG_SITE + cred metadata `auto_relogin: true`) means non-session invocations are no-ops — preserving the existing behavior of every verb when invoked without `--site`.
- [internal] No new tests — `tests/verb-retry.bats` already exercises the helper logic. Per-verb integration would require adapter-side runtime expiry detection (which still doesn't ship — adapters don't yet emit 22 mid-flight). When that lands, integration tests follow.

`browser-login.sh` deliberately NOT wired: login IS the relogin mechanism. Wrapping it in retry would risk infinite recursion (login fails → retry → login --auto → calls login → …). Login's own error handling is the right boundary.

After this PR, any verb invoked with `--site` (and a cred backing the resolved cred name) gets transparent session-expiry recovery for free. The harness is complete; adapter-side detection is the next layered concern.

Untouched per scope discipline: `scripts/browser-snapshot.sh` (already wired in part 3-ii's helper PR), `scripts/browser-login.sh` (intentionally unwired), `scripts/browser-doctor.sh` + every other non-session verb, all adapters, router rules.

### Phase 5 part 3-ii — Transparent verb-retry on EXIT_SESSION_EXPIRED (helper + snapshot wired)

- [feat] new `scripts/lib/verb_helpers.sh::invoke_with_retry VERB ARGS...` — wraps `tool_${VERB} ARGS`, returning its stdout + exit code. On `EXIT_SESSION_EXPIRED` (22), if a credential with `auto_relogin: true` exists for the resolved `--site` / `--as`, runs `bash browser-login.sh --auto` silently then retries the verb EXACTLY ONCE. Per parent spec §4.4 — every verb call → silent re-login → retry, exactly one attempt. Caller sees a single stdout + final rc.
- [feat] new gating helpers: `_can_auto_relogin` (checks ARG_SITE + cred metadata.auto_relogin: true), `_resolve_relogin_cred_name` (mirrors session resolution: ARG_AS → site.default_session), `_silent_relogin` (shells to login --auto for the resolved cred). All composed inside `invoke_with_retry` so the call site is one line.
- [feat] `scripts/browser-snapshot.sh` — wired into `invoke_with_retry` as exemplar. Other verbs (open / click / fill / inspect / audit / extract / login) deferred to follow-up sub-PR (mechanical churn, easier to review separately).
- [internal] new `tests/verb-retry.bats` (6 cases) — unit-tests the helper via bash function mocking + counter file: tool returning 0 (no retry), tool returning rc≠22 (no retry), tool returning 22 + no auto-relogin context (no retry), tool returning 22 + relogin OK + retry succeeds (final rc=0), tool returning 22 + relogin fails (no retry, original error propagated), tool returning 22 twice (final rc=22 — no triple-call).
- [docs] `docs/superpowers/plans/2026-05-05-phase-05-part-3-ii-verb-retry.md` — phase plan.

After this PR, session expiry on `bash scripts/browser-snapshot.sh --site app` is invisible to the agent: cookie revoked → adapter exits 22 → verb re-logins via stored cred → retry succeeds → user sees the snapshot result. The pattern is now ready to replicate across the other 7 verbs.

**Out of scope (deferred to 3-ii follow-ups):**
- Wiring `invoke_with_retry` into `open` / `click` / `fill` / `inspect` / `audit` / `extract` / `login` — mechanical replication of the snapshot edit. Will land as a single PR.
- End-to-end integration test (real adapter that detects expiry + real login --auto + real cred). Adapter-side detection logic (e.g. checking landed-on-login-page after navigate) is itself a separate concern; the helper is harness-ready when adapters start emitting 22.

Untouched per scope discipline: adapters, router rules, common.sh, credential.sh (already had auto_relogin field default-true from part 2d), session/site libs, every verb script except snapshot.

### Phase 5 part 1f — Chrome `--user-data-dir` passthrough for cdt-mcp

- [feat] `scripts/lib/node/chrome-devtools-bridge.mjs` — new `mcpSpawnArgs()` helper. When `CHROME_USER_DATA_DIR` env var is set, the bridge forwards `--user-data-dir DIR` to the spawned upstream MCP child. Used at all 3 spawn sites: `runStatelessOneShot`, `withMcpClient` (one-shot multi-call), and `daemonChildMain`. Without the env var: no flag is added (current behavior preserved).
- [feat] **Session loading for cdt-mcp.** Chrome's native session mechanism is `--user-data-dir` (a profile directory containing cookies, localStorage, extensions), not playwright-lib's `storageState` JSON. Users now have a path to use logged-in profiles with cdt-mcp: log in once with real Chrome at a known directory, then `export CHROME_USER_DATA_DIR=/path/to/profile` before running verb scripts.
- [internal] `tests/stubs/mcp-server-stub.mjs` — logs `process.argv.slice(2)` to MCP_STUB_LOG_FILE on startup, so bats can verify the bridge's spawn-arg forwarding.
- [internal] `tests/chrome-devtools-bridge_real.bats` (+2 cases) — `CHROME_USER_DATA_DIR` forwards `--user-data-dir DIR`; absence → no flag in spawn (regression guard).
- [internal] `tests/chrome-devtools-mcp_daemon_e2e.bats` (+1 case) — daemon child also receives the forwarded flag.
- [docs] `references/chrome-devtools-mcp-cheatsheet.md` — new "Session loading" subsection with copy-paste recipe; `CHROME_USER_DATA_DIR` row added to env-var table.
- [docs] `docs/superpowers/plans/2026-05-05-phase-05-part-1f-user-data-dir.md` — phase plan.

**Out of scope (1f-i minimal — passthrough only):**
- `bash scripts/browser-login.sh --user-data-dir-mode` (capture a profile dir via cdt-mcp). User provides the directory themselves.
- Session resolver hooks (`resolve_session_user_data_dir`) for verb scripts to auto-export the env var per `--site` / `--as`. Could land in a follow-up if user demand surfaces.

After this PR, **Phase 5 part 1 (cdt-mcp track) is feature-complete**: 8/8 verbs real-mode, router promotion (Path B), verb scripts, daemon dispatch, session loading. The HANDOFF queue's remaining items are the auth track (parts 3-ii through 4: transparent verb-retry on session expiry, auth-flow detection, 2FA detection, TOTP).

Untouched per scope discipline: all adapters' capability declarations (env var is bridge-internal), all verb scripts (no flag changes — env var is the surface), router rules, login flow, session/credential libs.

### Phase 5 part 1e-ii — Bridge dispatch for `inspect` + `extract` real-mode (8/8 cdt-mcp verbs)

- [feat] `scripts/lib/node/chrome-devtools-bridge.mjs` — `inspect` and `extract` work real-mode end-to-end. Pre-1e-ii both verbs exited 41 with hint pointing at part 1e. Now they route through the daemon when one is running, or one-shot via the new `withMcpClient(fn)` helper otherwise. Both paths share `dispatchInspect(mcpCall, msg)` and `dispatchExtract(mcpCall, msg)`.
- [feat] **Inspect = multi-tool composition.** Per-flag MCP-call mapping: `--capture-console` → `list_console_messages` → `console_messages` field; `--capture-network` → `list_network_requests` → `network_requests`; `--screenshot` → `take_screenshot` → `screenshot_path`; `--selector CSS` → `evaluate_script` (with `document.querySelectorAll`) → `matches`. Multi-flag = sequential MCP calls aggregated into one summary JSON.
- [feat] **Extract = single `evaluate_script` call.** `--selector CSS` wraps in `querySelectorAll` → `textContent.trim()` → joined; `--eval JS` passes the raw script through. Both flags acceptable (eval can use the selector via DOM API).
- [feat] **Refactor: `makeMcpCall(child, reader, startId)` factory** extracted to top level. The daemon's previously-inline `mcpCall` closure now uses the factory; the new one-shot `withMcpClient(fn)` helper also uses it. One id-tracking implementation; two callers.
- [feat] cdt-mcp adapter now real-mode for **all 8 declared verbs**: `open`, `snapshot`, `eval`, `audit`, `inspect`, `extract` work one-shot or daemon-routed; `click`, `fill` require a running daemon (refMap precondition).
- [internal] `tests/stubs/mcp-server-stub.mjs` — added `list_console_messages` (2 canned messages), `list_network_requests` (1 canned request), `take_screenshot` (canned path) tool handlers. evaluate_script handler unchanged.
- [internal] `tests/chrome-devtools-bridge_real.bats` — replaced 2 exit-41 tests for inspect/extract with 6 happy-path real-mode tests (one-shot path).
- [internal] `tests/chrome-devtools-mcp_daemon_e2e.bats` — added 5 cases covering inspect (capture-console / multi-flag / screenshot) and extract (selector / eval) via daemon. `attached_to_daemon: true` asserted on inspect to verify daemon-routing.
- [docs] `references/chrome-devtools-mcp-cheatsheet.md` — per-verb table reflects real-mode for all 8 verbs; multi-flag aggregation documented.
- [docs] `scripts/lib/tool/chrome-devtools-mcp.sh::tool_doctor_check` — note bumped: 8/8 verbs.
- [docs] `SKILL.md` — inspect/extract rows simplified (no longer "deferred").
- [docs] `docs/superpowers/plans/2026-05-05-phase-05-part-1e-ii-bridge-inspect-extract.md` — phase plan.

After this PR, the cdt-mcp adapter's full surface is real. The remaining HANDOFF queue items are Path B routing extensions (already shipped via 1d's rules) + Phase 5 parts 1f / 3-ii / 3-iii / 3-iv / 4. CI green on macos+ubuntu (499 tests; +9 over 1e-i's 490 — 11 new tests minus 2 deleted exit-41 tests).

Untouched per scope discipline: `scripts/lib/router.sh`, `scripts/lib/tool/chrome-devtools-mcp.sh` (capabilities unchanged — already declared inspect/extract), `scripts/lib/common.sh`, every credentials/session/site lib, every verb script (`scripts/browser-inspect.sh` and `scripts/browser-extract.sh` from 1e-i pass argv through unchanged — bridge changes are transparent).

### Phase 5 part 1e-i — Verb scripts: browser-audit + browser-extract (un-skip browser-inspect.bats)

- [feat] new `scripts/browser-audit.sh` — `audit` verb script. Flags: `--lighthouse` (default when no flag given), `--perf-trace`. Routes to chrome-devtools-mcp by default per 1d's `rule_audit_or_perf`. **Ships real-mode end-to-end** because the bridge already supports `audit` → `lighthouse_audit` (part 1c). Bare `bash scripts/browser-audit.sh` runs the default lighthouse path.
- [feat] new `scripts/browser-extract.sh` — `extract` verb script. Flags: `--selector CSS`, `--eval JS` (one required, both acceptable). Routes to chrome-devtools-mcp by default per 1d's `rule_extract_default`. Real-mode dispatch (no `BROWSER_SKILL_LIB_STUB=1`) still exits 41 — bridge daemon dispatch for `extract` lands in **part 1e-ii**.
- [feat] `scripts/browser-inspect.sh` — flag set updated to match cdt-mcp's declared `inspect` capabilities: `--capture-console`, `--capture-network`, `--screenshot`, `--selector CSS`. At least one is required. Pre-1e-i, the script required `--selector` (a Phase-2 assumption from when only playwright-cli existed). Real-mode dispatch still exits 41 — also part 1e-ii.
- [internal] new `tests/browser-audit.bats` (5 cases) — lib-stub mode coverage via existing `audit --lighthouse` fixture. Covers happy path, summary shape, ghost-tool rejection, dry-run, capability-filter rejection of `--tool=playwright-cli` for audit.
- [internal] new `tests/browser-extract.bats` (6 cases) — same shape via existing `extract --selector .title` fixture. Adds the missing-flag (`extract` with neither `--selector` nor `--eval`) usage error.
- [internal] `tests/browser-inspect.bats` un-skipped (was skipped pre-Phase-5 with comment "no adapter until Phase 5"). Re-aimed at cdt-mcp lib-stub mode using existing `inspect --capture-console` fixture. 4 cases: happy path, summary shape, ghost-tool rejection, dry-run.
- [docs] `SKILL.md` — new `audit` + `extract` rows; `inspect` row updated to reflect the broader flag set.
- [docs] `docs/superpowers/plans/2026-05-05-phase-05-part-1e-i-audit-extract-scripts.md` — phase plan.

After this PR, the CLI surface for `audit` / `extract` / `inspect` is first-class — no `--tool=` needed. Audit works real-mode end-to-end (lighthouse via the bridge's existing one-shot path); extract and inspect work in lib-stub mode (existing fixtures); their real-mode dispatch lands in part 1e-ii where the bridge daemon gains `inspect` and `extract` handlers. CI green on macos+ubuntu (490 tests; +11 over 1d's 479).

Untouched per scope discipline: `scripts/lib/router.sh`, `scripts/lib/tool/*.sh` (no capability changes — adapter already declared all three verbs), `scripts/lib/node/chrome-devtools-bridge.mjs` (deferred to 1e-ii), `scripts/lib/common.sh`, every credentials/session/site lib, every existing verb script.

### Phase 5 part 1d — Router promotion (chrome-devtools-mcp Path B)

- [feat] `scripts/lib/router.sh` — four new routing rules promote chrome-devtools-mcp from "opt-in via `--tool=`" to a router default per parent spec Appendix B:
  - `rule_capture_flags` — `--capture-console` / `--capture-network` on any verb routes to chrome-devtools-mcp.
  - `rule_audit_or_perf` — verb=`audit` OR `--lighthouse` / `--perf-trace` flags route to chrome-devtools-mcp.
  - `rule_inspect_default` — verb=`inspect` routes to chrome-devtools-mcp.
  - `rule_extract_default` — verb=`extract` routes to chrome-devtools-mcp. (`--scrape <urls...>` → obscura when it lands in Phase 8 — prepend a higher-precedence rule above; no edits needed here.)
- [feat] `ROUTING_RULES` reordered: session_required → capture_flags → audit_or_perf → inspect_default → extract_default → default_navigation. session_required still wins above the capture rules (preserves existing playwright-lib behavior for site/session use); the new rules slot above `default_navigation` so capture-flag combos on `open` / `click` / `fill` / `snapshot` route to chrome-devtools-mcp instead of playwright-cli.
- [internal] `tests/router.bats` (+10 cases) — capture-console / capture-network on snapshot, audit no-flag, --lighthouse and --perf-trace on snapshot, inspect default, extract default, capture wins over default-navigation, plain `open` regression guard, session-required wins over capture-flag, --tool=playwright-cli for inspect still rejected by capability filter.
- [internal] `tests/routing-capability-sync.bats` — drift guard extended to cover `audit` / `inspect` / `extract` (was: open / click / fill / snapshot only). Catches future regressions where a rule routes to a tool that doesn't declare the verb.
- [internal] Existing test "pick_tool audit (no --tool) falls through, dies EXIT_TOOL_MISSING" replaced with the new "verb=audit routes to chrome-devtools-mcp" (the pre-1d fall-through was the absence of this rule).
- [docs] `references/chrome-devtools-mcp-cheatsheet.md` — "When the router picks this adapter" table reflects the new defaults; documents the session+capture limitation (session wins; capture flags silently ignored — resolution path is part 1f).
- [docs] `docs/superpowers/plans/2026-05-05-phase-05-part-1d-router-promotion.md` — phase plan.

After this PR, `bash scripts/browser-snapshot.sh --capture-console` (or any verb with `--capture-*`) routes to chrome-devtools-mcp without `--tool=`. `bash scripts/browser-audit.sh` (when part 1e ships the script) will dispatch via the router automatically. The promotion is now meaningful because part 1c-ii made chrome-devtools-mcp's stateful verbs work via daemon — the router can confidently send click/fill traffic there too. No adapter changes; no verb script changes; the routing change is transparent to callers.

Untouched per scope discipline: every adapter file (`scripts/lib/tool/*.sh` capabilities unchanged), every verb script (`scripts/browser-*.sh` — they call `pick_tool VERB` and pick up the new routing for free), `scripts/lib/node/chrome-devtools-bridge.mjs`, `scripts/lib/common.sh`, `scripts/lib/output.sh`, every credentials/session/site lib, `tests/lint.sh`.

### Phase 5 part 1c-ii — chrome-devtools-mcp daemon + ref persistence (click/fill)

- [feat] `scripts/lib/node/chrome-devtools-bridge.mjs` — daemon mode lands. New verbs `daemon-start` / `daemon-stop` / `daemon-status` mirror `playwright-driver.mjs`'s lifecycle precedent. The daemon spawns ONE long-lived MCP server child, performs the `initialize` handshake once, holds the `eN ↔ uid` ref map, and exposes verb dispatch over a TCP loopback IPC server (`127.0.0.1:0` ephemeral port — Unix sun_path 104-char cap on macOS bats temp paths). State persisted at `${BROWSER_SKILL_HOME}/cdt-mcp-daemon.json` (mode 0600, dir 0700).
- [feat] **Stateful verbs `click` and `fill` work end-to-end via real MCP** when daemon is running. `bridge.mjs click eN` resolves `eN → uid` from the cached refMap (populated by the prior `snapshot`) and calls MCP `tools/call name=click args={uid}`. Without daemon → exit 41 with hint pointing at `daemon-start`. The remaining stateful verbs (`inspect` / `extract`) still exit 41 — bundled with their verb scripts in part 1e.
- [feat] **Stateless verbs route through the daemon when one is running** so the same MCP server child + Chrome state are reused across calls. Without daemon, the original part-1c one-shot path runs unchanged.
- [security] Privacy: `fill --secret-stdin` reads the secret from stdin only (never argv per AP-7). Daemon-side reply scrubs any echoed text from the MCP error path (`<redacted>` substitution mirroring `playwright-driver.mjs`). Sentinel canary `sekret-do-not-leak-CDT-1c-ii` verified absent from the skill's stdout summary.
- [internal] new `tests/chrome-devtools-mcp_daemon_e2e.bats` (12 cases) — daemon lifecycle (status / start / running / idempotent start / stop / stop-when-none), click via daemon (no-daemon hint, ref-translation happy path, unknown-ref error), fill via daemon (happy path, secret-stdin canary, no-daemon hint). Defensive setup: `CHROME_DEVTOOLS_MCP_BIN=${STUBS_DIR}/mcp-server-stub.mjs` exported in `setup()` (HANDOFF §60 pattern); `teardown()` always runs `daemon-stop || true`.
- [internal] `tests/stubs/mcp-server-stub.mjs` — added `click` and `fill` `tools/call` handlers (echo `uid` + `text` in their content text). The stub log captures the wire so bats can assert `eN → uid` translation server-side.
- [internal] `tests/chrome-devtools-bridge_real.bats` — updated 2 stateful exit-41 tests: now asserts the new `requires running daemon` hint (replaces the part 1c "deferred to 1c-ii" wording).
- [docs] `references/chrome-devtools-mcp-cheatsheet.md` — Status section + per-verb table updated; new "Daemon mode (phase-05 part 1c-ii)" subsection with copy-paste recipe; Limitations section trimmed (real MCP transport no longer "deferred").
- [docs] `scripts/lib/tool/chrome-devtools-mcp.sh::tool_doctor_check` — note bumped: stateless verbs one-shot, click/fill via daemon-start.
- [docs] `docs/superpowers/plans/2026-05-05-phase-05-part-1c-ii-cdt-mcp-daemon.md` — phase plan.

After this PR, the cdt-mcp adapter unblocks downstream work: `--tool=chrome-devtools-mcp` exposes 6 of 8 verbs in real mode (4 stateless + click + fill). The remaining 2 (`inspect` / `extract`) wait for part 1e where the verb scripts and daemon dispatch land together. Path B router promotion (part 1d) and Chrome `--user-data-dir` session loading (part 1f) remain queued.

Untouched per scope discipline: `scripts/lib/router.sh` (Path A still — promotion deferred to part 1d), `scripts/lib/common.sh`, `scripts/lib/output.sh`, `scripts/lib/credential.sh`, `scripts/lib/secret/*.sh`, `scripts/lib/site.sh`, `scripts/lib/session.sh`, `scripts/lib/secret_backend_select.sh`, `scripts/lib/mask.sh`, `scripts/lib/verb_helpers.sh`, every `scripts/browser-*.sh` (verb scripts unchanged — they shell to the adapter; the adapter shells to the bridge; the bridge handles IPC), every other adapter file, `tests/lint.sh`.

### Phase 5 part 3 — `login --auto` auto-relogin from stored credentials

- [feat] `scripts/browser-login.sh --auto` — programmatic headless login using the credential set via `creds-add`. Reads username from credential metadata, password via `credential_get_secret` (dispatches to whichever backend the cred uses — plaintext / keychain / libsecret). Sends `username\0password` to the driver via stdin per AP-7 (secret never on argv). Mutually exclusive with `--interactive` and `--storage-state-file`. Validates: cred exists, cred bound to `--site`, `auto_relogin=true`, `account` non-empty.
- [feat] `scripts/lib/node/playwright-driver.mjs::runAutoRelogin` — reads NUL-separated `username\0password` from stdin, launches headless chromium, navigates to site URL, fills best-effort form selectors (`input[type=email]`, `input[type=password]`, `button[type=submit]`, etc.), clicks submit, waits for navigation/network-idle (15s budget), captures `storageState`, writes to `--output-path`.
- [security] AP-7 STRICT: secret reaches driver via stdin pipe only. `printf '%s\0' "${account}"` precedes `credential_get_secret "${as}"` in the pipeline; combined stdin is exactly `account\0password`. Never appears in process argv.
- [security] Privacy: `--auto --dry-run` summary JSON contains `account` (the username, NOT the password) plus standard verb/tool/why/status/duration_ms/site/session keys. Sentinel canary `sekret` verified absent from `--dry-run` output.
- [internal] `tests/login.bats` — replaced the obsolete "--auto refused in Phase 2" test with 7 new `--auto` cases: mutex with `--interactive`, mutex with `--storage-state-file`, `--site` required, missing cred (exit 23), `auto_relogin=false` refusal, site-mismatch refusal, `--dry-run` happy path. Each test pre-creates the plaintext-acknowledged marker + exports keychain/libsecret stubs (defensive — preserves the lesson from part 2b).
- [docs] `SKILL.md` — added `login (auto)` row.
- [docs] `docs/superpowers/plans/2026-05-03-phase-05-part-3-auto-relogin.md` — phase plan.

The auth track now actually saves typing: stored credentials → one CLI invocation → fresh session captured. Stateless single-step username+password flows work via best-effort selectors. Multi-step / 2FA / non-standard form sites need future part 3-iii (auth-flow detection at creds-add time) or fall back to `--interactive`.

**Out of scope (deferred to follow-ups)**:
- **Transparent verb-retry on `EXIT_SESSION_EXPIRED`** (parent spec §4.4 silent re-login on every verb call) — Phase 5 part 3-ii.
- **Auth-flow detection at `creds add` time** — Phase 5 part 3-iii.
- **2FA detection → exit 25** — Phase 5 part 3-iv.
- Real-browser bats tests (no stub) — gated like `--interactive`'s; manual / future-CI.

Untouched per scope discipline: `scripts/lib/router.sh`, `scripts/lib/common.sh`, `scripts/lib/output.sh`, `scripts/lib/credential.sh`, `scripts/lib/secret/*.sh`, `scripts/lib/site.sh`, `scripts/lib/session.sh`, `scripts/lib/verb_helpers.sh` (verb-retry deferred), `scripts/lib/secret_backend_select.sh`, `scripts/lib/mask.sh`, `scripts/lib/tool/*.sh`, `scripts/lib/node/chrome-devtools-bridge.mjs`, `scripts/browser-doctor.sh`, every `scripts/browser-creds-*.sh`, every other adapter file, `tests/lint.sh`.

### Phase 5 part 1c — chrome-devtools-mcp real MCP stdio transport (stateless verbs)

- [feat] `scripts/lib/node/chrome-devtools-bridge.mjs::realDispatch` — implemented. Bridge spawns `${CHROME_DEVTOOLS_MCP_BIN:-chrome-devtools-mcp}` with stdio piped, performs MCP `initialize` handshake (protocol version `2024-11-05`), translates verb argv → `tools/call`, shapes response into skill summary JSON, cleanly shuts down. JSON-RPC 2.0 NDJSON wire protocol per MCP stdio convention.
- [feat] **Stateless verbs work end-to-end via real MCP**: `open` → `navigate_page`, `snapshot` → `take_snapshot`, `eval` → `evaluate_script`, `audit` → `lighthouse_audit` (60s timeout for lighthouse). uid → eN translation at adapter boundary for snapshot output (per token-efficient-output spec §5); the original upstream `uid` is preserved on each ref for traceability.
- [feat] **Stateful verbs (click/fill/inspect/extract) return exit 41** with self-healing hint pointing at part 1c-ii. They need eN → uid persistence across calls; without daemon-mode (planned next), each bridge process starts fresh and has no ref map. Hint message specifically calls out part 1c-ii so users know where the capability lands.
- [internal] new `tests/stubs/mcp-server-stub.mjs` — mock MCP server speaking JSON-RPC 2.0 NDJSON over stdio. Handles `initialize` + `notifications/initialized` + `tools/call` for the 4 stateless tools. Logs each received line to `${MCP_STUB_LOG_FILE}` so bats can assert handshake order. Lets bats run on macos + ubuntu CI without `npx chrome-devtools-mcp@latest` (which needs network + Chrome).
- [internal] `tests/chrome-devtools-bridge_real.bats` (13 cases) — real-mode integration via mock: BROWSER_SKILL_LIB_STUB=1 regression guard, initialize-before-tools/call ordering verified via stub log, all 4 stateless verbs, all 4 stateful verbs return 41, bad-args paths, missing-MCP-bin path.
- [bugfix] Initial implementation hit a JS temporal-dead-zone bug — `realDispatch(argv)` was invoked at module top before the `const TIMEOUT_MS` declarations below ran; the async function body's synchronous prelude referenced consts in TDZ → `ReferenceError`. Fix: move the entry-point invocation to the very end of the module (after all consts initialize).
- [docs] `references/chrome-devtools-mcp-cheatsheet.md` — updated Status section + per-verb real-mode behavior table; deferred-stateful note points at part 1c-ii.
- [docs] `docs/superpowers/plans/2026-05-03-phase-05-part-1c-cdt-mcp-transport.md` — phase plan.

After this PR, `bash scripts/browser-<verb>.sh --tool=chrome-devtools-mcp` actually works for the 4 stateless verbs against a real upstream MCP server (`npx chrome-devtools-mcp@latest` or any wrapper at `${CHROME_DEVTOOLS_MCP_BIN}`). Routing promotion (Path B) stays deferred to part 1d; verb scripts (audit/extract/inspect un-skip) to part 1e.

Untouched per scope discipline: `scripts/lib/router.sh`, `scripts/lib/common.sh`, `scripts/lib/output.sh`, `scripts/lib/credential.sh`, `scripts/lib/secret/*.sh`, `scripts/lib/site.sh`, `scripts/lib/session.sh`, `scripts/lib/secret_backend_select.sh`, `scripts/lib/mask.sh`, `scripts/lib/verb_helpers.sh`, `scripts/lib/tool/chrome-devtools-mcp.sh` (capabilities unchanged), `scripts/browser-doctor.sh`, every `scripts/browser-*.sh`, every other adapter file, `tests/lint.sh`.

### Phase 5 part 2e — `migrate-credential` cross-backend moves

- [feat] new `scripts/browser-creds-migrate.sh` — move a credential from one backend to another. CLI: `creds-migrate --as CRED_NAME --to BACKEND [--yes-i-know] [--yes-i-know-plaintext] [--dry-run]`. Mirrors `creds-remove`'s typed-name confirmation UX exactly.
- [feat] `scripts/lib/credential.sh` — new `credential_migrate_to NAME NEW_BACKEND` public primitive + new `_credential_dispatch_to BACKEND OP NAME` internal helper. Existing `_credential_dispatch_backend` refactored to delegate to the new helper (DRY: one dispatcher implementation, two entry points).
- [security] **Fail-safe ordering**: `credential_migrate_to` reads from old backend → writes to new backend → deletes from old → updates metadata. If the new-backend write fails (e.g. keychain unavailable), the original credential remains intact. If the old-backend delete fails AFTER a successful new-write, both backends transiently hold the secret — verb logs a warning, doesn't crash; user can manually clean up.
- [security] **First-use plaintext gate inherited from creds-add**: migrating TO plaintext requires `--yes-i-know-plaintext` (or a pre-existing acknowledgment marker). Closes the bypass-via-migrate hole that the part-2d-iii insight flagged. Successful migrate-to-plaintext also touches the marker so subsequent plaintext ops skip the gate silently (consistent with creds-add behavior).
- [security] Privacy invariant: summary JSON NEVER includes the secret value. Sentinel canary `sekret-do-not-leak-migrate` asserted absent from output.
- [internal] `tests/credential.bats` (+6 cases) — `credential_migrate_to` lib coverage: each backend pair (plaintext↔keychain↔libsecret), same-backend refusal, unknown-backend refusal, byte-exact secret preservation across migration.
- [internal] `tests/creds-migrate.bats` (11 cases) — verb integration: 3 backend pair migrations + plaintext-gate inheritance (refusal + acceptance) + same-backend refusal + unknown credential + unknown backend + typed-name mismatch + `--dry-run` + summary JSON shape + privacy canary.
- [docs] `SKILL.md` — added `creds migrate` row.
- [docs] `docs/superpowers/plans/2026-05-03-phase-05-part-2e-migrate-credential.md` — phase plan.

**Phase 5 part 2 is now feature-complete.** All 5 credentials verbs shipped (`creds add/list/show/remove/migrate`), all 3 Tier-1 backends real (plaintext/keychain/libsecret), smart per-OS auto-detect, masked reveal, first-use plaintext gate uniformly enforced (creds-add + creds-migrate), doctor surface. Only auto-relogin (Phase 5 part 3) and TOTP (Phase 5 part 4) remain in the broader phase.

Untouched per scope discipline: `scripts/lib/router.sh`, `scripts/lib/common.sh`, `scripts/lib/output.sh`, `scripts/lib/secret/*.sh`, `scripts/lib/site.sh`, `scripts/lib/session.sh`, `scripts/lib/secret_backend_select.sh`, `scripts/lib/mask.sh`, `scripts/browser-doctor.sh`, every other `scripts/browser-*.sh` (existing 4 creds verbs unchanged), every adapter file, `tests/lint.sh`.

### Phase 5 part 2d-iii — `mask.sh` + `creds show --reveal` + first-use plaintext gate

- [feat] new `scripts/lib/mask.sh` — reusable masking helper. `mask_string VAL [SHOW_FIRST=1] [SHOW_LAST=1]`. Examples: `"password123"` → `"p*********3"`; short strings (≤2 chars) → all stars (no leak); very-long strings cap at 80 middle stars to keep masked rendering bounded. Used by `creds show --reveal` for the masked preview alongside the unmasked value; reusable for any future verb that needs to render a sensitive value safely.
- [feat] `scripts/browser-creds-show.sh` — new `--reveal` flag. Default behavior unchanged (metadata only — privacy invariant from part 2d-ii holds). With `--reveal`: typed-phrase confirmation (mirror remove-session UX — user types credential name back via stdin), on match → emit `secret` + `secret_masked` keys alongside `meta`; on mismatch → die `EXIT_USAGE_ERROR`. Mismatch path verified to NOT leak the secret value in error output.
- [security] `creds show --reveal` works for all 3 backends (plaintext, keychain via stub, libsecret via stub). The masked preview lets the user confirm visually they revealed the right credential without re-leaking the value. Regression guard: `creds show` WITHOUT `--reveal` continues to refuse `secret`/`secret_masked` keys in output.
- [feat] `scripts/browser-creds-add.sh` — new `--yes-i-know-plaintext` flag + first-use plaintext gate. Per parent spec §1, plaintext is paper security without disk encryption — the first plaintext add now requires explicit acknowledgment. Marker file `${CREDENTIALS_DIR}/.plaintext-acknowledged` (mode 0600) tracks acknowledgment; subsequent plaintext adds skip the gate silently. Non-plaintext backends (keychain/libsecret) unaffected.
- [internal] `tests/mask.bats` (8 cases) — covers standard / empty / 1-char (no leak) / 2-char (no leak) / 3-char / custom bounds / 200-char (capped output).
- [internal] `tests/creds-show.bats` (+4 cases) — `--reveal` typed-phrase match (secret + masked emitted), `--reveal` mismatch (no leak in error path), `--reveal` works on keychain backend, regression guard for non-reveal path.
- [internal] `tests/creds-add.bats` (+4 cases) — plaintext gate refuses without flag, `--yes-i-know-plaintext` bypasses + creates marker, marker-pre-existing path silent, keychain/libsecret backends skip the gate. setup() pre-creates the marker so existing plaintext-backend tests don't hit the gate.
- [docs] `SKILL.md` — added `creds show --reveal` row; updated `creds add` row to mention `--yes-i-know-plaintext`.
- [docs] `docs/superpowers/plans/2026-05-03-phase-05-part-2d-iii-mask-and-reveal.md` — phase plan.

After this PR, the auth track's security/UX gaps are closed: secret disclosure is gated behind a typed-phrase confirmation; plaintext-on-disk requires explicit user acknowledgment. The `migrate-credential` cross-backend move (part 2e) is the last remaining auth-track verb.

Untouched per scope discipline: `scripts/lib/router.sh`, `scripts/lib/common.sh`, `scripts/lib/output.sh`, `scripts/lib/credential.sh`, `scripts/lib/secret/*.sh`, `scripts/lib/site.sh`, `scripts/lib/session.sh`, `scripts/lib/secret_backend_select.sh`, `scripts/browser-doctor.sh`, `scripts/browser-creds-list.sh`, `scripts/browser-creds-remove.sh`, every adapter file, `tests/lint.sh`.

### Phase 5 part 2d-ii — `creds list/show/remove` verbs

- [feat] new `scripts/browser-creds-list.sh` — walk `${CREDENTIALS_DIR}` and emit a single-line summary JSON listing all credentials. Optional `--site NAME` filter mirrors `list-sessions`. Each row carries `{credential, site, account, backend, auto_relogin, totp_enabled, created_at}` — metadata only; NEVER includes the secret payload (privacy invariant tested with sentinel canary `sekret-do-not-leak-list`).
- [feat] new `scripts/browser-creds-show.sh` — emit one credential's metadata JSON. NEVER emits the secret value (privacy invariant — bats grep guard with sentinel canary `sekret-do-not-leak-show`). `--reveal` flow with typed-phrase confirmation deferred to part 2d-iii.
- [feat] new `scripts/browser-creds-remove.sh` — typed-name confirmation delete, mirroring `remove-session` UX exactly. `--yes-i-know` skips prompt; `--dry-run` reports without writing. Calls `credential_delete` which dispatches the secret-removal to the appropriate backend (plaintext: file unlink; keychain: `security delete-generic-password`; libsecret: `secret-tool clear`). Tests exercise all 3 backends via stubs.
- [internal] `tests/creds-list.bats` (6 cases), `tests/creds-show.bats` (7 cases), `tests/creds-remove.bats` (10 cases) — total 23 new cases. Each setup() unconditionally exports `KEYCHAIN_SECURITY_BIN` + `LIBSECRET_TOOL_BIN` stubs (defensive: preserves the lesson from part 2b's keychain-dialog incident — never let a test fall through to a real OS vault).
- [docs] `SKILL.md` — added 3 rows: `creds list`, `creds show`, `creds remove`.
- [docs] `docs/superpowers/plans/2026-05-03-phase-05-part-2d-ii-creds-crud.md` — phase plan.

After this PR, the basic credential CRUD loop is complete: `creds add` (part 2d) → `creds list` / `creds show` (read; metadata-only) → `creds remove` (delete; backend-aware). The `--reveal` flow + `mask.sh` + first-use plaintext typed-phrase prompt land together in part 2d-iii where TTY-prompt patterns get factored. `migrate-credential` cross-backend moves stay in part 2e.

Untouched per scope discipline: `scripts/lib/router.sh`, `scripts/lib/common.sh`, `scripts/lib/output.sh`, `scripts/lib/site.sh`, `scripts/lib/session.sh`, `scripts/lib/credential.sh`, every `scripts/lib/secret/*.sh`, every adapter file, `scripts/browser-doctor.sh`, `scripts/browser-creds-add.sh`, `tests/lint.sh`.

### Phase 5 part 2d — `creds add` verb + smart backend select

- [feat] new `scripts/browser-creds-add.sh` — first user-visible auth verb. Registers a credential under `${CREDENTIALS_DIR}/<name>.{json,secret}`. CLI: `creds-add --site SITE --as CRED_NAME --password-stdin [--account ACCOUNT] [--backend keychain|libsecret|plaintext] [--auto-relogin true|false] [--dry-run]`. Validates site exists, cred name safe + not already registered. Auto-detects backend per OS if `--backend` not set.
- [security] AP-7 STRICT: `--password-stdin` is the **only** password-input path. NO `--password VALUE` flag. Lint-style grep test guards against future regression. Password reaches `credential_set_secret` via stdin pipe — never argv.
- [feat] new `scripts/lib/secret_backend_select.sh` — smart per-OS backend auto-detection per parent spec §1. `detect_backend` echoes `keychain` (Darwin + `security` on PATH), `libsecret` (Linux + `secret-tool` on PATH), or `plaintext` (fallback). `BROWSER_SKILL_FORCE_BACKEND` env override honored. Does NOT probe D-Bus reachability for libsecret (too brittle); user can override to `plaintext` if their Linux box has no agent.
- [feat] `scripts/browser-doctor.sh` — new advisory check after adapter aggregation. Walks `${CREDENTIALS_DIR}/*.json` and emits `credentials: N total (keychain: A, libsecret: B, plaintext: C)`. Does NOT increment `problems`; advisory only.
- [internal] `tests/creds-add.bats` (14 cases) — happy path × 3 backends + auto-detect + validation (existing cred / unknown site / unsafe name / missing required flags) + AP-7 grep guard + `--dry-run` + `--account` override + summary JSON shape. Defensive: setup() exports stub bins for keychain + libsecret unconditionally so no test can fall through to a real OS vault.
- [internal] `tests/secret_backend_select.bats` (8 cases) — env override, per-OS detection (Darwin/Linux/other) via a `uname -s` shim, missing-binary fallback to plaintext.
- [internal] `tests/doctor.bats` — added 2 cases: zero-credential state + per-backend breakdown line with hand-written metadata fixture.
- [bugfix] `scripts/lib/credential.sh` — `_CREDENTIAL_REQUIRED_FIELDS` changed from a space-separated string to a bash array. The string form was IFS-dependent: verb scripts set `IFS=$'\n\t'` (default protective hygiene), which silently broke `for field in ${_CREDENTIAL_REQUIRED_FIELDS}` word-splitting. Symptom: validation reported the entire string as one missing-field name. Array + `[@]` quoting is IFS-independent. Tests in part-2a passed because they ran in a `bash -c` subshell with default IFS; the bug surfaced when the verb script (the first IFS-strict caller) hit `credential_save`.
- [docs] `SKILL.md` — added `creds add` row to the verbs table.
- [docs] `docs/superpowers/plans/2026-05-03-phase-05-part-2d-creds-add.md` — phase plan.

NO `creds list/show/remove` this PR — those follow the patterns established here in part 2d-ii. NO `mask.sh` + `--reveal` typed-phrase flow — part 2d-iii. NO `migrate-credential` — part 2e. NO interactive `read -s` password prompt — TTY-aware mocking in bats is complex; deferred. NO first-use plaintext typed-phrase confirmation prompt — lands with the TTY-prompt patterns in 2d-iii.

Untouched per scope discipline: `scripts/lib/router.sh`, `scripts/lib/common.sh`, `scripts/lib/output.sh`, `scripts/lib/site.sh`, `scripts/lib/session.sh`, `scripts/lib/verb_helpers.sh`, `scripts/lib/secret/*.sh` (3 backends, all from parts 2a/2b/2c), every adapter file, `tests/lint.sh`, `tests/router.bats`.

### Phase 5 part 2c — Linux libsecret backend (secret-tool)

- [feat] new `scripts/lib/secret/libsecret.sh` — third (and final Tier-1) secret backend. Completes the per-OS roster: plaintext + keychain + libsecret. 4-fn API mirrors `keychain.sh` shape; shells to `${LIBSECRET_TOOL_BIN:-secret-tool}`; service prefix `${BROWSER_SKILL_LIBSECRET_SERVICE:-browser-skill}`; account = credential name. `secret_set` clear-then-store for idempotent overwrite; `secret_get` via `lookup`; `secret_delete` swallows missing-item exit-1 from `clear`; `secret_exists` probes via `lookup` to /dev/null.
- [security] AP-7 CLEAN — no documented exception. The upstream `secret-tool` CLI reads passwords from stdin natively (via `store` subcommand). The skill's own code pipes stdin directly into `secret-tool store`; password never appears in argv. Contrast with macOS keychain backend (`secret/keychain.sh`) which has a documented AP-7 exception due to the upstream `security` CLI's argv-only design.
- [feat] `scripts/lib/credential.sh` dispatcher: `libsecret` branch shifts from part-2a's `EXIT_TOOL_MISSING` placeholder to actual backend dispatch. **All three backend branches now dispatch to real implementations** — no placeholders remain in `_credential_dispatch_backend`.
- [internal] new `tests/stubs/secret-tool` — bash mock of `secret-tool` CLI. Supports `store/lookup/clear` with attr=val pairs (`service`, `account`). State in `${LIBSECRET_STUB_STORE}` (per-test isolated tempfile). Reads PW from stdin verbatim (no trailing-newline strip). Logs argv to `${STUB_LOG_FILE}` for shape assertions. Lets bats run on macos-latest CI (no libsecret) and ubuntu-latest CI (no D-Bus session) identically.
- [internal] `tests/secret_libsecret.bats` (13 cases) — full backend coverage: AP-7-clean header guard (asserts the absence of "AP-7 documented exception" + presence of stdin-clean affirmation), stdin-roundtrip, idempotent delete, multi-secret, last-write-wins (clear-then-store), service prefix override, byte-exact verbatim roundtrip.
- [internal] `tests/credential.bats` — replaced the part-2a "libsecret returns EXIT_TOOL_MISSING (deferred)" test with positive libsecret-roundtrip-via-stub test. Uses inline env-prefix style matching the existing keychain test.
- [docs] `docs/superpowers/plans/2026-05-02-phase-05-part-2c-libsecret.md` — phase plan.

NO verb scripts this PR. NO doctor changes. NO router/adapter touches. Linux libsecret becomes the **per-OS-default backend on Linux** (when `secret-tool` is on PATH and a D-Bus Secret Service is reachable) once `creds add` lands in part 2d.

Backend roster after this PR (3 of 3 Tier-1 shipped; smart auto-detect lands in 2d):

| OS | Default backend | Fallback |
|---|---|---|
| Darwin | keychain (security CLI) | plaintext-with-typed-phrase |
| Linux (with libsecret) | libsecret (secret-tool) | plaintext-with-typed-phrase |
| Linux (no libsecret) / other | plaintext-with-typed-phrase | (none) |

Untouched per scope discipline: `scripts/lib/router.sh`, `scripts/lib/common.sh`, `scripts/lib/output.sh`, `scripts/lib/secret/plaintext.sh`, `scripts/lib/secret/keychain.sh`, `scripts/browser-doctor.sh`, every `scripts/browser-<verb>.sh`, every adapter file, `SKILL.md`, `tests/lint.sh`.

### Phase 5 part 2b — macOS Keychain backend (security CLI)

- [feat] new `scripts/lib/secret/keychain.sh` — second secret backend. 4-fn API mirrors `plaintext.sh`. Shells to `${KEYCHAIN_SECURITY_BIN:-security}`; service prefix `${BROWSER_SKILL_KEYCHAIN_SERVICE:-browser-skill}`; account = credential name. `secret_set` reads stdin then calls `security add-generic-password -w "${secret}" -U`. `secret_get` echoes via `find-generic-password -w`. `secret_delete` idempotent (`|| true` swallows missing-item exit). `secret_exists` probes via `find-generic-password` without `-w`.
- [security] AP-7 documented exception: macOS `security` CLI takes the password on argv (`-w PASSWORD`); no clean stdin path in upstream tool. Mitigations documented in keychain.sh header — short-lived subprocess (~50ms), -U makes idempotent, Linux libsecret backend (part 2c) uses stdin-clean `secret-tool`. The skill's own code never puts secrets on argv; the leak surface is the brief `security` subprocess. Honest documented exception pattern, NOT silent compromise of the invariant.
- [feat] `scripts/lib/credential.sh` dispatcher: `keychain` branch shifted from part-2a's `EXIT_TOOL_MISSING` placeholder to actual backend dispatch (`source secret/keychain.sh; secret_${op}`). `libsecret` branch unchanged (still placeholder until 2c).
- [internal] new `tests/stubs/security` — bash mock of macOS `security` CLI. Supports `add/find/delete-generic-password` with `-s/-a/-w/-U` flag set the backend uses. State in `${KEYCHAIN_STUB_STORE}` (per-test isolated tempfile). Logs argv to `${STUB_LOG_FILE}` for shape assertions. Mirrors `tests/stubs/playwright-cli` + `tests/stubs/chrome-devtools-mcp` (now-deleted) patterns. Lets bats run on Ubuntu CI without macOS keychain access.
- [internal] `tests/secret_keychain.bats` (13 cases) — full backend coverage: stdin-roundtrip, idempotent delete, multi-secret, last-write-wins, override of service prefix, AP-7 header-comment grep guard.
- [internal] `tests/credential.bats` — replaced the part-2a "keychain returns EXIT_TOOL_MISSING (deferred)" test with positive keychain-roundtrip-via-stub test. libsecret-deferred test stays (still placeholder until 2c).
- [docs] `docs/superpowers/plans/2026-05-02-phase-05-part-2b-keychain.md` — phase plan.

NO verb scripts this PR. NO doctor changes. NO router/adapter touches. macOS Keychain becomes the **per-OS-default backend on macOS** once `creds add` lands in part 2d (smart auto-detect: keychain on macOS, libsecret on Linux with libsecret installed, plaintext fallback otherwise).

Untouched per scope discipline: `scripts/lib/router.sh`, `scripts/lib/common.sh`, `scripts/lib/output.sh`, `scripts/lib/site.sh`, `scripts/lib/session.sh`, `scripts/lib/secret/plaintext.sh`, `scripts/browser-doctor.sh`, every `scripts/browser-<verb>.sh`, every adapter file, `SKILL.md`, `tests/lint.sh`.

### Phase 5 part 2a — credentials foundation (lib + plaintext backend)

- [feat] new `scripts/lib/credential.sh` — credentials substrate. Eight public fns: `credential_save/load/meta_load/list_names/delete/exists/set_secret/get_secret`. Schema v1 (mirror session schema). Two files per credential: `<name>.json` for metadata (mode 0600, NEVER secret values) and `<name>.secret` for backend-owned payload. Backend dispatcher routes secret operations by `metadata.backend` field; sources backends on demand to keep parent-shell namespace clean.
- [feat] new `scripts/lib/secret/plaintext.sh` — first secret backend. Four fns: `secret_set/get/delete/exists`. AP-7-strict: secret material flows via stdin pipes only — never argv. Atomic writes (tmp + mv); mode 0600 files inside mode 0700 `${CREDENTIALS_DIR}`. Idempotent delete. Last-write-wins on overwrite (no implicit `--force` — caller's job to confirm via `credential_delete` first).
- [feat] backend dispatcher returns `EXIT_TOOL_MISSING` (21) with self-healing hint for `keychain` and `libsecret` backends — placeholders until those backends land in phase-05 part 2b (macOS Security framework via `security` CLI) and part 2c (Linux Secret Service via `secret-tool`).
- [security] `credential_load` privacy-invariant test: output MUST NOT contain a `secret` field or any secret value. `tests/credential.bats` asserts this with a sentinel value (`sekret-do-not-leak`) — guards against any future regression that conflates metadata with payload.
- [internal] `tests/credential.bats` (21 cases) + `tests/secret_plaintext.bats` (12 cases) — full lib + backend coverage including: file-mode invariants, dir-mode invariants, schema validation, dispatcher routing, deferred-backend exit codes, path-traversal rejection, AP-7 grep guard.
- [docs] `docs/superpowers/plans/2026-05-02-phase-05-part-2a-creds-foundation.md` — phase plan.

NO verb scripts this PR. `creds add/list/show/remove` land in part 2d once the backend roster (2a/2b/2c) is complete. NO doctor changes — credential count comes in 2d when verbs trigger surface visibility.

Untouched per scope discipline: `scripts/lib/router.sh`, `scripts/lib/common.sh`, `scripts/lib/output.sh`, `scripts/lib/site.sh`, `scripts/lib/session.sh`, `scripts/browser-doctor.sh`, every `scripts/browser-<verb>.sh`, every adapter file, `SKILL.md` (no new verbs to autogen), `tests/lint.sh`.

### Phase 5 part 1b — cdt-mcp bridge scaffold + lib-stub pivot

- [adapter] new `scripts/lib/node/chrome-devtools-bridge.mjs` — node ESM bridge between the chrome-devtools-mcp adapter and the upstream MCP server. Stub mode (`BROWSER_SKILL_LIB_STUB=1`) performs sha256(argv) → `tests/fixtures/chrome-devtools-mcp/<sha>.json` lookup and echoes contents (matches the part-1 hashing form `printf '%s\0' "$@" | shasum -a 256` so existing fixtures work unchanged). Real-mode MCP transport (initialize handshake + `tools/call` + `uid → eN` translation) is deferred to phase-05 part 1c — bridge throws with a self-healing hint pointing at that part.
- [adapter] `scripts/lib/tool/chrome-devtools-mcp.sh` rewired to shell to the bridge via a new `_drive` helper, mirroring `playwright-lib`'s shape exactly. Adapter no longer references `${CHROME_DEVTOOLS_MCP_BIN}` for verb dispatch; the env var still exists but its semantics shifted — it now means "the upstream MCP server binary the bridge spawns in real mode" (defaults to `chrome-devtools-mcp`).
- [adapter] `tool_doctor_check` pivoted from "bin on PATH" to "node on PATH + bridge file present" (mirror `playwright-lib::tool_doctor_check`). Includes a `note` field explaining real-mode transport is deferred to part 1c. Doctor now passes on plain CI without any env override (node is always present).
- [internal] deleted `tests/stubs/chrome-devtools-mcp` (~50 LOC of bash) — replaced by lib-stub mode in the bridge. Mirrors `playwright-lib`'s no-binary-stub model.
- [internal] reverted the part-1 additions to `tests/doctor.bats` (3 sites) and `tests/install.bats` (1 site) — `CHROME_DEVTOOLS_MCP_BIN="${STUBS_DIR}/chrome-devtools-mcp"` overrides are no longer needed because doctor now passes on node-and-bridge alone.
- [internal] `tests/chrome-devtools-mcp_adapter.bats` (21 cases): env var pivoted from `CHROME_DEVTOOLS_MCP_BIN` to `BROWSER_SKILL_LIB_STUB=1`; one test renamed from "stub bin on PATH" to "node on PATH (no env override needed)". Argv-shape assertions via `STUB_LOG_FILE` unchanged — bridge logs argv to that file in stub mode for parity.
- [docs] `references/chrome-devtools-mcp-cheatsheet.md` — new "Architecture" diagram (adapter → bridge → upstream); rewritten "Stub mode" section; new "Environment variables" reference table; "Limitations" section restructured to call out which sub-part lands each remaining capability.
- [docs] `docs/superpowers/plans/2026-05-02-phase-05-part-1b-cdt-mcp-bridge.md` — phase plan.

Untouched per Path A discipline: `scripts/lib/router.sh`, `scripts/lib/common.sh`, `scripts/lib/output.sh`, `scripts/browser-doctor.sh`, every `scripts/browser-<verb>.sh`, `references/routing-heuristics.md`, `tests/router.bats`, both pre-existing adapter files (`playwright-cli.sh`, `playwright-lib.sh`), 8 fixtures under `tests/fixtures/chrome-devtools-mcp/`.

### Phase 5 part 1 — chrome-devtools-mcp adapter (Path A — opt-in)

- [adapter] added `scripts/lib/tool/chrome-devtools-mcp.sh` — third concrete adapter, third on the toolbox roster after `playwright-cli` and `playwright-lib`. Declares all 8 verbs (`open click fill snapshot inspect audit extract eval`) so `--tool=chrome-devtools-mcp` makes the full surface reachable today via the capability filter in `pick_tool`. The flagship verbs (`inspect`, `audit`, `extract`) are the long-term defaults per parent spec Appendix B; router promotion (Path B) is deferred to phase-05 part 1c per anti-pattern AP-4 (no same-PR promotion).
- [adapter] real-mode placeholder: the adapter shells to `${CHROME_DEVTOOLS_MCP_BIN:-chrome-devtools-mcp}`. The upstream is an MCP server (`npx chrome-devtools-mcp@latest`, JSON-RPC over stdio), not a CLI. The stdio bridge that wires the adapter to it is deferred to phase-05 part 1b.
- [adapter] `tool_fill --secret-stdin` is honored (unlike `playwright-cli` which exits 41) — passes the flag through to the bin, which reads stdin. Differentiates from `playwright-cli` (rejects stdin) and matches `playwright-lib` (driver reads stdin in node).
- [internal] `tests/chrome-devtools-mcp_adapter.bats` (21 cases) — contract conformance + flagship verb declarations + happy-path verb dispatch via stub + missing-fixture exit-41 propagation + `--ref`-required guard.
- [internal] `tests/stubs/chrome-devtools-mcp` (mirror of `tests/stubs/playwright-cli`): `sha256(argv joined by NUL)` → fixture lookup; honors `--version` so doctor reports the bin as found under stub override.
- [internal] `tests/fixtures/chrome-devtools-mcp/<sha>.json` × 8 — covers inspect/audit/snapshot/eval/open/click/extract/fill argv shapes.
- [internal] `tests/doctor.bats` + `tests/install.bats` — added `CHROME_DEVTOOLS_MCP_BIN="${STUBS_DIR}/chrome-devtools-mcp"` alongside the playwright-cli stub so the `all checks passed` assertions stay true under the new adapter.
- [docs] `references/chrome-devtools-mcp-cheatsheet.md` — when-to-use, capability declaration, opt-in syntax, stub-mode notes, deferred-bridge call-out.
- [docs] `SKILL.md` + `references/tool-versions.md` — autogenerated 3rd adapter row.
- [docs] `docs/superpowers/plans/2026-05-01-phase-05-part-1-chrome-devtools-mcp.md` — phase plan.

Untouched per Path A discipline (recipe + AP-4): `scripts/lib/router.sh`, `scripts/lib/common.sh`, `scripts/lib/output.sh`, `scripts/browser-doctor.sh`, every `scripts/browser-<verb>.sh`, `references/routing-heuristics.md`, `tests/router.bats`, both pre-existing adapter files.

### Phase 4 part 4e — show-session + remove-session verbs (full session CRUD)

- [feat] `scripts/browser-show-session.sh` — emits session metadata (origin, captured_at, expires_in_hours, source_user_agent) plus storage_state counts (cookie_count, origin_count, file_size_bytes). **CRITICAL:** never emits cookie/token values; the agent has no business seeing raw session material. Test asserts cookie values do not leak into output.
- [feat] `scripts/browser-remove-session.sh` — typed-name confirmed delete of session storageState + meta. Mirrors `remove-site` ergonomics: `--yes-i-know` skips prompt, `--dry-run` reports planned action. Does NOT clear `site.default_session` pointers (cascade is Phase 5); dangling pointers surface clearly via `resolve_session_storage_state`'s self-healing hint at next use.
- [feat] `scripts/lib/session.sh::session_delete` — new lib helper. Idempotent (no-op on missing files), `assert_safe_name` guards path-traversal.
- [docs] `SKILL.md` verbs table gains `show-session` + `remove-session` rows.
- [internal] `tests/show-remove-session.bats` (10) — full coverage incl. cookie-value-leak guard. `tests/session.bats` (+3) — session_delete unit tests.

Session CRUD now complete: `login` (create) / `list-sessions` (read all) / `show-session` (read one) / `remove-session` (delete). Update happens via re-login.

### Phase 4 part 4d — Real-mode interactive login + multi-session ergonomics

- [feat] `playwright-driver.mjs::runLogin` — single-shot headed Chromium flow. Launches browser at `--url`, prints "press Enter when done logging in" to stderr, waits for stdin newline, captures `context.storageState()`, writes to `--output-path` (mode 0600). Independent of the IPC daemon — login is its own ephemeral isolated context.
- [feat] `scripts/browser-login.sh` adds `--interactive` flag (mutually exclusive with `--storage-state-file`). Shells the driver, validates the captured storageState through the same Phase-2 origin-binding pipeline, writes the session + meta sidecar. `--interactive --dry-run` skips the browser launch and reports the planned action. Summary `why` field becomes `interactive-headed-capture` (vs `storageState-file-import` for the file path).
- [feat] `scripts/browser-list-sessions.sh` — new verb. Lists sessions with their bound site + origin + captured_at + expires_in_hours. Optional `--site NAME` filter exposes the **1-many credential model**: a site can have many sessions (e.g. `prod--admin`, `prod--readonly`, `prod--ci`) for per-role/per-account workflows. Storage state itself stays at mode 0600; this verb only emits metadata, never cookie/token values.
- [docs] `SKILL.md` verbs table gains rows for `login --interactive`, `login --storage-state-file`, and `list-sessions`. Login usage block now documents the 1-many model explicitly.
- [internal] `tests/list-sessions.bats` (5 cases) + 3 new login-flag tests. Phase-2 fixture-based login tests unchanged.

### Phase 4 part 4b — IPC daemon + stateful verbs (snapshot/click/fill) real mode

- [feat] `daemonChildMain` becomes an IPC server. Holds `(BrowserServer, Browser, current Context, current Page, refMap)` in closure. Listens on TCP loopback (random port — Unix socket sun_path is 104 chars on macOS; bats temp paths exceed it). State file gains `ipc_host` + `ipc_port` fields.
- [feat] `runSnapshot` / `runClick` / `runFill` route through `ipcCall` — JSON-line protocol over TCP loopback. Daemon executes verbs against held state; clients are thin transports.
- [feat] `runOpen` ALSO routes through IPC when daemon present; the daemon-held context+page persists for snapshot/click/fill. Falls back to one-shot launch when no daemon.
- [feat] `--secret-stdin` for fill: client reads stdin, sends text in JSON IPC message, daemon scrubs Playwright error logs (which echo fill args) before replying. Client reply never contains the secret on any path.
- [feat] Snapshot uses Playwright 1.59's `page.ariaSnapshot()` (replaces dropped `page.accessibility`). Output is YAML; `parseAriaSnapshot()` extracts interactive (role, name) tuples and assigns `eN` ids. Click/fill use `page.getByRole(role, {name}).first()` for stable cross-call locators.
- [internal] Empirical finding documented: `chromium.connect()` clients DO NOT share contexts across connections — that's why daemon-side dispatch (this design) is necessary. `runOpen`'s `attached_to_daemon: true` field now genuinely reflects state persistence.
- [internal] `tests/playwright-lib_stateful_e2e.bats` — 4 gated cases covering full chain (start → open → snapshot → click → stop), no-open-page error, ref-not-found error, and the secret-leak guard.
- [docs] `docs/superpowers/plans/2026-05-01-phase-04-part-4c-ipc-daemon.md` — design doc the implementation followed; kept as historical record.

### Phase 4 part 4a — Daemon lifecycle + open-via-daemon

- [feat] `playwright-driver.mjs` `daemon-start` / `daemon-stop` / `daemon-status` subcommands. Spawns a detached node child that calls `chromium.launchServer()` and writes state (PID + wsEndpoint + started_at) to `${BROWSER_SKILL_HOME}/playwright-lib-daemon.json` (mode 0600). Parent polls (≤10s), prints state, exits. Stopping SIGTERMs the PID and cleans up.
- [feat] `runOpen` attaches to a running daemon when present (chromium.connect via wsEndpoint). Closes pre-existing contexts so the agent's "current context" is unambiguous; a new context+page persists in the daemon for subsequent verbs. Falls back to one-shot launch when no daemon — keeps existing smoke-test ergonomics. Output now includes `attached_to_daemon: bool` so callers can see which path ran.
- [feat] Daemon stderr captured to `${BROWSER_SKILL_HOME}/playwright-lib-daemon.log` (mode 0600) — silent failures (e.g. missing chromium cache) become diagnosable.
- [internal] `tests/playwright-lib_daemon_e2e.bats` — 5 e2e cases gated on `command -v playwright`. Covers start/status/stop, attach-on-open, idempotent start, stop-when-none-running. CI without Playwright skips the file via `setup_file()`.
- [fix] `.gitignore` — daemon state/log files (so accidental driver runs from inside the repo don't pollute git).

### Phase 4 part 3 — Real-mode driver (open) + sessions threaded into all verbs

- [feat] `scripts/lib/node/playwright-driver.mjs` real-mode `open` — single-shot launch + navigate + close. Lazy-imports `playwright` via `createRequire` with `npm root -g` fallback (or `BROWSER_SKILL_NPM_GLOBAL` override) so users can keep playwright globally installed without project-level package.json.
- [feat] Stateful verbs (snapshot/click/fill/login) emit a clear "daemon mode required (Phase 4 part 4)" hint in real mode; stub mode + playwright-cli routes remain functional.
- [feat] `scripts/browser-snapshot.sh`, `browser-click.sh`, `browser-fill.sh` now call `resolve_session_storage_state` between argv parse and `pick_tool` — sessions thread through every verb script that has an adapter.
- [feat] `lib/session.sh::session_save` validates `storageState.origins[*].localStorage` is an array. Real Playwright errors at `browser.newContext()` if the field is missing — the new guard surfaces it at save time with a clear pointer. Hand-edited storageState files (Phase-2 login flow input) trip on the original shape; real captures (`context.storageState()`) come out correctly.

### Phase 4 — Real Playwright (node-bridge adapter) + session loading

- [adapter] `scripts/lib/tool/playwright-lib.sh` — second concrete adapter; shells to a Node ESM driver that speaks the real Playwright API directly. Declares `session_load: true` capability, supports `--secret-stdin` natively (driver reads stdin in node), declares `login` verb (replaces the Phase-2 stub).
- [feat] `scripts/lib/node/playwright-driver.mjs` — Node ESM bridge. Stub mode (`BROWSER_SKILL_LIB_STUB=1`) hashes argv → reads `tests/fixtures/playwright-lib/<hash>.json` so CI runs without Playwright installed. Real mode: deferred to follow-up (lazy-imports playwright; launches chromium; applies storageState).
- [feat] `scripts/lib/verb_helpers.sh::resolve_session_storage_state` — maps `--site` / `--as` to a storageState file path; exports `BROWSER_SKILL_STORAGE_STATE`. Origin enforcement via Phase-2 `session_origin_check`. `--as` without `--site` is a usage error.
- [feat] `scripts/lib/router.sh::rule_session_required` — placed before `rule_default_navigation`; prefers `playwright-lib` when `BROWSER_SKILL_STORAGE_STATE` is set.
- [feat] `parse_verb_globals` adds `--as SESSION` (sets `ARG_AS`).
- [feat] `scripts/browser-open.sh` calls `resolve_session_storage_state`; verb scripts now thread sessions transparently.
- [fix] `scripts/browser-login.sh` summary tag changes from `tool=playwright-lib-stub` to `tool=playwright-lib` (Phase-2 carry-forward closed).
- [docs] `references/playwright-lib-cheatsheet.md` — new cheatsheet covering the node-bridge specifics.
- [docs] `SKILL.md` verbs table gains a session-loading example row.
- [internal] `tests/playwright-lib_adapter.bats` (17 cases — 6 driver stub-mode + 11 adapter contract). `tests/session-loading.bats` (10 cases — full --site/--as resolution coverage including origin mismatch + missing-session paths).

### Phase 3 part 3 — Sibling verb scripts

- [feat] `scripts/browser-snapshot.sh` — `eN`-indexed accessibility snapshot via picked adapter; passes through optional `--depth N`.
- [feat] `scripts/browser-click.sh` — click by `--ref eN` (preferred) or `--selector CSS` (mutually exclusive; one required).
- [feat] `scripts/browser-fill.sh` — fill by `--ref eN` with `--text VALUE` or `--secret-stdin` (mutually exclusive). `--secret-stdin` reads the secret from stdin and pipes it through to the adapter; the secret string never appears in argv (test asserts the leak guard).
- [feat] `scripts/browser-inspect.sh` — inspect by `--selector CSS`.
- [docs] `SKILL.md` verbs table gains `snapshot` / `click` / `fill` / `inspect` rows.
- [internal] 4 new bats files (19 cases) + 2 new stub fixtures (`fill --ref e3 --text hello`, `inspect --selector h1`).

### Phase 3 part 2 — Real verb scripts

- [feat] `scripts/lib/verb_helpers.sh` — `parse_verb_globals` + `source_picked_adapter` shared boilerplate for all verb scripts.
- [feat] `scripts/browser-open.sh` — first real verb script: `--site`/`--tool`/`--dry-run`/`--raw` global flags, `--url` required arg, full router → adapter → emit_summary pipeline.
- [docs] `SKILL.md` verbs table gains `open` row.
- [internal] `tests/verb_helpers.bats` (5) + `tests/browser-open.bats` (6) — full pipeline coverage via the playwright-cli stub.

### Phase 3 — Tool adapter extension model + first adapter

#### Added
- [feat] `BROWSER_SKILL_TOOL_ABI=1` constant in `scripts/lib/common.sh` — single-source ABI version for adapters; `LIB_TOOL_DIR` exported by `init_paths`.
- [feat] `scripts/lib/output.sh` — token-efficient output helpers (`emit_summary` / `emit_event` / `capture_path`) implementing `2026-05-01-token-efficient-adapter-output-design.md` §3.
- [feat] `scripts/lib/router.sh` — single-source routing precedence with `ROUTING_RULES` array of rule functions; `pick_tool` + `_tool_supports` capability filter; `rule_default_navigation` routes open/click/fill/snapshot/inspect to playwright-cli.
- [adapter] First concrete adapter `scripts/lib/tool/playwright-cli.sh` implementing the contract (3 identity + 8 verb-dispatch fns); sources `output.sh`.
- [feat] `scripts/regenerate-docs.sh` — manual generator for `references/tool-versions.md` and `SKILL.md` Tools block; idempotent.
- [internal] `tests/lint.sh` — three-tier adapter lint (static + dynamic + drift) with `lint.bats` coverage; drift tier enforces autogen sync + every-adapter-sources-output.sh.
- [internal] `tests/routing-capability-sync.bats` — drift test ensuring router rules align with adapter-declared capabilities.
- [internal] `tests/stubs/playwright-cli` + `tests/fixtures/playwright-cli/` — argv-hash-keyed adapter contract tests.
- [docs] `references/playwright-cli-cheatsheet.md`.
- [docs] `references/recipes/add-a-tool-adapter.md` — two-path recipe (Path A: ship-without-promotion; Path B: promote-to-default).
- [docs] `references/recipes/anti-patterns-tool-extension.md` — 9 WRONG/RIGHT examples.

#### Changed
- [adapter] `scripts/browser-doctor.sh` — adapter aggregation loop walks `scripts/lib/tool/*.sh` in subshells; `node` elevated from advisory to required; status semantics ok/partial/error per adapter outcomes.
- [docs] `SKILL.md` — added autogenerated `## Tools` section between markers.

#### Documentation
- New design spec: `docs/superpowers/specs/2026-04-30-tool-adapter-extension-model-design.md` augmenting parent spec §3.3 + §13.2.
- New design spec: `docs/superpowers/specs/2026-05-01-token-efficient-adapter-output-design.md` codifying the bytes adapters emit (sources: chrome-devtools-mcp design principles + microsoft/playwright-cli + browser-act/skills).

### Phase 2 — Site & session core

- [feat] `add-site` / `list-sites` / `show-site` / `remove-site` verbs ship (typed-name confirm on remove)
- [feat] `use` verb: get / set / clear current site
- [feat] `login` verb (Phase 2 stub): consumes a hand-edited Playwright storageState file, validates origins against the site URL, writes session + meta sidecar
- [feat] `lib/site.sh`: site profile CRUD with atomic write, mode 0600, schema_version=1
- [feat] `lib/session.sh`: storageState read/write, `session_origin_check` (spec §5.5), `session_expiry_summary`
- [feat] `common.sh`: `now_iso` helper added (UTC, second precision)
- [security] sessions inherit the same gitignored / 0600-files invariant as Phase 1
- [internal] `tests/helpers.bash` now sources `lib/common.sh`; `${EXIT_*:-N}` fallback pattern dropped from all `.bats` files
- [docs] SKILL.md verb table reflects new verbs; mode wording corrected to "0700 dir, 0600 files"; `CLAUDE_SKILL_DIR` explainer added

### Phase 1 — Foundation

- [feat] `install.sh --user --with-hooks --dry-run` ships
- [feat] `uninstall.sh` ships (symlink-only by default)
- [feat] `doctor` verb: deps + bash version + home dir mode + disk encryption (advisory)
- [feat] `lib/common.sh`: exit codes, logging, summary_json, BROWSER_SKILL_HOME resolver, with_timeout, now_ms
- [security] `.gitignore` blocks credentials/sessions/captures/keys/.env
- [security] `.githooks/pre-commit` blocks staged credentials and password-shaped diff content
- [docs] SKILL.md, README.md, SECURITY.md scaffolded
- [internal] bats unit suite (~44 tests) runs in <10 s

### Phase 1 — Pre-Phase-2 cleanup (post v0.1.0-phase-01-foundation)

- [fix] `now_ms()` moved from `browser-doctor.sh` into `lib/common.sh` so future verb scripts can compute `duration_ms` without copy-paste.
- [fix] `node` check in doctor downgraded to advisory: missing node now warns but does not increment `problems` (Phase 1 does not require node yet; Phase 3 will elevate).
- [internal] new `check_cmd_advisory` helper in doctor for warn-but-do-not-fail dependency checks.
