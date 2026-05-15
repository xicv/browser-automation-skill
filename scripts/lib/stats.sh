# shellcheck shell=bash
# scripts/lib/stats.sh — Phase 12 part 1: per-action telemetry / "balance triangle" audit.
#
# Emits one JSONL event per adapter invocation to
# ${BROWSER_SKILL_HOME}/memory/stats.jsonl (mode 0600, parent 0700).
# Each event captures: route, verb, selector kind/hit, retries, duration,
# stdout/stderr byte sizes (token proxies for the bash skill), post-condition
# result, and a 13-value failure-mode enum.
#
# Optional gen_ai.* token fields are populated only when Claude Code injects
# them via env (CLAUDE_USAGE_INPUT_TOKENS / _OUTPUT_TOKENS / _CACHE_READ_TOKENS
# / _CACHE_CREATE_TOKENS / _MODEL / _SERVICE_TIER) — left null otherwise.
# Field naming follows OpenInference + OTel GenAI v1.40 conventions so the log
# is forward-compatible with Langfuse/Phoenix/Jaeger via an OTLP exporter.
#
# Best-effort writer — failure NEVER taints the verb's exit code. Mirrors the
# contract of scripts/browser-do.sh::_record_event and lib/memory.sh::
# memory_record_recent_url (Phase 11 v2 prior art).
#
# Public API:
#   stats_init_dir                       — lazy-create memory dir mode 0700
#   stats_random_id                      — 16-hex-char id (fork-free $RANDOM
#                                          unless STATS_USE_CRYPTO_ID=1)
#   stats_now_iso_ms                     — ISO 8601 with ms precision; uses
#                                          $EPOCHREALTIME (bash 5.0+) — no fork
#   stats_classify_failure RC OUT ERR    — echo one failure_mode enum value
#   stats_postcond_check T M EXP OBS     — return 0/1; sets STATS_POSTCOND_HIT
#   stats_extract_selector_meta ARGS...  — sets STATS_SEL_KIND, STATS_SEL_VALUE
#   stats_emit_event JSON_OBJECT         — append one JSONL line (best-effort)
#   stats_run_adapter_emit VERB ROUTE T0 RC STDOUT STDERR -- ARGS...
#                                        — convenience helper for verb scripts.
#                                          Post-condition contract comes via env:
#                                            STATS_EXPECT_TYPE     ∈ url|element_path|element_value
#                                            STATS_EXPECT_MATCH    ∈ exact|include|semantic (default: include)
#                                            STATS_EXPECT_VALUE    (string; "" disables check)
#                                            STATS_OBSERVED        (string the verb measured)
#
# Performance notes (Phase 12 part 2 — audit improvements):
#   - Bash 5.0+ required. macOS users need Homebrew bash (already the case for
#     this skill's other bash-isms). $EPOCHREALTIME + LC_ALL=C ${#var} + $RANDOM
#     replace ~9 forks per emit; one jq invocation remains.
#   - chmod 600 runs only on file creation, not every emit.
#
# Schema: see references/stats-schema.json. Schema version: 1.

[ -n "${BROWSER_SKILL_STATS_LOADED:-}" ] && return 0
readonly BROWSER_SKILL_STATS_LOADED=1

readonly STATS_SCHEMA_VERSION=1

# Failure-mode enum (synced with WAREX + Agent-E + WebVoyager taxonomies).
# Update references/stats-schema.json::failure_mode.enum in lockstep.
# shellcheck disable=SC2034  # documentation constant; consumers grep this for the canonical list
readonly STATS_FAILURE_MODES="element_not_found element_ambiguous wrong_element_acted stale_ref action_timeout navigation_mismatch js_not_ready network_error captcha_blocked auth_required popup_intercept extraction_mismatch oblivious_success"

# stats_init_dir — idempotent mkdir + chmod for ${BROWSER_SKILL_HOME}/memory/.
# Same lazy-create pattern as memory_init_dir in lib/memory.sh; duplicated here
# so callers that don't source memory.sh can still emit (e.g. extract verb).
stats_init_dir() {
  local dir
  dir="${BROWSER_SKILL_HOME}/memory"
  mkdir -p "${dir}" 2>/dev/null || return 1
  chmod 700 "${dir}" 2>/dev/null || true
}

# stats_random_id — 16 hex chars. Fork-free $RANDOM-based by default (~60 bits
# effective entropy; adequate for in-session correlation IDs, NOT cryptography).
# Set STATS_USE_CRYPTO_ID=1 to fall back to `openssl rand -hex 8` when crypto-
# strength uniqueness is needed (e.g. cross-session log export).
stats_random_id() {
  if [ "${STATS_USE_CRYPTO_ID:-0}" = "1" ] && command -v openssl >/dev/null 2>&1; then
    openssl rand -hex 8
  else
    # 4 × $RANDOM (15 bits each, %04x pads to 4 hex chars). printf -v keeps
    # the result in a var without forking; piping to stdout is one printf call.
    local _hex
    printf -v _hex '%04x%04x%04x%04x' "${RANDOM}" "${RANDOM}" "${RANDOM}" "${RANDOM}"
    printf '%s\n' "${_hex}"
  fi
}

# stats_now_iso_ms — ISO 8601 with ms precision, UTC. Uses bash 5.0+ $EPOCHREALTIME
# (no fork) + the bash-4.2+ `printf -v %()T` builtin date formatter (no fork).
# Fallback for bash <5.0 is a single `date -u` fork at second precision — no
# python3 dependency, no millisecond gymnastics.
stats_now_iso_ms() {
  if [ -n "${EPOCHREALTIME:-}" ]; then
    local secs=${EPOCHREALTIME%.*}
    local frac=${EPOCHREALTIME#*.}
    local ms=${frac:0:3}
    local _ts
    # %()T strftime reads TZ at call time; env-prefix sets it for this builtin.
    TZ=UTC printf -v _ts '%(%Y-%m-%dT%H:%M:%S)T.%sZ' "${secs}" "${ms}"
    printf '%s\n' "${_ts}"
  else
    # Legacy fallback (bash <5.0). Second precision only.
    date -u +%Y-%m-%dT%H:%M:%SZ
  fi
}

# stats_classify_failure RC STDOUT STDERR
# Echo one failure_mode enum value (or empty when outcome is success).
# Heuristic — looks for adapter-specific markers in stdout/stderr.
# RC == 0 → empty (no failure).
# Otherwise pattern-match exit codes + error text. Conservative: when nothing
# matches, echo "" so the event records failure_mode=null and the human can
# look at error_message instead.
stats_classify_failure() {
  local rc="$1" out="$2" err="$3"
  [ "${rc}" = "0" ] && return 0

  # Exit code first (common.sh constants).
  case "${rc}" in
    13) printf 'extraction_mismatch\n'; return 0 ;;  # EXIT_ASSERTION_FAILED
    22) printf 'auth_required\n';       return 0 ;;  # EXIT_SESSION_EXPIRED
    25) printf 'auth_required\n';       return 0 ;;  # EXIT_AUTH_INTERACTIVE_REQUIRED
    30) printf 'network_error\n';       return 0 ;;  # EXIT_NETWORK_ERROR
    43) printf 'action_timeout\n';      return 0 ;;  # EXIT_TOOL_TIMEOUT
  esac

  local combined="${out}${err}"
  # Order matters — earlier patterns win on overlap. Each branch lists
  # NON-OVERLAPPING substrings: e.g. *"captcha"* already matches "hcaptcha"
  # and "recaptcha", so listing those separately would be dead code.
  case "${combined}" in
    *"captcha"*|*"Cloudflare"*)
      printf 'captcha_blocked\n'; return 0 ;;
    *"login required"*|*"unauthorized"*|*" 401 "*|*" 403 "*)
      printf 'auth_required\n'; return 0 ;;
    *"strict mode"*|*"ambiguous"*)
      printf 'element_ambiguous\n'; return 0 ;;
    *"not found"*|*"no element"*|*"Target closed"*|*"detached"*)
      printf 'element_not_found\n'; return 0 ;;
    *"stale "*|*"snapshot is outdated"*|*"ref expired"*|*"invalid ref"*)
      printf 'stale_ref\n'; return 0 ;;
    *"timeout"*|*"timed out"*|*"exceeded"*)
      printf 'action_timeout\n'; return 0 ;;
    *"net::ERR"*|*"ECONNREFUSED"*|*"ENOTFOUND"*|*"ETIMEDOUT"*)
      printf 'network_error\n'; return 0 ;;
    *"navigation"*|*"redirect"*|*"URL did not match"*)
      printf 'navigation_mismatch\n'; return 0 ;;
    *"modal"*|*"dialog"*|*"consent"*|*"popup"*)
      printf 'popup_intercept\n'; return 0 ;;
    *"script error"*|*"ReferenceError"*|*"TypeError"*)
      printf 'js_not_ready\n'; return 0 ;;
  esac
  # No match — empty (caller stores failure_mode=null).
  return 0
}

# stats_postcond_check TYPE MATCHER EXPECTED OBSERVED
# Verify a post-condition. TYPE ∈ {url, element_path, element_value};
# MATCHER ∈ {exact, include, semantic}. Returns 0 on hit, 1 on miss.
# Sets STATS_POSTCOND_HIT="true"/"false" so callers can serialize.
# Semantic matcher v1 = case-insensitive substring (placeholder for LLM-judge).
stats_postcond_check() {
  local type="$1" matcher="$2" expected="$3" observed="$4"
  STATS_POSTCOND_HIT="false"
  [ -z "${type}" ] && return 1
  [ -z "${expected}" ] && return 1
  case "${matcher}" in
    exact)
      [ "${expected}" = "${observed}" ] && STATS_POSTCOND_HIT="true"
      ;;
    include)
      case "${observed}" in
        *"${expected}"*) STATS_POSTCOND_HIT="true" ;;
      esac
      ;;
    semantic)
      # v1 placeholder: case-insensitive substring. Upgrade path = LLM-judge.
      local exp_lc="${expected,,}" obs_lc="${observed,,}"
      case "${obs_lc}" in
        *"${exp_lc}"*) STATS_POSTCOND_HIT="true" ;;
      esac
      ;;
    *)
      return 1
      ;;
  esac
  [ "${STATS_POSTCOND_HIT}" = "true" ]
}

# stats_extract_selector_meta ARGS...
# Walks an argv looking for --ref / --selector / --src-ref / --dst-ref and
# sets STATS_SEL_KIND ∈ {a11y_ref, css, role, text, none} + STATS_SEL_VALUE.
# Read-only on argv — does not modify positional params.
stats_extract_selector_meta() {
  STATS_SEL_KIND="none"
  STATS_SEL_VALUE=""
  local prev=""
  local a
  for a in "$@"; do
    case "${prev}" in
      --ref|--src-ref|--dst-ref)
        STATS_SEL_KIND="a11y_ref"
        STATS_SEL_VALUE="${a}"
        return 0
        ;;
      --selector)
        STATS_SEL_VALUE="${a}"
        case "${a}" in
          'role='*|"[role="*)         STATS_SEL_KIND="role" ;;
          'text='*|*':has-text('*)    STATS_SEL_KIND="text" ;;
          *)                          STATS_SEL_KIND="css"  ;;
        esac
        return 0
        ;;
    esac
    prev="${a}"
  done
  return 0
}

# stats_emit_event JSON_OBJECT
# Append one canonicalised JSONL line to memory/stats.jsonl. Best-effort —
# emits warn: on failure but never taints exit code.
# Phase 12 part 2: chmod runs only on file creation, not every emit (eliminates
# one fork per write on the hot path).
stats_emit_event() {
  local payload="$1"
  if ! stats_init_dir; then
    warn "stats: could not create memory dir; event skipped"
    return 0
  fi
  local file="${BROWSER_SKILL_HOME}/memory/stats.jsonl"
  local needs_chmod=0
  [ -f "${file}" ] || needs_chmod=1
  local line
  if ! line="$(printf '%s' "${payload}" | jq -c . 2>/dev/null)"; then
    warn "stats: jq encode failed (best-effort; action exit unchanged)"
    return 0
  fi
  if ! printf '%s\n' "${line}" >> "${file}" 2>/dev/null; then
    warn "stats: append failed (best-effort; action exit unchanged)"
    return 0
  fi
  [ "${needs_chmod}" = "1" ] && chmod 600 "${file}" 2>/dev/null
  return 0
}

# stats_run_adapter_emit VERB ROUTE T0_MS RC STDOUT STDERR -- ARGS...
# Convenience wrapper that builds + emits a complete event from raw bash vars.
# Caller passes already-captured stdout/stderr (as strings); we compute byte
# sizes from them. ARGS... is the verb's own argv (used by selector extractor).
#
# Post-condition contract comes via env (kept out of positional args to keep
# the call-site readable — see Phase 12 part 2 audit):
#   STATS_EXPECT_TYPE   ∈ url | element_path | element_value
#   STATS_EXPECT_MATCH  ∈ exact | include | semantic   (default: include)
#   STATS_EXPECT_VALUE  string                          ("" disables check)
#   STATS_OBSERVED      string the verb measured
# Verb scripts conventionally export BROWSER_STATS_EXPECT_* / BROWSER_STATS_OBSERVED
# and this helper reads either prefix (BROWSER_STATS_* preferred, STATS_* legacy).
stats_run_adapter_emit() {
  local verb="$1" route="$2" t0_ms="$3" rc="$4"
  local stdout="$5" stderr="$6"
  shift 6
  [ "${1:-}" = "--" ] && shift

  # Resolve post-condition fields from env (BROWSER_STATS_* wins; STATS_* legacy fallback).
  local exp_type="${BROWSER_STATS_EXPECT_TYPE:-${STATS_EXPECT_TYPE:-}}"
  local exp_match="${BROWSER_STATS_EXPECT_MATCH:-${STATS_EXPECT_MATCH:-include}}"
  local exp_value="${BROWSER_STATS_EXPECT_VALUE:-${STATS_EXPECT_VALUE:-}}"
  local observed="${BROWSER_STATS_OBSERVED:-${STATS_OBSERVED:-}}"

  local t1_ms duration_ms
  t1_ms="$(now_ms)"
  duration_ms=$(( t1_ms - t0_ms ))

  stats_extract_selector_meta "$@"

  local failure_mode outcome
  if [ "${rc}" = "0" ]; then
    outcome="success"
    failure_mode=""
  else
    outcome="fail"
    failure_mode="$(stats_classify_failure "${rc}" "${stdout}" "${stderr}")"
  fi

  STATS_POSTCOND_HIT=""
  local postcond_hit_json="null"
  if [ -n "${exp_type}" ] && [ -n "${exp_value}" ]; then
    if stats_postcond_check "${exp_type}" "${exp_match:-include}" "${exp_value}" "${observed}"; then
      postcond_hit_json="true"
    else
      postcond_hit_json="false"
      # Oblivious-success detection: adapter said OK but post-condition fails.
      if [ "${outcome}" = "success" ]; then
        outcome="partial"
        failure_mode="oblivious_success"
      fi
    fi
  fi

  local span_id trace_id ts site
  span_id="$(stats_random_id)"
  trace_id="${BROWSER_SKILL_TRACE_ID:-${span_id}}"
  ts="$(stats_now_iso_ms)"
  site="${ARG_SITE:-}"
  if [ -z "${site}" ] && command -v current_get >/dev/null 2>&1; then
    site="$(current_get 2>/dev/null || true)"
  fi

  # Byte counts via LC_ALL=C ${#var} — bash builtin, fork-free.
  # `${#var}` returns CHARS in UTF-8 locale, BYTES under LC_ALL=C. Save+restore
  # the prior LC_ALL so the rest of the function (jq) sees its original locale.
  local argv_bytes stdout_bytes stderr_bytes _argv_str _saved_lc="${LC_ALL-}"
  LC_ALL=C
  _argv_str="$*"
  argv_bytes=${#_argv_str}
  stdout_bytes=${#stdout}
  stderr_bytes=${#stderr}
  if [ -z "${_saved_lc}" ]; then
    unset LC_ALL
  else
    LC_ALL="${_saved_lc}"
  fi

  # Token fields from env (Claude Code injects when available; null otherwise).
  local model="${CLAUDE_MODEL:-${ANTHROPIC_MODEL:-}}"
  local input_tokens="${CLAUDE_USAGE_INPUT_TOKENS:-}"
  local output_tokens="${CLAUDE_USAGE_OUTPUT_TOKENS:-}"
  local cache_read="${CLAUDE_USAGE_CACHE_READ_TOKENS:-}"
  local cache_create="${CLAUDE_USAGE_CACHE_CREATE_TOKENS:-}"
  local service_tier="${CLAUDE_SERVICE_TIER:-}"
  local session_id="${CLAUDE_SESSION_ID:-${BROWSER_SKILL_SESSION_ID:-}}"

  # Build event JSON via jq for safe escaping (never bash-interpolate JSON strings).
  local event
  event=$(jq -nc \
    --argjson schema_version "${STATS_SCHEMA_VERSION}" \
    --arg ts "${ts}" \
    --arg span_id "${span_id}" \
    --arg trace_id "${trace_id}" \
    --arg parent_span_id "${BROWSER_SKILL_PARENT_SPAN_ID:-}" \
    --arg session_id "${session_id}" \
    --arg verb "${verb}" \
    --arg adapter_route "${route}" \
    --arg gen_ai_tool_name "${route}.${verb}" \
    --arg site "${site}" \
    --arg selector_kind "${STATS_SEL_KIND}" \
    --arg selector_value "${STATS_SEL_VALUE}" \
    --argjson duration_ms "${duration_ms}" \
    --argjson argv_bytes "${argv_bytes:-0}" \
    --argjson stdout_bytes "${stdout_bytes:-0}" \
    --argjson stderr_bytes "${stderr_bytes:-0}" \
    --argjson rc "${rc}" \
    --arg outcome "${outcome}" \
    --arg failure_mode "${failure_mode}" \
    --arg model "${model}" \
    --arg service_tier "${service_tier}" \
    --arg input_tokens "${input_tokens}" \
    --arg output_tokens "${output_tokens}" \
    --arg cache_read "${cache_read}" \
    --arg cache_create "${cache_create}" \
    --arg exp_type "${exp_type}" \
    --arg exp_match "${exp_match}" \
    --arg exp_value "${exp_value}" \
    --arg observed "${observed}" \
    --argjson postcond_hit "${postcond_hit_json}" '
    {
      schema_version: $schema_version,
      ts: $ts,
      span_id: $span_id,
      trace_id: $trace_id,
      parent_span_id: ($parent_span_id | select(. != "") // null),
      session_id: ($session_id | select(. != "") // null),
      gen_ai_operation_name: "execute_tool",
      gen_ai_tool_name: $gen_ai_tool_name,
      gen_ai_tool_type: "function",
      verb: $verb,
      adapter_route: $adapter_route,
      site: ($site | select(. != "") // null),
      selector_kind: $selector_kind,
      selector_value: ($selector_value | select(. != "") // null),
      duration_ms: $duration_ms,
      argv_bytes: $argv_bytes,
      stdout_bytes: $stdout_bytes,
      stderr_bytes: $stderr_bytes,
      rc: $rc,
      outcome: $outcome,
      failure_mode: ($failure_mode | select(. != "") // null),
      model: ($model | select(. != "") // null),
      service_tier: ($service_tier | select(. != "") // null),
      gen_ai_usage_input_tokens:                (if $input_tokens  == "" then null else ($input_tokens  | tonumber) end),
      gen_ai_usage_output_tokens:               (if $output_tokens == "" then null else ($output_tokens | tonumber) end),
      gen_ai_usage_cache_read_input_tokens:     (if $cache_read    == "" then null else ($cache_read    | tonumber) end),
      gen_ai_usage_cache_creation_input_tokens: (if $cache_create  == "" then null else ($cache_create  | tonumber) end),
      post_condition_target_type:  ($exp_type  | select(. != "") // null),
      post_condition_matcher:      ($exp_match | select(. != "") // null),
      post_condition_expected:     ($exp_value | select(. != "") // null),
      post_condition_observed:     ($observed  | select(. != "") // null),
      post_condition_hit:          $postcond_hit
    }')

  stats_emit_event "${event}"
}
