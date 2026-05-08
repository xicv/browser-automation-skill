# Phase 7 part 1-iii — `inspect --capture` wire-up (capture + sanitize composition)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans.

**Goal:** First composition of 7-1-i's `lib/capture.sh` + 7-1-ii's `lib/sanitize.sh` against a real verb. `inspect --capture` writes `console.json` + `network.har` to `${CAPTURES_DIR}/NNN/`, both sanitized by default. Privacy canary asserts no leakage end-to-end.

**Branch:** `feature/phase-07-part-1-iii-inspect-capture-wireup`
**Tag:** `v0.35.0-phase-07-part-1-iii-inspect-capture-wireup`

---

## Surface

```bash
bash scripts/browser-inspect.sh --capture-console --capture-network --capture
# → ~/.browser-skill/captures/001/console.json   (sanitize_console applied)
# → ~/.browser-skill/captures/001/network.har    (sanitize_har applied)
# → ~/.browser-skill/captures/001/meta.json      (status:ok, files[], total_bytes)
# Summary line includes capture_id="001"
# Adapter stdout (agent-visible) ALSO sanitized — defense in depth
```

`--capture` is opt-in. Without it: existing inspect behavior unchanged (raw output, no persist).

---

## Three-step pipeline (per call when `--capture` set)

```
adapter call → adapter_out (raw JSON; bridge reply with .console_messages + .network_requests)
        ↓
sanitize_inspect_reply (NEW helper in lib/sanitize.sh)
   ├── extract .console_messages  → sanitize_console → write console.json
   ├── extract .network_requests  → wrap as HAR → sanitize_har → write network.har
   └── reassemble adapter reply with sanitized substitutes
        ↓
print SANITIZED adapter_out to stdout (agent-visible — defense in depth)
        ↓
emit_summary verb=inspect ... capture_id=NNN
```

Why sanitize stdout AND disk: the streaming output is the agent's transcript surface — same leak vector as disk persistence. Single sanitize, both sinks. Spec §4.1 emphasizes disk sanitization; defense-in-depth applies sanitize to stdout too at zero extra cost (one transformation, two emits).

---

## `sanitize_inspect_reply` (new helper)

Lives in `scripts/lib/sanitize.sh`. Reads inspect-shaped JSON on stdin, emits same shape with `.console_messages` and `.network_requests` sanitized:

```bash
sanitize_inspect_reply() {
  # stdin: full inspect JSON reply from bridge.
  # stdout: same JSON shape with .console_messages + .network_requests sanitized.
  ...
}
```

Implementation: bash function that uses `jq` to extract → pipes through existing `sanitize_console` / `sanitize_har` (the latter via HAR envelope wrap-then-unwrap) → reassembles with `jq --argjson` substitutes.

**Why this lives in lib/sanitize.sh:** it's sanitize-domain logic, not verb-domain. Future verbs that need per-call sanitization (e.g. `audit --capture` in 7-1-v wiring) can reuse the same helper or pattern.

---

## What this sub-part does NOT ship

Per 7-1-iii sub-scope discipline:

- **No `--unsanitized` flag.** Typed-phrase opt-out is 7-1-iv. This PR's behavior is ALWAYS sanitized when `--capture` set.
- **No `meta.sanitized:false` audit field.** 7-1-iv. (Today's meta.json doesn't carry `sanitized` field; absent = always-sanitized in 7-1-iii.)
- **No retention/prune.** 7-1-v.
- **No screenshot capture.** Existing `--screenshot` flag still emits `screenshot_path` from adapter; persisted as part of inspect.json or skipped in 7-1-iii. Out of scope for this PR's primary path; revisit in a follow-up if user demand surfaces.
- **No HAR shape adapter** for the bridge's flat `network_requests` array. Test fixture authors HAR-shape entries directly. Real CDT-MCP shape may need adaptation; that's binding-hardening track.

---

## File structure

### New
- `tests/fixtures/chrome-devtools-mcp/d0fcae777fd32c21edd55fca4e04d2b3130ea15124eac7f0de79613c080d1733.json` — bridge fixture for `inspect --capture-console --capture-network` argv. Contains rich content with sensitive headers + URL params + console message text (privacy-canary fodder).
- `docs/superpowers/plans/2026-05-08-phase-07-part-1-iii-inspect-capture-wireup.md` — this plan.

### Modified
- `scripts/lib/sanitize.sh` — adds `sanitize_inspect_reply` helper (~40 lines).
- `scripts/browser-inspect.sh` — accepts `--capture`, sandwiches `capture_start` / `sanitize_inspect_reply` / per-aspect file writes / `capture_finish` around adapter call.
- `tests/sanitize.bats` (+~2 cases) — direct unit tests for `sanitize_inspect_reply`: console + network co-sanitization in one pass.
- `tests/browser-inspect.bats` (+~5 cases) — `--capture` wire-up: dir 0700, files 0600, capture_id in summary, persisted files sanitized, **privacy canary** (Authorization Bearer + console password + URL api_key all redacted on disk + on stdout).
- `CHANGELOG.md` — `[Unreleased]` Phase 7 part 1-iii entry.

### NOT modified
- No bridge changes — bridge already emits the right reply shape.
- No router changes.
- No adapter capabilities.
- No drift sync needed (capabilities unchanged).

---

## Test plan

### `tests/sanitize.bats` (+~2 cases)
1. `sanitize_inspect_reply` — applies sanitize_console to .console_messages AND sanitize_har envelope to .network_requests in one stdin → stdout pass.
2. `sanitize_inspect_reply` — preserves non-sanitized fields (verb, tool, why, status, etc.) untouched.

### `tests/browser-inspect.bats` (+~5 cases)
1. **`--capture` writes captures/001/{console.json, network.har, meta.json}** — files exist; `meta.json::status == "ok"`; `summary.capture_id == "001"`.
2. **Mode 0700 dir, 0600 files** — perms invariant per existing capture pipeline.
3. **Privacy canary (HEADER)** — fixture has `Authorization: Bearer SECRET-CANARY-7-1-iii`; persisted `network.har` has the literal canary string ABSENT and `***REDACTED***` PRESENT; same for stdout output.
4. **Privacy canary (URL param)** — fixture has `?api_key=URL-CANARY`; persisted network.har: `URL-CANARY` absent, `api_key=***` present.
5. **Privacy canary (console)** — fixture has console message `password: PWD-CANARY`; persisted console.json: `PWD-CANARY` absent, `password: ***` present.
6. **Without `--capture`** — adapter output emitted RAW (no sanitization), no captures/ dir created. Existing behavior preserved.

---

## Tag + push

```bash
git tag v0.35.0-phase-07-part-1-iii-inspect-capture-wireup
git push -u origin feature/phase-07-part-1-iii-inspect-capture-wireup
git push origin v0.35.0-phase-07-part-1-iii-inspect-capture-wireup
gh pr create --title "feat(phase-7-part-1-iii): inspect --capture wire-up (capture + sanitize composition)"
```
