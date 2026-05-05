#!/usr/bin/env bash
# scripts/browser-extract.sh — extract content via CSS selector or arbitrary JS.
# Usage: bash scripts/browser-extract.sh [--site NAME] [--tool NAME] [--dry-run]
#                                        [--raw] (--selector CSS | --eval JS)
#
# Routes to chrome-devtools-mcp by default (post-1d router promotion — only
# adapter with `evaluate_script` + `list_network_requests` per parent spec
# Appendix B). `--scrape <urls...>` would route to obscura when Phase 8 lands.
# Exactly one of --selector / --eval is required (both is acceptable too).

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

selector="" eval_js=""
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
    --eval)
      eval_js="${REMAINING_ARGV[i+1]:-}"
      [ -n "${eval_js}" ] || die "${EXIT_USAGE_ERROR}" "--eval requires a value"
      verb_argv+=(--eval "${eval_js}")
      i=$((i + 2))
      ;;
    *)
      verb_argv+=("${REMAINING_ARGV[i]}")
      i=$((i + 1))
      ;;
  esac
done

if [ -z "${selector}" ] && [ -z "${eval_js}" ]; then
  die "${EXIT_USAGE_ERROR}" "extract requires --selector CSS or --eval JS"
fi

if [ "${ARG_DRY_RUN:-0}" = "1" ]; then
  ok "dry-run: would extract ${selector:-${eval_js}}"
  emit_summary verb=extract tool=none why=dry-run status=ok selector="${selector}" dry_run=true
  exit 0
fi

picked="$(pick_tool extract "${verb_argv[@]}")"
tool_name="${picked%%$'\t'*}"
why="${picked#*$'\t'}"

source_picked_adapter "${tool_name}"

set +e
adapter_out="$(tool_extract "${verb_argv[@]}")"
adapter_rc=$?
set -e

[ -n "${adapter_out}" ] && printf '%s\n' "${adapter_out}"

if [ "${adapter_rc}" -eq 0 ]; then
  emit_summary verb=extract tool="${tool_name}" why="${why}" status=ok selector="${selector}"
  exit 0
fi
emit_summary verb=extract tool="${tool_name}" why="${why}" status=error selector="${selector}"
exit "${adapter_rc}"
