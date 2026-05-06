#!/usr/bin/env bash
# scripts/browser-tab-close.sh — close a tab in the daemon-held browser.
# Usage: bash scripts/browser-tab-close.sh [--site NAME] [--tool NAME]
#                                           [--dry-run] [--raw]
#                                           (--tab-id N | --by-url-pattern STR)
#
# Routes to chrome-devtools-mcp by default (Phase 6 part 8-iii). Daemon-required.
# Splices the matching entry from the daemon's tabs[] cache + asks upstream MCP
# to close the page. If the closed tab matches `currentTab`, the pointer is
# nulled (`current_tab_id: null` in subsequent tab-list output).
#
# Mutex: exactly one of --tab-id (canonical 1-based id from tab-list output) or
# --by-url-pattern (substring-contains, first-match-wins, mirrors tab-switch).
#
# Why --tab-id instead of --by-index: by the time agents reach tab-close, they
# already hold a tab_id from tab-list. Positional indexing would drift across
# successive closes; canonical id is unambiguous.

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

tab_id="" by_url_pattern=""
verb_argv=()
i=0
while [ "${i}" -lt "${#REMAINING_ARGV[@]}" ]; do
  case "${REMAINING_ARGV[i]}" in
    --tab-id)
      tab_id="${REMAINING_ARGV[i+1]:-}"
      [ -n "${tab_id}" ] || die "${EXIT_USAGE_ERROR}" "--tab-id requires a value"
      verb_argv+=(--tab-id "${tab_id}")
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
if [ -n "${tab_id}" ] && [ -n "${by_url_pattern}" ]; then
  die "${EXIT_USAGE_ERROR}" "--tab-id and --by-url-pattern are mutually exclusive"
fi
if [ -z "${tab_id}" ] && [ -z "${by_url_pattern}" ]; then
  die "${EXIT_USAGE_ERROR}" "tab-close requires exactly one of --tab-id N or --by-url-pattern STR"
fi

# Validate tab_id is a positive integer (1-based).
if [ -n "${tab_id}" ]; then
  if ! printf '%s' "${tab_id}" | grep -Eq '^[1-9][0-9]*$'; then
    die "${EXIT_USAGE_ERROR}" "--tab-id must be a positive integer (1-based); got: ${tab_id}"
  fi
fi

if [ "${ARG_DRY_RUN:-0}" = "1" ]; then
  if [ -n "${tab_id}" ]; then
    ok "dry-run: would close tab #${tab_id}"
    emit_summary verb=tab-close tool=none why=dry-run status=ok tab_id="${tab_id}" dry_run=true
  else
    ok "dry-run: would close first tab matching ${by_url_pattern}"
    emit_summary verb=tab-close tool=none why=dry-run status=ok by_url_pattern="${by_url_pattern}" dry_run=true
  fi
  exit 0
fi

picked="$(pick_tool tab-close "${verb_argv[@]}")"
tool_name="${picked%%$'\t'*}"
why="${picked#*$'\t'}"

source_picked_adapter "${tool_name}"

set +e
adapter_out="$(invoke_with_retry tab-close "${verb_argv[@]}")"
adapter_rc=$?
set -e

[ -n "${adapter_out}" ] && printf '%s\n' "${adapter_out}"

if [ "${adapter_rc}" -eq 0 ]; then
  emit_summary verb=tab-close tool="${tool_name}" why="${why}" status=ok
  exit 0
fi
emit_summary verb=tab-close tool="${tool_name}" why="${why}" status=error
exit "${adapter_rc}"
