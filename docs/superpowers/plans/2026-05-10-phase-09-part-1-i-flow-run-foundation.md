# Phase 9 part 1-i — `flow run <file>` foundation

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans.

**Goal:** First sub-part of Phase 9. Ships `flow run <file>` end-to-end against the v1 YAML subset. Per-step bash verb dispatch + `${var}` templating + whole-flow capture (meta.json + steps.jsonl). NO `${refs.NAME}` resolution (deferred to 9-1-ii). NO `assert` step (deferred to 9-1-ii).

**Branch:** `phase-09-part-1-i-flow-run-foundation`
**Tag:** `v0.42.0-phase-09-part-1-i-flow-run-foundation`

---

## YAML subset supported in 9-1-i (constrained; design doc §3 F1+F2 + this doc)

```yaml
name: my-flow                                    # required
session: task-1                                  # optional; passed as --as to verb scripts
vars:                                            # optional; ${var} substituted at parse-time
  url_path: /users/new
  user_email: alice@example.com

steps:                                           # required; ≥1 step
  - open: { url: ${url_path} }
  - snapshot: {}
  - fill: { ref: e3, text: ${user_email} }
  - wait: { selector: .toast-success, timeout: 5000 }
```

**Constraints (v1):**
- Top-level keys: `name`, `session`, `vars`, `steps` only. Unknown top-level → parser warns + ignores.
- `vars:` block — flat key:value, one per line, scalar values only. No nested maps; no lists.
- `steps:` — list of single-key maps. Each step's body is a flow-style `{ key: val, key: val }` inline map. Block-style step bodies (multi-line indented map) NOT supported in v1.
- Step body values: scalar strings/numbers/booleans only. Lists / nested maps NOT supported in v1.
- `${var}` substitution at parse time only. Missing var → `EXIT_USAGE_ERROR` before first step runs.
- `${refs.NAME}` recognized but **NOT resolved** in v1 (passed through as literal string). 9-1-ii adds resolution; until then, callers should use literal `e3` / `e7` refs (or selectors).

**Documented limits (out of scope for 9-1-i):**
- No nested `vars`. No list-valued vars. No env-var pull-through (would need `${env.HOME}` syntax).
- No multi-line strings in step bodies. No comments inside `{...}` (comments outside steps OK).
- No conditional / loop / parallel constructs.
- No `${refs.NAME}` resolution.
- No `assert` step (the verb doesn't exist yet).

## API additions

### `scripts/browser-flow.sh` (new entry point)

```bash
bash scripts/browser-flow.sh run <flow-file> [--var key=val [--var key=val ...]] [--dry-run]
```

- `<flow-file>` — path to a `.flow.yaml` file. Resolves relative to `${CWD}` first, then `${BROWSER_SKILL_HOME}/flows/`. Path security: realpath canonicalize + reject sensitive patterns (mirror `references/recipes/path-security.md`).
- `--var key=val` — overrides a `vars:` entry. Repeatable. Missing override-target → silent no-op (overrides any vars: defaults).
- `--dry-run` — parses + validates + prints planned step list; does NOT execute.

**Exit semantics:**
- Parse error / missing var → `EXIT_USAGE_ERROR` (2).
- All steps succeed → exit 0; summary `status: ok`.
- Some steps succeed, some fail → exit 0 (still "completed"); summary `status: partial`, `failed_steps` count.
- All steps fail → exit non-zero (carries last failed step's exit code); summary `status: error`.
- Aborted mid-flow (parse error of dynamic value, etc.) → exit `EXIT_GENERIC_ERROR` (1); summary `status: aborted`.

### `scripts/lib/flow.sh` (new lib helper)

Three-fn API:
```bash
flow_parse <flow-file>                # → emits per-step JSON to stdout (one per line)
flow_apply_vars <step-json> <var-map> # → substitutes ${var} in step args; emits modified step JSON
flow_dispatch <step-json>             # → calls bash scripts/browser-<verb>.sh with translated argv
```

`flow_parse` is the YAML reader. Implementation: bash sed/awk over the v1 subset. ~80 LOC. Output is jq-friendly JSON: `{step_index, verb, args}` per step on stdout, one per line.

`flow_apply_vars` walks `step.args` values; for each `${var}` occurrence, looks up the var map; emits the substituted shape.

`flow_dispatch` translates step args back to verb-script flag form. e.g. `{verb: "fill", args: {ref: "e3", text: "Alice"}}` → `bash scripts/browser-fill.sh --ref e3 --text Alice`. Captures the verb's stdout (the verb's own summary line) → wraps in step-event JSON for steps.jsonl.

### `scripts/browser-flow.sh` capture composition (per design doc F4)

```
capture_start "flow"
  → meta.json: { capture_id, verb: "flow", flow_name, ... }

for each step in flow:
  → flow_dispatch <step>
  → append step-event line to ${CAPTURE_DIR}/steps.jsonl

capture_finish "ok|partial|error" sanitized=true
  → meta.json updated: status, finished_at, step_count, successful_steps, failed_steps
```

`steps.jsonl` line shape:
```json
{"step_index": 0, "verb": "open", "args": {"url": "/users/new"}, "status": "ok", "duration_ms": 142, "exit_code": 0, "summary": {<verb's own summary line>}}
```

## Test cases (RED → GREEN)

`tests/flow-runner.bats` (new file, ~12 cases):

1. `flow_parse` of a valid 3-step flow → emits 3 JSON-line steps with correct `step_index`/`verb`/`args`.
2. `flow_parse` of an empty flow (no `steps:`) → exit 2 (USAGE_ERROR); "missing required field 'steps'".
3. `flow_parse` of a flow with no `name:` → exit 2; "missing required field 'name'".
4. `flow_parse` of a flow with one unknown top-level key → warns to stderr + parses successfully.
5. `flow_apply_vars` substitutes `${var}` in step args; missing var → exit 2.
6. `flow_apply_vars` leaves `${refs.NAME}` literal (deferred to 9-1-ii).
7. `flow_dispatch` of `{verb: "snapshot", args: {}}` → invokes `bash scripts/browser-snapshot.sh`; captures the verb's summary line.
8. `flow_dispatch` of `{verb: "open", args: {url: "...", headed: true}}` → invokes with `--url ... --headed` (boolean true → bare flag).
9. `flow_dispatch` of unknown verb → exit 41 (UNSUPPORTED_OP); step-event records the failure.
10. **End-to-end:** `bash scripts/browser-flow.sh run <file> --dry-run` → parses + prints plan + exits 0; no capture written.
11. **End-to-end:** `bash scripts/browser-flow.sh run <file>` (3 stub-supported steps) → 3 step events in steps.jsonl + summary `status: ok / step_count: 3 / successful_steps: 3`.
12. **End-to-end:** flow with one failing step → summary `status: partial / successful_steps: 2 / failed_steps: 1`.

`tests/fixtures/flows/` (new dir):
- `simple.flow.yaml` — 3-step happy-path flow (snapshot + open + dry-run-friendly).
- `with-vars.flow.yaml` — uses `vars:` + `${var}` substitution.
- `missing-name.flow.yaml` — invalid (missing `name:`).
- `mixed-results.flow.yaml` — 3 steps; one expected to fail.

## Path security + privacy canary

- `<flow-file>` arg → realpath canonicalize → reject if path matches sensitive patterns (`/.ssh/`, `/.aws/`, etc.) per existing `references/recipes/path-security.md`. Bats covers traversal attempts.
- `${var}` substitution: vars cannot reference secrets directly. Caller-supplied `--var key=val` is OK (caller's choice). Privacy canary: a `vars:` containing a "PASSWORD-CANARY" sentinel must not leak into stdout summary line OR steps.jsonl unless the substituted location is itself a fill `--text` arg (which is the caller's expressed intent).

## Sub-scope (what 9-1-i does NOT do)

- **No `${refs.NAME}` resolution.** Literal pass-through. 9-1-ii adds resolution.
- **No `assert` step.** 9-1-ii adds the verb.
- **No `flow record`.** 9-1-iii.
- **No `replay <id>`.** 9-1-iv.
- **No `history` / `baseline` operations.** 9-1-v.
- **No `flow run --strict` flag.** Default-partial mapping. 9-1-iv adds `--strict` for replay; consider adding to flow run later if demand surfaces.
- **No nested-map step bodies.** Flow-style `{...}` inline only.
- **No multi-line strings or block scalars.** Single-line scalars only.
- **No env-var pull-through** in `${var}` syntax. Future enhancement if user-asked.

## Acceptance

- `tests/flow-runner.bats` 12+ cases all green.
- `bash tests/lint.sh` exit 0 (all three tiers).
- `bash scripts/browser-flow.sh run tests/fixtures/flows/simple.flow.yaml` (with stub adapters) exits 0; emits per-step events + summary.
- `--dry-run` prints planned step list without invoking adapters; exit 0.
- `${var}` substitution works; missing var → exit 2.
- `${refs.NAME}` passes through as literal (test fixture documents this).
- CHANGELOG `[Unreleased]` `[feat]` tag.

## Notes for follow-ups

- **9-1-ii: `${refs.NAME}` resolution + `assert` step** — snapshot step populates a per-flow refMap; subsequent steps resolve `${refs.X}` via accessibility-tree name match. New `assert` verb (selector + text-contains predicate).
- **9-1-iii: `flow record`** — wraps `playwright codegen`; transformer JS → YAML; password canary.
- **9-1-iv: `replay <id>`** — re-execute capture's steps; structured diff.
- **9-1-v: `history` + `baseline`** — read-side ops + the prune-with-flags verb (folds in `browser-clean.sh` follow-up).
