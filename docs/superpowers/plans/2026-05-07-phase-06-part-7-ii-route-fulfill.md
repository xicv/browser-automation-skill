# Phase 6 part 7-ii — `route` verb extension: `--action fulfill`

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans.

**Goal:** Synthetic responses for routed network requests. Agents can mock APIs end-to-end (HTTP status + body), completing the block/allow/fulfill triad started in 7-i. **Closes Phase 6 entirely.**

**Branch:** `feature/phase-06-part-7-ii-route-fulfill`
**Tag:** `v0.32.0-phase-06-part-7-ii-route-fulfill`

---

## Surface

```bash
# Inline body
bash scripts/browser-route.sh \
  --pattern "https://api.example.com/users/*" \
  --action fulfill \
  --status 404 \
  --body 'not found'

# Body via stdin (AP-7 NUL-terminated; binary-safe except for NUL itself)
printf '{"users":[]}' | bash scripts/browser-route.sh \
  --pattern "https://*.tracking.com/api/*" \
  --action fulfill \
  --status 200 \
  --body-stdin
```

Daemon-required (mirrors 7-i). Without daemon → exit 41.

---

## Validation rules (bash-side; bridge re-checks defensively)

- `--action fulfill` adds `fulfill` to the accepted set `{block, allow, fulfill}`.
- `--action fulfill` **requires** `--status N` (integer in `[100, 599]`).
- `--action fulfill` **requires** exactly one of `--body STR` ⊕ `--body-stdin` (mutex).
- `--status N` is only valid with `--action fulfill`. Combined with `block`/`allow` → error.
- `--body` / `--body-stdin` only valid with `--action fulfill`. Combined with `block`/`allow` → error.

---

## Body transport (binary-safety contract)

Hop chain: `bash route.sh` → `tool_route` (adapter) → `node bridge.mjs` → daemon-child (in-process JS) → MCP `route_url`.

- `--body STR`: rides argv all the way through. Argv can't carry NUL — caller knows.
- `--body-stdin`: bash route.sh **does not** read stdin itself; it forwards the `--body-stdin` flag to the bridge so stdin is inherited naturally (matches `fill --secret-stdin` precedent in `scripts/browser-fill.sh:87`). Bridge reads stdin via AP-7 NUL-terminated `IFS= read -r -d ''` equivalent (Node: read-all-stdin until EOF; bash bats validation uses `read -r -d ''` for the bash-side analogue).

**Documented limitation:** bash variables and JSON IPC strings can't carry the NUL byte itself. Multipart bodies legitimately containing NUL would need a different transport (base64? file path?). Out of scope for 7-ii. Documented in CHANGELOG.

**Body verbatim policy:** unlike `fill --secret-stdin` (which strips one trailing newline, since secrets shouldn't carry it), `route fulfill` stores the body **as-is** including trailing bytes. Reason: HTTP bodies are content, not credentials — round-trip fidelity matters. Test asserts roundtrip.

---

## Daemon state evolution

`routeRules` slot extends:

```diff
- [{ pattern, action }]                      // 7-i: block | allow
+ [{ pattern, action },                      // unchanged for block | allow
+  { pattern, action: 'fulfill', status: N, body: 'STR' }]  // new for fulfill
```

In-memory only — rules die with the daemon (already true in 7-i; no on-disk persistence introduced). Body lives in the daemon process; never written to disk.

---

## Reply shape

Block/allow unchanged. Fulfill:

```json
{
  "verb": "route",
  "tool": "chrome-devtools-mcp",
  "why":  "mcp/route_url",
  "status": "ok",
  "pattern": "https://api.example.com/users/*",
  "action": "fulfill",
  "fulfill_status": 404,
  "body_bytes": 9,
  "rule_count": 1,
  "mcp_ack": "routed ... (status 404, 9 bytes)",
  "attached_to_daemon": true
}
```

`fulfill_status` (not `status` — that's already used for ok/error). `body_bytes` is the byte length, not the body itself — avoids noisy output for large bodies and avoids re-emitting agent-supplied content.

---

## File structure

### New
- `tests/browser-route.bats` (extend; 1 test rewritten + ~7 added) — fulfill validation, mutex, status-range, body-stdin roundtrip-shape (in dry-run).
- `docs/superpowers/plans/2026-05-07-phase-06-part-7-ii-route-fulfill.md` — this plan.

### Modified
- `scripts/browser-route.sh` — accept `fulfill`; parse `--status` / `--body` / `--body-stdin`; mutex + range validation.
- `scripts/lib/tool/chrome-devtools-mcp.sh::tool_route` — already passes `rest` through; no change needed (verify in tests).
- `scripts/lib/node/chrome-devtools-bridge.mjs::runRouteViaDaemon` — parse extra flags; read stdin on `--body-stdin`; ipc `{verb:'route', pattern, action, status?, body?}`.
- `scripts/lib/node/chrome-devtools-bridge.mjs` daemon-child `case 'route'` — extend allowed actions; validate status+body for fulfill; persist extended rule shape; pass status+body to MCP `route_url`.
- `tests/stubs/mcp-server-stub.mjs::route_url` — echo `(status N, M bytes)` suffix on fulfill so e2e can assert.
- `tests/chrome-devtools-mcp_daemon_e2e.bats` (+~3) — fulfill happy with status+body persisted; body roundtrips verbatim through stdin; bridge-side rejection of out-of-range status (defense-in-depth).
- `CHANGELOG.md` — Phase 6 part 7-ii subsection. Note **Phase 6 complete (11/11 verbs)**.
- `SKILL.md` — autoregenerated tools-table (no row count change since `route` already present).

---

## Test plan

`tests/browser-route.bats`:
1. **rewritten** — `--action fulfill` (with status + body) succeeds dry-run; output JSON has `action == "fulfill"`, `fulfill_status == 200`, `body_bytes > 0`, `dry_run == true`.
2. `--action fulfill` without `--status` → `EXIT_USAGE_ERROR` mentioning `--status`.
3. `--action fulfill` without body → `EXIT_USAGE_ERROR` mentioning `--body`.
4. `--action fulfill --body X --body-stdin` mutex → `EXIT_USAGE_ERROR`.
5. `--action fulfill --status 99` (out of range) → `EXIT_USAGE_ERROR` mentioning `100-599`.
6. `--action fulfill --status notanumber` → `EXIT_USAGE_ERROR`.
7. `--action block --status 200` (status without fulfill) → `EXIT_USAGE_ERROR`.
8. `--action allow --body X` (body without fulfill) → `EXIT_USAGE_ERROR`.

`tests/chrome-devtools-mcp_daemon_e2e.bats`:
1. fulfill via daemon: `rule_count == 1`, `fulfill_status == 200`, `body_bytes` matches body length, MCP stub log records the call.
2. `--body-stdin` body roundtrips verbatim — daemon stub echoes `M bytes` matching the bash-piped byte count.
3. fulfill with non-int status arriving at the bridge (defensive) — daemon-child error event mentioning `100-599`.

---

## Tag + push

```bash
git tag v0.32.0-phase-06-part-7-ii-route-fulfill
git push -u origin feature/phase-06-part-7-ii-route-fulfill
git push origin v0.32.0-phase-06-part-7-ii-route-fulfill
gh pr create --title "feat(phase-6-part-7-ii): route fulfill verb extension (closes Phase 6)"
```
