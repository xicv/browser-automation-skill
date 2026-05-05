#!/usr/bin/env bash
# scripts/browser-wait.sh — explicit wait for element state.
# Usage: bash scripts/browser-wait.sh [--site NAME] [--tool NAME] [--dry-run]
#                                      [--raw] --selector CSS
#                                      [--state visible|hidden|attached|detached]
#                                      [--timeout MS]
#
# Routes to chrome-devtools-mcp by default (Phase 6 part 4). Stateless —
# works one-shot or daemon-routed (parallel to eval/audit/snapshot).

set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/common.sh"
# shellcheck source=lib/output.sh
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/output.sh"
# shellcheck source=lib/router.sh
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/router.sh"
# shellcheck source=lib/verb_helpers.sh
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/verb_helpers.sh"

init_paths

SUMMARY_T0="$(now_ms)"; export SUMMARY_T0

parse_verb_globals "$@"

resolve_session_storage_state

selector="" state="" timeout=""
verb_argv=()
i=0
while [ "${i}" -lt "${#REMAINING_ARGV[@]}" ]; do
  case "${REMAINING_ARGV[i]}" in
    --selector)
      selector="${REMAINING_ARGV[i+1]:-}"
      [ -n "${selector}" ] || die "${EXIT_USAGE_ERROR}" "--selector requires a value"
      verb_argv+=(--selector "${selector}")
      i=$((i + 2))
      ;;
    --state)
      state="${REMAINING_ARGV[i+1]:-}"
      [ -n "${state}" ] || die "${EXIT_USAGE_ERROR}" "--state requires a value"
      case "${state}" in
        visible|hidden|attached|detached) ;;
        *) die "${EXIT_USAGE_ERROR}" "--state must be one of {visible, hidden, attached, detached} (got: ${state})" ;;
      esac
      verb_argv+=(--state "${state}")
      i=$((i + 2))
      ;;
    --timeout)
      timeout="${REMAINING_ARGV[i+1]:-}"
      [ -n "${timeout}" ] || die "${EXIT_USAGE_ERROR}" "--timeout requires a value (milliseconds)"
      verb_argv+=(--timeout "${timeout}")
      i=$((i + 2))
      ;;
    *)
      verb_argv+=("${REMAINING_ARGV[i]}")
      i=$((i + 1))
      ;;
  esac
done

[ -n "${selector}" ] || die "${EXIT_USAGE_ERROR}" "wait requires --selector CSS"

if [ "${ARG_DRY_RUN:-0}" = "1" ]; then
  ok "dry-run: would wait for ${selector} (state=${state:-visible}, timeout=${timeout:-default})"
  emit_summary verb=wait tool=none why=dry-run status=ok selector="${selector}" \
               state="${state}" timeout="${timeout}" dry_run=true
  exit 0
fi

picked="$(pick_tool wait "${verb_argv[@]}")"
tool_name="${picked%%$'\t'*}"
why="${picked#*$'\t'}"

source_picked_adapter "${tool_name}"

set +e
adapter_out="$(invoke_with_retry wait "${verb_argv[@]}")"
adapter_rc=$?
set -e

[ -n "${adapter_out}" ] && printf '%s\n' "${adapter_out}"

if [ "${adapter_rc}" -eq 0 ]; then
  emit_summary verb=wait tool="${tool_name}" why="${why}" status=ok selector="${selector}"
  exit 0
fi
emit_summary verb=wait tool="${tool_name}" why="${why}" status=error selector="${selector}"
exit "${adapter_rc}"
