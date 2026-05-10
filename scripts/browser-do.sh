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

init_paths

SUMMARY_T0="$(now_ms)"

# --- Whitelist: verbs that accept --selector as primary target ---
# v1 = [click]. Other selector-target verbs (fill, hover, press, select)
# currently take only --ref eN — refs are snapshot-relative and can't be
# cached across snapshots. They're added here when their adapter ABI gains
# selector-mode plumbing (a follow-up sub-part).
readonly DO_VERB_WHITELIST=(click)

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
  arg_site="" arg_threshold="3"
  cli_urls=()
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --site)      arg_site="$2";      shift 2 ;;
      --threshold) arg_threshold="$2"; shift 2 ;;
      --url)       cli_urls+=("$2");   shift 2 ;;
      -h|--help)   usage; exit 0 ;;
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
  while IFS= read -r cluster_event; do
    [ -z "${cluster_event}" ] && continue
    printf '%s\n' "${cluster_event}"
    emit_count=$(( emit_count + 1 ))
  done < <(printf '%s' "${cluster_output}" | jq -c \
    --argjson threshold "${arg_threshold}" \
    --argjson known "${known_json}" \
    --arg site "${site}" \
    '.clusters
     | map(select(.count >= $threshold and ([.templated] | inside($known) | not)))
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

  # Count clusters skipped due to "already in patterns.json".
  skipped_known="$(printf '%s' "${cluster_output}" | jq -r \
    --argjson threshold "${arg_threshold}" \
    --argjson known "${known_json}" \
    '.clusters | map(select(.count >= $threshold and ([.templated] | inside($known)))) | length')"

  duration_ms=$(( $(now_ms) - SUMMARY_T0 ))
  summary_json verb=do mode=propose site="${site}" \
    proposals="${emit_count}" skipped_known="${skipped_known}" \
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
  if ! memory_record_failure "${site}" "${archetype_id}" "${arg_intent}" 2>/dev/null; then
    warn "browser-do: cache fail_count update failed (best-effort; action exit unchanged)"
  else
    self_heal_triggered=true
  fi
fi

duration_ms=$(( $(now_ms) - SUMMARY_T0 ))
summary_json verb=do mode=intent cache_hit=true site="${site}" \
  archetype_id="${archetype_id}" duration_ms="${duration_ms}" \
  dispatched_verb="${arg_verb}" dispatch_rc="${dispatch_rc}" \
  self_heal_triggered="${self_heal_triggered}" status=ok

exit "${dispatch_rc}"
