# Phase 9 part 1-ii — `${refs.NAME}` resolution + `assert` step

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans.

**Goal:** Second sub-part of Phase 9. Adds the missing capability that 9-1-i deferred. After a `snapshot:` step, subsequent steps' `${refs.NAME}` placeholders resolve via accessibility-tree text → ref lookup. Plus a new `assert` verb (selector + text-contains predicate) so flows can verify post-conditions.

**Branch:** `phase-09-part-1-ii-refs-and-assert`
**Tag:** `v0.43.0-phase-09-part-1-ii-refs-and-assert`

---

## Snapshot verb's stub-mode event line (researched)

```
{"event":"snapshot","refs":[{"ref":"e1","tag":"a","text":"Home"},{"ref":"e2","tag":"button","text":"Sign in"}]}
{"verb":"snapshot","tool":"playwright-cli","why":"default for snapshot","status":"ok","duration_ms":75}
```

The first line is an `event:snapshot` carrying `refs[]` array of `{ref, tag, text}` objects. The second is the standard summary. Real-mode emits the same shape (event line + summary line).

## Locked decisions

### R1: ref-source = parse the snapshot verb's `event:snapshot` stdout line

`flow_dispatch` already captures verb stdout. Extension: scan captured lines for any `event:snapshot` line; extract `refs[]`; attach as `refs` field on the step-event JSON. Browser-flow.sh's main loop then harvests step.refs into a global `FLOW_REFS` assoc map (text → ref).

**Rejected:** R2 (read snapshot's stored capture file) — adds capture-file-read I/O on every step; fragile to capture composition (the snapshot might not be in a captures/NNN/ dir at all in dry-run mode).

### R2: name-match policy = exact text match (case-sensitive, no trim)

`${refs.Email}` looks up `FLOW_REFS["Email"]`. No case-fold, no trim. Matches Playwright's `getByRole({name: ...})` semantics.

**Rejected:** case-insensitive (silent matches across distinct-meaning labels); trim-only (cheap whitespace-tolerance — but if it matters, the user can author the YAML with the trimmed name). Strict-match is the safer default.

### R3: multi-snapshot semantics = latest-snapshot-wins (replace FLOW_REFS wholesale)

```yaml
steps:
  - snapshot: {}                  # FLOW_REFS = {Home: e1, Sign in: e2}
  - click: { ref: ${refs.Home} }
  - open: { url: /admin }
  - snapshot: {}                  # FLOW_REFS = {Logout: e1, Settings: e2}  ← REPLACED
  - click: { ref: ${refs.Logout} }
```

Rationale: matches single-page mental model. The DOM changes after `open`; the prior snapshot's refs are stale.

**Rejected:** accumulate semantics — older refs would silently coexist with newer; risk of cross-page ref collisions. Latest-wins is simpler and safer.

### R4: missing-ref = `EXIT_USAGE_ERROR` with helpful message

`${refs.Foo}` when `FLOW_REFS["Foo"]` is missing → die with:
```
flow_apply_vars: undefined ref '${refs.Foo}' (no snapshot has surfaced "Foo" — add a snapshot step first OR check the accessible name)
```

Per design doc §3 F3: "Not-yet-snapshotted ref → `EXIT_USAGE_ERROR` (fail loud; don't guess)." Confirmed.

### A1: `assert` verb = thin wrapper, no adapter ABI changes

```bash
bash scripts/browser-assert.sh --selector CSS --text-contains TEXT
```

Internally shells to `bash scripts/browser-extract.sh --selector CSS` to get the selector's text (uses existing extract verb's surface; routes through router + chrome-devtools-mcp by default). Bash-side compares the extracted text against `--text-contains TEXT` predicate. Returns:
- exit 0 + `status: ok` if predicate matches
- exit 13 (`EXIT_ASSERTION_FAILED`) + `status: error` + `expected:` / `got:` fields if predicate fails

**No new tool_assert function on adapters.** Composition over ABI extension.

**Predicate set in v1:** `--text-contains TEXT` only. Future iteration: `--text-equals`, `--text-regex`, `--selector-count-eq N`. Per design doc §12 open Q (1).

## API additions

### `scripts/lib/flow.sh::flow_dispatch` (extend)

After running the verb, scan captured `verb_out` for any `event:snapshot` line. If found, extract `refs[]` and attach as `refs` field on the step-event JSON.

### `scripts/lib/flow.sh::flow_apply_vars` (extend)

Recognize `${refs.NAME}` placeholders. Look up `FLOW_REFS[NAME]`; if missing → die `EXIT_USAGE_ERROR`. Replaces the prior literal-pass-through behavior from 9-1-i. **Backward note:** this is a behavior change for any flow that currently relies on `${refs.X}` passing through as a literal string. Tracker: `tests/fixtures/flows/refs-passthrough.flow.yaml` is updated to test the new resolution path; the literal-pass-through scenario is no longer supported.

### `scripts/browser-flow.sh` main loop (extend)

After each step-event, check `.refs`. If non-null, replace `FLOW_REFS` wholesale. New global `declare -gA FLOW_REFS=()`.

### `scripts/browser-assert.sh` (new)

Standard verb shape:
```bash
bash scripts/browser-assert.sh --selector CSS --text-contains TEXT [--site NAME] [--tool NAME] [--dry-run]
```

- Parses `--selector` + `--text-contains` (both required).
- Calls `bash scripts/browser-extract.sh --selector CSS` (subprocess).
- Captures the extract result; parses it for the selector's text.
- Compares against `text-contains` predicate.
- Emits summary: `status: ok` (matches) / `status: error` (predicate failed; includes `expected` + `got` fields).
- Exit codes: 0 (ok) / 13 (`EXIT_ASSERTION_FAILED`) / 2 (`EXIT_USAGE_ERROR`) / 1 (extract subprocess failed).

## Test cases (RED → GREEN)

`tests/flow-runner.bats` (extend the 12-case file):

13. `flow_dispatch` of a snapshot step extracts refs[] from event line into step.refs.
14. `flow_apply_vars` resolves `${refs.Email}` via global `FLOW_REFS`.
15. `flow_apply_vars` errors loudly on missing ref (`${refs.GhostName}`).
16. **End-to-end:** snapshot → fill ${refs.Sign in} → executes with `e2` substituted (per stub fixture text→ref map).
17. Two snapshots in one flow → second replaces FLOW_REFS wholesale (latest-wins).

`tests/fixtures/flows/with-refs.flow.yaml` — new fixture using `${refs.NAME}` after snapshot.
`tests/fixtures/flows/refs-passthrough.flow.yaml` — UPDATE: now tests resolution path (rename or repurpose).

`tests/browser-assert.bats` (new file, ~5 cases):

1. `--selector` + `--text-contains` happy path: extract returns matching text → exit 0 + `status:ok`.
2. predicate fail: extract returns non-matching text → exit 13 + `status:error` + `expected` + `got`.
3. missing `--selector` → `EXIT_USAGE_ERROR`.
4. missing `--text-contains` → `EXIT_USAGE_ERROR`.
5. `--dry-run` → planned action printed; exit 0; no extract subprocess invoked.

## Sub-scope (what 9-1-ii does NOT do)

- **No `--text-regex` predicate.** v1 is `--text-contains` only.
- **No `--text-equals` predicate.** Use `--text-contains` with the full string for now.
- **No `--selector-count-eq N` predicate.** Future iteration.
- **No multi-snapshot accumulate mode.** Latest-wins.
- **No name-match-with-fuzzy-toleration.** Exact match only.
- **No `flow record`** (9-1-iii).
- **No `replay <id>`** (9-1-iv).
- **No `history` / `baseline`** (9-1-v).

## Acceptance

- `tests/flow-runner.bats` extended with 5 new cases (12 → 17); all green.
- `tests/browser-assert.bats` new file with 5 cases; all green.
- `bash tests/lint.sh` exit 0 (all three tiers).
- New `scripts/browser-assert.sh` reachable; routes via existing router (no new rule needed if assert routes through extract internally).
- `with-refs.flow.yaml` fixture exercises end-to-end snapshot → ref resolution → fill.
- CHANGELOG `[Unreleased]` `[feat]` tag.

## Notes for follow-ups

- **9-1-iii: `flow record`** — wraps `playwright codegen`; transformer JS → YAML.
- **9-1-iv: `replay <id>`** — re-execute capture's steps; structured diff.
- **9-1-v: `history` + `baseline`** — read-side ops; closes Phase 9.
