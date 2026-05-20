#!/usr/bin/env bash
# scripts/browser-do.sh
# Phase 11 part 1-ii — memory-aware verb. Two sub-modes:
#   browser-do --verb VERB --intent "..."        — cache lookup; dispatch on hit; emit cache_miss event on miss
#   browser-do record --intent --selector --url  — explicit write-back through lib/memory.sh
#
# Skill stays model-agnostic: on miss, parent agent picks ref via its own
# snapshot+reasoning, then explicitly calls `record`. No LLM call here.

set -euo pipefail
IFS=$'\n\t'
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="${SCRIPT_DIR}"
export SCRIPTS_DIR

# shellcheck source=lib/common.sh
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/common.sh"
# shellcheck source=lib/site.sh
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/site.sh"
# shellcheck source=lib/memory.sh
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/memory.sh"
# shellcheck source=lib/stats.sh
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/stats.sh"

init_paths

SUMMARY_T0="$(now_ms)"

# --- Whitelist: verbs that accept --selector as primary target ---
# Whitelist grows as adapter ABI gains selector-mode plumbing per verb.
# fill: PR #99. hover: PR #101. select: PR #103. press: deferred (bridge
# `case 'press':` is target-less by design — would need new "focus + press"
# semantics; tracked in HANDOFF as separate decision).
readonly DO_VERB_WHITELIST=(click fill hover select)

_verb_in_whitelist() {
  local needle="$1" v
  for v in "${DO_VERB_WHITELIST[@]}"; do
    [ "${v}" = "${needle}" ] && return 0
  done
  return 1
}

# --- Privacy canary ---
# Refuse cache writes containing the literal sentinel. Backs the recipe-
# pattern privacy-canary tests; not a real secret-detector. Real entropy
# scanning is a future hardening pass.
readonly CANARY_SENTINEL='PASSWORD-CANARY'

# --- Phase 11 v2 part 1: observation log (events.jsonl) writer ---
# Tee per-invocation cache-hit/miss observations into a JSONL log under
# ${BROWSER_SKILL_HOME}/memory/events.jsonl. Doctor's read side (PR #113)
# consumes the .cache_hit field to report a real hit-rate.
#
# Shape: each line is a JSON object with at least .cache_hit (bool) + .ts
# (ISO 8601). Optional fields: .site, .archetype_id, .reason, .dispatched_verb,
# .dispatch_rc. Intent strings are NEVER logged — user input could leak.
# Doctor only needs .cache_hit; everything else is best-effort context.
#
# Best-effort writer. Failure must NOT taint the verb's exit code; emits a
# warn: line and continues. Same contract as memory_record write-back failures
# in the existing dispatch path.
#
# Append-only. File created mode 0600; parent dir mode 0700.
#
# Signature: _record_event JSON_STRING
# Caller builds the per-event JSON (each call site has different fields);
# this helper adds {ts, verb, mode} envelope and appends.
_record_event() {
  local payload="$1"
  local events_dir events_file ts line
  events_dir="${BROWSER_SKILL_HOME}/memory"
  events_file="${events_dir}/events.jsonl"
  ts="$(now_iso)"

  if ! mkdir -p "${events_dir}" 2>/dev/null; then
    warn "browser-do: could not create memory dir; observation log skipped"
    return 0
  fi
  chmod 700 "${events_dir}" 2>/dev/null || true

  if ! line="$(printf '%s' "${payload}" | jq -c --arg ts "${ts}" \
      '. + {ts:$ts, verb:"do", mode:"intent"}' 2>/dev/null)"; then
    warn "browser-do: events.jsonl encode failed (best-effort; action exit unchanged)"
    return 0
  fi

  # O_APPEND on POSIX is atomic for writes under PIPE_BUF (4KB); jsonl lines
  # are well below that, so concurrent appenders interleave by line, not by
  # character. Same pattern as standard audit-log writers.
  if ! printf '%s\n' "${line}" >> "${events_file}" 2>/dev/null; then
    warn "browser-do: events.jsonl append failed (best-effort; action exit unchanged)"
    return 0
  fi

  # First write may have raced umask; chmod is idempotent thereafter.
  chmod 600 "${events_file}" 2>/dev/null || true
}

_canary_check() {
  local field="$1" value="$2"
  if printf '%s' "${value}" | grep -qF -- "${CANARY_SENTINEL}"; then
    die "${EXIT_BLOCKLIST_REJECTED}" "browser-do: refused — ${field} contains canary sentinel '${CANARY_SENTINEL}' (privacy guard; never put credential bytes in cache args)"
  fi
}

# --- URL → pattern derivation ---
# Replace numeric path segments with `:id`. UUID/slug detection deferred
# to 11-2-ii. Caller can always pass --pattern to override.
_derive_pattern_from_url() {
  local url="$1" pathname
  pathname="$(node -e "process.stdout.write(new URL(process.argv[1], 'https://x').pathname)" "${url}" 2>/dev/null)" \
    || die "${EXIT_USAGE_ERROR}" "browser-do: invalid --url '${url}'"
  # /[digits] → /:id  (one or more digit segments anywhere in pathname).
  printf '%s' "${pathname}" | sed -E 's@/[0-9]+@/:id@g'
}

# --- Pattern → archetype_id derivation ---
# Strip leading '/', drop ':' chars, replace '/' with '-', lowercase.
# Constrained to assert_safe_name's regex so memory_save_archetype accepts it.
_derive_archetype_id() {
  local pattern="$1"
  printf '%s' "${pattern#/}" \
    | sed -E 's|:||g; s|/|-|g; s|[^A-Za-z0-9_-]|_|g' \
    | tr '[:upper:]' '[:lower:]'
}

# --- Site resolution ---
# --site flag wins; falls back to current_get; empty → die USAGE.
_resolve_site() {
  local arg="$1"
  if [ -n "${arg}" ]; then
    printf '%s' "${arg}"
    return 0
  fi
  local cur
  cur="$(current_get || true)"
  if [ -z "${cur}" ]; then
    die "${EXIT_USAGE_ERROR}" "browser-do: --site not given and no current site set (use 'browser-use --set NAME' or pass --site)"
  fi
  printf '%s' "${cur}"
}

# --- usage ---
usage() {
  cat <<'USAGE'
Usage:
  browser-do --verb VERB --intent "..." [--site NAME] [--url URL] [-- VERB_ARG ...]
  browser-do record --intent "..." --selector "..." --url "..." [--site NAME] [--pattern PAT] [--archetype NAME]

Verbs (whitelist): click | fill | hover | press | select
USAGE
}

# --- Sub-mode dispatch ---
sub_mode="${1:-}"
[ -n "${sub_mode}" ] || { usage >&2; die "${EXIT_USAGE_ERROR}" "browser-do: missing sub-mode or flag"; }

# `record` and `propose` are literal sub-modes; otherwise we're in --intent
# mode (flags handled below).
case "${sub_mode}" in
  record|propose) shift ;;
  -h|--help) usage; exit 0 ;;
  --*) sub_mode="intent" ;;
  *) die "${EXIT_USAGE_ERROR}" "browser-do: unknown sub-mode '${sub_mode}' (expected 'record', 'propose', or --intent flag)" ;;
esac

# ---------- record sub-mode ----------
if [ "${sub_mode}" = "record" ]; then
  arg_site="" arg_intent="" arg_selector="" arg_url="" arg_pattern="" arg_archetype=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --site)      arg_site="$2";      shift 2 ;;
      --intent)    arg_intent="$2";    shift 2 ;;
      --selector)  arg_selector="$2";  shift 2 ;;
      --url)       arg_url="$2";       shift 2 ;;
      --pattern)   arg_pattern="$2";   shift 2 ;;
      --archetype) arg_archetype="$2"; shift 2 ;;
      -h|--help)   usage; exit 0 ;;
      *) die "${EXIT_USAGE_ERROR}" "browser-do record: unknown flag '$1'" ;;
    esac
  done
  [ -n "${arg_intent}"   ] || die "${EXIT_USAGE_ERROR}" "browser-do record: --intent required"
  [ -n "${arg_selector}" ] || die "${EXIT_USAGE_ERROR}" "browser-do record: --selector required"
  [ -n "${arg_url}"      ] || die "${EXIT_USAGE_ERROR}" "browser-do record: --url required"

  # Privacy canary first — refuse before touching disk.
  _canary_check "intent"   "${arg_intent}"
  _canary_check "selector" "${arg_selector}"

  site="$(_resolve_site "${arg_site}")"

  pattern="${arg_pattern}"
  if [ -z "${pattern}" ]; then
    pattern="$(_derive_pattern_from_url "${arg_url}")"
  fi

  archetype_id="${arg_archetype}"
  if [ -z "${archetype_id}" ]; then
    archetype_id="$(_derive_archetype_id "${pattern}")"
  fi

  # Ensure archetype JSON exists (lazy-init empty shell so memory_record can
  # upsert into it).
  arch_path="${BROWSER_SKILL_HOME}/memory/${site}/archetypes/${archetype_id}.json"
  if [ ! -f "${arch_path}" ]; then
    init_json="$(jq -nc --arg id "${archetype_id}" --arg p "${pattern}" --arg now "$(now_iso)" \
      '{schema_version:1, archetype_id:$id, url_pattern:$p,
        first_seen:$now, last_seen:$now, use_count:0, interactions:[]}')"
    memory_save_archetype "${site}" "${archetype_id}" "${init_json}"
  fi

  memory_record_pattern "${site}" "${pattern}" "${archetype_id}"
  memory_record         "${site}" "${archetype_id}" "${arg_intent}" "${arg_selector}"

  printf '%s\n' "$(jq -nc --arg site "${site}" --arg arch "${archetype_id}" \
    --arg pat "${pattern}" --arg int "${arg_intent}" \
    '{_kind:"record_ok", site:$site, archetype_id:$arch, url_pattern:$pat, intent:$int}')"
  duration_ms=$(( $(now_ms) - SUMMARY_T0 ))
  summary_json verb=do mode=record site="${site}" archetype_id="${archetype_id}" \
    url_pattern="${pattern}" duration_ms="${duration_ms}" status=ok
  exit 0
fi

# ---------- propose sub-mode (Phase 11 part 2-ii) ----------
# Pure-compute. Reads URLs from --url args + stdin; clusters by templated
# pathname (numeric → :id, UUID → :uuid); emits _kind:proposal events for
# clusters meeting threshold AND not already in patterns.json.
if [ "${sub_mode}" = "propose" ]; then
  arg_site="" arg_threshold="3" arg_auto_record="false" arg_from_recent="false"
  cli_urls=()
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --site)        arg_site="$2";      shift 2 ;;
      --threshold)   arg_threshold="$2"; shift 2 ;;
      --url)         cli_urls+=("$2");   shift 2 ;;
      --auto-record) arg_auto_record="true"; shift ;;
      --from-recent) arg_from_recent="true"; shift ;;
      -h|--help)     usage; exit 0 ;;
      *) die "${EXIT_USAGE_ERROR}" "browser-do propose: unknown flag '$1'" ;;
    esac
  done
  if [[ ! "${arg_threshold}" =~ ^[0-9]+$ ]]; then
    die "${EXIT_USAGE_ERROR}" "browser-do propose: --threshold must be a positive integer (got: ${arg_threshold})"
  fi
  site="$(_resolve_site "${arg_site}")"

  # Collect URLs from stdin (one per line; skip blank + ^# comments) into
  # the same list. Stdin is non-blocking — if no pipe is connected, read
  # immediately returns. -t 0 is "is stdin a TTY?"; we read stdin only if
  # it's NOT a TTY (i.e. piped or redirected).
  urls=("${cli_urls[@]+"${cli_urls[@]}"}")
  if [ ! -t 0 ]; then
    while IFS= read -r line; do
      [ -z "${line}" ] && continue
      [[ "${line}" =~ ^[[:space:]]*# ]] && continue
      urls+=("${line}")
    done
  fi

  # Pick A6: --from-recent appends URLs from the navigation observation log
  # filtered to the current site. Absent log → no-op (not an error).
  if [ "${arg_from_recent}" = "true" ]; then
    recent_file="${BROWSER_SKILL_HOME}/memory/recent_urls.jsonl"
    if [ -f "${recent_file}" ]; then
      while IFS= read -r recent_url; do
        [ -z "${recent_url}" ] && continue
        urls+=("${recent_url}")
      done < <(jq -r --arg s "${site}" 'select(.site == $s) | .url' "${recent_file}" 2>/dev/null || true)
    fi
  fi

  # Build node-helper input + invoke. Empty urls → empty cluster set.
  cluster_helper="$(dirname "${BASH_SOURCE[0]}")/lib/node/url-pattern-cluster.mjs"
  cluster_input="$(jq -nc --argjson u "$(printf '%s\n' "${urls[@]+"${urls[@]}"}" | jq -R . | jq -sc .)" '{urls: $u}')"
  cluster_output="$(printf '%s' "${cluster_input}" | node "${cluster_helper}")"

  # Load known patterns from patterns.json (if any) into a sorted unique list.
  patterns_path="${BROWSER_SKILL_HOME}/memory/${site}/patterns.json"
  known_json='[]'
  if [ -f "${patterns_path}" ]; then
    known_json="$(jq -c '[.patterns[].url_pattern] // []' "${patterns_path}")"
  fi

  # Filter clusters: count >= threshold AND templated NOT in known.
  emit_count=0
  skipped_known=0
  auto_recorded=0
  while IFS= read -r cluster_event; do
    [ -z "${cluster_event}" ] && continue
    printf '%s\n' "${cluster_event}"
    emit_count=$(( emit_count + 1 ))
    # Pick A3: when --auto-record, persist the (url_pattern, archetype_id)
    # pair via memory_record_pattern. The proposal stream is already filtered
    # to "not already in patterns.json", so each emit is a fresh pattern.
    # memory_record_pattern is idempotent (per its docstring); best-effort
    # write — failure emits warn: and continues; never taints exit code.
    if [ "${arg_auto_record}" = "true" ]; then
      _ar_url_pattern="$(printf '%s' "${cluster_event}" | jq -r '.url_pattern')"
      _ar_arch_id="$(printf '%s' "${cluster_event}" | jq -r '.archetype_id')"
      if memory_record_pattern "${site}" "${_ar_url_pattern}" "${_ar_arch_id}" 2>/dev/null; then
        auto_recorded=$(( auto_recorded + 1 ))
      else
        warn "browser-do propose: auto-record failed for pattern '${_ar_url_pattern}' (best-effort)"
      fi
    fi
  done < <(printf '%s' "${cluster_output}" | jq -c \
    --argjson threshold "${arg_threshold}" \
    --argjson known "${known_json}" \
    --arg site "${site}" \
    '# Pick A4: canonicalize both the cluster pattern and each known pattern
     # before compare so /devices/:id matches an already-known /devices/:itemId.
     # Original cluster .templated is preserved on emit (only the compare uses
     # the canonical form).
     def _canonical: gsub(":[A-Za-z_][A-Za-z0-9_]*"; ":_");
     ($known | map(_canonical)) as $known_canon
     | .clusters
     | map(select(.count >= $threshold and ([(.templated | _canonical)] | inside($known_canon) | not)))
     | .[] |
       {_kind:"proposal", site:$site,
        url_pattern:.templated,
        archetype_id:(.templated
                       | sub("^/"; "")
                       | gsub(":"; "")
                       | gsub("/"; "-")
                       | gsub("[^A-Za-z0-9_-]"; "_")
                       | ascii_downcase),
        sample_urls:(.urls[0:3]),
        count:.count}')

  # Count clusters skipped due to "already in patterns.json" (canonical match).
  skipped_known="$(printf '%s' "${cluster_output}" | jq -r \
    --argjson threshold "${arg_threshold}" \
    --argjson known "${known_json}" \
    'def _canonical: gsub(":[A-Za-z_][A-Za-z0-9_]*"; ":_");
     ($known | map(_canonical)) as $known_canon
     | .clusters | map(select(.count >= $threshold and ([(.templated | _canonical)] | inside($known_canon)))) | length')"

  duration_ms=$(( $(now_ms) - SUMMARY_T0 ))
  summary_json verb=do mode=propose site="${site}" \
    proposals="${emit_count}" skipped_known="${skipped_known}" \
    auto_recorded="${auto_recorded}" \
    threshold="${arg_threshold}" url_count="${#urls[@]}" \
    duration_ms="${duration_ms}" status=ok
  exit 0
fi

# ---------- intent sub-mode ----------
arg_site="" arg_verb="" arg_intent="" arg_url="" arg_pattern="" arg_archetype=""
extra_args=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --site)      arg_site="$2";      shift 2 ;;
    --verb)      arg_verb="$2";      shift 2 ;;
    --intent)    arg_intent="$2";    shift 2 ;;
    --url)       arg_url="$2";       shift 2 ;;
    --pattern)   arg_pattern="$2";   shift 2 ;;
    --archetype) arg_archetype="$2"; shift 2 ;;
    --)          shift; extra_args=("$@"); break ;;
    -h|--help)   usage; exit 0 ;;
    *) die "${EXIT_USAGE_ERROR}" "browser-do --intent: unknown flag '$1'" ;;
  esac
done
[ -n "${arg_verb}"   ] || die "${EXIT_USAGE_ERROR}" "browser-do: --verb required"
[ -n "${arg_intent}" ] || die "${EXIT_USAGE_ERROR}" "browser-do: --intent required"
_verb_in_whitelist "${arg_verb}" \
  || die "${EXIT_USAGE_ERROR}" "browser-do: --verb '${arg_verb}' not in whitelist (allowed: ${DO_VERB_WHITELIST[*]})"

site="$(_resolve_site "${arg_site}")"

# Resolve archetype with most-explicit-wins priority (Phase 11 part 2-i R1):
#   1. --archetype NAME — direct; skip URL lookup + pattern derivation.
#   2. --pattern PAT    — derive archetype-id via _derive_archetype_id.
#   3. --url URL        — memory_resolve_archetype (Phase 11 part 1-ii path).
# Empty archetype after this block → cache_miss reason:no_pattern_for_url.
archetype_id=""
if [ -n "${arg_archetype}" ]; then
  assert_safe_name "${arg_archetype}" "archetype-id"
  archetype_id="${arg_archetype}"
elif [ -n "${arg_pattern}" ]; then
  archetype_id="$(_derive_archetype_id "${arg_pattern}")"
elif [ -n "${arg_url}" ]; then
  archetype_id="$(memory_resolve_archetype "${site}" "${arg_url}" 2>/dev/null || true)"
fi

if [ -z "${archetype_id}" ]; then
  printf '%s\n' "$(jq -nc --arg int "${arg_intent}" --arg site "${site}" \
    --arg url "${arg_url}" \
    '{_kind:"cache_miss", intent:$int, site:$site, url:$url,
      archetype_id:null, reason:"no_pattern_for_url",
      suggestion:"snapshot+pick+record"}')"
  duration_ms=$(( $(now_ms) - SUMMARY_T0 ))
  _record_event "$(jq -nc --arg site "${site}" \
    '{cache_hit:false, site:$site, reason:"no_pattern_for_url"}')"
  summary_json verb=do mode=intent cache_hit=false reason=no_pattern_for_url \
    site="${site}" duration_ms="${duration_ms}" status=miss
  exit "${EXIT_EMPTY_RESULT}"
fi

selector="$(memory_lookup "${site}" "${archetype_id}" "${arg_intent}" 2>/dev/null || true)"

if [ -z "${selector}" ]; then
  printf '%s\n' "$(jq -nc --arg int "${arg_intent}" --arg site "${site}" \
    --arg url "${arg_url}" --arg arch "${archetype_id}" \
    '{_kind:"cache_miss", intent:$int, site:$site, url:$url,
      archetype_id:$arch, reason:"intent_not_cached",
      suggestion:"snapshot+pick+record"}')"
  duration_ms=$(( $(now_ms) - SUMMARY_T0 ))
  _record_event "$(jq -nc --arg site "${site}" --arg arch "${archetype_id}" \
    '{cache_hit:false, site:$site, archetype_id:$arch, reason:"intent_not_cached"}')"
  summary_json verb=do mode=intent cache_hit=false reason=intent_not_cached \
    site="${site}" archetype_id="${archetype_id}" duration_ms="${duration_ms}" status=miss
  exit "${EXIT_EMPTY_RESULT}"
fi

# Cache hit — dispatch via existing verb script. --selector prepended; extra
# args forwarded verbatim. Forward stdin/stdout/stderr; the dispatched verb
# emits its own summary; ours follows.
#
# BROWSER_DO_DISPATCH_OVERRIDE (test-only env hook): if set, the value is
# treated as the dispatch script path instead of scripts/browser-${verb}.sh.
# Production callers never set this; it lets bats mock the dispatched verb's
# exit code so we can test the self-heal failure-counting trigger end-to-end.
verb_script="${BROWSER_DO_DISPATCH_OVERRIDE:-${SCRIPT_DIR}/browser-${arg_verb}.sh}"
[ -x "${verb_script}" ] || [ -f "${verb_script}" ] \
  || die "${EXIT_TOOL_MISSING}" "browser-do: dispatch target not found: ${verb_script}"

printf '%s\n' "$(jq -nc --arg int "${arg_intent}" --arg sel "${selector}" \
  --arg arch "${archetype_id}" --arg site "${site}" \
  '{_kind:"cache_hit", intent:$int, selector:$sel, archetype_id:$arch, site:$site}')"

# Run the verb. Capture its exit; forward unchanged. Best-effort cache update
# on success only — write-back failure must NOT taint the verb's exit code.
dispatch_rc=0
bash "${verb_script}" --selector "${selector}" "${extra_args[@]+"${extra_args[@]}"}" || dispatch_rc=$?

self_heal_triggered=false

if [ "${dispatch_rc}" -eq 0 ]; then
  if ! memory_record "${site}" "${archetype_id}" "${arg_intent}" "${selector}" 2>/dev/null; then
    warn "browser-do: cache success_count update failed (best-effort; action exit unchanged)"
  fi
  if ! memory_record_pattern "${site}" \
       "$(jq -r '.url_pattern' "${BROWSER_SKILL_HOME}/memory/${site}/archetypes/${archetype_id}.json")" \
       "${archetype_id}" 2>/dev/null; then
    warn "browser-do: pattern hit_count update failed (best-effort)"
  fi
elif [ "${dispatch_rc}" -eq "${EXIT_EMPTY_RESULT}" ] || [ "${dispatch_rc}" -eq "${EXIT_ASSERTION_FAILED}" ]; then
  # Self-heal trigger (Phase 11 1-iii D1): only canonical "selector miss" /
  # "expected element absent" exit codes drive the failure counter. Network
  # errors (30), tool crashes (42), timeouts (43) are environmental — they
  # would poison the cache if we counted them.

  # Phase 13: weak-fingerprint rescue tier — try BEFORE incrementing fail_count.
  # Algorithm scores DOM candidates by tag + classes + attrs Jaccard, returns
  # a synthesised selector if any candidate scores >= BROWSER_DO_RESCUE_THRESHOLD
  # (default 0.70). If the rescued selector works on retry, the cache silently
  # heals (selector overwritten, fail_count reset, self_heal_history appended).
  rescued_selector=""
  rescued_selector="$(memory_fingerprint_rescue "${site}" "${archetype_id}" \
                       "${arg_intent}" "${selector}" 2>/dev/null || printf '')"
  rescued=false
  if [ -n "${rescued_selector}" ] && [ "${rescued_selector}" != "${selector}" ]; then
    # Retry the verb with the rescued selector. Capture rc separately so the
    # original dispatch_rc only flips to 0 when the retry actually succeeds.
    retry_rc=0
    bash "${verb_script}" --selector "${rescued_selector}" "${extra_args[@]+"${extra_args[@]}"}" \
      || retry_rc=$?
    if [ "${retry_rc}" -eq 0 ]; then
      if memory_record_heal "${site}" "${archetype_id}" "${arg_intent}" \
                            "${selector}" "${rescued_selector}" 2>/dev/null; then
        rescued=true
        self_heal_triggered=true
        dispatch_rc=0  # treat as success for the verb's exit-code contract
        printf '%s\n' "$(jq -nc \
          --arg from "${selector}" --arg to "${rescued_selector}" \
          '{_kind:"fingerprint_rescue", from_selector:$from, to_selector:$to,
            rescued:true}')"
        # Phase 13 + 12 audit hook: emit a dedicated stats.jsonl event so
        # `browser-stats report` can compute heal-rate over time. Best-effort.
        _rescue_span_id="$(stats_random_id 2>/dev/null || printf '')"
        _rescue_ts="$(stats_now_iso_ms 2>/dev/null || printf '')"
        if [ -n "${_rescue_span_id}" ] && [ -n "${_rescue_ts}" ]; then
          _rescue_event="$(jq -nc \
            --argjson schema_version 1 \
            --arg ts "${_rescue_ts}" \
            --arg span_id "${_rescue_span_id}" \
            --arg trace_id "${BROWSER_SKILL_TRACE_ID:-${_rescue_span_id}}" \
            --arg verb "do" \
            --arg site "${site}" \
            --arg from "${selector}" \
            --arg to "${rescued_selector}" '
            { schema_version: $schema_version,
              ts: $ts, span_id: $span_id, trace_id: $trace_id,
              parent_span_id: null, session_id: null,
              gen_ai_operation_name: "execute_tool",
              gen_ai_tool_name: "browser-do.fingerprint_rescue",
              gen_ai_tool_type: "function",
              verb: $verb,
              adapter_route: "browser-do",
              site: ($site | select(. != "") // null),
              selector_kind: "css", selector_value: $from,
              duration_ms: 0, argv_bytes: 0, stdout_bytes: 0, stderr_bytes: 0,
              rc: 0,
              outcome: "success",
              failure_mode: null,
              rescued: true,
              fingerprint_from_selector: $from,
              fingerprint_to_selector: $to
            }' 2>/dev/null || printf '')"
          [ -n "${_rescue_event}" ] && stats_emit_event "${_rescue_event}" 2>/dev/null || true
        fi
      else
        warn "browser-do: rescue retry succeeded but memory_record_heal failed (best-effort)"
      fi
    fi
  fi
  # Phase 14 Path 3: visual rescue via local VLM (extension hook).
  # Inserts BETWEEN fingerprint-rescue failure and the fail_count++ path.
  # Both env vars must be set:
  #   BROWSER_SKILL_VISION_FALLBACK=1     enable the tier
  #   BROWSER_SKILL_VISUAL_RESCUE_CMD=PATH  executable hook script
  # The hook receives: SITE INTENT CACHED_SELECTOR (positional). It should
  # decide if the cached element is still the right target visually and:
  #   exit 0 + stdout "yes" → cache rescued; click/fill proceeds as if cache hit
  #   exit 0 + stdout "no"  → fall through to fail_count++ → cloud LLM
  #   non-zero exit         → fall through (treat as "unreachable")
  # See references/recipes/visual-rescue-hook.md for a llama.cpp probe example.
  #
  # The skill is intentionally agnostic about HOW the hook reasons (screenshot
  # crop, full-page snapshot, OCR-only, local-model-of-choice). We ship the
  # seam; users plug their own probe.
  if [ "${rescued}" != "true" ] \
     && [ "${BROWSER_SKILL_VISION_FALLBACK:-0}" = "1" ] \
     && [ -n "${BROWSER_SKILL_VISUAL_RESCUE_CMD:-}" ] \
     && [ -x "${BROWSER_SKILL_VISUAL_RESCUE_CMD}" ]; then
    visual_rc=0
    visual_out="$("${BROWSER_SKILL_VISUAL_RESCUE_CMD}" \
                  "${site}" "${arg_intent}" "${selector}" 2>/dev/null)" \
                || visual_rc=$?
    if [ "${visual_rc}" -eq 0 ] && [ "${visual_out}" = "yes" ]; then
      rescued=true
      dispatch_rc=0  # treat as success — element is still semantically present
      self_heal_triggered=true
      printf '%s\n' "$(jq -nc \
        --arg sel "${selector}" \
        '{_kind:"visual_rescue", selector:$sel, rescued:true,
          hook:"BROWSER_SKILL_VISUAL_RESCUE_CMD"}')"
      # Emit stats.jsonl event so browser-stats can compute visual-rescue rate.
      _vr_span_id="$(stats_random_id 2>/dev/null || printf '')"
      _vr_ts="$(stats_now_iso_ms 2>/dev/null || printf '')"
      if [ -n "${_vr_span_id}" ] && [ -n "${_vr_ts}" ]; then
        _vr_event="$(jq -nc \
          --argjson schema_version 1 \
          --arg ts "${_vr_ts}" \
          --arg span_id "${_vr_span_id}" \
          --arg trace_id "${BROWSER_SKILL_TRACE_ID:-${_vr_span_id}}" \
          --arg site "${site}" \
          --arg sel "${selector}" '
          { schema_version: $schema_version,
            ts: $ts, span_id: $span_id, trace_id: $trace_id,
            parent_span_id: null, session_id: null,
            gen_ai_operation_name: "execute_tool",
            gen_ai_tool_name: "browser-do.visual_rescue",
            gen_ai_tool_type: "function",
            verb: "do",
            adapter_route: "browser-do",
            site: ($site | select(. != "") // null),
            selector_kind: "css", selector_value: $sel,
            duration_ms: 0, argv_bytes: 0, stdout_bytes: 0, stderr_bytes: 0,
            rc: 0,
            outcome: "success",
            failure_mode: null,
            rescued: true,
            fingerprint_from_selector: $sel,
            fingerprint_to_selector: $sel
          }' 2>/dev/null || printf '')"
        [ -n "${_vr_event}" ] && stats_emit_event "${_vr_event}" 2>/dev/null || true
      fi
    fi
  fi

  if [ "${rescued}" != "true" ]; then
    # Fingerprint rescue didn't apply or didn't succeed — original fail_count
    # path runs (Phase 11 1-iii D1 self-heal still escalates to LLM after 4 fails).
    if ! memory_record_failure "${site}" "${archetype_id}" "${arg_intent}" 2>/dev/null; then
      warn "browser-do: cache fail_count update failed (best-effort; action exit unchanged)"
    else
      self_heal_triggered=true
    fi
  fi
fi

duration_ms=$(( $(now_ms) - SUMMARY_T0 ))
_record_event "$(jq -nc --arg site "${site}" --arg arch "${archetype_id}" \
  --arg dv "${arg_verb}" --argjson rc "${dispatch_rc}" \
  '{cache_hit:true, site:$site, archetype_id:$arch,
    dispatched_verb:$dv, dispatch_rc:$rc}')"
summary_json verb=do mode=intent cache_hit=true site="${site}" \
  archetype_id="${archetype_id}" duration_ms="${duration_ms}" \
  dispatched_verb="${arg_verb}" dispatch_rc="${dispatch_rc}" \
  self_heal_triggered="${self_heal_triggered}" status=ok

exit "${dispatch_rc}"
