#!/usr/bin/env bash
# scripts/browser-audit.sh — run a Lighthouse / perf-trace audit.
# Usage: bash scripts/browser-audit.sh [--site NAME] [--tool NAME] [--dry-run]
#                                      [--raw] [--lighthouse] [--perf-trace]
#
# Routes to chrome-devtools-mcp by default (post-1d router promotion — only
# adapter with `lighthouse_audit` and `performance_*` MCP tools per parent
# spec Appendix B). `--lighthouse` is the implicit default; `--perf-trace`
# can coexist.

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

verb_argv=("${REMAINING_ARGV[@]}")

# Default to --lighthouse when neither flag is provided. Adapter still sees
# the flag in argv so router rules + capability filter can react.
if ! _has_flag --lighthouse "${verb_argv[@]}" && ! _has_flag --perf-trace "${verb_argv[@]}"; then
  verb_argv+=(--lighthouse)
fi

if [ "${ARG_DRY_RUN:-0}" = "1" ]; then
  ok "dry-run: would run audit"
  emit_summary verb=audit tool=none why=dry-run status=ok dry_run=true
  exit 0
fi

picked="$(pick_tool audit "${verb_argv[@]}")"
tool_name="${picked%%$'\t'*}"
why="${picked#*$'\t'}"

source_picked_adapter "${tool_name}"

set +e
adapter_out="$(tool_audit "${verb_argv[@]}")"
adapter_rc=$?
set -e

[ -n "${adapter_out}" ] && printf '%s\n' "${adapter_out}"

if [ "${adapter_rc}" -eq 0 ]; then
  emit_summary verb=audit tool="${tool_name}" why="${why}" status=ok
  exit 0
fi
emit_summary verb=audit tool="${tool_name}" why="${why}" status=error
exit "${adapter_rc}"
