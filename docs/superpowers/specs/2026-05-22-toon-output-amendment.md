| Field | Value |
|---|---|
| Status | Locked |
| Author | xicao |
| Date | 2026-05-22 |
| Spec ID | 2026-05-22-toon-output-amendment |
| Augments | `2026-05-01-token-efficient-adapter-output-design.md` §3, §4, §7.5, §8 |
| Successors | Phase 12 plan (`scripts/lib/node/toon-encode.mjs`, `emit_summary_toon`, per-verb `--format=toon`) |

# TOON Output Mode — Spec Amendment

## 0. Why this amendment

The parent spec (`2026-05-01-token-efficient-adapter-output-design.md`) was written when **single-line JSON was the SOTA for LLM-facing tool output**. Between Nov 2025 and May 2026, Token-Oriented Object Notation (TOON) emerged as a measurably-better encoding for *uniform tabular* payloads: **40–60 % fewer tokens than JSON at equal-or-better LLM parse accuracy (76.4 % vs 75.0 % across four models, [InfoQ Nov 2025](https://www.infoq.com/news/2025/11/toon-reduce-llm-cost-tokens/))**. Adopting TOON closes the gap between this skill's discipline and 2026 SOTA — *for the verbs where TOON helps*. For single-result verbs (open/click/fill), JSON stays the cheapest option and remains the default.

This amendment:
1. Adds `--format=toon` as the **4th orthogonal flag** joining `--raw` / `--json` / `--depth` (parent §4).
2. Lifts the multi-line anti-pattern (parent §7.5) **only** when `--format=toon` is active.
3. Defines per-verb TOON shape for the inline-tabular verbs.
4. Pins the MCP auto-flip rule (MCP callers are token-sensitive by definition).

JSON remains the default everywhere. No existing scripted caller breaks.

## 1. The 4th orthogonal flag

| Flag | Meaning | Default |
|---|---|---|
| `--raw` | Strip everything but the result value (parent §4). | off |
| `--json` | Wrap in `{"verb":..., "result": <value>}` envelope (parent §4). | off |
| `--depth N` | Partial snapshot — descend at most N levels (parent §4). | unlimited |
| **`--format=toon`** | **Emit TOON instead of single-line JSON summary. Per-verb shape locked in §3.** | **off (JSON summary remains default)** |

Mutual exclusion: `--format=toon` is mutually exclusive with `--raw` and `--json` (different output envelopes). Combining any two MUST fail `EXIT_USAGE_ERROR` (2) with a self-healing hint.

## 2. When TOON is allowed (verb-eligibility gate)

A verb MAY support `--format=toon` only if its summary contains an **inline uniform-shape array** of ≥ 3 objects with ≥ 2 fields each. Concretely the eligible verbs at amendment time:

| Verb | Tabular field | Typical row count | Expected savings |
|---|---|---|---|
| `browser-list-sites` | `sites[]` | 3–50 | 40–60 % |
| `browser-list-sessions` | `sessions[]` | 1–10 | 30–50 % |
| `browser-history list` | `captures[]` | 1–500 | 50–70 % |
| `browser-tab-list` | `tabs[]` | 1–20 | 30–50 % |
| `browser-stats report` | `entries[]` | 10–10000 | 50–75 % |
| `browser-extract --scrape` | `results[]` | 5–10000 | 50–80 % |
| `browser-doctor` | `checks[]` | 5–25 | 30–50 % |

Verbs OUTSIDE this list MUST reject `--format=toon` with `EXIT_USAGE_ERROR` and the hint `error: --format=toon not supported for <verb> (single-result output; use JSON default)`. This prevents accidental token-bloat from TOON-headers on single-object payloads.

## 3. TOON shape contract

TOON encoding is delegated to the official reference implementation `@toon-format/toon` (npm). The skill's Node bridge (`scripts/lib/node/toon-encode.mjs`) is a thin wrapper around `encode()`. **Skill code MUST NOT hand-roll TOON serialization** — conformance risk + maintenance cost.

The TOON output of an eligible verb is the SAME logical JSON object the verb would have emitted, encoded via `encode()`. The eligibility constraint in §2 guarantees the inline array is a uniform table, which `encode()` will emit as a `field-list table` form (the case where TOON's savings are maximal):

```
verb: list-sites
tool: none
why: list
status: ok
count: 6
duration_ms: 133
sites[6]{name,url,label,default_session,default_tool,last_used_at}:
  localhost-connect,http://localhost:8090,,,,2026-05-12T03:05:21Z
  prod-app,https://app.example.com,,,,2026-04-29T07:39:33Z
  ...
```

The required parent-spec §3.1 keys (`verb`, `tool`, `why`, `status`, `duration_ms`) remain present at the TOON-document root — schema unchanged, encoding changed.

## 4. MCP auto-flip rule

The MCP server (`scripts/lib/node/mcp-server.mjs`) is the canonical token-sensitive caller (its consumers are LLMs by definition). For every eligible verb (§2), the MCP server's `argMap` MUST append `--format=toon` to the script invocation, UNLESS the MCP client explicitly opted out via a per-call argument `{"format": "json"}`.

Bash CLI callers retain the JSON default. Skilled human users + downstream `jq` pipelines stay unbroken.

## 5. Mandatory keys (unchanged)

The five required keys from parent §3.1 (`verb`, `tool`, `why`, `status`, `duration_ms`) remain mandatory in TOON output. The TOON encoder emits them at the document root. Lint tier 3 (§8) extends to verify their presence in both JSON and TOON outputs.

## 6. Lint tier 3 additions

Parent spec §8 enforces JSON shape drift. This amendment adds:

1. For each verb with a `tests/fixtures/<adapter>/<verb>--summary.toon` fixture, lint MUST:
   - Parse it via `node -e 'require("@toon-format/toon").decode(...)'`.
   - Confirm round-trip equals the corresponding `--summary.json` fixture.
2. Eligible verbs from §2 MUST have BOTH a JSON and a TOON fixture; ineligible verbs MUST have only JSON.
3. `emit_summary_toon` calls MUST come from `scripts/lib/output.sh`. Hand-rolled `node -e 'encode(...)'` invocations elsewhere fail lint (defense-in-depth against drift from the helper).

## 7. Anti-pattern carve-outs (parent §7.5)

Parent spec §7.5 lists multi-line summary as anti-pattern. **This carve-out applies only to `--format=toon` outputs of eligible verbs (§2).** In all other cases, the multi-line anti-pattern stands.

The reason multi-line was banned originally was `tail -1 | jq` breakage on parser-greedy single-line assumption. TOON callers (LLMs + the MCP server) consume the full document, not `tail -1 | jq`. Different consumer, different shape; that's the entire point of the flag.

## 8. Migration

Phase 12 PR 1 (proof-of-value):
- Lands this amendment (this doc).
- Adds `@toon-format/toon` npm dep + `toon-encode.mjs` bridge.
- Adds `emit_summary_toon` to `output.sh`.
- Wires `--format=toon` on the 3 highest-ROI verbs: `browser-list-sites`, `browser-history list`, `browser-extract --scrape`.
- Adds MCP auto-flip for those 3 tools.
- Adds bats benchmark proving ≥ 30 % byte-size savings per verb on synthetic fixtures.

Phase 12 PR 2+ (mechanical roll-out):
- Wires the remaining eligible verbs from §2: `list-sessions`, `tab-list`, `stats report`, `doctor`.
- Each follow-up = ~50 LOC + 3 bats.

Out-of-scope this phase:
- Snapshot YAML → TOON conversion (YAML is already close; ROI vs. risk lower than tabular wins).
- TOON for streaming events (parent §3.3) — streaming is per-event, no array form.
- Hand-rolled bash TOON encoder (conformance risk; locked to upstream `@toon-format/toon`).

## 9. Acceptance criteria

This amendment is "done" when:

1. `scripts/lib/node/toon-encode.mjs` exists and shells out to `@toon-format/toon::encode()`.
2. `scripts/lib/output.sh::emit_summary_toon` exists with same key=value contract as `emit_summary`.
3. Three verbs (`list-sites`, `history list`, `extract --scrape`) accept `--format=toon` and emit TOON.
4. MCP server auto-appends `--format=toon` for the three tools above unless `{"format":"json"}` overrides.
5. New bats `tests/toon-savings.bats` measures byte-savings on those three verbs vs JSON baseline; asserts ≥ 30 % each.
6. Lint tier 3 (§6 of this amendment) flags drift.
7. CI green on both Ubuntu and macOS.

## 10. Sources

- [toon-format/toon — Token-Oriented Object Notation reference impl + spec](https://github.com/toon-format/toon)
- [@toon-format/toon — npm](https://www.npmjs.com/package/@toon-format/toon)
- [InfoQ: New TOON Format Hopes to Cut LLM Costs by Reducing Token Consumption (Nov 2025)](https://www.infoq.com/news/2025/11/toon-reduce-llm-cost-tokens/)
- [MindStudio: How to Optimize MCP Server Token Usage — Code Execution, Tool Search, and TOON (2026)](https://www.mindstudio.ai/blog/optimize-mcp-server-token-usage)
- [Anthropic Messages API: Prompt Caching docs (2026)](https://docs.anthropic.com/en/docs/build-with-claude/prompt-caching)
- [DEV: How Accessibility Tree Formatting Affects Token Cost in Browser MCPs (2026)](https://dev.to/kuroko1t/how-accessibility-tree-formatting-affects-token-cost-in-browser-mcps-n2a)
