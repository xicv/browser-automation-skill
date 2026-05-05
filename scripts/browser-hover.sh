#!/usr/bin/env bash
# scripts/browser-hover.sh — pointer hover an element by --ref eN.
# Usage: bash scripts/browser-hover.sh [--site NAME] [--tool NAME] [--dry-run]
#                                       [--raw] --ref eN
#
# Routes to chrome-devtools-mcp by default (Phase 6 part 3). Stateful —
# requires running daemon (refMap precondition; mirrors click/select).
# `--selector` path is a follow-up sub-part if user demand surfaces.

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

ref=""
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
    *)
      verb_argv+=("${REMAINING_ARGV[i]}")
      i=$((i + 1))
      ;;
  esac
done

[ -n "${ref}" ] || die "${EXIT_USAGE_ERROR}" "hover requires --ref eN"

if [ "${ARG_DRY_RUN:-0}" = "1" ]; then
  ok "dry-run: would hover ${ref}"
  emit_summary verb=hover tool=none why=dry-run status=ok ref="${ref}" dry_run=true
  exit 0
fi

picked="$(pick_tool hover "${verb_argv[@]}")"
tool_name="${picked%%$'\t'*}"
why="${picked#*$'\t'}"

source_picked_adapter "${tool_name}"

set +e
adapter_out="$(invoke_with_retry hover "${verb_argv[@]}")"
adapter_rc=$?
set -e

[ -n "${adapter_out}" ] && printf '%s\n' "${adapter_out}"

if [ "${adapter_rc}" -eq 0 ]; then
  emit_summary verb=hover tool="${tool_name}" why="${why}" status=ok ref="${ref}"
  exit 0
fi
emit_summary verb=hover tool="${tool_name}" why="${why}" status=error ref="${ref}"
exit "${adapter_rc}"
