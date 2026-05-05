#!/usr/bin/env bash
# scripts/browser-press.sh — keyboard press via the picked adapter.
# Usage: bash scripts/browser-press.sh [--site NAME] [--tool NAME] [--dry-run]
#                                       [--raw] --key KEY
#
# Routes to chrome-devtools-mcp by default (Phase 6 part 1 introduces press
# via cdt-mcp; playwright-cli/lib don't declare press today). KEY is a
# Playwright/CDP key name like "Enter", "Tab", "Escape", "ArrowDown",
# "Cmd+S", "PageDown".

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

key=""
verb_argv=()
i=0
while [ "${i}" -lt "${#REMAINING_ARGV[@]}" ]; do
  case "${REMAINING_ARGV[i]}" in
    --key)
      key="${REMAINING_ARGV[i+1]:-}"
      [ -n "${key}" ] || die "${EXIT_USAGE_ERROR}" "--key requires a value"
      verb_argv+=(--key "${key}")
      i=$((i + 2))
      ;;
    *)
      verb_argv+=("${REMAINING_ARGV[i]}")
      i=$((i + 1))
      ;;
  esac
done

[ -n "${key}" ] || die "${EXIT_USAGE_ERROR}" "press requires --key KEY (e.g. --key Enter)"

if [ "${ARG_DRY_RUN:-0}" = "1" ]; then
  ok "dry-run: would press ${key}"
  emit_summary verb=press tool=none why=dry-run status=ok key="${key}" dry_run=true
  exit 0
fi

picked="$(pick_tool press "${verb_argv[@]}")"
tool_name="${picked%%$'\t'*}"
why="${picked#*$'\t'}"

source_picked_adapter "${tool_name}"

set +e
adapter_out="$(invoke_with_retry press "${verb_argv[@]}")"
adapter_rc=$?
set -e

[ -n "${adapter_out}" ] && printf '%s\n' "${adapter_out}"

if [ "${adapter_rc}" -eq 0 ]; then
  emit_summary verb=press tool="${tool_name}" why="${why}" status=ok key="${key}"
  exit 0
fi
emit_summary verb=press tool="${tool_name}" why="${why}" status=error key="${key}"
exit "${adapter_rc}"
