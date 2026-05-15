# browser-stats — telemetry / audit / tuning surface

Per-action JSONL audit log under `${BROWSER_SKILL_HOME}/memory/stats.jsonl`
plus a lazy-built SQLite mirror at `memory/stats.db`. JSONL is the source of
truth; SQLite is regenerated from cursor (`memory/stats.db::stats_cursor`).

## Mental model — balance triangle

```
   tokens
      \
       \
        \____ accuracy
        /
       /
   latency
```

Every adapter invocation emits one event. `browser-stats report` rolls events
up by (route × verb × outcome) and surfaces:

- success rate (and post-condition hit-rate — the *real* accuracy signal)
- p50/avg token proxies (`stdout_bytes`, `stderr_bytes`, `argv_bytes`)
- avg duration_ms
- $/event when `CLAUDE_USAGE_*` env vars present (priced via
  [`stats-prices.json`](stats-prices.json))
- failure-mode histogram (13-value enum — see schema)
- **`oblivious_success`** count: adapter reported `outcome=success` but
  the post-condition assertion failed. This is the audit's killer signal —
  without it, naive self-reported success rates lie.

## Verbs

| Verb | What it does |
|---|---|
| `browser-stats rebuild` | Tail `stats.jsonl` from cursor → upsert into `stats.db`. Idempotent. Builds schema on first run. |
| `browser-stats report [--days N] [--route R] [--verb V] [--pareto]` | Human-readable summary. `--pareto` adds a per-route composite efficiency score. |
| `browser-stats mark <span_id> success\|fail[:reason]` | Record a user override on one event. Audit-report applies overrides over self-reported outcomes. |
| `browser-stats tune [--days N] [--route R]` | Surface worst-performing (verb, route) candidates for `/autoresearch` handoff. Human-in-loop — never auto-mutates the skill. |

## Examples

```bash
# Daily summary (last 7 days, all routes):
bash scripts/browser-stats.sh report

# Per-route Pareto frontier (success_rate × output-byte efficiency):
bash scripts/browser-stats.sh report --pareto --days 30

# Just one route:
bash scripts/browser-stats.sh report --route chrome-devtools-mcp --days 14

# Override an event (e.g. you know the audit miscategorized this):
bash scripts/browser-stats.sh mark a1b2c3d4e5f6a7b8 fail:wrong_element_acted

# Find tuning candidates:
bash scripts/browser-stats.sh tune --days 30
```

## Wiring an adapter call site

Every verb script that invokes an adapter should emit one stats event per
invocation. Pattern (see `scripts/browser-open.sh` for a real example):

```bash
source "${SCRIPT_DIR}/lib/stats.sh"

stats_t0="$(now_ms)"
set +e
adapter_out="$(invoke_with_retry open "${verb_argv[@]}")"
adapter_rc=$?
set -e

# Phase 12 part 2: post-condition contract via env vars (keeps the helper
# call-site readable — 6 positional args instead of 10). Verb script sets
# OBSERVED to the verb-specific signal (URL for open, adapter_out for
# click/extract). End-user sets EXPECT_* via env to assert specific values.
BROWSER_STATS_OBSERVED="${url}" \
  stats_run_adapter_emit \
    "open" "${tool_name}" "${stats_t0}" "${adapter_rc}" \
    "${adapter_out}" "" \
    -- "${verb_argv[@]}"
```

### Post-condition env vars (caller sets before invoking the verb)

| Env var | Values | Default |
|---|---|---|
| `BROWSER_STATS_EXPECT_TYPE`  | `url`, `element_path`, `element_value` | (none — disables check) |
| `BROWSER_STATS_EXPECT_MATCH` | `exact`, `include`, `semantic` | `include` |
| `BROWSER_STATS_EXPECT_VALUE` | any string | (none — disables check) |
| `BROWSER_STATS_OBSERVED`     | any string | set by verb script |

Example:
```bash
BROWSER_STATS_EXPECT_TYPE=url \
BROWSER_STATS_EXPECT_MATCH=include \
BROWSER_STATS_EXPECT_VALUE='/devices/42' \
  bash scripts/browser-open.sh --url https://example.com/devices/42
# → event will carry post_condition_hit:true; oblivious_success detected on mismatch
```

### Contract

- Helper is best-effort — failure never taints caller's exit code (warns to stderr).
- `parent_span_id` is null unless caller exported `BROWSER_SKILL_PARENT_SPAN_ID`
  (used by `browser-flow` to nest step spans inside a run span).
- `model` + `gen_ai_usage_*` fields populate only when `CLAUDE_USAGE_*` /
  `CLAUDE_MODEL` env vars are set. Outside Claude Code → null.
- `stats_random_id` is fork-free `$RANDOM` by default (~60 bits, fine for
  correlation). Set `STATS_USE_CRYPTO_ID=1` if you need `openssl rand` strength.
- Requires **bash 5.0+** (`$EPOCHREALTIME`). Falls back to second precision
  on legacy bash; the skill's other bash-isms already require Homebrew bash
  on macOS.

## Schema

See [`stats-schema.json`](stats-schema.json) for the full JSON Schema. Field
names follow OpenInference + OTel GenAI v1.40 conventions (snake_case
flattening) for direct compatibility with Langfuse / Phoenix / Jaeger via an
OTLP exporter.

Failure-mode enum (13 values, sourced from WAREX + Agent-E + WebVoyager
taxonomies):

```
element_not_found     element_ambiguous     wrong_element_acted
stale_ref             action_timeout        navigation_mismatch
js_not_ready          network_error         captcha_blocked
auth_required         popup_intercept       extraction_mismatch
oblivious_success
```

## Privacy

- All writes are local (`memory/` mode 0700, files mode 0600).
- chrome-devtools-mcp opt-out of upstream Clearcut telemetry recommended:
  pass `--no-usage-statistics` in the adapter wrapper (or set
  `CDT_MCP_NO_USAGE_STATISTICS=1`).
- `selector_value` and `post_condition_observed` may contain user data.
  No remote sink ever. Future `--redact` mode can hash these.

## Doctor integration

`browser-doctor` surfaces:
- `ok: stats events recorded: N` (or `warn: stats.jsonl absent`)
- `ok: stats SQLite indexed: N (delta from JSONL: K)`
- `warn: stats has N oblivious_success in last 7 days` (when > 0)

## Schema migrations

`stats.jsonl` starts at `schema_version: 1`. Future shape changes ship a
migrator under `scripts/lib/migrators/stats/v1_to_v2.sh` (same pattern as
`memory/`); `browser-migrate run` applies it. SQLite is rebuilt from JSONL
on the first `rebuild` after a bump.
