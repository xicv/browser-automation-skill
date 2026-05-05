#!/usr/bin/env bash
# scripts/browser-tab-list.sh — enumerate tabs/pages currently held by the daemon.
# Usage: bash scripts/browser-tab-list.sh [--site NAME] [--tool NAME]
#                                          [--dry-run] [--raw]
#
# Routes to chrome-devtools-mcp by default (Phase 6 part 8-i). Daemon-required:
# the verb caches the result in the daemon's `tabs` slot so 8-ii (tab-switch)
# and 8-iii (tab-close) can reference the same `tab_id` shape. Without daemon
# → exit 41 with hint.
#
# Read-only — no flags, no state mutation. The daemon dispatch calls upstream
# MCP `list_pages` (best-effort name; real upstream may differ) and normalizes
# to `[{tab_id, url, title}]`. `tab_id` is bridge-assigned (1-based, stable for
# the lifetime of one list_pages call); upstream's CDP target id never escapes
# the bridge.

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

# tab-list takes no required flags; pass remaining argv straight through so
# routing/capability checks still see globals like --tool.
verb_argv=("${REMAINING_ARGV[@]}")

if [ "${ARG_DRY_RUN:-0}" = "1" ]; then
  ok "dry-run: would enumerate tabs via daemon"
  emit_summary verb=tab-list tool=none why=dry-run status=ok dry_run=true
  exit 0
fi

picked="$(pick_tool tab-list "${verb_argv[@]}")"
tool_name="${picked%%$'\t'*}"
why="${picked#*$'\t'}"

source_picked_adapter "${tool_name}"

set +e
adapter_out="$(invoke_with_retry tab-list "${verb_argv[@]}")"
adapter_rc=$?
set -e

[ -n "${adapter_out}" ] && printf '%s\n' "${adapter_out}"

if [ "${adapter_rc}" -eq 0 ]; then
  emit_summary verb=tab-list tool="${tool_name}" why="${why}" status=ok
  exit 0
fi
emit_summary verb=tab-list tool="${tool_name}" why="${why}" status=error
exit "${adapter_rc}"
