#!/usr/bin/env bash
# scripts/browser-click.sh — click an element by --ref eN or --selector CSS.
# Usage: bash scripts/browser-click.sh [--site NAME] [--tool NAME] [--dry-run]
#                                      [--raw] (--ref eN | --selector CSS)

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

ref="" selector=""
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
    --selector)
      selector="${REMAINING_ARGV[i+1]:-}"
      [ -n "${selector}" ] || die "${EXIT_USAGE_ERROR}" "--selector requires a value"
      verb_argv+=(--selector "${selector}")
      i=$((i + 2))
      ;;
    *)
      verb_argv+=("${REMAINING_ARGV[i]}")
      i=$((i + 1))
      ;;
  esac
done

if [ -n "${ref}" ] && [ -n "${selector}" ]; then
  die "${EXIT_USAGE_ERROR}" "--ref and --selector are mutually exclusive"
fi
if [ -z "${ref}" ] && [ -z "${selector}" ]; then
  die "${EXIT_USAGE_ERROR}" "click requires --ref eN or --selector CSS"
fi

if [ "${ARG_DRY_RUN:-0}" = "1" ]; then
  ok "dry-run: would click ${ref:-${selector}}"
  emit_summary verb=click tool=none why=dry-run status=ok ref="${ref}" selector="${selector}" dry_run=true
  exit 0
fi

picked="$(pick_tool click "${verb_argv[@]}")"
tool_name="${picked%%$'\t'*}"
why="${picked#*$'\t'}"

source_picked_adapter "${tool_name}"

set +e
adapter_out="$(tool_click "${verb_argv[@]}")"
adapter_rc=$?
set -e

[ -n "${adapter_out}" ] && printf '%s\n' "${adapter_out}"

if [ "${adapter_rc}" -eq 0 ]; then
  emit_summary verb=click tool="${tool_name}" why="${why}" status=ok ref="${ref}" selector="${selector}"
  exit 0
fi
emit_summary verb=click tool="${tool_name}" why="${why}" status=error ref="${ref}" selector="${selector}"
exit "${adapter_rc}"
