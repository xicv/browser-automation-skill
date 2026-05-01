#!/usr/bin/env bash
# scripts/browser-snapshot.sh — capture an accessibility snapshot via the
# routed adapter; result is eN-indexed per token-efficient-output spec §5.
# Usage: bash scripts/browser-snapshot.sh [--site NAME] [--tool NAME]
#                                         [--dry-run] [--raw] [--depth N]

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

# Resolve site/session → BROWSER_SKILL_STORAGE_STATE (no-op if neither set).
# Router's rule_session_required reads the env var to prefer playwright-lib.
resolve_session_storage_state

# Verb has no required arg; --depth N is optional and passed through.
verb_argv=("${REMAINING_ARGV[@]}")

if [ "${ARG_DRY_RUN:-0}" = "1" ]; then
  ok "dry-run: would snapshot"
  emit_summary verb=snapshot tool=none why=dry-run status=ok dry_run=true
  exit 0
fi

picked="$(pick_tool snapshot "${verb_argv[@]}")"
tool_name="${picked%%$'\t'*}"
why="${picked#*$'\t'}"

source_picked_adapter "${tool_name}"

set +e
adapter_out="$(tool_snapshot "${verb_argv[@]}")"
adapter_rc=$?
set -e

[ -n "${adapter_out}" ] && printf '%s\n' "${adapter_out}"

if [ "${adapter_rc}" -eq 0 ]; then
  emit_summary verb=snapshot tool="${tool_name}" why="${why}" status=ok
  exit 0
fi
emit_summary verb=snapshot tool="${tool_name}" why="${why}" status=error
exit "${adapter_rc}"
