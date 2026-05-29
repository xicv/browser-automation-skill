# browser-delegate cheatsheet

`browser-delegate` hands a whole multi-step web task to an out-of-process agent
(Webwright) driven by a **secondary LLM** (GLM via its Anthropic-compatible
endpoint). The observe-execute-inspect loop runs on the GLM budget, so Claude
Code sees only the dispatch + a compact summary — not the intermediate
trajectory. This is a higher-order verb (peer to `browser-flow` / `browser-do`),
NOT a primitive adapter, and the router never auto-selects it.

See the design: `docs/superpowers/specs/2026-05-29-phase-15-webwright-delegate-adapter.md`.

## When to use it

- Use for **novel, multi-step** web tasks where the primitive verbs would push
  many snapshots into Claude's context (scrape-across-pages, fill-a-long-form,
  navigate-and-extract).
- Do NOT use for single-step extracts (cached primitive verbs win on tokens,
  latency, and determinism) or for anything requiring login (phase 1 is no-auth).

## Usage

```bash
# Task via flag
browser-delegate --task "Return the top 3 HN stories as JSON" \
  --start-url https://news.ycombinator.com --task-id hn_top3

# Task via stdin
echo "Summarise the first paragraph of the Playwright wiki page" \
  | browser-delegate --start-url https://en.wikipedia.org/wiki/Playwright_(software)

# See the resolved command without running it
browser-delegate --dry-run --task "..." --start-url https://example.com
```

## Flags

| Flag | Meaning |
|---|---|
| `--task TEXT` | the task (or pipe via stdin) |
| `--start-url URL` | starting URL (required) |
| `--task-id NAME` | output folder name (default `delegate-<epoch>`) |
| `--site NAME` | no-auth site context; **refused** if the site has stored creds |
| `--max-steps N` | step-budget hint (forwarded to the backend) |
| `--backend NAME` | delegated backend (default + only: `webwright`) |
| `--dry-run` | print the resolved command + output path; spawn nothing |

## Output

One `_kind:"delegate_result"` line (final answer + workspace path + step count +
offloaded token counts) followed by the standard `emit_summary` line. The full
trajectory is never printed — it stays under `$BROWSER_SKILL_HOME/delegate/`.

## Configuration

- Webwright location: `$HOME/tools/Webwright` (override `BROWSER_SKILL_WEBWRIGHT_DIR`).
- Backend model / endpoint / key: configured inside the Webwright install
  (`src/webwright/config/model_claude.yaml` + global `.env`), not here.

## Telemetry

Each run appends a `verb:"delegate"` event to `memory/stats.jsonl` with
`offloaded_input_tokens` / `offloaded_output_tokens` / `offloaded_cached_input_tokens`
+ `delegate_steps` + `delegate_model`. These are billed to the secondary-LLM
budget and are reported separately from Claude-context `gen_ai_usage_*` tokens.

## Privacy

The delegated run's workspace (screenshots, logs, raw responses) is scanned for
a canary sentinel before any result is surfaced; a hit refuses the result. Until
the credential bridge ships (phase 2), keep delegated tasks to public, no-auth
pages.
