#!/usr/bin/env bash
# scripts/browser-drag.sh — pointer drag from src element to dst element by ref.
# Usage: bash scripts/browser-drag.sh [--site NAME] [--tool NAME] [--dry-run]
#                                      [--raw] --src-ref eA --dst-ref eB
#
# Routes to chrome-devtools-mcp by default (Phase 6 part 5). Stateful —
# requires running daemon (refMap precondition for BOTH src and dst). MCP
# `drag` tool accepts {src_uid, dst_uid}. Selector-based path is a follow-up
# sub-part if user demand surfaces.

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

src_ref="" dst_ref=""
verb_argv=()
i=0
while [ "${i}" -lt "${#REMAINING_ARGV[@]}" ]; do
  case "${REMAINING_ARGV[i]}" in
    --src-ref)
      src_ref="${REMAINING_ARGV[i+1]:-}"
      [ -n "${src_ref}" ] || die "${EXIT_USAGE_ERROR}" "--src-ref requires a value"
      verb_argv+=(--src-ref "${src_ref}")
      i=$((i + 2))
      ;;
    --dst-ref)
      dst_ref="${REMAINING_ARGV[i+1]:-}"
      [ -n "${dst_ref}" ] || die "${EXIT_USAGE_ERROR}" "--dst-ref requires a value"
      verb_argv+=(--dst-ref "${dst_ref}")
      i=$((i + 2))
      ;;
    *)
      verb_argv+=("${REMAINING_ARGV[i]}")
      i=$((i + 1))
      ;;
  esac
done

[ -n "${src_ref}" ] || die "${EXIT_USAGE_ERROR}" "drag requires --src-ref eN"
[ -n "${dst_ref}" ] || die "${EXIT_USAGE_ERROR}" "drag requires --dst-ref eN"

if [ "${ARG_DRY_RUN:-0}" = "1" ]; then
  ok "dry-run: would drag ${src_ref} → ${dst_ref}"
  emit_summary verb=drag tool=none why=dry-run status=ok \
               src_ref="${src_ref}" dst_ref="${dst_ref}" dry_run=true
  exit 0
fi

picked="$(pick_tool drag "${verb_argv[@]}")"
tool_name="${picked%%$'\t'*}"
why="${picked#*$'\t'}"

source_picked_adapter "${tool_name}"

set +e
adapter_out="$(invoke_with_retry drag "${verb_argv[@]}")"
adapter_rc=$?
set -e

[ -n "${adapter_out}" ] && printf '%s\n' "${adapter_out}"

if [ "${adapter_rc}" -eq 0 ]; then
  emit_summary verb=drag tool="${tool_name}" why="${why}" status=ok \
               src_ref="${src_ref}" dst_ref="${dst_ref}"
  exit 0
fi
emit_summary verb=drag tool="${tool_name}" why="${why}" status=error \
             src_ref="${src_ref}" dst_ref="${dst_ref}"
exit "${adapter_rc}"
