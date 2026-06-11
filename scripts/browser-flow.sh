#!/usr/bin/env bash
# scripts/browser-flow.sh — flow runner verb (Phase 9 part 1-i).
#
# Usage:
#   bash scripts/browser-flow.sh run <flow-file> [--var key=val ...] [--dry-run]
#
# Sub-modes (current):
#   run   — execute a .flow.yaml file end-to-end (this PR)
# Sub-modes (planned):
#   record — wrap `playwright codegen` (9-1-iii)
#
# Capture composition (per design doc 2026-05-10-phase-09-flow-runner-design §3 F4):
#   one capture per flow run; per-step events streamed to ${CAPTURE_DIR}/steps.jsonl;
#   meta.json carries verb=flow + flow_name + step_count + successful_steps +
#   failed_steps + status (ok / partial / error).

set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="${SCRIPT_DIR}"
export SCRIPTS_DIR

# shellcheck source=lib/common.sh
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/common.sh"
# shellcheck source=lib/output.sh
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/output.sh"
# shellcheck source=lib/capture.sh
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/capture.sh"
# shellcheck source=lib/flow.sh
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/flow.sh"

init_paths

SUMMARY_T0="$(now_ms)"; export SUMMARY_T0

sub_mode="${1:-}"
[ -n "${sub_mode}" ] || die "${EXIT_USAGE_ERROR}" "browser-flow: missing sub-mode (use 'run')"
shift

case "${sub_mode}" in
  run) ;;
  record)
    # Phase 9 part 1-iii: wraps `playwright codegen <url>`; transforms emitted
    # JS → flow YAML; writes ${OUT} mode 0600. Privacy canary on recorder
    # write side: passwords detected via /password/i name match, replaced
    # with ${secrets.password} placeholder.
    # shellcheck source=lib/flow_record.sh
    # shellcheck disable=SC1091
    source "${SCRIPT_DIR}/lib/flow_record.sh"

    record_url=""
    record_out=""
    record_name=""
    record_tool=""
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --url)  record_url="$2"; shift 2 ;;
        --out)  record_out="$2"; shift 2 ;;
        --name) record_name="$2"; shift 2 ;;
        --tool) record_tool="$2"; shift 2 ;;
        --site) shift 2 ;;  # accepted; site resolution deferred
        *)      die "${EXIT_USAGE_ERROR}" "browser-flow record: unknown flag '$1'" ;;
      esac
    done

    # Per locked decision W1: codegen targets Playwright/Chrome; obscura's
    # stateless one-shot model has no interactive recording surface.
    if [ "${record_tool}" = "obscura" ]; then
      die "${EXIT_USAGE_ERROR}" "browser-flow record: recorder does not support obscura (codegen targets Playwright; obscura is stateless one-shot — no interactive recording surface)"
    fi

    # Per locked decision O1: --out is REQUIRED.
    [ -n "${record_out}" ] || die "${EXIT_USAGE_ERROR}" "browser-flow record: --out FILE is required"
    [ -n "${record_url}" ] || die "${EXIT_USAGE_ERROR}" "browser-flow record: --url URL is required (or --site NAME — deferred to follow-up)"

    # Path security: realpath canonicalize + sensitive-pattern reject. Mirror
    # references/recipes/path-security.md.
    record_out_dir="$(dirname "${record_out}")"
    [ -d "${record_out_dir}" ] || mkdir -p "${record_out_dir}"
    record_out_abs="$(cd "${record_out_dir}" && pwd)/$(basename "${record_out}")"
    case "${record_out_abs}" in
      */.ssh/*|*/.aws/*|*/.gnupg/*|*/.netrc*|*/private_key*|*/id_rsa*|*/id_ed25519*)
        die "${EXIT_USAGE_ERROR}" "browser-flow record: --out path matches sensitive pattern (refusing): ${record_out_abs}"
        ;;
    esac

    # Default flow name = basename of --out (sans .flow.yaml).
    [ -z "${record_name}" ] && record_name="$(basename "${record_out}" .flow.yaml)"

    # Spawn codegen (or mock via env-var override).
    codegen_bin="${PLAYWRIGHT_CODEGEN_BIN:-}"
    if [ -z "${codegen_bin}" ]; then
      codegen_bin="$(command -v playwright || true)"
      [ -z "${codegen_bin}" ] && die "${EXIT_PREFLIGHT_FAILED}" "playwright not found on PATH (set PLAYWRIGHT_CODEGEN_BIN to override)"
      codegen_args=(codegen --target javascript "${record_url}")
    else
      codegen_args=()
    fi

    # Capture codegen stdout. Real codegen blocks until user closes the headed
    # window; mock exits immediately.
    set +e
    codegen_js="$("${codegen_bin}" "${codegen_args[@]}" 2>/dev/null)"
    codegen_rc=$?
    set -e
    if [ "${codegen_rc}" -ne 0 ]; then
      die "${EXIT_TOOL_CRASHED}" "playwright codegen failed (rc=${codegen_rc})"
    fi

    # Transform JS → YAML. flow_record_transform sets globals
    # FLOW_RECORD_PASSWORD_REDACTIONS + FLOW_RECORD_STEP_COUNT.
    yaml_out="$(printf '%s' "${codegen_js}" | flow_record_transform "${record_name}" 2>/tmp/flow-record-stderr-$$.log)"
    redaction_msgs="$(cat /tmp/flow-record-stderr-$$.log 2>/dev/null || true)"
    rm -f /tmp/flow-record-stderr-$$.log
    [ -n "${redaction_msgs}" ] && printf '%s\n' "${redaction_msgs}" >&2

    # Write to --out, mode 0600.
    tmp="${record_out_abs}.tmp.$$"
    printf '%s' "${yaml_out}" > "${tmp}"
    chmod 600 "${tmp}"
    mv "${tmp}" "${record_out_abs}"

    emit_summary verb=flow tool=playwright-cli why=record status=ok mode=record \
      flow_name="${record_name}" out_file="${record_out_abs}" \
      step_count="${FLOW_RECORD_STEP_COUNT}" \
      password_redactions="${FLOW_RECORD_PASSWORD_REDACTIONS}"
    exit 0
    ;;
  *)    die "${EXIT_USAGE_ERROR}" "browser-flow: unknown sub-mode '${sub_mode}'" ;;
esac

flow_file="${1:-}"
[ -n "${flow_file}" ] || die "${EXIT_USAGE_ERROR}" "browser-flow run: missing <flow-file>"
shift

# Path security: realpath canonicalize. Reject sensitive patterns. Per recipe
# references/recipes/path-security.md.
if [ ! -f "${flow_file}" ]; then
  alt="${BROWSER_SKILL_HOME}/flows/${flow_file}"
  if [ -f "${alt}" ]; then
    flow_file="${alt}"
  else
    die "${EXIT_USAGE_ERROR}" "flow file not found: ${flow_file}"
  fi
fi
flow_file_abs="$(cd "$(dirname "${flow_file}")" && pwd)/$(basename "${flow_file}")"
case "${flow_file_abs}" in
  */.ssh/*|*/.aws/*|*/.gnupg/*|*/.netrc*|*/private_key*|*/id_rsa*|*/id_ed25519*)
    die "${EXIT_USAGE_ERROR}" "flow file path matches sensitive pattern (refusing): ${flow_file_abs}"
    ;;
esac

cli_var_overrides=()
dry_run=0
continue_on_error=0
check_only=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --var)
      [ -n "${2:-}" ] || die "${EXIT_USAGE_ERROR}" "--var requires key=val"
      cli_var_overrides+=("$2")
      shift 2
      ;;
    --dry-run)
      dry_run=1
      shift
      ;;
    --continue-on-error)
      continue_on_error=1
      shift
      ;;
    --check)
      check_only=1
      shift
      ;;
    *)
      die "${EXIT_USAGE_ERROR}" "browser-flow run: unknown flag '$1'"
      ;;
  esac
done

# Reset flow state in this shell.
declare -gA FLOW_VARS=()
declare -gA FLOW_REFS=()
FLOW_NAME=""
FLOW_SITE=""
FLOW_SESSION=""

# Parse the flow file → captures _meta line + per-step lines on stdout.
parsed="$(flow_parse "${flow_file_abs}")"

# Extract _meta line (first one with _kind=="meta").
meta_line="$(printf '%s\n' "${parsed}" | jq -c -s 'map(select(._kind=="meta")) | .[0]' 2>/dev/null || printf 'null')"
[ "${meta_line}" = "null" ] && die "${EXIT_GENERIC_ERROR}" "flow_parse: missing _meta line in output"
FLOW_NAME="$(printf '%s' "${meta_line}" | jq -r '.name')"
FLOW_SITE="$(printf '%s' "${meta_line}" | jq -r '.site // ""')"
FLOW_SESSION="$(printf '%s' "${meta_line}" | jq -r '.session // ""')"
[ -z "${FLOW_SITE}" ] || assert_safe_name "${FLOW_SITE}" "flow site"
[ -z "${FLOW_SESSION}" ] || assert_safe_name "${FLOW_SESSION}" "flow session"

# Hydrate FLOW_VARS from _meta.vars (file-defined defaults).
while IFS=$'\t' read -r k v; do
  [ -z "${k}" ] && continue
  FLOW_VARS["${k}"]="${v}"
done <<< "$(printf '%s' "${meta_line}" | jq -r '.vars | to_entries[]? | "\(.key)\t\(.value)"')"

# Apply CLI --var overrides (after parse, so they win over file vars:).
for ov in "${cli_var_overrides[@]}"; do
  case "${ov}" in
    *=*) FLOW_VARS["${ov%%=*}"]="${ov#*=}" ;;
    *)   die "${EXIT_USAGE_ERROR}" "--var requires key=val (got: ${ov})" ;;
  esac
done

# Extract step lines.
steps_jsonl="$(printf '%s\n' "${parsed}" | jq -c 'select(._kind=="step")')"
step_count=$(printf '%s\n' "${steps_jsonl}" | grep -c '^.' || printf '0')

# Pre-flight: validate every step verb against existing browser-<verb>.sh scripts
# BEFORE executing step 1 (P0b fix). Unknown verb → EXIT_USAGE_ERROR with the
# step index, bad verb, and the valid verb list.
_flow_valid_verbs() {
  local scripts_dir="${SCRIPTS_DIR:-${REPO_ROOT:-.}/scripts}"
  local verbs=() f verb
  for f in "${scripts_dir}"/browser-*.sh; do
    [ -f "${f}" ] || continue
    verb="$(basename "${f}" .sh)"
    verb="${verb#browser-}"
    case "${verb}" in
      flow) continue ;;  # exclude flow itself
    esac
    verbs+=("${verb}")
  done
  printf '%s\n' "${verbs[@]}" | sort
}

while IFS= read -r _pf_step; do
  [ -z "${_pf_step}" ] && continue
  _pf_verb="$(printf '%s' "${_pf_step}" | jq -r '.verb')"
  _pf_idx="$(printf '%s' "${_pf_step}" | jq -r '.step_index')"
  _pf_script="${SCRIPTS_DIR:-${REPO_ROOT:-.}/scripts}/browser-${_pf_verb}.sh"
  if [ ! -f "${_pf_script}" ]; then
    _valid_verbs="$(_flow_valid_verbs | tr '\n' ' ')"
    die "${EXIT_USAGE_ERROR}" \
      "flow preflight: step ${_pf_idx} uses unknown verb '${_pf_verb}' (valid: ${_valid_verbs})"
  fi
done <<< "${steps_jsonl}"

if [ "${dry_run}" = "1" ]; then
  # Dry-run pre-pass: substitute vars (with refs-mode=skip since no snapshot
  # has actually run); print the planned step list. Per Phase 9 part 1-ii:
  # ${refs.NAME} stays literal in dry-run output (FLOW_REFS would be empty
  # anyway).
  while IFS= read -r step_line; do
    [ -z "${step_line}" ] && continue
    flow_apply_vars "${step_line}" skip
  done <<< "${steps_jsonl}"
  emit_summary verb=flow tool=none why=dry-run status=ok mode=run \
    flow_name="${FLOW_NAME}" step_count="${step_count}" dry_run=true
  exit 0
fi

# --check: parse + preflight (already done above) + print normalized step plan
# then exit 0 without executing anything (P0b fix).
if [ "${check_only}" = "1" ]; then
  printf '%s\n' "${steps_jsonl}"
  emit_summary verb=flow tool=none why=check status=ok mode=run \
    flow_name="${FLOW_NAME}" step_count="${step_count}"
  exit 0
fi

# Real run: capture pipeline + per-step dispatch with mid-flow ref resolution.
capture_start "flow"
# Append flow_name into meta.json (additive; no schema bump per design F4).
meta="${CAPTURE_DIR}/meta.json"
tmp="${meta}.tmp.$$"
jq --arg n "${FLOW_NAME}" '.flow_name = $n' "${meta}" > "${tmp}"
chmod 600 "${tmp}"
mv "${tmp}" "${meta}"

steps_log="${CAPTURE_DIR}/steps.jsonl"
: > "${steps_log}"
chmod 600 "${steps_log}"

successful_steps=0
failed_steps=0
last_exit=0
while IFS= read -r step_line; do
  [ -z "${step_line}" ] && continue
  # Per-step substitution AT EXECUTION TIME — FLOW_REFS may have just been
  # populated by the prior snapshot step. flow_apply_vars defaults to
  # refs-mode=strict (fail loud on missing ref).
  set +e
  substituted_step="$(flow_apply_vars "${step_line}")"
  apply_rc=$?
  set -e
  if [ "${apply_rc}" -ne 0 ]; then
    # flow_apply_vars already emitted the error message via die. Surface
    # the failure as a step-event + abort the flow.
    evt="$(jq -nc \
      --argjson step_index "$(printf '%s' "${step_line}" | jq '.step_index')" \
      --arg     verb       "$(printf '%s' "${step_line}" | jq -r '.verb')" \
      --argjson exit_code  "${apply_rc}" \
      --arg     status     "error" \
      --arg     error      "var/ref substitution failed" \
      '{step_index: $step_index, verb: $verb, status: $status, exit_code: $exit_code, error: $error}')"
    printf '%s\n' "${evt}" >> "${steps_log}"
    failed_steps=$((failed_steps + 1))
    last_exit="${apply_rc}"
    break
  fi

  evt="$(flow_dispatch "${substituted_step}")"
  printf '%s\n' "${evt}" >> "${steps_log}"
  status="$(printf '%s' "${evt}" | jq -r '.status')"
  if [ "${status}" = "ok" ]; then
    successful_steps=$((successful_steps + 1))
  else
    failed_steps=$((failed_steps + 1))
    last_exit="$(printf '%s' "${evt}" | jq -r '.exit_code')"
    [ "${last_exit}" = "null" ] || [ -z "${last_exit}" ] && last_exit="${EXIT_GENERIC_ERROR}"
    # Abort on first failure unless --continue-on-error is set (P0b fix).
    if [ "${continue_on_error}" = "0" ]; then
      break
    fi
  fi

  # Phase 9 part 1-ii: harvest step.refs into FLOW_REFS (latest-wins).
  refs_for_step="$(printf '%s' "${evt}" | jq -c '.refs // null')"
  if [ "${refs_for_step}" != "null" ]; then
    # Reset FLOW_REFS wholesale (latest-snapshot-wins).
    FLOW_REFS=()
    while IFS=$'\t' read -r ref_text ref_id; do
      [ -z "${ref_text}" ] && continue
      FLOW_REFS["${ref_text}"]="${ref_id}"
    done <<< "$(printf '%s' "${refs_for_step}" | jq -r '.[] | "\(.text)\t\(.ref)"')"
  fi
done <<< "${steps_jsonl}"

# Determine overall flow status.
if [ "${failed_steps}" = "0" ]; then
  flow_status="ok"
elif [ "${successful_steps}" = "0" ]; then
  flow_status="error"
else
  flow_status="partial"
fi

# Append per-flow counts to meta.json.
tmp="${meta}.tmp.$$"
jq \
  --argjson sc "${step_count}" \
  --argjson ss "${successful_steps}" \
  --argjson fs "${failed_steps}" \
  '. + {step_count: $sc, successful_steps: $ss, failed_steps: $fs}' \
  "${meta}" > "${tmp}"
chmod 600 "${tmp}"
mv "${tmp}" "${meta}"

capture_finish "${flow_status}" true

emit_summary verb=flow tool=none why=run status="${flow_status}" mode=run \
  flow_name="${FLOW_NAME}" capture_id="${CAPTURE_ID}" \
  step_count="${step_count}" successful_steps="${successful_steps}" failed_steps="${failed_steps}"

if [ "${flow_status}" = "ok" ]; then
  exit 0
fi
exit "${last_exit}"
