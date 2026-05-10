# Phase 9 — Flow runner: declarative composition + record + replay + history

> Design doc. Captures decisions before code lands. Sequenced **after Phase 8** (obscura adapter ✅ COMPLETE). Implementation begins next session.

## 1. Why this exists

Today, every browser action by an agent is a single-verb call. Iterative debugging works (Phase 7 capture pipeline + sessions), but anything multi-step is **re-narrated by the LLM every turn** — same form-fill described in 8 prompts every time. Phase 9 adds **declarative composition**: a `.flow.yaml` file expresses N steps once; `flow run` executes them in order against the existing verb surface; `flow record` produces the file from a headed session; `replay` re-runs a prior capture's steps and diffs the result.

Per parent spec §3.2 verbs 31-34 + §4.3 (multi-step interactive flow):

> Two modes:
> - **Ad-hoc**: LLM composes per turn (snapshot → fill e3 Alice → fill e5 ... → click e12 → wait .toast → inspect). Each step its own verb call sharing a session.
> - **Saved (`flow run <file>`)**: declarative YAML file ↓

Saved flows are the multi-step contract. Phase 9 ships the runner + recorder + replay diff + history surface + baseline (blessed captures) primitives.

## 2. Scope of Phase 9

**In scope:**
- `flow run <file>` — execute a `.flow.yaml`; per-step dispatch through existing verb surface; templating via `${var}` + `${refs.Name}`; whole-flow capture composition; status mapping (ok / partial / error).
- `flow record [--site NAME] [--out FILE]` — wrap `playwright codegen <url>` (or comparable); transform output → `.flow.yaml`; round-trips with `flow run`.
- `replay <capture-id>` — re-execute a capture's steps + auto-diff vs original (status / per-step output / per-aspect file diffs).
- `history list` / `history show <id>` / `history diff <id1> <id2>` / `history clear` — CRUD over `${CAPTURES_DIR}/`. Composes with Phase 7's `_index.json`.
- `baseline save <id> --as NAME` / `baseline list` / `baseline remove <NAME>` — named blessed captures; sets `meta.is_baseline:true` (Phase 7's prune skip-rule already honors this; no migration needed).

**Out of scope:**
- `report --since "..." --format markdown` (parent spec verb 35) — defer to Phase 10+.
- Cross-flow composition (one flow calling another) — defer; v1 ships flat single-file flows.
- Conditional steps (`if`, `unless`, branches) — defer; v1 is straight-line.
- Loops (`for url in urls: ...`) — defer; v1 single execution per step.
- Parallel-step execution — defer; v1 sequential.
- Visual-diff backend for replay (`compare` from ImageMagick per parent spec §6.4) — speculative; defer until first replay-with-screenshot lands.
- Auto-recording from `browser-do` interactions (Phase 11 memory zone) — explicitly deferred per memory design doc §7.

## 3. Architectural decisions (locked)

### F1: Flow file format = YAML; storage = `~/.browser-skill/flows/<name>.flow.yaml`

Parent spec §4.3 already commits to YAML. YAML's strengths fit declarative steps (terse, human-editable, comment-friendly, native list syntax). JSON considered + rejected: too noisy for hand-authoring (every step gets `{}` braces); no comments; weaker readability for nested step bodies. Storage path mirrors `sites/`, `sessions/`, `credentials/`, `captures/` — `flows/` joins them as a top-level subdirectory under `BROWSER_SKILL_HOME` (mode 0700; files mode 0600). Already pre-allocated in parent spec §3.4.

**Parser:** node helper (`scripts/lib/node/flow-runner.mjs` per parent spec §3.3) — js-yaml is the dependency. Bash-side YAML parsing is brittle; node-helper boundary is the natural place.

### F2: Step shape = **single-key map per step** (parent spec §4.3 example)

```yaml
steps:
  - open:   { path: /users/new }
  - snapshot: {}
  - fill:   { ref: ${refs.Name},  text: Alice }
  - click:  { ref: ${refs.Submit} }
  - wait:   { selector: .toast-success, timeout: 5000 }
  - assert: { selector: .toast-success, text_contains: "successfully" }
```

Each step is a one-key map: the key names the verb; the value is the verb's argv as a flat map. Direct 1:1 with bash verb argv:
- `open: { path: /users/new }` → `bash scripts/browser-open.sh --url /users/new` (with site-base resolution)
- `fill: { ref: e3, text: Alice }` → `bash scripts/browser-fill.sh --ref e3 --text Alice`
- `assert: { selector: .toast, text_contains: "x" }` → new sub-mode of an existing verb (TBD: `inspect` or new `assert`)

**Rejected:** F3 (verb name as a top-level field with separate `args:` map — more typing, no readability win); F4 (sequential verb-name + argv arrays — loses self-documentation per step).

**Open: `assert` step** — the parent spec example has `assert` but no current verb provides it. Two options for v1:
- (a) Implement `assert` as a thin wrapper around `inspect --selector` + bash-side text/regex predicate. New verb.
- (b) Defer `assert` from v1; flows can use `wait --selector` for presence checks but not text assertions.

Decide during 9-1-i plan-doc. Lean toward (a) — small verb, high value for verify-style flows.

### F3: Templating = `${var}` (flow-vars) + `${refs.NAME}` (snapshot-resolved refs); resolved at parse time and step time respectively

```yaml
name: create-user
vars:
  user_email: alice@example.com
session: task-1
steps:
  - open: { path: /users/new }
  - snapshot: {}                                  # populates refs[]
  - fill: { ref: ${refs.Email}, text: ${user_email} }
  - click: { ref: ${refs.Submit} }
```

- `${var}` — substituted at flow-load time from `vars:` block + CLI overrides (`--var user_email=bob@example.com`). Missing var → `EXIT_USAGE_ERROR` before first step runs.
- `${refs.NAME}` — substituted at step-execution time from the most-recent `snapshot`'s accessible-name → ref map. Requires a `snapshot` step earlier in the flow OR the bridge daemon's persistent `refMap`. **Not-yet-snapshotted ref → `EXIT_USAGE_ERROR`** (fail loud; don't guess).
- Both syntaxes use `${...}` (single namespace). `vars:` keys MUST NOT shadow `refs.*` (lint at parse time).

**Rejected:** Mustache-style `{{var}}` (extra brace adds no value; bash heredocs use `${...}` natively); template-string evaluation (eval-injection risk).

### F4: Capture composition = **one capture per flow run**, per-step events streamed inside

```
${CAPTURES_DIR}/NNN/                           # mode 0700 (existing Phase 7 shape)
├── meta.json                                  # mode 0600
│     { capture_id, verb: "flow", flow_name, schema_version: 1,
│       started_at, finished_at, status,
│       step_count, successful_steps, failed_steps,
│       sanitized: true, files: [...] }
├── steps.jsonl                                # NEW: streaming per-step events
│     {step_index, verb, args, status, duration_ms, output_summary, ...}
└── (per-step aspect files when explicitly captured by step)
    ├── screenshot-step-04.png
    ├── console-step-07.json
    └── network-step-07.har
```

`steps.jsonl` is the chronological event log. Each line is one step's summary (verb + args + status + duration + brief output). Tools like `history show <id>` render this as a per-step table.

**Rejected:** per-step capture dirs (e.g. `captures/NNN/step-04/...`) — explodes capture count (a 10-step flow becomes 10 captures); breaks `_index.json` count-based pruning. Per-step files inside a single capture dir composes cleanly with Phase 7 retention/prune.

### F5: Replay semantics = **re-execute steps + structured diff**; new capture entry; original kept

```
replay 042
  → loads captures/042/meta.json + steps.jsonl
  → re-executes the flow against the same session (or --session NEW if specified)
  → writes captures/NNN/ with replay_of: 042 in meta
  → emits diff: {steps_diverged, per_step_status_diff, per_aspect_file_diff}
```

Diff dimensions per step:
- **Status diff** — old step status vs new step status (ok / partial / error / aborted).
- **Output diff** — JSON-summary line diff (using jq-diff or simple key-by-key).
- **Per-aspect file diff** — when both runs have the same aspect file (e.g. console.json or network.har), produce a structured diff (not raw byte diff for JSON/HAR; raw byte sha256 for screenshots).

**Status mapping:**
- All steps match → `status: ok`, `replay_match: true`.
- Some steps diverged but flow completed → `status: partial`, `replay_match: false`, divergence count in summary.
- Replay aborted before completion (selector not found, network error) → `status: error`.

**Rejected:** strict-only (any divergence → exit non-zero) — too brittle for real-world UI changes; partial is the better default. CI/test-mode users can pass `--strict` to flip the mapping.

### F6: Recorder = **wrap `playwright codegen <url>` + transform** (path of least resistance for v1)

```
flow record --site prod-app --out create-user.flow.yaml
  → resolves session if --site has one (else open headed without storageState)
  → spawns: playwright codegen --target javascript <site-base-url>
  → user clicks/types in the popped headed Chromium
  → user closes the codegen window when done
  → captures the JS that codegen emitted
  → transformer converts JS lines → flow YAML steps
  → writes ${CAPTURES_DIR}/../flows/<name>.flow.yaml
```

**Mapping table (codegen → flow YAML):**
| Codegen output | Flow YAML |
|---|---|
| `await page.goto('https://...')` | `- open: { url: 'https://...' }` |
| `await page.getByRole('textbox', { name: 'Email' }).fill('alice@x.com')` | `- snapshot: {}` then `- fill: { ref: ${refs.Email}, text: alice@x.com }` |
| `await page.getByRole('button', { name: 'Submit' }).click()` | `- click: { ref: ${refs.Submit} }` (assumes prior snapshot) |
| `await page.locator('.toast').waitFor()` | `- wait: { selector: .toast }` |

**Rejected:** F7 (bridge eventstream — adapter would emit per-action events; bash collects) — adapter-invasive, requires daemon protocol additions, brittle on adapter switching. F8 (custom Playwright recorder script) — reinvents codegen.

**Open:** secrets in recorded flows. If user types password during recording, codegen captures the literal text. Recorder MUST detect password-input fields (`input[type=password]`) in the codegen output and emit `${secrets.password}` placeholder + warn the user to wire `--secret-stdin` into the resulting flow run. **Privacy canary on the recorder write side** (recipe: `references/recipes/privacy-canary.md`).

### F7: History = pure read-side; reuses Phase 7 `_index.json`; `history clear` is the only mutation

```
history list [--limit N] [--since DATE]
  → reads _index.json + meta.json files; emits one summary line per capture
history show <id>
  → reads meta.json + steps.jsonl; pretty-prints
history diff <id1> <id2>
  → loads both captures' meta + steps.jsonl; emits structured diff (same shape as replay's diff)
history clear [--keep N | --before DATE | --not-baseline]
  → wraps Phase 7's capture_prune with manual override flags
  → still respects is_baseline + in_progress skip rules
```

`history clear` is the `browser-clean.sh` force-prune verb mentioned in HANDOFF as a Phase 7 follow-up. Folding it into `history clear` (rather than a standalone `clean` verb) keeps the user-facing verb count tight and groups it with related read operations.

### F8: Baseline = thin wrapper over Phase 7's `meta.is_baseline:true`

```
baseline save <id> --as NAME
  → sets meta.is_baseline:true on captures/NNN
  → writes baselines.json: {schema_version: 1, baselines: [{name, capture_id, ...}]}
baseline list
  → reads baselines.json
baseline remove <NAME>
  → reads name → capture_id from baselines.json
  → REMOVES baseline-status from meta.json (sets is_baseline:false)
  → splices entry from baselines.json
  → does NOT delete the capture dir (use history clear --not-baseline for that)
```

Phase 7's `capture_prune` already skips `is_baseline:true` entries. Baseline ops are pure metadata management on top of an already-safe foundation.

`baselines.json` is gitignored same as captures (`[PERSONAL]` per parent spec §3.4 — references concrete user data).

## 4. Sub-part split (5 sub-parts; Phase 9 ships in 5 PRs + closure)

| Sub-part | Scope | Size | Depends on |
|---|---|---|---|
| **9-1-i** | `flow run <file>` foundation. Node-helper YAML parser + per-step bash verb dispatch + `${var}` templating + whole-flow capture (meta.json + steps.jsonl). NO `${refs.NAME}` resolution yet (steps must use literal selectors / refs). NO `assert` step. RED bats: parse + dispatch + capture write + 3-4 step golden flow. | medium | — |
| **9-1-ii** | `${refs.NAME}` resolution + `assert` step. Snapshot-step populates a per-flow refMap; subsequent steps resolve `${refs.X}` via accessibility-tree name match. New `assert` verb (selector + text predicate). | medium | 9-1-i |
| **9-1-iii** | `flow record` — wrap `playwright codegen`; transformer JS → YAML. Privacy canary on recorder write side (passwords → `${secrets.password}` placeholder). | medium-large | 9-1-ii (uses ${refs.X} shape) |
| **9-1-iv** | `replay <id>` — re-run capture's steps; structured diff (status / output / per-aspect file). New `--strict` flag. New `replay_of` + `replay_match` fields in meta.json (additive; no schema bump). | medium | 9-1-i |
| **9-1-v** | `history list/show/diff/clear` + `baseline save/list/remove`. Read-side wrappers + the prune-with-flags verb (folds in HANDOFF's "browser-clean.sh" follow-up). New `baselines.json` index. **Closes Phase 9.** | medium-large | 9-1-i, 9-1-iv |

**Phase 9 part 1** = sub-parts 9-1-i + 9-1-ii (flow run end-to-end). MVP shippable after these two.
**Phase 9 part 2** = sub-parts 9-1-iii + 9-1-iv + 9-1-v (record + replay + history+baseline).

## 5. Storage shape (frozen at Phase 9 ship)

```
${BROWSER_SKILL_HOME}/                       # mode 0700
├── flows/                                    # NEW (lazy-created on first flow record/save)
│   └── <name>.flow.yaml                      # mode 0600 [PERSONAL — gitignored]
├── baselines.json                            # NEW (lazy-created on first baseline save)
│                                              # mode 0600 [PERSONAL — gitignored]
│   { schema_version: 1, baselines: [
│       { name, capture_id, saved_at, saved_by_session?, summary }
│     ] }
└── captures/NNN/
    ├── meta.json                             # EXTENDED:
    │     {... existing Phase 7 fields ...,
    │      verb: "flow"|"replay"|"<other>",
    │      flow_name?, replay_of?, replay_match?,
    │      step_count?, successful_steps?, failed_steps?,
    │      is_baseline?  (Phase 7 forward-compat — now actually set) }
    └── steps.jsonl                           # NEW (per-flow + per-replay; mode 0600)
```

**Schema additions are non-breaking** — every new field is optional. `schema_version: 1` stays. `flows/` + `baselines.json` are net-new at v1 (no migration from prior version).

## 6. New verbs added in Phase 9 (counter increment)

| Verb | Sub-part | Notes |
|---|---|---|
| `flow run <file>` | 9-1-i | Single verb; sub-modes are the YAML steps |
| `flow record` | 9-1-iii | Sub-mode of `flow` (parallel to `flow run`) |
| `assert` | 9-1-ii | Lightweight verify-style verb; selector + text predicate |
| `replay <id>` | 9-1-iv | Single verb; consumes capture id |
| `history list/show/diff/clear` | 9-1-v | Sub-modes of `history` |
| `baseline save/list/remove` | 9-1-v | Sub-modes of `baseline` |

**User-facing verb count after Phase 9:** 34 → ~40 (counts depend on whether sub-modes count; per parent spec Appendix A footnote, parent rows count as 36; this PR adds 5 parent rows → 39 + sub-modes = ~50 distinct invocations).

## 7. Test strategy

**Unit tests:**
- `tests/flow-runner.bats` — YAML parse (valid + invalid); `${var}` substitution; missing-var error; ref-map population; step dispatch; status aggregation (ok / partial / error).
- `tests/flow-record.bats` — codegen-output transformer (JS → YAML mappings table-driven); password-detection canary (input[type=password] → ${secrets.password}).
- `tests/replay.bats` — capture loading; re-execution; structured diff (status, output, per-aspect file); --strict flag.
- `tests/history.bats` — list (limit/since filters); show (meta + steps.jsonl); diff (cap-vs-cap); clear (keep/before/not-baseline flags).
- `tests/baseline.bats` — save (sets is_baseline + writes baselines.json); list; remove (clears is_baseline + splices baselines.json; does NOT rm capture dir).

**Integration tests:**
- `tests/flow-run-end-to-end.bats` — author a 5-step `.flow.yaml`; run against the stub adapter; assert all 5 steps fire; assert capture has correct meta + steps.jsonl shape.
- `tests/replay-end-to-end.bats` — run a flow → capture A; replay A → capture B; assert diff is empty (no divergence); flip a step's expected output; replay → assert divergence reported.

**Privacy canary:**
- Recorded flow with password input → never carries plaintext password (recorder transformer + bats fixture).
- Replay diff output never echoes credential bytes from prior captures (Phase 7 sanitization composes).

## 8. Layered defense — prior recipe corpus applies

| Recipe | How it applies to Phase 9 |
|---|---|
| `privacy-canary.md` | Recorder write-side (passwords → `${secrets.password}`); replay diff-side (sanitization carry-over from Phase 7's HAR/console redaction). |
| `path-security.md` | `flows/<name>.flow.yaml` paths constructed by skill (no user-supplied path); `--out FILE` arg goes through realpath canonicalization + sensitive-pattern reject. Same shape as Phase 6 part 6 upload. |
| `body-bytes-not-body.md` | Replay diff emits `body_bytes_diff` not `body_diff` for HAR responses. Same discipline as Phase 6 part 7-ii route fulfill. |
| `model-routing.md` | Flow run is mostly mechanical (YAML → verb dispatch → done). Sonnet handles. Per-step LLM calls only happen when `${refs.X}` resolution needs reasoning (cache miss path). |

**New recipe candidate (post-Phase-9-1-v):** `references/recipes/flow-record-secrets.md` — codifies the password-detection + `${secrets.X}` placeholder pattern. Ships AFTER 9-1-iii lands in production use.

## 9. Interaction with adjacent phases

| Phase | Interaction with flow runner |
|---|---|
| **Phase 7** (capture pipeline) | Flow runs write captures using existing `capture_start` / `capture_finish`. Replay writes a new capture. `meta.is_baseline:true` (Phase 7 forward-compat) is now actually set by `baseline save`. `capture_prune` still honors baselines. **No Phase 7 changes required.** |
| **Phase 8** (obscura adapter) | Flow steps that include `extract --scrape <urls>` route through the existing router → obscura. **No Phase 8 changes required.** |
| **Phase 10** (schema migration) | `meta.json` schema gains optional fields in 9-1-i / 9-1-iv (non-breaking; no version bump). `flows/<name>.flow.yaml` and `baselines.json` are v1 from day one. Phase 10's migration tooling will need to know about these new files. |
| **Phase 11** (memory) | **Sequencing-locked: Phase 11 ships AFTER Phase 9** per memory design doc §13. Reasoning: flow record's manual semantics establish first; auto-recording layered on. **Open question (per memory design doc §7): does memory propose flows when N similar interactions accumulate?** Re-evaluate post-Phase-11. |

## 10. Daemon state implications

| Slot | Phase 9 impact |
|---|---|
| `refMap` | Already used by stateful verbs (click/fill). `${refs.NAME}` in flow steps reads this. **No new slot.** |
| `routeRules` | Flow steps may include `route: { ... }`; reads existing slot. No change. |
| `tabs` / `currentTab` | Flow steps may include `tab-list`/`tab-switch`/`tab-close`; reads existing slots. No change. |
| `flowState` (NEW?) | Considered: per-flow state holding `current_step_index` + `flow_vars`. **Rejected** — flows are stateless from the daemon's POV; bash flow-runner.mjs holds the iteration state in process memory; daemon stays oblivious. |

**No daemon protocol changes** in Phase 9. All flow-runner state lives in the node-helper process.

## 11. Cost economics (target metrics)

Flow run cost vs ad-hoc:
- **Ad-hoc 5-step form fill:** ~5 LLM turns (one per `eN` choice + dispatch). Each turn ~500-1000 tokens. Total ~2500-5000 tokens.
- **Saved flow 5-step form fill:** 1 LLM turn to issue `flow run create-user --var email=alice@x.com`. ~50 tokens. **~50× cheaper after first run.**

This is the third leg of the cost-reduction trio:
1. **Model routing** (skill → Sonnet) — ~3× cheaper per turn.
2. **Memory** (Phase 11) — ~70% turns skipped on repeat actions; ~3× cheaper compounding.
3. **Saved flows** (Phase 9) — ~50× cheaper for any multi-step pattern that fits a flow.

Memory + flows compose: memory remembers individual action mappings; flows compose them into runnable sequences. After both ship, a returning user's typical session shrinks from N×LLM turns to 1×LLM turn (`flow run` invocation) + zero memory misses.

## 12. Open questions (decide during implementation)

1. **`assert` verb shape** — text-equality, regex, JSON-path, all three? Lean toward `text_contains` (substring) + `selector_count_eq` (presence count) for v1; defer regex.
2. **Recorder password detection** — strict input-type check (`input[type=password]`)? Or also detect by name pattern (`name="password"`, `id="password"`, `data-testid="password-field"`)? Be strict by default; document the bypass for confirmed-non-password fields.
3. **Replay capture chain** — should `replay 042` write `captures/NNN/meta.json::replay_of: 042` AND back-reference 042 with `replayed_by: NNN`? Two-way link is cleaner but doubles writes. Pick one direction; default forward-only.
4. **`history diff <id1> <id2>` between non-flow captures** — does it work for two `inspect` captures? Two `extract` captures? Maybe; the diff machinery is per-aspect-file, not flow-specific. Document the support matrix.
5. **`baselines.json` migration semantics** — if `baselines.json` references a capture that was manually `rm -rf`'d, list/show fail-soft (skip) or fail-loud (error)? Lean fail-soft; emit one warn line.
6. **`flow record` against the obscura adapter** — codegen targets Playwright/Chrome. Recording an obscura-targeted flow doesn't make sense (one-shot scrape; no interaction sequence). Document the limitation; recorder rejects `--tool obscura`.

## 13. Sequencing (locked)

```
Phase 8 (✅ COMPLETE) — obscura adapter
        ↓
Phase 9 (this design doc) — flow runner
   ├── part 1: 9-1-i (flow run foundation), 9-1-ii (refs + assert)
   └── part 2: 9-1-iii (flow record), 9-1-iv (replay), 9-1-v (history + baseline → CLOSES Phase 9)
        ↓
Phase 10 — schema migration tooling
        ↓
Phase 11 — memory (design doc shipped 2026-05-08; implementation queued AFTER Phase 9 per design §13)
   ├── part 1: 11-1-i, ii, iii (memory + browser-do + self-heal)
   └── part 2: 11-2-i, ii (URL pattern handling)
        ↓
Recipe doc: cache-write-security.md (after Phase 11 part 1)
Recipe doc: flow-record-secrets.md (after Phase 9 part 2)
```

## 14. References

Prior art:
- [Playwright codegen](https://playwright.dev/docs/codegen) — Microsoft's official recorder; outputs JS/TS/Python/Java/.NET. Wraps + transforms in 9-1-iii.
- [Cypress recorder](https://docs.cypress.io/) — comparable surface; Cypress-specific, not used.
- [Selenium IDE](https://www.selenium.dev/selenium-ide/) — historical record/playback; demonstrates pattern but heavyweight.
- [Mocha+Cypress declarative test files](https://docs.cypress.io/guides/core-concepts/writing-and-organizing-tests) — `it.each` + `describe` shape comparison.
- [GitHub Actions workflow YAML](https://docs.github.com/en/actions/using-workflows) — single-key-map step shape (parent spec §4.3 followed this convention).

Internal cross-references:
- Parent spec: `docs/superpowers/specs/2026-04-27-browser-automation-skill-design.md` §3.2 (verbs 31-34), §3.4 (storage layout — `flows/`, `baselines.json` pre-allocated), §4.3 (multi-step flow YAML example), §4.5 (capture pipeline), §12 (sequencing).
- Phase 11 memory design: `docs/superpowers/specs/2026-05-08-phase-11-memory-design.md` §7 (Phase 9/11 overlap zone — sequencing rationale), §13 (sequencing lock).
- Phase 7 capture pipeline: `scripts/lib/capture.sh` — `capture_prune` skip-rule honors `is_baseline:true` (already shipped in 7-1-v as forward-compat for Phase 9).
- Recipe corpus: `references/recipes/{privacy-canary,path-security,body-bytes-not-body,model-routing}.md`.
