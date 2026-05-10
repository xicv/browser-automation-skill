#!/usr/bin/env bash
# scripts/browser-assert.sh — verify-style assertion verb (Phase 9 part 1-ii).
#
# Usage:
#   bash scripts/browser-assert.sh --selector CSS --text-contains TEXT \
#        [--site NAME] [--tool NAME] [--dry-run]
#
# Thin wrapper: shells to `bash scripts/browser-extract.sh --selector CSS`
# (subprocess; routes through router + chrome-devtools-mcp by default);
# parses the extracted text; bash-side compares against --text-contains
# predicate. NO new tool_assert function on adapters — composition over ABI
# extension (per design doc §6 + plan-doc 2026-05-10-phase-09-part-1-ii §A1).
#
# Exit codes:
#   0  — assertion passed
#   13 — EXIT_ASSERTION_FAILED — predicate did not match
#   2  — EXIT_USAGE_ERROR (missing required flag)
#   1  — EXIT_GENERIC_ERROR (extract subprocess failed)

set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/common.sh"
# shellcheck source=lib/output.sh
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/output.sh"
# shellcheck source=lib/verb_helpers.sh
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/verb_helpers.sh"

init_paths

SUMMARY_T0="$(now_ms)"; export SUMMARY_T0

parse_verb_globals "$@"

selector=""
text_contains=""
i=0
while [ "${i}" -lt "${#REMAINING_ARGV[@]}" ]; do
  case "${REMAINING_ARGV[i]}" in
    --selector)
      selector="${REMAINING_ARGV[i+1]:-}"
      [ -n "${selector}" ] || die "${EXIT_USAGE_ERROR}" "--selector requires a value"
      i=$((i + 2))
      ;;
    --text-contains)
      text_contains="${REMAINING_ARGV[i+1]:-}"
      [ -n "${text_contains}" ] || die "${EXIT_USAGE_ERROR}" "--text-contains requires a value"
      i=$((i + 2))
      ;;
    *)
      i=$((i + 1))
      ;;
  esac
done

[ -n "${selector}" ]      || die "${EXIT_USAGE_ERROR}" "assert requires --selector CSS"
[ -n "${text_contains}" ] || die "${EXIT_USAGE_ERROR}" "assert requires --text-contains TEXT"

if [ "${ARG_DRY_RUN:-0}" = "1" ]; then
  ok "dry-run: would assert selector=${selector} text_contains=${text_contains}"
  emit_summary verb=assert tool=none why=dry-run status=ok \
    selector="${selector}" text_contains="${text_contains}" dry_run=true
  exit 0
fi

# Compose: shell to browser-extract.sh to get the selector's text. The extract
# verb's stdout is one event line + one summary line. We parse the event line.
set +e
extract_out="$(bash "${SCRIPT_DIR}/browser-extract.sh" --selector "${selector}" 2>&1)"
extract_rc=$?
set -e

if [ "${extract_rc}" -ne 0 ]; then
  emit_summary verb=assert tool=extract why=composition status=error \
    selector="${selector}" text_contains="${text_contains}" \
    error="extract subprocess failed (rc=${extract_rc})"
  exit "${EXIT_GENERIC_ERROR}"
fi

# Find the extract event line; collect all matched text. The shipped extract
# event shape is {"event":"extract","selector":"...","matches":["Welcome","Hello"]}
# (matches[] is array of strings — see tests/fixtures/chrome-devtools-mcp/
# 05efe417...json). Fall through to .text for the playwright-cli shape.
got_text="$(
  printf '%s\n' "${extract_out}" \
    | jq -r -s '
        map(select(.event == "extract")) | .[0] |
        (.text // (.matches // []) | if type == "array" then join("\n") else . end)' 2>/dev/null \
    || printf ''
)"

if printf '%s' "${got_text}" | grep -qF -- "${text_contains}"; then
  emit_summary verb=assert tool=extract why=composition status=ok \
    selector="${selector}" text_contains="${text_contains}"
  exit 0
fi

emit_summary verb=assert tool=extract why=composition status=error \
  selector="${selector}" text_contains="${text_contains}" \
  expected="${text_contains}" got="${got_text}"
exit "${EXIT_ASSERTION_FAILED}"
