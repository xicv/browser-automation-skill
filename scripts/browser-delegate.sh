#!/usr/bin/env bash
# scripts/browser-delegate.sh
# Phase 15 part 1 — delegated agent-loop verb (ship-dark, explicit-invoke only).
#
# Hands a whole multi-step web task to an out-of-process agent (Webwright)
# driven by a SECONDARY LLM (e.g. GLM via its Anthropic-compatible endpoint),
# so the observe-execute-inspect token cost lands on the secondary-LLM budget,
# NOT on Claude Code's context. Claude sees only this dispatch + a compact
# summary — never the intermediate trajectory.
#
# Phase 1 scope: NO-AUTH tasks only. Refuses any --site that has stored
# credentials (credential/session bridge deferred — see
# docs/superpowers/specs/2026-05-29-phase-15-webwright-delegate-adapter.md §5).
#
# The router NEVER auto-selects this verb; it is a higher-order orchestration
# verb (peer to browser-flow / browser-do / browser-replay), not a primitive
# adapter. See spec §3.

set -euo pipefail
IFS=$'\n\t'
umask 077

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
# shellcheck source=lib/credential.sh
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/credential.sh"

init_paths
SUMMARY_T0="$(now_ms)"

readonly _DELEGATE_WEBWRIGHT_DIR_DEFAULT="${HOME}/tools/Webwright"
# Privacy canary sentinel (shared with browser-do). If the delegated run's
# workspace contains this literal, refuse to surface the result. Not a real
# secret detector — backs the privacy-canary regression test (spec §6).
readonly _DELEGATE_CANARY_SENTINEL='PASSWORD-CANARY'

# Delegation policy modes (config sub-mode). Default 'off' → fully opt-in, so
# users without Webwright/GLM see zero behavior change.
readonly _DELEGATE_DEFAULT_MODE="off"
readonly _DELEGATE_MODES="off ask auto"

_delegate_webwright_env_file() {
  if [ -n "${MSWEBA_GLOBAL_CONFIG_DIR:-}" ]; then
    printf '%s/.env' "${MSWEBA_GLOBAL_CONFIG_DIR}"
    return 0
  fi
  case "$(uname -s)" in
    Darwin) printf '%s/Library/Application Support/webwright/.env' "${HOME}" ;;
    *)      printf '%s/.config/webwright/.env' "${HOME}" ;;
  esac
}

_delegate_env_has_key() {
  local env_file
  env_file="$(_delegate_webwright_env_file)"
  [ -f "${env_file}" ] || return 1
  grep -Eq '^[[:space:]]*ANTHROPIC_API_KEY=[^[:space:]]+' "${env_file}" 2>/dev/null
}

_delegate_site_has_credentials() {
  local site="$1" name meta cred_site
  [ -d "${CREDENTIALS_DIR}" ] || return 1
  [ -f "${CREDENTIALS_DIR}/${site}.json" ] && return 0
  for name in $(credential_list_names); do
    meta="$(credential_load "${name}" 2>/dev/null)" || continue
    cred_site="$(printf '%s' "${meta}" | jq -r '.site // ""' 2>/dev/null || printf '')"
    [ "${cred_site}" = "${site}" ] && return 0
  done
  return 1
}

usage() {
  cat <<'USAGE'
Usage:
  browser-delegate --task "..." --start-url URL [options]
  browser-delegate --start-url URL < task.txt           # task via stdin

Options:
  --task TEXT        natural-language task (or pipe it via stdin)
  --start-url URL    starting URL (required)
  --task-id NAME     output folder name (default: delegate-<epoch>)
  --site NAME        no-auth site context; REFUSED if the site has creds
  --max-steps N      step budget hint (forwarded to the backend)
  --backend NAME     delegated backend (default + only: webwright)
  --dry-run          print the resolved command + output path; spawn nothing
  -h, --help

Phase 1: NO-AUTH tasks only. The agent loop runs out-of-process on a secondary
LLM; Claude Code sees only this dispatch + a compact summary.
USAGE
}

# ---------- config sub-mode (opt-in delegation policy) ----------
# Policy lives in ${CONFIG_FILE} under .delegate. Default mode is 'off' so
# users who never opted in get identical behavior to before this verb existed.
_delegate_backend_available() {
  local ww="${BROWSER_SKILL_WEBWRIGHT_DIR:-${_DELEGATE_WEBWRIGHT_DIR_DEFAULT}}"
  [ -n "${BROWSER_DELEGATE_RUNNER_CMD:-}" ] && return 0
  [ -d "${ww}" ] && [ -f "${ww}/.venv/bin/activate" ] && _delegate_env_has_key
}

_delegate_config_get() {
  local cfg='{}'
  [ -f "${CONFIG_FILE}" ] && cfg="$(cat "${CONFIG_FILE}" 2>/dev/null || printf '{}')"
  local avail=false
  _delegate_backend_available && avail=true
  local ww="${BROWSER_SKILL_WEBWRIGHT_DIR:-${_DELEGATE_WEBWRIGHT_DIR_DEFAULT}}"
  local env_file
  env_file="$(_delegate_webwright_env_file)"
  printf '%s' "${cfg}" | jq -c \
    --arg defmode "${_DELEGATE_DEFAULT_MODE}" \
    --argjson avail "${avail}" \
    --arg ww "${ww}" \
    --arg env_file "${env_file}" '
    (.delegate // {}) as $d
    | { _kind:"delegate_policy",
        mode: ($d.mode // $defmode),
        backend: ($d.backend // "webwright"),
        min_steps: ($d.min_steps // 3),
        auto_exclude: ($d.auto_exclude // ["auth"]),
        available: $avail,
        webwright_dir: $ww,
        webwright_env_file: $env_file }'
  emit_summary verb=delegate tool=config why="resolved delegation policy" status=ok
}

_delegate_config_set() {
  local set_mode="" set_backend="" set_min="" set_exclude="" changed=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --mode)      set_mode="$2";    changed=1; shift 2 ;;
      --backend)   set_backend="$2"; changed=1; shift 2 ;;
      --min-steps) set_min="$2";     changed=1; shift 2 ;;
      --exclude)   set_exclude="$2"; changed=1; shift 2 ;;
      -h|--help)   usage; exit 0 ;;
      *) die "${EXIT_USAGE_ERROR}" "browser-delegate config set: unknown flag '$1'" ;;
    esac
  done
  [ "${changed}" = "1" ] || die "${EXIT_USAGE_ERROR}" "browser-delegate config set: nothing to set (use --mode|--backend|--min-steps|--exclude)"
  if [ -n "${set_mode}" ] && [[ " ${_DELEGATE_MODES} " != *" ${set_mode} "* ]]; then
    die "${EXIT_USAGE_ERROR}" "browser-delegate config set: --mode '${set_mode}' invalid (expected: ${_DELEGATE_MODES})"
  fi
  if [ -n "${set_min}" ] && ! [[ "${set_min}" =~ ^[0-9]+$ ]]; then
    die "${EXIT_USAGE_ERROR}" "browser-delegate config set: --min-steps must be a non-negative integer"
  fi

  mkdir -p "${BROWSER_SKILL_HOME}"
  chmod 700 "${BROWSER_SKILL_HOME}" 2>/dev/null || true
  local cur='{}'
  [ -f "${CONFIG_FILE}" ] && cur="$(cat "${CONFIG_FILE}" 2>/dev/null || printf '{}')"

  local patch
  patch="$(jq -nc \
    --arg mode "${set_mode}" \
    --arg backend "${set_backend}" \
    --arg min "${set_min}" \
    --arg exclude "${set_exclude}" '
    {}
    | (if $mode    != "" then .mode = $mode else . end)
    | (if $backend != "" then .backend = $backend else . end)
    | (if $min     != "" then .min_steps = ($min | tonumber) else . end)
    | (if $exclude != "" then .auto_exclude = ($exclude | split(",") | map(select(. != ""))) else . end)')"

  local merged
  merged="$(printf '%s' "${cur}" | jq --argjson p "${patch}" '.delegate = ((.delegate // {}) + $p)')" \
    || die "${EXIT_GENERIC_ERROR}" "browser-delegate config set: failed to merge (is ${CONFIG_FILE} valid JSON?)"

  local tmp
  tmp="$(mktemp "${BROWSER_SKILL_HOME}/.config.json.XXXXXX")"
  printf '%s\n' "${merged}" > "${tmp}"
  mv "${tmp}" "${CONFIG_FILE}"
  chmod 600 "${CONFIG_FILE}" 2>/dev/null || true

  _delegate_config_get
}

_delegate_config() {
  local action="${1:-get}"
  case "${action}" in
    get) shift || true; _delegate_config_get ;;
    set) shift; _delegate_config_set "$@" ;;
    -h|--help) usage; exit 0 ;;
    *) die "${EXIT_USAGE_ERROR}" "browser-delegate config: unknown action '${action}' (expected 'get' or 'set')" ;;
  esac
}

# Early dispatch: `browser-delegate config ...` short-circuits task handling.
if [ "${1:-}" = "config" ]; then
  shift
  _delegate_config "$@"
  exit 0
fi

arg_task="" arg_start_url="" arg_task_id="" arg_site="" arg_max_steps=""
arg_backend="webwright" arg_dry_run="false"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --task)       arg_task="$2";       shift 2 ;;
    --start-url)  arg_start_url="$2";   shift 2 ;;
    --task-id)    arg_task_id="$2";     shift 2 ;;
    --site)       arg_site="$2";        shift 2 ;;
    --max-steps)  arg_max_steps="$2";   shift 2 ;;
    --backend)    arg_backend="$2";     shift 2 ;;
    --dry-run)    arg_dry_run="true";   shift ;;
    -h|--help)    usage; exit 0 ;;
    *) die "${EXIT_USAGE_ERROR}" "browser-delegate: unknown flag '$1'" ;;
  esac
done

# Task from stdin when not passed via flag and stdin is piped (not a TTY).
if [ -z "${arg_task}" ] && [ ! -t 0 ]; then
  arg_task="$(cat)"
fi

[ -n "${arg_task}" ]      || { usage >&2; die "${EXIT_USAGE_ERROR}" "browser-delegate: --task required (flag or stdin)"; }
[ -n "${arg_start_url}" ] || { usage >&2; die "${EXIT_USAGE_ERROR}" "browser-delegate: --start-url required"; }

if [ "${arg_backend}" != "webwright" ]; then
  die "${EXIT_USAGE_ERROR}" "browser-delegate: --backend '${arg_backend}' unsupported (phase 1: webwright only)"
fi

# Quiet shellcheck: --max-steps is accepted now, forwarded to the backend in a
# later phase (budget plumbing). Referenced here so it is not "unused".
: "${arg_max_steps:=}"

task_id="${arg_task_id}"
if [ -z "${task_id}" ]; then
  task_id="delegate-$(date -u +%Y%m%d%H%M%S)"
fi
assert_safe_name "${task_id}" "task-id"

# --- Phase 1 no-auth guard: refuse credentialed sites (spec §5) ---
if [ -n "${arg_site}" ]; then
  assert_safe_name "${arg_site}" "site-name"
  if _delegate_site_has_credentials "${arg_site}"; then
    die "${EXIT_BLOCKLIST_REJECTED}" "browser-delegate: refused — site '${arg_site}' has stored credentials; phase 1 is NO-AUTH only (credential bridge deferred, spec §5). Run an anonymous task or omit --site."
  fi
fi

ww_dir="${BROWSER_SKILL_WEBWRIGHT_DIR:-${_DELEGATE_WEBWRIGHT_DIR_DEFAULT}}"
runner_override="${BROWSER_DELEGATE_RUNNER_CMD:-}"
out_dir="${BROWSER_SKILL_HOME}/delegate"

real_cmd_str="(cd '${ww_dir}' && source .venv/bin/activate && python <task-file-runner> --start-url '${arg_start_url}' --task-id '${task_id}' -o '${out_dir}')"

# --- dry-run: print resolved plan, spawn nothing ---
if [ "${arg_dry_run}" = "true" ]; then
  jq -nc --arg cmd "${real_cmd_str}" --arg out "${out_dir}" --arg ww "${ww_dir}" \
    --arg backend "${arg_backend}" --arg sid "${task_id}" \
    '{_kind:"dry_run", backend:$backend, task_id:$sid, webwright_dir:$ww, output_dir:$out, command:$cmd}'
  emit_summary verb=delegate tool="${arg_backend}" why="dry-run (no spawn)" \
    status=ok task_id="${task_id}" dry_run=true
  exit 0
fi

mkdir -p "${out_dir}"
chmod 700 "${out_dir}" 2>/dev/null || true

# --- Preflight: backend present (skipped when a test runner override is set) ---
if [ -z "${runner_override}" ]; then
  if [ ! -d "${ww_dir}" ] || [ ! -f "${ww_dir}/.venv/bin/activate" ]; then
    die "${EXIT_TOOL_MISSING}" "browser-delegate: Webwright not found at '${ww_dir}'. Setup guide: references/webwright-setup.md (clone + venv + pip install -e . + playwright install + GLM key). Or set BROWSER_SKILL_WEBWRIGHT_DIR to an existing install."
  fi
  if ! _delegate_env_has_key; then
    die "${EXIT_PREFLIGHT_FAILED}" "browser-delegate: ANTHROPIC_API_KEY not found in '$(_delegate_webwright_env_file)' (required by Webwright model_claude.yaml for GLM/Anthropic-compatible delegation)"
  fi
fi

task_file="$(mktemp "${out_dir}/${task_id}.task.XXXXXX")"
printf '%s' "${arg_task}" > "${task_file}"
chmod 600 "${task_file}" 2>/dev/null || true

# Real backend invocation, isolated so the SC1091 (can't follow venv activate)
# disable is scoped tightly. Reads outer vars by dynamic scope.
_delegate_run_real() {
  # shellcheck disable=SC1091
  cd "${ww_dir}" && source .venv/bin/activate \
    && python - "${task_file}" "${arg_start_url}" "${task_id}" "${out_dir}" <<'PY'
from pathlib import Path
import sys

from webwright.run.cli import run_one

task_path, start_url, task_id, out_dir = sys.argv[1:5]
run_one(
    task=Path(task_path).read_text(encoding="utf-8"),
    task_id=task_id,
    start_url=start_url,
    config_spec=["base.yaml", "model_claude.yaml"],
    output_dir=Path(out_dir),
)
PY
}

# Capture stdout (the final answer) so the canary scan runs BEFORE we surface it.
runner_rc=0
if [ -n "${runner_override}" ]; then
  runner_stdout="$("${runner_override}" "${task_file}" "${arg_start_url}" "${task_id}" "${out_dir}" 2>/dev/null)" || runner_rc=$?
else
  runner_stdout="$(_delegate_run_real 2>/dev/null)" || runner_rc=$?
fi
rm -f "${task_file}" 2>/dev/null || true

# Locate the run directory the backend created (newest lexical match = newest ts).
run_dir=""
shopt -s nullglob
for d in "${out_dir}/${task_id}"*/; do
  run_dir="${d%/}"
done
shopt -u nullglob

# --- Privacy-canary gate: scan workspace + captured stdout BEFORE surfacing (spec §6) ---
canary_hit="false"
if [ -n "${run_dir}" ] && [ -d "${run_dir}" ]; then
  if grep -rqF -- "${_DELEGATE_CANARY_SENTINEL}" "${run_dir}" 2>/dev/null; then
    canary_hit="true"
  fi
fi
case "${runner_stdout}" in
  *"${_DELEGATE_CANARY_SENTINEL}"*) canary_hit="true" ;;
esac
if [ "${canary_hit}" = "true" ]; then
  die "${EXIT_BLOCKLIST_REJECTED}" "browser-delegate: refused — delegated run contains the privacy canary sentinel; result withheld (privacy guard, spec §6). Inspect ${run_dir} manually."
fi

# --- Parse offloaded token + step metrics from the trajectory ---
traj="${run_dir}/trajectory.json"
offloaded_in=0 offloaded_out=0 offloaded_cached=0 backend_model="unknown"
if [ -n "${run_dir}" ] && [ -f "${traj}" ]; then
  offloaded_in="$(jq -r '.model.usage.cumulative_response.input_tokens // 0' "${traj}" 2>/dev/null || printf '0')"
  offloaded_out="$(jq -r '.model.usage.cumulative_response.output_tokens // 0' "${traj}" 2>/dev/null || printf '0')"
  offloaded_cached="$(jq -r '.model.usage.cumulative_response.cached_input_tokens // 0' "${traj}" 2>/dev/null || printf '0')"
  backend_model="$(jq -r '.model.config.model_name // "unknown"' "${traj}" 2>/dev/null || printf 'unknown')"
fi
[[ "${offloaded_in}"     =~ ^[0-9]+$ ]] || offloaded_in=0
[[ "${offloaded_out}"    =~ ^[0-9]+$ ]] || offloaded_out=0
[[ "${offloaded_cached}" =~ ^[0-9]+$ ]] || offloaded_cached=0

steps=0
if [ -n "${run_dir}" ] && [ -d "${run_dir}/debug/steps" ]; then
  shopt -s nullglob
  step_files=("${run_dir}/debug/steps/"step_*.json)
  steps="${#step_files[@]}"
  shopt -u nullglob
fi

if [ "${runner_rc}" -eq 0 ]; then
  status="ok"; outcome="success"; exit_code="${EXIT_OK}"
else
  status="error"; outcome="fail"; exit_code="${EXIT_TOOL_CRASHED}"
fi
duration_ms=$(( $(now_ms) - SUMMARY_T0 ))
delegate_stdout_bytes=0
_saved_lc="${LC_ALL-}"
LC_ALL=C
delegate_stdout_bytes=${#runner_stdout}
if [ -z "${_saved_lc}" ]; then
  unset LC_ALL
else
  LC_ALL="${_saved_lc}"
fi

# --- Telemetry: delegate event with OFFLOADED token fields, kept distinct from
# gen_ai_usage_* (Claude-context tokens). spec §7. Best-effort. ---
_span_id="$(stats_random_id 2>/dev/null || printf '')"
_ts="$(stats_now_iso_ms 2>/dev/null || printf '')"
if [ -n "${_span_id}" ] && [ -n "${_ts}" ]; then
  _ev="$(jq -nc \
    --argjson schema_version 1 \
    --arg ts "${_ts}" --arg span_id "${_span_id}" \
    --arg trace_id "${BROWSER_SKILL_TRACE_ID:-${_span_id}}" \
    --arg verb "delegate" \
    --arg backend "${arg_backend}" \
    --arg model "${backend_model}" \
    --arg site "${arg_site}" \
    --argjson duration_ms "${duration_ms}" \
    --argjson stdout_bytes "${delegate_stdout_bytes}" \
    --argjson rc "${runner_rc}" \
    --arg outcome "${outcome}" \
    --argjson steps "${steps}" \
    --argjson off_in "${offloaded_in}" \
    --argjson off_out "${offloaded_out}" \
    --argjson off_cached "${offloaded_cached}" '
    { schema_version: $schema_version, ts: $ts, span_id: $span_id, trace_id: $trace_id,
      parent_span_id: null, session_id: null,
      gen_ai_operation_name: "invoke_agent",
      gen_ai_tool_name: ("browser-delegate." + $backend),
      gen_ai_tool_type: "function",
      verb: $verb,
      adapter_route: "browser-delegate",
      delegate_backend: $backend,
      delegate_model: ($model | select(. != "" and . != "unknown") // null),
      delegate_steps: $steps,
      site: ($site | select(. != "") // null),
      selector_kind: "none",
      selector_value: null,
      duration_ms: $duration_ms,
      argv_bytes: 0,
      stdout_bytes: $stdout_bytes,
      stderr_bytes: 0,
      rc: $rc, outcome: $outcome, failure_mode: null,
      offloaded_input_tokens: $off_in,
      offloaded_output_tokens: $off_out,
      offloaded_cached_input_tokens: $off_cached
    }' 2>/dev/null || printf '')"
  [ -n "${_ev}" ] && stats_emit_event "${_ev}" 2>/dev/null || true
fi

# --- Surface the COMPACT result (final answer + workspace), never the trajectory.
# Failure output is intentionally withheld: failed delegated runs can print
# partial page text, prompts, or model diagnostics that have not passed the
# success-path contract.
if [ "${runner_rc}" -eq 0 ]; then
  jq -nc \
    --arg fr "${runner_stdout}" \
    --arg ws "${run_dir}" \
    --arg backend "${arg_backend}" \
    --arg model "${backend_model}" \
    --argjson steps "${steps}" \
    --argjson off_in "${offloaded_in}" \
    --argjson off_out "${offloaded_out}" '
    {_kind:"delegate_result", backend:$backend,
     model:($model|select(.!="" and .!="unknown")//null),
     workspace:($ws|select(.!="")//null), steps:$steps,
     offloaded_input_tokens:$off_in, offloaded_output_tokens:$off_out,
     final_response:$fr}'
else
  jq -nc \
    --arg ws "${run_dir}" \
    --arg backend "${arg_backend}" \
    --arg model "${backend_model}" \
    --argjson steps "${steps}" \
    --argjson rc "${runner_rc}" \
    --argjson off_in "${offloaded_in}" \
    --argjson off_out "${offloaded_out}" '
    {_kind:"delegate_error", backend:$backend,
     model:($model|select(.!="" and .!="unknown")//null),
     workspace:($ws|select(.!="")//null), steps:$steps, runner_rc:$rc,
     offloaded_input_tokens:$off_in, offloaded_output_tokens:$off_out}'
fi

emit_summary verb=delegate tool="${arg_backend}" why="delegated agent loop on secondary LLM; tokens offloaded off Claude context" \
  status="${status}" task_id="${task_id}" steps="${steps}" \
  offloaded_input_tokens="${offloaded_in}" offloaded_output_tokens="${offloaded_out}" \
  offloaded_cached_input_tokens="${offloaded_cached}" \
  backend="${arg_backend}" model="${backend_model}" \
  duration_ms="${duration_ms}"

exit "${exit_code}"
