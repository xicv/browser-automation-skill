# Phase 7 part 1-iv — `--unsanitized` typed-phrase opt-out + audit flag + doctor counter

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans.

**Goal:** Escape-hatch for users who legitimately need raw network/console data (e.g. debugging an auth flow that the sanitizer is hiding). Strict typed-phrase confirmation; `meta.sanitized:false` audit field for forensic review; `doctor` counter so accidental persistence of raw captures is visible.

**Branch:** `feature/phase-07-part-1-iv-unsanitized-flag`
**Tag:** `v0.36.0-phase-07-part-1-iv-unsanitized-flag`

---

## Surface

```bash
# Default (sanitized) — unchanged from 7-1-iii:
bash scripts/browser-inspect.sh --capture-console --capture-network --capture
# → console.json + network.har sanitized; meta.sanitized = true

# Opt-out (raw):
printf '%s\n' 'I want raw network/console data including auth tokens' \
  | bash scripts/browser-inspect.sh --capture-console --capture-network --capture --unsanitized
# → console.json + network.har RAW (no redaction)
# → meta.json::sanitized = false (audit field)
# → stdout output ALSO raw (consistent with disk)

# Mismatched phrase → error:
printf '%s\n' 'wrong phrase' \
  | bash scripts/browser-inspect.sh ... --unsanitized
# → EXIT_USAGE_ERROR; capture aborted; no files written
```

Phrase (verbatim, per parent spec §8.3):
```
I want raw network/console data including auth tokens
```

---

## Typed-phrase mechanism (mirrors `creds-show --reveal`)

```bash
# Prompt to stderr (so it doesn't pollute the JSON stdout contract):
printf 'Type the unsanitized confirmation phrase to confirm: ' >&2

# Read single line from stdin:
IFS= read -r answer || true

# Strict equality (no normalization, no leading/trailing whitespace strip):
if [ "${answer}" != "I want raw network/console data including auth tokens" ]; then
  die "${EXIT_USAGE_ERROR}" "unsanitized aborted (confirmation mismatch)"
fi
```

**Why no env var bypass.** `creds-show --reveal` doesn't have one. For scripted use, the typed phrase is piped via stdin (`printf '...' | bash inspect.sh ...`). Friction-by-design. Future env var bypass requires explicit user-demand signal — not preemptive.

**Why prompt to stderr.** stdout is the JSON contract; the prompt is interactive UX. Stderr keeps the contract clean.

---

## `lib/capture.sh::capture_finish` extension

```bash
# capture_finish [status] [sanitized]
#   status: "ok" | "error"  (default "ok")
#   sanitized: "true" | "false"  (default "true")
#
# When sanitized=false, writes meta.sanitized = false; otherwise
# meta.sanitized = true. Field is ALWAYS present in v1+ schema.
```

**Schema impact:** `meta.json` adds `sanitized: bool` field. Field is added without bumping `schema_version` since:
- All existing readers ignore unknown fields (jq accesses are guarded).
- Default value is `true` for callers that don't pass an explicit value (snapshot 7-1-i, retroactively).
- Renaming/removing later WOULD bump schema_version per the v1 contract.

---

## `browser-doctor.sh` counter

After the existing credentials block, add a captures block:

```
captures: 12 total (sanitized:false: 2)
  warning: 2 capture(s) with sanitization disabled — review captures/004/, captures/009/
```

Walks `${CAPTURES_DIR}/*/meta.json`; reads `.sanitized` field; counts both totals. Uses `[ "${sanitized}" = "false" ]` so missing/null reads as sanitized=true (forward-compatible with pre-7-1-iv captures).

When `sanitized:false` count > 0: emit `warn` line listing the capture IDs. Non-fatal (doesn't increment `problems`); informational so users notice when they've been doing raw captures.

---

## What this sub-part does NOT ship

- **No retention/prune.** That's 7-1-v.
- **No env var bypass for typed phrase.** Scripted use pipes via stdin.
- **No --unsanitized on snapshot.** Snapshot's data isn't sanitization-relevant (refs only). Flag rejected on snapshot to avoid confusion.
- **No retroactive meta.sanitized backfill** for captures created pre-7-1-iv. Doctor reads `.sanitized // null` and treats null as sanitized:true.

---

## File structure

### New
- `docs/superpowers/plans/2026-05-09-phase-07-part-1-iv-unsanitized-flag.md` — this plan.

### Modified
- `scripts/browser-inspect.sh` — accept `--unsanitized`; typed-phrase confirm; skip `sanitize_inspect_reply` on confirmed; pass `false` to `capture_finish`.
- `scripts/lib/capture.sh::capture_finish` — accept optional 2nd arg `sanitized`. Default `"true"`. Writes meta.sanitized field.
- `scripts/browser-doctor.sh` — add captures-sanitization counter block.
- `tests/browser-inspect.bats` (+~5 cases) — typed-phrase mismatch error; happy path raw persistence; meta.sanitized=false; default sanitized=true; canary survives in raw mode.
- `tests/capture.bats` (+~3 cases) — `capture_finish ok true` writes sanitized=true; `capture_finish ok false` writes sanitized=false; default `capture_finish` (no args) writes sanitized=true.
- `tests/browser-doctor.bats` (+~2 cases) — counter present in summary when captures exist; warn line emitted when sanitized:false count > 0.
- `CHANGELOG.md` — `[Unreleased]` Phase 7 part 1-iv entry.

### NOT modified
- No router/adapter/bridge changes.
- No drift sync needed.

---

## Test plan

### `tests/capture.bats` (+~3 cases)
1. `capture_finish ok true` → meta.sanitized = true.
2. `capture_finish ok false` → meta.sanitized = false.
3. `capture_finish` (no args, default) → meta.sanitized = true (backward-compat).

### `tests/browser-inspect.bats` (+~5 cases)
4. `--unsanitized` with typed-phrase mismatch → `EXIT_USAGE_ERROR`; no captures dir created.
5. `--unsanitized` with correct typed phrase → meta.sanitized = false; canary string PRESERVED on disk (e.g. `HEADER-CANARY-7-1-iv` survives).
6. Default (no `--unsanitized`) → meta.sanitized = true (backward-compat with 7-1-iii canary tests).
7. `--unsanitized` confirmed: stdout output ALSO raw (consistent with disk).
8. `--unsanitized` confirmed: typed-phrase requirement is `IFS= read -r` strict — leading whitespace mismatch fails.

### `tests/browser-doctor.bats` (+~2 cases)
9. After 2 sanitized captures: doctor reports `captures: 2 total (sanitized:false: 0)`; no warn.
10. After mixed (1 sanitized, 1 unsanitized): doctor reports `captures: 2 total (sanitized:false: 1)` + warn line.

---

## Tag + push

```bash
git tag v0.36.0-phase-07-part-1-iv-unsanitized-flag
git push -u origin feature/phase-07-part-1-iv-unsanitized-flag
git push origin v0.36.0-phase-07-part-1-iv-unsanitized-flag
gh pr create --title "feat(phase-7-part-1-iv): --unsanitized opt-out + audit + doctor counter"
```
