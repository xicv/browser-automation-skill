#!/usr/bin/env bash
# scripts/browser-tab-switch.sh — switch the daemon's active tab.
# Usage: bash scripts/browser-tab-switch.sh [--site NAME] [--tool NAME]
#                                            [--dry-run] [--raw]
#                                            (--by-index N | --by-url-pattern STR)
#
# Routes to chrome-devtools-mcp by default (Phase 6 part 8-ii). Daemon-required:
# the daemon updates its `currentTab` pointer (added in this sub-part) and asks
# the upstream MCP to focus the corresponding page. Without daemon → exit 41.
#
# Mutex: exactly one of --by-index / --by-url-pattern. --by-index is 1-based
# (matches `tab_id` from tab-list). --by-url-pattern is substring-contains
# (case-sensitive, first match wins).
#
# If the daemon's tabs[] cache is empty (no preceding tab-list call), the
# daemon transparently auto-calls list_pages before resolving the selector.

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

by_index="" by_url_pattern=""
verb_argv=()
i=0
while [ "${i}" -lt "${#REMAINING_ARGV[@]}" ]; do
  case "${REMAINING_ARGV[i]}" in
    --by-index)
      by_index="${REMAINING_ARGV[i+1]:-}"
      [ -n "${by_index}" ] || die "${EXIT_USAGE_ERROR}" "--by-index requires a value"
      verb_argv+=(--by-index "${by_index}")
      i=$((i + 2))
      ;;
    --by-url-pattern)
      by_url_pattern="${REMAINING_ARGV[i+1]:-}"
      [ -n "${by_url_pattern}" ] || die "${EXIT_USAGE_ERROR}" "--by-url-pattern requires a value"
      verb_argv+=(--by-url-pattern "${by_url_pattern}")
      i=$((i + 2))
      ;;
    *)
      verb_argv+=("${REMAINING_ARGV[i]}")
      i=$((i + 1))
      ;;
  esac
done

# Mutex + presence: exactly one selector required.
if [ -n "${by_index}" ] && [ -n "${by_url_pattern}" ]; then
  die "${EXIT_USAGE_ERROR}" "--by-index and --by-url-pattern are mutually exclusive"
fi
if [ -z "${by_index}" ] && [ -z "${by_url_pattern}" ]; then
  die "${EXIT_USAGE_ERROR}" "tab-switch requires exactly one of --by-index N or --by-url-pattern STR"
fi

# Validate by-index is a positive integer (1-based).
if [ -n "${by_index}" ]; then
  if ! printf '%s' "${by_index}" | grep -Eq '^[1-9][0-9]*$'; then
    die "${EXIT_USAGE_ERROR}" "--by-index must be a positive integer (1-based); got: ${by_index}"
  fi
fi

if [ "${ARG_DRY_RUN:-0}" = "1" ]; then
  if [ -n "${by_index}" ]; then
    ok "dry-run: would switch to tab #${by_index}"
    emit_summary verb=tab-switch tool=none why=dry-run status=ok by_index="${by_index}" dry_run=true
  else
    ok "dry-run: would switch to first tab matching ${by_url_pattern}"
    emit_summary verb=tab-switch tool=none why=dry-run status=ok by_url_pattern="${by_url_pattern}" dry_run=true
  fi
  exit 0
fi

picked="$(pick_tool tab-switch "${verb_argv[@]}")"
tool_name="${picked%%$'\t'*}"
why="${picked#*$'\t'}"

source_picked_adapter "${tool_name}"

set +e
adapter_out="$(invoke_with_retry tab-switch "${verb_argv[@]}")"
adapter_rc=$?
set -e

[ -n "${adapter_out}" ] && printf '%s\n' "${adapter_out}"

if [ "${adapter_rc}" -eq 0 ]; then
  emit_summary verb=tab-switch tool="${tool_name}" why="${why}" status=ok
  exit 0
fi
emit_summary verb=tab-switch tool="${tool_name}" why="${why}" status=error
exit "${adapter_rc}"
