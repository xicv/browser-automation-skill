#!/usr/bin/env bash
# scripts/browser-route.sh — register a network-route rule on the daemon.
# Usage: bash scripts/browser-route.sh [--site NAME] [--tool NAME]
#                                       [--dry-run] [--raw]
#                                       --pattern URL_PATTERN
#                                       --action allow|block
#
# Routes to chrome-devtools-mcp by default (Phase 6 part 7-i). Daemon-state-
# mutating: registers the {pattern, action} rule in the daemon's routeRules
# array. Daemon-required.
#
# Phase 6 part 7-i: action ∈ {allow, block}. fulfill (synthetic responses
# with --status / --body) lands in part 7-ii.

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

pattern="" action=""
verb_argv=()
i=0
while [ "${i}" -lt "${#REMAINING_ARGV[@]}" ]; do
  case "${REMAINING_ARGV[i]}" in
    --pattern)
      pattern="${REMAINING_ARGV[i+1]:-}"
      [ -n "${pattern}" ] || die "${EXIT_USAGE_ERROR}" "--pattern requires a value"
      verb_argv+=(--pattern "${pattern}")
      i=$((i + 2))
      ;;
    --action)
      action="${REMAINING_ARGV[i+1]:-}"
      [ -n "${action}" ] || die "${EXIT_USAGE_ERROR}" "--action requires a value"
      case "${action}" in
        allow|block) ;;
        fulfill) die "${EXIT_USAGE_ERROR}" "route --action fulfill is part 7-ii (deferred); current sub-part supports allow|block only" ;;
        *) die "${EXIT_USAGE_ERROR}" "--action must be one of {allow, block} (got: ${action}); fulfill is part 7-ii" ;;
      esac
      verb_argv+=(--action "${action}")
      i=$((i + 2))
      ;;
    *)
      verb_argv+=("${REMAINING_ARGV[i]}")
      i=$((i + 1))
      ;;
  esac
done

[ -n "${pattern}" ] || die "${EXIT_USAGE_ERROR}" "route requires --pattern URL_PATTERN"
[ -n "${action}" ]  || die "${EXIT_USAGE_ERROR}" "route requires --action (allow|block)"

if [ "${ARG_DRY_RUN:-0}" = "1" ]; then
  ok "dry-run: would register route rule pattern=${pattern} action=${action}"
  emit_summary verb=route tool=none why=dry-run status=ok \
               pattern="${pattern}" action="${action}" dry_run=true
  exit 0
fi

picked="$(pick_tool route "${verb_argv[@]}")"
tool_name="${picked%%$'\t'*}"
why="${picked#*$'\t'}"

source_picked_adapter "${tool_name}"

set +e
adapter_out="$(invoke_with_retry route "${verb_argv[@]}")"
adapter_rc=$?
set -e

[ -n "${adapter_out}" ] && printf '%s\n' "${adapter_out}"

if [ "${adapter_rc}" -eq 0 ]; then
  emit_summary verb=route tool="${tool_name}" why="${why}" status=ok \
               pattern="${pattern}" action="${action}"
  exit 0
fi
emit_summary verb=route tool="${tool_name}" why="${why}" status=error \
             pattern="${pattern}" action="${action}"
exit "${adapter_rc}"
