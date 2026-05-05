#!/usr/bin/env bash
# scripts/browser-fill.sh — fill an input by --ref eN with --text or --secret-stdin.
# Usage: bash scripts/browser-fill.sh [--site NAME] [--tool NAME] [--dry-run]
#                                     [--raw] --ref eN (--text VALUE | --secret-stdin)
#
# CRITICAL: --secret-stdin reads the secret from this script's stdin and pipes
# it to the adapter; the secret never appears on argv (anti-pattern AP-7).
# Test: tests/browser-fill.bats::secret-not-in-argv.

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
# Router's rule_session_required reads the env var to prefer playwright-lib
# (which natively supports --secret-stdin via stdin-pipe to driver).
resolve_session_storage_state

ref="" text="" use_stdin=0
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
    --text)
      text="${REMAINING_ARGV[i+1]:-}"
      [ -n "${text}" ] || die "${EXIT_USAGE_ERROR}" "--text requires a value"
      verb_argv+=(--text "${text}")
      i=$((i + 2))
      ;;
    --secret-stdin)
      use_stdin=1
      verb_argv+=(--secret-stdin)
      i=$((i + 1))
      ;;
    *)
      verb_argv+=("${REMAINING_ARGV[i]}")
      i=$((i + 1))
      ;;
  esac
done

[ -n "${ref}" ] || die "${EXIT_USAGE_ERROR}" "fill requires --ref eN"
if [ -n "${text}" ] && [ "${use_stdin}" = "1" ]; then
  die "${EXIT_USAGE_ERROR}" "--text and --secret-stdin are mutually exclusive"
fi
if [ -z "${text}" ] && [ "${use_stdin}" = "0" ]; then
  die "${EXIT_USAGE_ERROR}" "fill requires --text VALUE or --secret-stdin"
fi

if [ "${ARG_DRY_RUN:-0}" = "1" ]; then
  ok "dry-run: would fill ${ref}"
  emit_summary verb=fill tool=none why=dry-run status=ok ref="${ref}" dry_run=true
  exit 0
fi

picked="$(pick_tool fill "${verb_argv[@]}")"
tool_name="${picked%%$'\t'*}"
why="${picked#*$'\t'}"

source_picked_adapter "${tool_name}"

# stdin (if --secret-stdin) flows through to tool_fill -> adapter binary.
# Capture stdout in subshell; stdin inherits naturally.
set +e
adapter_out="$(invoke_with_retry fill "${verb_argv[@]}")"
adapter_rc=$?
set -e

[ -n "${adapter_out}" ] && printf '%s\n' "${adapter_out}"

if [ "${adapter_rc}" -eq 0 ]; then
  emit_summary verb=fill tool="${tool_name}" why="${why}" status=ok ref="${ref}"
  exit 0
fi
emit_summary verb=fill tool="${tool_name}" why="${why}" status=error ref="${ref}"
exit "${adapter_rc}"
