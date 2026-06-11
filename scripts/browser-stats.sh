#!/usr/bin/env bash
# scripts/browser-stats.sh — Phase 12 part 1: telemetry surface verb.
# Usage:
#   browser-stats event ...              # internal — emit one event from CLI
#   browser-stats rebuild                # rebuild SQLite mirror from JSONL
#   browser-stats report [--days N] [--route ROUTE] [--verb VERB] [--pareto]
#   browser-stats mark <span_id> <verdict>[:<reason>]
#   browser-stats tune [--days N] [--route ROUTE]
#
# Verdict ∈ {success, fail}. Reason optional ("fail:popup_intercept" etc).
#
# All subcommands respect $BROWSER_SKILL_HOME. Writes are mode 0600 in the
# memory/ dir (mode 0700). No network. SQLite is built lazily on `rebuild`;
# JSONL is the source of truth.

set -Eeuo pipefail
# Inherit errexit into command substitutions (bash 4.4+). Without this,
# `local x=$(jq ...)` silently swallows jq's non-zero exit (shellcheck SC2311
# trap). With it, the script aborts as expected.
shopt -s inherit_errexit
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/common.sh"
# shellcheck source=lib/output.sh
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/output.sh"
# shellcheck source=lib/stats.sh
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/stats.sh"

init_paths

SUMMARY_T0="$(now_ms)"; export SUMMARY_T0

STATS_JSONL="${BROWSER_SKILL_HOME}/memory/stats.jsonl"
STATS_DB="${BROWSER_SKILL_HOME}/memory/stats.db"
PRICES_FILE="${BROWSER_STATS_PRICES_FILE:-${SCRIPT_DIR}/../references/stats-prices.json}"

subcmd="${1:-}"
[ -n "${subcmd}" ] || die "${EXIT_USAGE_ERROR}" "browser-stats: subcommand required (event|rebuild|report|mark|tune)"
shift

# --- helpers ----------------------------------------------------------------

require_sqlite3() {
  command -v sqlite3 >/dev/null 2>&1 \
    || die "${EXIT_PREFLIGHT_FAILED}" "browser-stats: sqlite3 not installed"
}

stats_sql_quote() {
  local v="$1"
  v="${v//\'/\'\'}"
  printf "'%s'" "${v}"
}

stats_require_nonnegative_int() {
  local value="$1" label="$2"
  [[ "${value}" =~ ^[0-9]+$ ]] \
    || die "${EXIT_USAGE_ERROR}" "${label} must be a non-negative integer"
}

# stats_db_init — create schema if absent (idempotent).
stats_db_init() {
  require_sqlite3
  stats_init_dir
  sqlite3 "${STATS_DB}" <<'SQL'
CREATE TABLE IF NOT EXISTS stats_events (
  id                          INTEGER PRIMARY KEY AUTOINCREMENT,
  schema_version              INTEGER NOT NULL,
  ts                          TEXT    NOT NULL,
  trace_id                    TEXT    NOT NULL,
  span_id                     TEXT    NOT NULL UNIQUE,
  parent_span_id              TEXT,
  session_id                  TEXT,
  gen_ai_tool_name            TEXT,
  verb                        TEXT    NOT NULL,
  adapter_route               TEXT    NOT NULL,
  site                        TEXT,
  selector_kind               TEXT,
  selector_value              TEXT,
  duration_ms                 INTEGER,
  argv_bytes                  INTEGER DEFAULT 0,
  stdout_bytes                INTEGER DEFAULT 0,
  stderr_bytes                INTEGER DEFAULT 0,
  rc                          INTEGER,
  outcome                     TEXT    NOT NULL,
  failure_mode                TEXT,
  model                       TEXT,
  service_tier                TEXT,
  input_tokens                INTEGER,
  output_tokens               INTEGER,
  cache_read_tokens           INTEGER,
  cache_create_tokens         INTEGER,
  delegate_backend            TEXT,
  delegate_model              TEXT,
  delegate_steps              INTEGER,
  offloaded_input_tokens      INTEGER,
  offloaded_output_tokens     INTEGER,
  offloaded_cached_input_tokens INTEGER,
  post_condition_target_type  TEXT,
  post_condition_matcher      TEXT,
  post_condition_hit          INTEGER,
  post_condition_expected     TEXT,
  post_condition_observed     TEXT,
  raw_json                    TEXT    NOT NULL
);
CREATE INDEX IF NOT EXISTS ix_stats_ts            ON stats_events(ts DESC);
CREATE INDEX IF NOT EXISTS ix_stats_verb_route    ON stats_events(verb, adapter_route);
CREATE INDEX IF NOT EXISTS ix_stats_outcome       ON stats_events(outcome);
CREATE INDEX IF NOT EXISTS ix_stats_site          ON stats_events(site);
CREATE INDEX IF NOT EXISTS ix_stats_failure_mode  ON stats_events(failure_mode);

CREATE TABLE IF NOT EXISTS stats_cursor (
  source     TEXT PRIMARY KEY,
  last_line  INTEGER NOT NULL DEFAULT 0,
  last_ts    TEXT
);
CREATE TABLE IF NOT EXISTS stats_overrides (
  span_id     TEXT PRIMARY KEY,
  verdict     TEXT NOT NULL,
  reason      TEXT,
  marked_at   TEXT NOT NULL
);
PRAGMA user_version = 1;
SQL
  local col name type exists
  for col in \
    "delegate_backend|TEXT" \
    "delegate_model|TEXT" \
    "delegate_steps|INTEGER" \
    "offloaded_input_tokens|INTEGER" \
    "offloaded_output_tokens|INTEGER" \
    "offloaded_cached_input_tokens|INTEGER"; do
    name="${col%%|*}"
    type="${col#*|}"
    exists="$(sqlite3 "${STATS_DB}" "SELECT COUNT(*) FROM pragma_table_info('stats_events') WHERE name='${name}';")"
    if [ "${exists}" = "0" ]; then
      sqlite3 "${STATS_DB}" "ALTER TABLE stats_events ADD COLUMN ${name} ${type};"
    fi
  done
  chmod 600 "${STATS_DB}" 2>/dev/null || true
}

# stats_rebuild — tail JSONL from last cursor, upsert into SQLite.
stats_rebuild() {
  stats_db_init
  [ -f "${STATS_JSONL}" ] || { ok "stats: no JSONL yet — nothing to rebuild"; return 0; }

  local last_line cur new_lines processed=0
  last_line=$(sqlite3 "${STATS_DB}" \
    "SELECT COALESCE(last_line, 0) FROM stats_cursor WHERE source='stats.jsonl';" 2>/dev/null \
    || printf '0')
  last_line="${last_line:-0}"
  cur=$(wc -l < "${STATS_JSONL}" | tr -d ' ')

  if [ "${cur}" -le "${last_line}" ]; then
    ok "stats: SQLite up to date (${cur} lines indexed)"
    return 0
  fi

  # Stream new lines into SQL inserts via jq → sqlite3 stdin (single transaction).
  new_lines=$(( cur - last_line ))
  {
    printf 'BEGIN;\n'
    tail -n "${new_lines}" "${STATS_JSONL}" | jq -r '
      def q: tostring | gsub("'"'"'"; "'"'"''"'"'");
      def sql_int_or_null:
        if type == "number" and floor == . and . >= 0 then tostring
        elif type == "string" and test("^[0-9]+$") then .
        else "NULL" end;
      [
        (.schema_version // 1 | sql_int_or_null),
        ("'"'"'" + (.ts // "" | q) + "'"'"'"),
        ("'"'"'" + (.trace_id // "" | q) + "'"'"'"),
        ("'"'"'" + (.span_id // "" | q) + "'"'"'"),
        (if .parent_span_id then ("'"'"'" + (.parent_span_id | q) + "'"'"'") else "NULL" end),
        (if .session_id then ("'"'"'" + (.session_id | q) + "'"'"'") else "NULL" end),
        (if .gen_ai_tool_name then ("'"'"'" + (.gen_ai_tool_name | q) + "'"'"'") else "NULL" end),
        ("'"'"'" + (.verb // "" | q) + "'"'"'"),
        ("'"'"'" + (.adapter_route // "" | q) + "'"'"'"),
        (if .site then ("'"'"'" + (.site | q) + "'"'"'") else "NULL" end),
        (if .selector_kind then ("'"'"'" + (.selector_kind | q) + "'"'"'") else "NULL" end),
        (if .selector_value then ("'"'"'" + (.selector_value | q) + "'"'"'") else "NULL" end),
        (.duration_ms // 0 | sql_int_or_null),
        (.argv_bytes // 0 | sql_int_or_null),
        (.stdout_bytes // 0 | sql_int_or_null),
        (.stderr_bytes // 0 | sql_int_or_null),
        (.rc // 0 | sql_int_or_null),
        ("'"'"'" + (.outcome // "" | q) + "'"'"'"),
        (if .failure_mode then ("'"'"'" + (.failure_mode | q) + "'"'"'") else "NULL" end),
        (if .model then ("'"'"'" + (.model | q) + "'"'"'") else "NULL" end),
        (if .service_tier then ("'"'"'" + (.service_tier | q) + "'"'"'") else "NULL" end),
        (.gen_ai_usage_input_tokens | sql_int_or_null),
        (.gen_ai_usage_output_tokens | sql_int_or_null),
        (.gen_ai_usage_cache_read_input_tokens | sql_int_or_null),
        (.gen_ai_usage_cache_creation_input_tokens | sql_int_or_null),
        (if .post_condition_target_type then ("'"'"'" + (.post_condition_target_type | q) + "'"'"'") else "NULL" end),
        (if .post_condition_matcher     then ("'"'"'" + (.post_condition_matcher | q) + "'"'"'") else "NULL" end),
        (if .post_condition_hit == true then "1" elif .post_condition_hit == false then "0" else "NULL" end),
        (if .post_condition_expected then ("'"'"'" + (.post_condition_expected | q) + "'"'"'") else "NULL" end),
        (if .post_condition_observed then ("'"'"'" + (.post_condition_observed | q) + "'"'"'") else "NULL" end),
        ("'"'"'" + (. | tostring | q) + "'"'"'"),
        (if .delegate_backend then ("'"'"'" + (.delegate_backend | q) + "'"'"'") else "NULL" end),
        (if .delegate_model then ("'"'"'" + (.delegate_model | q) + "'"'"'") else "NULL" end),
        (.delegate_steps | sql_int_or_null),
        (.offloaded_input_tokens | sql_int_or_null),
        (.offloaded_output_tokens | sql_int_or_null),
        (.offloaded_cached_input_tokens | sql_int_or_null)
      ] | "INSERT OR IGNORE INTO stats_events (" +
        "schema_version,ts,trace_id,span_id,parent_span_id,session_id,gen_ai_tool_name," +
        "verb,adapter_route,site,selector_kind,selector_value,duration_ms,argv_bytes,stdout_bytes,stderr_bytes,rc,outcome,failure_mode," +
        "model,service_tier,input_tokens,output_tokens,cache_read_tokens,cache_create_tokens," +
        "post_condition_target_type,post_condition_matcher,post_condition_hit,post_condition_expected,post_condition_observed,raw_json," +
        "delegate_backend,delegate_model,delegate_steps,offloaded_input_tokens,offloaded_output_tokens,offloaded_cached_input_tokens" +
        ") VALUES (" + join(",") + ");"
    '
    printf "INSERT INTO stats_cursor(source,last_line,last_ts) VALUES('stats.jsonl',%d,datetime('now')) ON CONFLICT(source) DO UPDATE SET last_line=excluded.last_line,last_ts=excluded.last_ts;\n" "${cur}"
    printf 'COMMIT;\n'
  } | sqlite3 "${STATS_DB}"
  processed="${new_lines}"
  ok "stats: rebuilt — indexed ${processed} new event(s) (total lines: ${cur})"
}

# stats_load_prices — sources the JSON price table; sets globals PRICE_<MODEL>_<KIND>.
# Falls back silently if file missing — cost columns become null in report.
stats_load_prices() {
  PRICES_AVAILABLE=0
  [ -f "${PRICES_FILE}" ] || return 0
  PRICES_AVAILABLE=1
}

# stats_report — print summary tables.
stats_report() {
  require_sqlite3
  stats_rebuild >/dev/null 2>&1 || true
  [ -f "${STATS_DB}" ] || { ok "stats: no events yet"; emit_summary verb=stats tool=none why=report status=empty events=0; return 0; }

  local days=7 route_filter="" verb_filter="" pareto=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --days)   days="$2"; shift 2 ;;
      --route)  route_filter="$2"; shift 2 ;;
      --verb)   verb_filter="$2"; shift 2 ;;
      --pareto) pareto=1; shift ;;
      *) die "${EXIT_USAGE_ERROR}" "report: unknown flag '$1'" ;;
    esac
  done
  stats_require_nonnegative_int "${days}" "--days"

  local where="WHERE ts >= datetime('now', '-${days} days')"
  [ -n "${route_filter}" ] && where="${where} AND adapter_route=$(stats_sql_quote "${route_filter}")"
  [ -n "${verb_filter}" ]  && where="${where} AND verb=$(stats_sql_quote "${verb_filter}")"

  stats_load_prices

  printf '\n=== browser-stats report (last %s day(s)) ===\n\n' "${days}" >&2

  # Headline: events / outcomes.
  local total
  total=$(sqlite3 "${STATS_DB}" "SELECT COUNT(*) FROM stats_events ${where};")
  [ "${total}" = "0" ] && { ok "stats: no events in window"; emit_summary verb=stats tool=none why=report status=empty events=0; return 0; }

  printf 'Events: %s\n' "${total}" >&2
  sqlite3 -separator $'\t' "${STATS_DB}" "
    SELECT outcome, COUNT(*) AS n,
           ROUND(100.0*COUNT(*)/${total}, 1) AS pct
    FROM stats_events ${where}
    GROUP BY outcome ORDER BY n DESC;" \
    | awk -F'\t' 'BEGIN{printf "\n  %-10s %8s %8s\n", "outcome","count","pct"}
                  {printf "  %-10s %8s %7s%%\n",$1,$2,$3}' >&2

  # Route × verb table.
  printf '\nRoute × verb:\n' >&2
  sqlite3 -separator $'\t' "${STATS_DB}" "
    SELECT adapter_route, verb, COUNT(*) AS n,
           SUM(CASE WHEN outcome='success' THEN 1 ELSE 0 END) AS ok,
           CAST(AVG(duration_ms) AS INTEGER) AS avg_ms,
           CAST(AVG(stdout_bytes) AS INTEGER) AS avg_out
    FROM stats_events ${where}
    GROUP BY adapter_route, verb
    ORDER BY n DESC LIMIT 20;" \
    | awk -F'\t' 'BEGIN{printf "  %-22s %-12s %6s %6s %8s %10s\n","route","verb","n","ok","avg_ms","avg_out_b"}
                  {printf "  %-22s %-12s %6s %6s %8s %10s\n",$1,$2,$3,$4,$5,$6}' >&2

  # Failure modes.
  printf '\nFailure modes:\n' >&2
  sqlite3 -separator $'\t' "${STATS_DB}" "
    SELECT COALESCE(failure_mode,'(unclassified)') AS fm, COUNT(*) AS n
    FROM stats_events ${where} AND outcome != 'success'
    GROUP BY failure_mode ORDER BY n DESC LIMIT 15;" 2>/dev/null \
    | awk -F'\t' '{printf "  %-24s %6s\n",$1,$2}' >&2

  # Post-condition assertion rate.
  printf '\nPost-condition assertions:\n' >&2
  sqlite3 -separator $'\t' "${STATS_DB}" "
    SELECT
      SUM(CASE WHEN post_condition_hit=1 THEN 1 ELSE 0 END) AS hit,
      SUM(CASE WHEN post_condition_hit=0 THEN 1 ELSE 0 END) AS miss,
      SUM(CASE WHEN post_condition_hit IS NULL THEN 1 ELSE 0 END) AS none
    FROM stats_events ${where};" \
    | awk -F'\t' '{printf "  hit:%s  miss:%s  not-asserted:%s\n",$1,$2,$3}' >&2

  # Oblivious-success — the killer signal.
  local obliv
  obliv=$(sqlite3 "${STATS_DB}" "
    SELECT COUNT(*) FROM stats_events ${where}
    AND failure_mode='oblivious_success';")
  printf '\n  ⚠ oblivious_success: %s (adapter said ok but post-condition failed)\n' "${obliv}" >&2

  local delegate_events offloaded_total_tokens
  delegate_events="$(sqlite3 "${STATS_DB}" "
    SELECT COUNT(*) FROM stats_events ${where}
    AND adapter_route='browser-delegate';")"
  offloaded_total_tokens="$(sqlite3 "${STATS_DB}" "
    SELECT COALESCE(SUM(
      COALESCE(offloaded_input_tokens, CAST(json_extract(raw_json, '$.offloaded_input_tokens') AS INTEGER), 0) +
      COALESCE(offloaded_output_tokens, CAST(json_extract(raw_json, '$.offloaded_output_tokens') AS INTEGER), 0) +
      COALESCE(offloaded_cached_input_tokens, CAST(json_extract(raw_json, '$.offloaded_cached_input_tokens') AS INTEGER), 0)
    ), 0)
    FROM stats_events ${where}
    AND adapter_route='browser-delegate';")"

  if [ "${delegate_events}" != "0" ]; then
    printf '\nDelegation offload (secondary LLM):\n' >&2
    sqlite3 -separator $'\t' "${STATS_DB}" "
      SELECT
        COALESCE(delegate_backend, json_extract(raw_json, '$.delegate_backend'), '(unknown)') AS backend,
        COALESCE(delegate_model, json_extract(raw_json, '$.delegate_model'), model, '(unknown)') AS model_name,
        COUNT(*) AS n,
        SUM(CASE WHEN outcome='success' THEN 1 ELSE 0 END) AS ok,
        CAST(AVG(duration_ms) AS INTEGER) AS avg_ms,
        CAST(AVG(COALESCE(delegate_steps, CAST(json_extract(raw_json, '$.delegate_steps') AS INTEGER), 0)) AS INTEGER) AS avg_steps,
        COALESCE(SUM(COALESCE(offloaded_input_tokens, CAST(json_extract(raw_json, '$.offloaded_input_tokens') AS INTEGER), 0)), 0) AS in_tok,
        COALESCE(SUM(COALESCE(offloaded_output_tokens, CAST(json_extract(raw_json, '$.offloaded_output_tokens') AS INTEGER), 0)), 0) AS out_tok,
        COALESCE(SUM(COALESCE(offloaded_cached_input_tokens, CAST(json_extract(raw_json, '$.offloaded_cached_input_tokens') AS INTEGER), 0)), 0) AS cached_tok,
        COALESCE(SUM(
          COALESCE(offloaded_input_tokens, CAST(json_extract(raw_json, '$.offloaded_input_tokens') AS INTEGER), 0) +
          COALESCE(offloaded_output_tokens, CAST(json_extract(raw_json, '$.offloaded_output_tokens') AS INTEGER), 0) +
          COALESCE(offloaded_cached_input_tokens, CAST(json_extract(raw_json, '$.offloaded_cached_input_tokens') AS INTEGER), 0)
        ), 0) AS total_tok
      FROM stats_events ${where}
      AND adapter_route='browser-delegate'
      GROUP BY backend, model_name
      ORDER BY total_tok DESC, n DESC;" \
      | awk -F'\t' 'BEGIN{printf "  %-14s %-22s %6s %6s %8s %9s %10s %10s %10s %10s\n","backend","model","n","ok","avg_ms","avg_step","input","output","cached","total"}
                    {printf "  %-14s %-22s %6s %6s %8s %9s %10s %10s %10s %10s\n",$1,$2,$3,$4,$5,$6,$7,$8,$9,$10}' >&2
  fi

  # Token + cost rollup if prices available.
  if [ "${PRICES_AVAILABLE}" = "1" ]; then
    printf '\nToken / cost (when injected via CLAUDE_USAGE_* env):\n' >&2
    sqlite3 -separator $'\t' "${STATS_DB}" "
      SELECT
        COALESCE(model,'(no model)') AS m,
        COUNT(*) AS n,
        COALESCE(SUM(input_tokens),0) AS in_tok,
        COALESCE(SUM(output_tokens),0) AS out_tok,
        COALESCE(SUM(cache_read_tokens),0) AS cr,
        COALESCE(SUM(cache_create_tokens),0) AS cc
      FROM stats_events ${where}
      GROUP BY model ORDER BY n DESC;" \
      | awk -F'\t' 'BEGIN{printf "  %-22s %6s %10s %10s %10s %10s\n","model","n","input","output","cache_r","cache_w"}
                    {printf "  %-22s %6s %10s %10s %10s %10s\n",$1,$2,$3,$4,$5,$6}' >&2

    # Read prices, compute $ per model. Per-model row produced by SQLite;
    # jq does the dollar math (centi-USD rounded to keep the report readable).
    local rows_json
    rows_json="$(sqlite3 "${STATS_DB}" -json "
      SELECT
        COALESCE(model,'(none)') AS model,
        COALESCE(SUM(input_tokens),0)        AS i,
        COALESCE(SUM(output_tokens),0)       AS o,
        COALESCE(SUM(cache_read_tokens),0)   AS cr,
        COALESCE(SUM(cache_create_tokens),0) AS cc
      FROM stats_events ${where}
      GROUP BY model;")"
    [ -z "${rows_json}" ] && rows_json='[]'
    local cost_json
    cost_json=$(
      jq -nc \
        --slurpfile prices "${PRICES_FILE}" \
        --argjson rows "${rows_json}" '
        ($prices[0].models // {}) as $p
        | [ $rows[]
            | . as $r
            | ($p[$r.model]) as $price
            | if ($price == null) then
                {model: $r.model, cost_usd: null}
              else
                ( ($r.i  * ($price.input        // 0)) +
                  ($r.o  * ($price.output       // 0)) +
                  ($r.cr * ($price.cache_read   // 0)) +
                  ($r.cc * ($price.cache_create // 0))
                ) as $raw
                | (($raw * 100 | round) / 100) as $cents
                | {model: $r.model, cost_usd: $cents}
              end
          ]'
    )
    printf '\n  cost (USD, computed from references/stats-prices.json):\n' >&2
    printf '%s\n' "${cost_json}" | jq -r '.[] | "    \(.model): $\(.cost_usd // "n/a")"' >&2
  fi

  # Pareto frontier — composite efficiency score.
  if [ "${pareto}" = "1" ]; then
    printf '\nRoute Pareto (success_rate × 1/(1+log10(1+avg_kb))):\n' >&2
    sqlite3 -separator $'\t' "${STATS_DB}" "
      SELECT adapter_route,
             ROUND(1.0*SUM(CASE WHEN outcome='success' THEN 1 ELSE 0 END)/COUNT(*),3) AS sr,
             CAST(AVG(stdout_bytes)/1024.0 AS REAL) AS kb,
             ROUND(
               (1.0*SUM(CASE WHEN outcome='success' THEN 1 ELSE 0 END)/COUNT(*))
               / (1.0 + 0.4343*LN(1.0 + AVG(stdout_bytes)/1024.0))
             ,3) AS efficiency
      FROM stats_events ${where}
      GROUP BY adapter_route ORDER BY efficiency DESC;" \
      | awk -F'\t' 'BEGIN{printf "  %-22s %8s %10s %12s\n","route","sr","avg_kb","efficiency"}
                    {printf "  %-22s %8s %10.2f %12s\n",$1,$2,$3,$4}' >&2
  fi

  emit_summary verb=stats tool=none why=report status=ok events="${total}" days="${days}" \
    delegate_events="${delegate_events}" offloaded_total_tokens="${offloaded_total_tokens}"
}

# stats_mark — record a user override for one span_id.
stats_mark() {
  stats_db_init
  local span="${1:-}"; local verdict_full="${2:-}"
  [ -n "${span}" ] && [ -n "${verdict_full}" ] \
    || die "${EXIT_USAGE_ERROR}" "mark: usage: browser-stats mark <span_id> <success|fail[:reason]>"
  local verdict reason
  verdict="${verdict_full%%:*}"
  reason="${verdict_full#*:}"
  [ "${reason}" = "${verdict}" ] && reason=""
  case "${verdict}" in
    success|fail) ;;
    *) die "${EXIT_USAGE_ERROR}" "mark: verdict must be 'success' or 'fail' (got '${verdict}')" ;;
  esac
  # Confirm span exists.
  local found
  found=$(sqlite3 "${STATS_DB}" "SELECT COUNT(*) FROM stats_events WHERE span_id='${span//\'/\'\'}';")
  if [ "${found}" = "0" ]; then
    warn "mark: span_id '${span}' not found in stats_events (override recorded anyway; will apply on rebuild)"
  fi
  sqlite3 "${STATS_DB}" "
    INSERT INTO stats_overrides(span_id, verdict, reason, marked_at)
    VALUES('${span//\'/\'\'}', '${verdict}', '${reason//\'/\'\'}', datetime('now'))
    ON CONFLICT(span_id) DO UPDATE SET verdict=excluded.verdict, reason=excluded.reason, marked_at=excluded.marked_at;"
  ok "stats: override recorded — span=${span} verdict=${verdict} reason=${reason:-(none)}"
  emit_summary verb=stats tool=none why=mark status=ok span_id="${span}" verdict="${verdict}"
}

# stats_tune — surface a candidate verb for /autoresearch handoff.
stats_tune() {
  require_sqlite3
  stats_rebuild >/dev/null 2>&1 || true
  local days=30 route_filter=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --days)  days="$2"; shift 2 ;;
      --route) route_filter="$2"; shift 2 ;;
      *) die "${EXIT_USAGE_ERROR}" "tune: unknown flag '$1'" ;;
    esac
  done
  stats_require_nonnegative_int "${days}" "--days"
  local where="WHERE ts >= datetime('now', '-${days} days')"
  [ -n "${route_filter}" ] && where="${where} AND adapter_route=$(stats_sql_quote "${route_filter}")"

  printf '\n=== browser-stats tune (last %s day(s)) ===\n\n' "${days}" >&2
  printf 'Worst-performing (verb,route) by success rate (min 10 events):\n' >&2
  sqlite3 -separator $'\t' "${STATS_DB}" "
    SELECT verb, adapter_route,
           COUNT(*) AS n,
           ROUND(1.0*SUM(CASE WHEN outcome='success' THEN 1 ELSE 0 END)/COUNT(*),3) AS sr,
           CAST(AVG(duration_ms) AS INTEGER) AS avg_ms
    FROM stats_events ${where}
    GROUP BY verb, adapter_route
    HAVING n >= 10
    ORDER BY sr ASC, avg_ms DESC LIMIT 5;" \
    | awk -F'\t' 'BEGIN{printf "  %-12s %-22s %6s %8s %10s\n","verb","route","n","sr","avg_ms"}
                  {printf "  %-12s %-22s %6s %8s %10s\n",$1,$2,$3,$4,$5}' >&2

  printf '\nHand-off recipe (human-in-loop):\n' >&2
  printf '  1. Pick a (verb,route) row above with low success rate.\n' >&2
  printf '  2. Invoke /autoresearch with that verb as the optimization target.\n' >&2
  printf '  3. autoresearch reads stats_events to derive eval cases automatically.\n' >&2
  printf '  4. Review proposed mutation; apply by hand. No auto-merge.\n' >&2

  emit_summary verb=stats tool=none why=tune status=ok days="${days}"
}

# stats_prune — close the telemetry feedback loop (Phase 14+).
#
# Find (site, selector) tuples with ≥THRESHOLD oblivious_success events in
# the last --days days. Each such tuple = "cache lied" repeatedly: adapter
# said ok but post-condition failed. The interaction's cached selector is
# semantically broken (pointing at the wrong element, or page redesigned in
# a way Phase-13 + Path 3 can't rescue).
#
# Modes:
#   default (advisory): list candidates as NDJSON _kind:prune_candidate
#                       lines; summary reports count. No mutation.
#   --apply           : mark each candidate interaction .disabled=true in
#                       its archetype JSON; emits _kind:prune_applied. The
#                       disabled marker is the same one Phase 11 self-heal
#                       sets after 4 plain failures; cache lookups skip
#                       disabled interactions, so the cloud-LLM path takes
#                       over on the next call.
#
# Why pruning matters: without this, cache pollution accumulates silently
# over time. Phase 12 telemetry (oblivious_success) was the read side;
# this is the write side that closes the loop.
stats_prune() {
  require_sqlite3
  stats_rebuild >/dev/null 2>&1 || true
  local days=7 threshold=3 apply=0 site_filter=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --days)      days="$2"; shift 2 ;;
      --threshold) threshold="$2"; shift 2 ;;
      --apply)     apply=1; shift ;;
      --site)      site_filter="$2"; shift 2 ;;
      -h|--help)
        cat <<'PRUNEUSAGE' >&2
browser-stats prune [--days N] [--threshold N] [--apply] [--site NAME]

Find cache archetype interactions where the cached selector has caused
≥THRESHOLD oblivious_success events in the last --days days (default
--days 7, --threshold 3). Adapter said ok but post-condition failed
— a strong "cache is wrong" signal that Phase-13 + Path 3 couldn't
heal. Dry-run by default: emits _kind:prune_candidate lines. With
--apply, marks each matching interaction .disabled=true in its
archetype JSON (lookups skip disabled → cloud-LLM path runs instead).
PRUNEUSAGE
        return 0
        ;;
      *) die "${EXIT_USAGE_ERROR}" "prune: unknown flag '$1'" ;;
    esac
  done
  stats_require_nonnegative_int "${days}" "--days"
  stats_require_nonnegative_int "${threshold}" "--threshold"
  local where="WHERE failure_mode='oblivious_success' AND ts >= datetime('now', '-${days} days') AND site IS NOT NULL AND selector_value IS NOT NULL"
  [ -n "${site_filter}" ] && where="${where} AND site=$(stats_sql_quote "${site_filter}")"

  local candidates
  candidates="$(sqlite3 -separator $'\t' "${STATS_DB}" "
    SELECT site, selector_value, COUNT(*) AS n
    FROM stats_events ${where}
    GROUP BY site, selector_value
    HAVING n >= ${threshold}
    ORDER BY n DESC;" 2>/dev/null)"

  local candidate_count=0 applied_count=0
  while IFS=$'\t' read -r site sel n; do
    [ -z "${site}" ] && continue
    [ -z "${sel}" ] && continue
    local arch_dir="${BROWSER_SKILL_HOME}/memory/${site}/archetypes"
    [ -d "${arch_dir}" ] || continue
    local arch_file
    for arch_file in "${arch_dir}"/*.json; do
      [ -f "${arch_file}" ] || continue
      local arch_id intent
      arch_id="$(basename "${arch_file}" .json)"
      intent="$(jq -r --arg sel "${sel}" \
        '.interactions[]? | select(.selector == $sel) | .intent' \
        "${arch_file}" 2>/dev/null | head -1)"
      if [ -n "${intent}" ]; then
        candidate_count=$((candidate_count + 1))
        jq -nc \
          --arg site "${site}" --arg sel "${sel}" \
          --arg arch_id "${arch_id}" --arg intent "${intent}" \
          --argjson n "${n}" \
          '{_kind:"prune_candidate", site:$site, selector:$sel,
            oblivious_success_count:$n, archetype_id:$arch_id, intent:$intent}'
        if [ "${apply}" = "1" ]; then
          local tmp
          tmp="$(mktemp)"
          jq --arg sel "${sel}" \
            '(.interactions[] | select(.selector == $sel)).disabled = true' \
            "${arch_file}" > "${tmp}" \
            && mv "${tmp}" "${arch_file}" \
            && chmod 600 "${arch_file}" \
            && applied_count=$((applied_count + 1))
          jq -nc \
            --arg site "${site}" --arg sel "${sel}" \
            --arg arch_id "${arch_id}" --arg intent "${intent}" \
            '{_kind:"prune_applied", site:$site, selector:$sel,
              archetype_id:$arch_id, intent:$intent}'
        fi
        break
      fi
    done
  done <<< "${candidates}"

  emit_summary verb=stats tool=none why=prune status=ok \
    days="${days}" threshold="${threshold}" \
    candidates="${candidate_count}" applied="${applied_count}"
}

case "${subcmd}" in
  rebuild) stats_rebuild "$@" ;;
  report)  stats_report  "$@" ;;
  mark)    stats_mark    "$@" ;;
  tune)    stats_tune    "$@" ;;
  prune)   stats_prune   "$@" ;;
  event)
    # Internal use — adapters normally call lib/stats.sh helpers directly.
    # Exposed via CLI for debugging and for tests.
    die "${EXIT_USAGE_ERROR}" "browser-stats event: reserved for in-process callers (use lib/stats.sh::stats_run_adapter_emit)"
    ;;
  *) die "${EXIT_USAGE_ERROR}" "browser-stats: unknown subcommand '${subcmd}' (expected: rebuild|report|mark|tune|prune)" ;;
esac
