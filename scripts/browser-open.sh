#!/usr/bin/env bash
# scripts/browser-open.sh — open a URL via the routed adapter.
# Usage: bash scripts/browser-open.sh [--site NAME] [--tool NAME] [--dry-run]
#                                     [--raw] --url <URL>
# Emits one streaming JSON line per adapter event (if any), then a single
# JSON summary line. See docs/superpowers/specs/2026-04-27-browser-automation-skill-design.md §5.4
# and docs/superpowers/specs/2026-05-01-token-efficient-adapter-output-design.md §3.

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

url=""
verb_argv=()
i=0
while [ "${i}" -lt "${#REMAINING_ARGV[@]}" ]; do
  case "${REMAINING_ARGV[i]}" in
    --url)
      url="${REMAINING_ARGV[i+1]:-}"
      [ -n "${url}" ] || die "${EXIT_USAGE_ERROR}" "--url requires a value"
      verb_argv+=(--url "${url}")
      i=$((i + 2))
      ;;
    *)
      verb_argv+=("${REMAINING_ARGV[i]}")
      i=$((i + 1))
      ;;
  esac
done

[ -n "${url}" ] || die "${EXIT_USAGE_ERROR}" "--url <URL> is required"

if [ "${ARG_DRY_RUN:-0}" = "1" ]; then
  ok "dry-run: would open ${url}"
  emit_summary verb=open tool=none why=dry-run status=ok url="${url}" dry_run=true
  exit 0
fi

picked="$(pick_tool open "${verb_argv[@]}")"
tool_name="${picked%%$'\t'*}"
why="${picked#*$'\t'}"

source_picked_adapter "${tool_name}"

set +e
adapter_out="$(tool_open "${verb_argv[@]}")"
adapter_rc=$?
set -e

[ -n "${adapter_out}" ] && printf '%s\n' "${adapter_out}"

if [ "${adapter_rc}" -eq 0 ]; then
  emit_summary verb=open tool="${tool_name}" why="${why}" status=ok url="${url}"
  exit 0
fi
emit_summary verb=open tool="${tool_name}" why="${why}" status=error url="${url}"
exit "${adapter_rc}"
