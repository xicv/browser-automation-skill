| Field | Value |
|---|---|
| Status | Draft for review |
| Author | xicao |
| Date | 2026-05-01 |
| Spec ID | 2026-05-01-token-efficient-adapter-output-design |
| Augments | `2026-04-27-browser-automation-skill-design.md` §3.3, §5.7 |
| Augments | `2026-04-30-tool-adapter-extension-model-design.md` §2 (adapter ABI) |
| Successors | Phase 3 plan (`scripts/lib/tool/playwright-cli.sh`) implements this |

# Token-Efficient Adapter Output — Design Spec

## 0. Why this spec exists

The parent spec defines **what** verbs the skill exposes. The extension-model spec defines **how** an adapter plugs in (ABI + routing + doctor). Neither pins down **the shape of an adapter's output bytes** — what the LLM actually consumes after a verb runs. Every token in that output is paid for by every caller of every verb, on every invocation, forever. Get this wrong once and the cost compounds across the whole skill's lifetime.

This spec codifies the output contract every adapter MUST honour. It is short on purpose: seven principles + one mandatory output schema + three flag conventions + an explicit anti-pattern list.

## 1. Sources

The contract here is **not invented** — it is the intersection of three independently-converged production designs:

| Source | What we take | Reference |
|---|---|---|
| **Chrome DevTools MCP** (`ChromeDevTools/chrome-devtools-mcp`) | The seven design principles in §2 below; the "reference over value" + "semantic summary" rules. | `docs/design-principles.md` (8 principles, condensed to 7 by merging "small deterministic blocks" into the schema in §3) |
| **Microsoft Playwright CLI** (`microsoft/playwright-cli`) | The `eN` ref scheme; the `--raw` / `--json` / `--depth` flag conventions; snapshot-to-file pattern with stdout reference. | README §"Raw output", `skills/playwright-cli/SKILL.md` |
| **BrowserAct skills** (`browser-act/skills`) | Indexed-element interaction model (`click 5`, `input 3 "text"` after `state` returns `[3] input "Search"`); declarative trigger-action policy file pattern. | `browser-act/SKILL.md` Core Workflow; `references/policies.md` |

A direct quote from Microsoft's own README, on why CLI + SKILLS beats MCP for coding agents: *"CLI invocations are more token-efficient: they avoid loading large tool schemas and verbose accessibility trees into the model context, allowing agents to act through concise, purpose-built commands."* — `microsoft/playwright-mcp` README. We are building exactly that pattern; this spec is the discipline that makes it land.

## 2. Seven principles (the spine)

Every adapter output is judged against these. They are ordered by frequency-of-application: principle 1 fires on every output, principle 7 fires on heavy assets only.

1. **Token-optimised semantic summary, not raw data.** *"LCP was 3.2s"* beats 50k lines of JSON. Adapters MUST distil tool output into the smallest verb-summary that preserves agent decision-power. Raw blobs go to disk under `${CAPTURES_DIR}/`.
2. **Reference over value for heavy assets.** Screenshots, traces, HARs, full DOM snapshots, videos: write to a file, return the path. Never inline >2 KB of base64 or full HTML on stdout.
3. **Single-line JSON summary terminates every verb.** Already mandated by parent spec §5.4. This spec extends: streaming JSON lines before the summary are also one-object-per-line, never multi-line. Parsed with `jq -c`.
4. **Stable `eN` element refs across snapshot calls within a session.** A click target stays addressable as `e15` until the page mutates that node out of the accessibility tree. Same as Microsoft's playwright-cli; same logical model as chrome-devtools-mcp's `uid`. Adapters that route to a tool exposing a different scheme MUST translate at the adapter boundary so verb users see one scheme.
5. **Self-healing errors.** Errors include the verb, the action attempted, the ref or selector that failed, and one suggested next step. Example: `error: ref e15 detached after navigation; run 'snapshot' to refresh refs and retry`. Parent spec §5.1 exit-code table is the discrete part; the human-readable hint on stderr is this principle.
6. **Progressive complexity flags, not new verbs.** A verb-author tempted to ship `screenshot-full` SHOULD instead ship `screenshot` with `--full`. Three orthogonal flags below (§4) cover the surface area. Verbs stay countable on one hand.
7. **Files are the right place for large data.** Adapters MUST NOT stream a 4 MB HAR through stdout. The contract: return `{"har": "${CAPTURES_DIR}/<verb>-<ts>.har"}` and let the LLM `Read` the file (or not).

## 3. Mandatory output schema

Every verb produces **exactly two stream regions** on stdout:

```
[0..N streaming JSON lines]   ← optional, one object per line, used for progress + intermediate results
[1 summary JSON line]         ← MANDATORY, last line of stdout, parseable by `jq -c`
```

Stderr is reserved for human messages (logger output, hints, warnings). Stderr is never parsed by routing/test logic.

### 3.1 Summary object — required keys

| Key | Type | Source | Notes |
|---|---|---|---|
| `verb` | string | parent spec §5.4 | E.g. `"open"`, `"snapshot"`, `"click"` |
| `tool` | string | parent spec §5.4 | Adapter name from `tool_metadata().name` |
| `why` | string | parent spec §5.4 | One-line reason this tool was picked (router output, or `"--tool=X explicit"`) |
| `status` | enum | parent spec §5.4 | `"ok"` / `"partial"` / `"empty"` / `"error"` / `"aborted"` |
| `duration_ms` | integer | extension-model §2 | Wall-clock from verb entry to summary emit |

### 3.2 Summary object — verb-specific keys

Verbs that produce DOM state add **one** of:

- `snapshot_path` — path to YAML/JSON snapshot file under `${CAPTURES_DIR}/snapshots/`. Used by every verb that mutates the page (`open`, `click`, `fill`, `navigate`, `back`, `forward`, `reload`).
- `refs_inline` — array of `{id, role, name}` objects, **only when total length ≤ 2 KB**. Above that threshold, fall back to `snapshot_path`.

Verbs that produce captures add path-keys: `screenshot_path`, `har_path`, `trace_path`, `video_path`, `pdf_path`. Never inline.

Verbs that read scalar data add the value directly: `title`, `url`, `text`, `value`, `count`. These stay inline.

### 3.3 Streaming line schema (when used)

Streaming lines have one required key, `event`:

```jsonl
{"event": "navigated", "url": "https://example.com/login"}
{"event": "console", "level": "warning", "text": "Deprecation: ..."}
{"event": "request", "method": "POST", "url": "...", "status": 200}
```

Streaming is opt-in per verb. The default is summary-only.

## 4. Three orthogonal flags (Microsoft's convention, adopted)

Every adapter MUST honour these flag names with these meanings:

| Flag | Meaning | Default |
|---|---|---|
| `--raw` | Strip everything but the result value: no streaming, no summary metadata, just the data. Pipeable to `jq`/`grep`/redirect. Verbs without a primary value (e.g. `click`) emit nothing. | off |
| `--json` | Wrap output in a single JSON envelope `{"verb":..., "result": <value>}` instead of the streaming+summary pair. For non-LLM tooling. | off (verb summary pair is the LLM-friendly default) |
| `--depth N` | Partial snapshot — descend at most N levels of the accessibility tree. | unlimited |

Adapters that do not support a flag for a given verb MUST exit with `EXIT_TOOL_UNSUPPORTED_OP` (41) and a self-healing hint. They MUST NOT silently ignore the flag — that's how token-bloat creeps back in via "I asked for raw, got full".

## 5. Element-ref scheme (`eN`)

Adapters that surface DOM elements MUST emit refs as `e<N>` where `N` is a stable, monotonically-assigned integer per accessibility-tree-traversal. Refs are valid until the next page mutation observed by the adapter. After mutation, calling a verb with a stale ref MUST fail with `EXIT_TOOL_UNSUPPORTED_OP` and the self-healing hint `ref e15 stale; run 'snapshot' to refresh`.

Why this exact scheme:

- **Microsoft's playwright-cli uses it.** Agents trained on Microsoft's skill transfer for free.
- **One-character prefix + integer = ~3 tokens per ref**, vs CSS selectors at 10–40 tokens, vs XPath at 20–80, vs full accessibility node JSON at 50+. A page with 30 refs costs ~90 tokens to address; the same page in CSS-selector form costs >500.
- **Adapter-side translation** keeps the verb surface stable when the underlying tool changes ID schemes (chrome-devtools-mcp `uid` → our `eN` is a simple map; same for any future tool).

Snapshot files (the YAML/JSON written under `${CAPTURES_DIR}/snapshots/`) carry the full role/name/value/children tree, indexed by `eN`. The LLM `Read`s that file once when it needs to disambiguate; subsequent verbs reference by `eN` without re-snapshotting.

## 6. Capture file layout

```
${CAPTURES_DIR}/                          # mode 0700
├── snapshots/<site>--<ts>.yaml           # accessibility snapshot YAML, eN-indexed
├── screenshots/<site>--<ts>.png          # via screenshot verb
├── hars/<site>--<ts>.har                 # sanitised by default per parent spec §1
├── traces/<site>--<ts>.zip               # playwright trace
├── videos/<site>--<ts>.webm              # playwright video
└── pdfs/<site>--<ts>.pdf                 # via pdf verb
```

Filenames embed the site name and an ISO-8601 timestamp (compact form, no `:`, e.g. `2026-05-01T142342Z`). The 14-day age cap + 500-count cap from parent spec §1 applies.

## 7. Anti-patterns (six WRONG / RIGHT pairs)

### 7.1 Inlining a screenshot

WRONG:
```json
{"verb":"screenshot","status":"ok","data":"iVBORw0KGgoAAAANSUhEUgAA…<2 MB of base64>…"}
```
RIGHT:
```json
{"verb":"screenshot","status":"ok","screenshot_path":"~/.browser-skill/captures/screenshots/prod--2026-05-01T142342Z.png","duration_ms":318}
```

### 7.2 Returning full HTML

WRONG: `{"verb":"open","html":"<html>…40 KB…</html>"}`
RIGHT: `{"verb":"open","status":"ok","snapshot_path":"…/snapshots/…yaml","url":"https://app.example.com/dashboard","title":"Dashboard"}`

### 7.3 CSS selector instead of `eN`

WRONG: agent calls `click "div#root > main > section.cards > article:nth-child(3) button.primary"`.
RIGHT: agent calls `click e17` after `snapshot` populated `e17 = button "Buy now"`.

### 7.4 New verb instead of progressive flag

WRONG: shipping `screenshot-full`, `screenshot-element`, `screenshot-clip`.
RIGHT: `screenshot [target] [--full] [--clip x,y,w,h]`. One verb; flags compose.

### 7.5 Multi-line summary

WRONG (multi-line JSON breaks `tail -1 | jq`):
```json
{
  "verb": "doctor",
  "status": "ok"
}
```
RIGHT: `{"verb":"doctor","tool":"none","why":"health-check","status":"ok","problems":0,"duration_ms":42}`

### 7.6 Silently ignored `--raw`

WRONG: `playwright-cli --raw click e15` emits the same streaming + summary as without `--raw`.
RIGHT: with `--raw`, `click` emits nothing on stdout (it has no result value), exit 0. The agent sees a zero-byte payload and saves the tokens.

## 8. Compliance checks (lint tier 3)

The Phase 3 lint runner (`tests/lint.sh`) gains these drift checks:

1. Every adapter's `tool_capabilities()` lists every verb it dispatches; missing entries fail.
2. For each (adapter, verb) pair, a fixture under `tests/fixtures/<adapter>/<verb>--summary.json` is asserted to:
   - Be exactly one line.
   - Parse as JSON.
   - Contain the five required keys from §3.1.
   - Use only path-keys (not inline data) for capture-producing verbs (regex: keys ending in `_path` exist for `screenshot`/`har`/`trace`/`video`/`pdf`).
3. Every adapter MUST source-import `scripts/lib/output.sh` (a new helper module, Phase 3 deliverable) which exposes `emit_summary`, `emit_event`, `capture_path` — adapter authors who hand-roll JSON typically miss the §3.1 keys.

## 9. Out-of-scope

- **Sanitisation rules** for HARs and console captures live in parent spec §1 (`Capture sanitization` decision). This spec only mandates that captures go to files, not what gets redacted in them.
- **Cloud captcha solvers** (browser-act has one). Out of scope: violates parent spec §1 invariant *"never online, never in argv"*.
- **Real-Chrome auto-attach via CDP**. Out of scope this phase; a future tool adapter (e.g. `chrome-devtools-mcp` or `obscura`) MAY add it; the contract here applies to it unchanged.
- **Agent-side caching** of snapshots. Adapter writes the file; what the agent does with it is agent's concern.

## 10. Migration

No code currently violates this spec because no adapter has been built yet. Phase 3 Task 6 (`scripts/lib/tool/playwright-cli.sh`) implements the contract from day one. The pre-Phase-3 verbs (`add-site`, `list-sites`, `login`, etc.) already emit single-line JSON summaries; their summaries already conform.

The only retroactive change: Phase 3 spec adds an `output.sh` helper deliverable to its file list (§3 of that spec), and Task 1 of Phase 3 plan (already complete on `feature/phase-03-extension-model`) needs no edit.

## 11. Acceptance criteria

This spec is "done" when:

1. Parent spec §3.3 has a one-paragraph pointer to this doc.
2. Phase 3 spec §2 has a one-paragraph pointer to this doc, in the adapter ABI section.
3. `scripts/lib/output.sh` exists and exposes `emit_summary` / `emit_event` / `capture_path`.
4. `scripts/lib/tool/playwright-cli.sh` (Phase 3 Task 6) uses those helpers exclusively to emit output.
5. Lint tier 3 enforces the §8 drift checks.
6. The first verb that returns a snapshot (Phase 4 `browser-snapshot.sh` or earlier) round-trips: snapshot → file → `eN` ref → click verb succeeds.

(1) and (2) are addressed in the same commit as this spec. (3)–(6) land inside Phase 3 / Phase 4 plans.
