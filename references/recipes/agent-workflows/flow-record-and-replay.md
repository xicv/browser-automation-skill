# Workflow: flow record and replay

**Goal:** capture a manual multi-step interaction via `playwright codegen`, replay it, diff against a baseline.

**Outcome:** a `.flow.yaml` file describes a deterministic action sequence; `replay` re-executes it + emits a per-step diff against a captured baseline.

## Prerequisites

- Site registered + session captured (run [`login-then-scrape.md`](login-then-scrape.md) steps 0-3 first).
- `playwright` installed (`npm i -g playwright @playwright/test && playwright install chromium`).
- A multi-step task in mind — e.g. "create a new task, assign to me, set priority high."

## Steps

### 1. Record the flow

```bash
bash scripts/browser-flow.sh record \
  --site acme --as acme--admin \
  --out create-task.flow.yaml
# → opens a browser via `playwright codegen`
# → perform the multi-step task in the real UI
# → close the browser; the regex-based JS→YAML mapper emits the .flow.yaml
```

Password-canary write-side fires automatically (PR for Phase 9 part 1-iii): any field matching `/password/i` becomes `${secrets.password}` placeholder; the literal is dropped from the YAML.

Inspect the result:

```bash
cat create-task.flow.yaml
# steps:
#   - open: { url: "https://app.acme.com/tasks/new" }
#   - fill: { ref: e3, text: "Ship Pick D recipes" }
#   - click: { ref: e7 }
#   - select: { ref: e12, value: "high" }
#   - click: { ref: e15 }
#   - assert: { selector: ".toast-success", text-contains: "Created" }
```

`${refs.NAME}` and `${var}` templating are available; see `docs/superpowers/specs/2026-05-10-phase-09-flow-runner-design.md` for the full schema.

### 2. Run the flow with whole-flow capture

```bash
bash scripts/browser-flow.sh run create-task.flow.yaml --capture
# → executes each step; emits one _kind:step JSON event per step
# → on success: summary line + capture_id NNN
# → captures all per-step events + final state to ~/.browser-skill/captures/NNN/

# Capture id is in the summary; e.g. capture_id: 042
```

### 3. Mark this run as a baseline

```bash
bash scripts/browser-flow.sh baseline save 042 --as after-redesign
# → ~/.browser-skill/baselines.json gains entry
# → captures/042/meta.json gets is_baseline:true (skip-rule honored by prune)
```

### 4. Replay later + diff against baseline

Time passes. Site changes. Re-run + diff:

```bash
bash scripts/browser-flow.sh run create-task.flow.yaml --capture
# → new capture_id 043

bash scripts/browser-replay.sh 043 --strict
# → per-step replay_diff events
# → exit 13 (ASSERTION_FAILED) on first divergent step under --strict;
#   exit 0 with non-zero diff count under default mode

bash scripts/browser-flow.sh history diff 042 043
# → structured per-step diff, with duration_ms stripped before compare
# (Phase 9 part 1-iv strip-timing-from-semantic-comparison pattern)
```

The diff stripping ensures timing-sensitive fields don't pollute the comparison — only semantic differences surface.

## Verification

```bash
bash scripts/browser-flow.sh history list --limit 5
# → newest-first table; 043 above 042; both with their summary fields

bash scripts/browser-flow.sh baseline list
# → after-redesign → capture 042
```

## Variations

- **Re-record after schema change:** the YAML's `${refs.NAME}` references break when the page restructures. Re-record, re-baseline.
- **Cross-environment replay:** capture against staging, replay against prod — drift the URL via `--var base=https://prod.example.com` if the flow uses `${base}` templating.
- **Multi-baseline:** keep one baseline per release (`baseline save NNN --as v1.2.3`); compare any new capture against any historical baseline.

## Don't

- **Don't commit `.flow.yaml` files with real secrets in them.** The recorder strips `/password/i` fields, but other sensitive content (API tokens in URL query strings, PII in text values) survives. Inspect every recorded YAML before committing.
- **Don't `baseline remove` a capture you still need to diff against.** The removal is a typed-phrase-confirmed delete; gone for good.
- **Don't expect deterministic replay across browser versions.** Playwright codegen-generated refs (`e3`, `e7`, etc.) are snapshot-relative; a major Chromium update may rearrange the accessibility tree. Re-record on upgrade.
