#!/usr/bin/env bash
# scripts/browser-select.sh — pick an option from a <select> element by ref.
# Usage: bash scripts/browser-select.sh [--site NAME] [--tool NAME]
#                                        [--dry-run] [--raw] --ref eN
#                                        (--value V | --label L | --index N)
#
# Routes to chrome-devtools-mcp by default (Phase 6 part 2). Stateful —
# requires a running daemon (refMap precondition; same shape as click/fill).

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

ref="" value="" label="" index=""
mode_count=0
verb_argv=()
i=0
while [ "${i}" -lt "${#REMAINING_ARGV[@]}" ]; do
  case "${REMAINING_ARGV[i]}" in
    --ref)
      ref="${REMAINING_ARGV[i+1]:-}"
      [ -n "${ref}" ] || die "${EXIT_USAGE_ERROR}" "--ref requires a value"
      verb_argv+=(--ref "${ref}")
      i=$((i + 2))
      ;;
    --value)
      value="${REMAINING_ARGV[i+1]:-}"
      [ -n "${value}" ] || die "${EXIT_USAGE_ERROR}" "--value requires a value"
      verb_argv+=(--value "${value}")
      mode_count=$((mode_count + 1))
      i=$((i + 2))
      ;;
    --label)
      label="${REMAINING_ARGV[i+1]:-}"
      [ -n "${label}" ] || die "${EXIT_USAGE_ERROR}" "--label requires a value"
      verb_argv+=(--label "${label}")
      mode_count=$((mode_count + 1))
      i=$((i + 2))
      ;;
    --index)
      index="${REMAINING_ARGV[i+1]:-}"
      [ -n "${index}" ] || die "${EXIT_USAGE_ERROR}" "--index requires a value"
      verb_argv+=(--index "${index}")
      mode_count=$((mode_count + 1))
      i=$((i + 2))
      ;;
    *)
      verb_argv+=("${REMAINING_ARGV[i]}")
      i=$((i + 1))
      ;;
  esac
done

[ -n "${ref}" ] || die "${EXIT_USAGE_ERROR}" "select requires --ref eN"
if [ "${mode_count}" -eq 0 ]; then
  die "${EXIT_USAGE_ERROR}" "select requires one of --value, --label, or --index"
fi
if [ "${mode_count}" -gt 1 ]; then
  die "${EXIT_USAGE_ERROR}" "select: --value / --label / --index are mutually exclusive"
fi

if [ "${ARG_DRY_RUN:-0}" = "1" ]; then
  ok "dry-run: would select ${ref} (value=${value}, label=${label}, index=${index})"
  emit_summary verb=select tool=none why=dry-run status=ok ref="${ref}" \
               value="${value}" label="${label}" index="${index}" dry_run=true
  exit 0
fi

picked="$(pick_tool select "${verb_argv[@]}")"
tool_name="${picked%%$'\t'*}"
why="${picked#*$'\t'}"

source_picked_adapter "${tool_name}"

set +e
adapter_out="$(invoke_with_retry select "${verb_argv[@]}")"
adapter_rc=$?
set -e

[ -n "${adapter_out}" ] && printf '%s\n' "${adapter_out}"

if [ "${adapter_rc}" -eq 0 ]; then
  emit_summary verb=select tool="${tool_name}" why="${why}" status=ok ref="${ref}"
  exit 0
fi
emit_summary verb=select tool="${tool_name}" why="${why}" status=error ref="${ref}"
exit "${adapter_rc}"
